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
  v_attending_count integer;
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

  select count(*), count(*) filter (where attending)
  into v_answered_count, v_attending_count
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
    or v_answered_count <> v_published_count
    or v_attending_count = 0 then
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

create or replace function public.get_registration(p_query_code_hash text)
returns table (
  registration_id uuid,
  serial_no bigint,
  full_name text,
  district_id integer,
  record_status text,
  can_change boolean,
  choices jsonb
)
language sql
security invoker
set search_path = ''
as $$
  select registration.id,
    registration.serial_no,
    registration.full_name,
    registration.district_id,
    registration.record_status,
    settings.is_registration_open
      and (settings.registration_deadline_at is null or settings.registration_deadline_at > now()),
    coalesce(
      jsonb_agg(
        jsonb_build_object(
          'activity_id', activity.id,
          'title', activity.title,
          'attending', choice.attending
        ) order by activity.sort_order
      ) filter (where activity.id is not null),
      '[]'::jsonb
    )
  from public.registrations registration
  cross join public.site_settings settings
  left join public.activities activity on activity.is_published
  left join public.registration_choices choice
    on choice.registration_id = registration.id and choice.activity_id = activity.id
  where registration.query_code_hash = p_query_code_hash
    and registration.record_status <> 'duplicate_void'
  group by registration.id, settings.is_registration_open, settings.registration_deadline_at;
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
  v_attending_count integer;
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
  select count(*), count(*) filter (where attending)
  into v_answered_count, v_attending_count
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
    or v_answered_count <> v_published_count
    or v_attending_count = 0 then
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
  if p_status = 'active' and not exists (
    select 1 from public.registration_choices
    where registration_id = v_registration.id and attending
  ) then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
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

create or replace function public.check_query_availability()
returns boolean
language sql
security invoker
set search_path = ''
as $$
  select suspended_at is null from public.query_attempts where id;
$$;

create or replace function public.record_query_result(p_success boolean)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_now timestamptz := now();
  v_state public.query_attempts%rowtype;
begin
  select * into v_state from public.query_attempts where id for update;

  if v_state.suspended_at is not null then return false; end if;
  if p_success then return true; end if;

  if v_state.window_started_at < v_now - interval '10 minutes' then
    update public.query_attempts
    set window_started_at = v_now, failed_count = 1;
    return true;
  end if;

  update public.query_attempts
  set failed_count = failed_count + 1,
      suspended_at = case when failed_count + 1 >= 30 then v_now else null end;

  return v_state.failed_count + 1 < 30;
end;
$$;

create or replace function public.reset_registration_query_code(
  p_serial_no bigint,
  p_query_code_hash text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration_id uuid;
begin
  if p_query_code_hash !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'INVALID_QUERY_CODE_HASH';
  end if;

  select id into v_registration_id
  from public.registrations
  where serial_no = p_serial_no and record_status <> 'duplicate_void'
  for update;

  if not found then return false; end if;

  update public.registrations
  set query_code_hash = p_query_code_hash, updated_at = now()
  where id = v_registration_id;

  insert into public.audit_events (actor_type, action, target_type, target_id)
  values ('maintenance', 'registration.query_code_reset', 'registration', v_registration_id);

  return true;
end;
$$;

create or replace function public.reset_query_protection()
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.query_attempts
  set window_started_at = now(), failed_count = 0, suspended_at = null
  where id;

  insert into public.audit_events (actor_type, action, target_type)
  values ('maintenance', 'query_protection.reset', 'system');
end;
$$;

revoke execute on function public.create_registration(uuid, text, integer, text, jsonb) from public, anon, authenticated;
revoke execute on function public.get_registration(text) from public, anon, authenticated;
revoke execute on function public.update_registration(text, text, integer, jsonb) from public, anon, authenticated;
revoke execute on function public.set_registration_status(text, text) from public, anon, authenticated;
revoke execute on function public.check_query_availability() from public, anon, authenticated;
revoke execute on function public.record_query_result(boolean) from public, anon, authenticated;
revoke execute on function public.reset_registration_query_code(bigint, text) from public, anon, authenticated;
revoke execute on function public.reset_query_protection() from public, anon, authenticated;

grant execute on function public.create_registration(uuid, text, integer, text, jsonb) to service_role;
grant execute on function public.get_registration(text) to service_role;
grant execute on function public.update_registration(text, text, integer, jsonb) to service_role;
grant execute on function public.set_registration_status(text, text) to service_role;
grant execute on function public.check_query_availability() to service_role;
grant execute on function public.record_query_result(boolean) to service_role;
grant execute on function public.reset_registration_query_code(bigint, text) to service_role;
grant execute on function public.reset_query_protection() to service_role;

commit;
