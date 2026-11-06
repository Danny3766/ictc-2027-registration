begin;

create or replace function public.create_registration(
  p_request_id uuid,
  p_full_name text,
  p_district_id integer,
  p_query_code_hash text,
  p_choices jsonb
)
returns table (registration_id uuid, serial_no bigint)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration_id uuid;
  v_serial_no bigint;
  v_published_count integer;
  v_answered_count integer;
begin
  if not exists (
    select 1 from public.site_settings
    where id and is_registration_open
      and (registration_deadline_at is null or registration_deadline_at > now())
  ) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;

  if length(btrim(p_full_name)) not between 1 and 100 then
    raise exception using errcode = '22023', message = 'INVALID_NAME';
  end if;

  if not exists (
    select 1 from public.districts where id = p_district_id and is_active
  ) then
    raise exception using errcode = '22023', message = 'INVALID_DISTRICT';
  end if;

  if jsonb_typeof(p_choices) <> 'array' then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;

  select count(*) into v_published_count
  from public.activities where is_published;

  select count(*) into v_answered_count
  from (
    select distinct (choice->>'activity_id')::bigint as activity_id,
      (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
    where choice ? 'activity_id' and choice ? 'attending'
  ) answers
  join public.activities activity on activity.id = answers.activity_id
  where activity.is_published;

  if v_published_count = 0
    or jsonb_array_length(p_choices) <> v_published_count
    or v_answered_count <> v_published_count then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;

  insert into public.registrations (
    create_request_id, full_name, district_id, query_code_hash
  ) values (
    p_request_id, btrim(p_full_name), p_district_id, p_query_code_hash
  )
  returning id, registrations.serial_no into v_registration_id, v_serial_no;

  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  join public.activities activity on activity.id = (choice->>'activity_id')::bigint
  where activity.is_published;

  insert into public.audit_events (actor_type, action, target_type, target_id, after_data)
  values ('public', 'registration.created', 'registration', v_registration_id,
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id));

  return query select v_registration_id, v_serial_no;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where create_request_id = p_request_id) then
      raise exception using errcode = '23505', message = 'DUPLICATE_REQUEST';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

create or replace function public.update_registration(
  p_query_code_hash text,
  p_full_name text,
  p_district_id integer,
  p_choices jsonb
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
  v_published_count integer;
  v_answered_count integer;
begin
  if not exists (
    select 1 from public.site_settings
    where id and is_registration_open
      and (registration_deadline_at is null or registration_deadline_at > now())
  ) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;

  select * into v_registration
  from public.registrations
  where query_code_hash = p_query_code_hash and record_status <> 'duplicate_void'
  for update;

  if not found then return false; end if;
  if length(btrim(p_full_name)) not between 1 and 100 then
    raise exception using errcode = '22023', message = 'INVALID_NAME';
  end if;
  if not exists (select 1 from public.districts where id = p_district_id and is_active) then
    raise exception using errcode = '22023', message = 'INVALID_DISTRICT';
  end if;
  if jsonb_typeof(p_choices) <> 'array' then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;

  select count(*) into v_published_count from public.activities where is_published;
  select count(*) into v_answered_count
  from (
    select distinct (choice->>'activity_id')::bigint as activity_id,
      (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
    where choice ? 'activity_id' and choice ? 'attending'
  ) answers
  join public.activities activity on activity.id = answers.activity_id
  where activity.is_published;

  if v_published_count = 0
    or jsonb_array_length(p_choices) <> v_published_count
    or v_answered_count <> v_published_count then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;

  update public.registrations set
    full_name = btrim(p_full_name),
    district_id = p_district_id,
    import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = v_registration.id;

  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration.id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  join public.activities activity on activity.id = (choice->>'activity_id')::bigint
  where activity.is_published
  on conflict (registration_id, activity_id) do update
    set attending = excluded.attending, updated_at = now();

  insert into public.audit_events (actor_type, action, target_type, target_id, before_data, after_data)
  values ('public', 'registration.updated', 'registration', v_registration.id,
    jsonb_build_object('full_name', v_registration.full_name, 'district_id', v_registration.district_id),
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id));

  return true;
exception
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

create or replace function public.set_registration_status(
  p_query_code_hash text,
  p_status text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
begin
  if p_status not in ('active', 'cancelled') then
    raise exception using errcode = '22023', message = 'INVALID_STATUS';
  end if;
  if not exists (
    select 1 from public.site_settings
    where id and is_registration_open
      and (registration_deadline_at is null or registration_deadline_at > now())
  ) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;

  select * into v_registration
  from public.registrations
  where query_code_hash = p_query_code_hash and record_status <> 'duplicate_void'
  for update;

  if not found then return false; end if;
  if p_status = 'active' and exists (
    select 1 from public.activities activity
    where activity.is_published and not exists (
      select 1 from public.registration_choices choice
      where choice.registration_id = v_registration.id and choice.activity_id = activity.id
    )
  ) then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;

  update public.registrations set
    record_status = p_status,
    import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = v_registration.id;

  insert into public.audit_events (actor_type, action, target_type, target_id, before_data, after_data)
  values ('public', 'registration.' || p_status, 'registration', v_registration.id,
    jsonb_build_object('record_status', v_registration.record_status),
    jsonb_build_object('record_status', p_status));

  return true;
end;
$$;

update public.activities set
  description = '暫定 10:30–11:00 之間開始；確切時間待確認。用餐後前往台北大巨蛋。'
where category = 'meal' and title = '週六午餐';

update public.activities set
  description = '暫定 19:00–20:30；確切時間待確認。'
where category = 'meal' and title = '週六晚餐';

update public.activities set
  venue = '玉喜飯店',
  address = '台北市忠孝東路四段 289 號 3 樓',
  description = '12:40 散會後前往；確切用餐時間待確認。'
where category = 'meal' and title = '主日午餐';

update public.activities set
  venue = '三十八會所',
  address = '台北市忠孝東路一段 150 號',
  description = '是否舉行待確認；活動時間、帶菜方式及菜色分配待公告。'
where category = 'other' and title = '主日晚間帶菜愛筵';
commit;
