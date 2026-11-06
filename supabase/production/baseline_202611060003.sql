-- 正式環境初始建置：依檔名順序串接 supabase/migrations 的 16 支 migration，包成單一交易。
-- 只在全新的正式 Supabase 專案執行一次；測試專案與已套用過 migration 的資料庫不得執行。
-- 內容與逐支執行相同，只移除各檔自己的 begin; 與 commit;。任何一段失敗，整份回滾。
-- 之後新增的 migration 照常放 supabase/migrations/，正式與測試專案都逐支套用。
-- 來源檔與 SHA-256（原始位元組）：
--   202611030001_initial.sql  f06d1f380660e67e762e3851a67ce95c49dbbc9a85ed35496d053c29188e6a83
--   202611030002_registration_rpcs.sql  5193eef58ae9884f245abd3988b6c4a7c1fa680b7e692793df326f0b7a83ef94
--   202611030003_public_choices_and_activity_details.sql  2b9dd1a393f6a499435abba550ce8aab124a8495f9aaeb75345af75481e1ba48
--   202611030004_create_rate_limit_and_test_guard.sql  5b86040659ba5fe5a0761f4d3c769b6f681c25dfc5a76f04119c918e63980189
--   202611040001_staff_backoffice_and_name_lookup.sql  80d08fbe154040c789d8e050ed63aaeb5ef89d5e2e1458ec8061fba670435167
--   202611040002_activity_reorder.sql  f84b7caa81b03602b8b95afe9186afa58871cfff3980e510f4b4ba90f41e2ac6
--   202611040003_activity_time_precision.sql  01318109bbfcbc855d2d3ace1e11d492626f77cf2b3bb79439141dd732ebc89c
--   202611050001_hosting.sql  6e0d133d6bb2f8213cd7a5167abc21c8345dabef78de6ac0a1821ac2857c209d
--   202611050002_hosting_review_fixes.sql  050c5c11be82e1884242d89a3cd5c8573fe3e526f910e404c938024a5e4e9c85
--   202611050003_staff_account_management.sql  bd8379846f02f7e2eb350076117654687ad037e07e6564e67db30d0ec5517743
--   202611050004_hosting_dropdowns_site_note_other_district.sql  50cb851c9638d7b74b8eba0bdd592102f6c608bc89cf42c4ba7019d138f7cca7
--   202611050005_hosting_pickup.sql  e5567f571f2425ae989eb2c065676642c39ea72ab3e2319b64fdcf99d45b556a
--   202611050006_meal_pricing_and_audience.sql  37f6aebb7a8114d76e2e4c9ce06c93519c6cf2ab851dd4bd75b4aba771bdc23b
--   202611060001_independent_pickup.sql  f63a3bc5f15db5aefa72c72fe22c0c5d945262563c14ec7a3885fc875c3981df
--   202611060002_activity_audiences.sql  81fdfdf7ea5fd18f6b698ad145ff5cc656b59b965ce699a8beffa920ec38e34a
--   202611060003_revoke_default_api_grants.sql  5eebd15030d402fde6930bab8eb45481be358509730801c2fd9cbeee482b21e2

begin;

-- ===== 202611030001_initial.sql =====

create table public.districts (
  id integer primary key,
  name text not null unique,
  is_active boolean not null default true,
  sort_order integer not null
);

create table public.site_settings (
  id boolean primary key default true check (id),
  event_name text not null,
  venue text,
  address text,
  registration_deadline_at timestamptz,
  is_registration_open boolean not null default false,
  updated_at timestamptz not null default now()
);

create table public.program_items (
  id bigint generated always as identity primary key,
  event_date date not null,
  start_time time,
  end_time time,
  title text not null,
  note text,
  sort_order integer not null,
  is_visible boolean not null default true
);

create table public.activities (
  id bigint generated always as identity primary key,
  category text not null check (category in ('meeting', 'meal', 'other')),
  title text not null,
  starts_at timestamptz,
  ends_at timestamptz,
  venue text,
  address text,
  map_url text,
  description text,
  fee_amount integer check (fee_amount >= 0),
  is_published boolean not null default false,
  sort_order integer not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.registrations (
  id uuid primary key default gen_random_uuid(),
  serial_no bigint generated always as identity unique,
  create_request_id uuid not null unique,
  full_name text not null check (length(btrim(full_name)) between 1 and 100),
  district_id integer not null references public.districts(id),
  query_code_hash text not null unique check (length(query_code_hash) = 64),
  record_status text not null default 'active' check (record_status in ('active', 'cancelled', 'duplicate_void')),
  import_status text not null default 'pending' check (import_status in ('pending', 'imported', 'reimport_needed')),
  duplicate_review_status text not null default 'unreviewed' check (duplicate_review_status in ('unreviewed', 'confirmed_distinct')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  imported_at timestamptz,
  imported_by uuid
);

create table public.registration_choices (
  registration_id uuid not null references public.registrations(id) on delete cascade,
  activity_id bigint not null references public.activities(id),
  attending boolean not null,
  updated_at timestamptz not null default now(),
  primary key (registration_id, activity_id)
);

create table public.staff_profiles (
  auth_user_id uuid primary key references auth.users(id) on delete cascade,
  username text not null,
  display_name text not null,
  district_id integer references public.districts(id),
  role text not null check (role in ('admin', 'staff')),
  is_active boolean not null default true,
  must_change_password boolean not null default true,
  created_at timestamptz not null default now()
);

create table public.audit_events (
  id bigint generated always as identity primary key,
  actor_type text not null,
  actor_user_id uuid,
  action text not null,
  target_type text not null,
  target_id uuid,
  before_data jsonb,
  after_data jsonb,
  created_at timestamptz not null default now()
);

create unique index staff_profiles_username_key on public.staff_profiles (lower(username));

create table public.query_attempts (
  id boolean primary key default true check (id),
  window_started_at timestamptz not null default now(),
  failed_count integer not null default 0,
  suspended_at timestamptz
);

alter table public.districts enable row level security;
alter table public.site_settings enable row level security;
alter table public.program_items enable row level security;
alter table public.activities enable row level security;
alter table public.registrations enable row level security;
alter table public.registration_choices enable row level security;
alter table public.staff_profiles enable row level security;
alter table public.audit_events enable row level security;
alter table public.query_attempts enable row level security;

create policy "read active districts" on public.districts for select to anon using (is_active);
create policy "read site settings" on public.site_settings for select to anon using (true);
create policy "read visible program" on public.program_items for select to anon using (is_visible);
create policy "read published activities" on public.activities for select to anon using (is_published);

grant select on public.districts, public.site_settings, public.program_items, public.activities to anon;
grant all on public.districts, public.site_settings, public.program_items, public.activities,
  public.registrations, public.registration_choices, public.staff_profiles,
  public.query_attempts to service_role;
grant select, insert on public.audit_events to service_role;
grant usage, select on all sequences in schema public to service_role;

insert into public.districts (id, name, sort_order) values
  (1, '林森', 1), (2, '忠孝', 2), (3, '杭州', 3);

insert into public.site_settings (event_name, venue, address) values
  ('2027 國際華語相調特會', '台北大巨蛋', '台北市信義區忠孝東路四段 515 號');

insert into public.query_attempts default values;

insert into public.activities (category, title, starts_at, ends_at, venue, address, description, fee_amount, is_published, sort_order) values
  ('meeting', '華語特會（第一天）', '2027-02-20 12:30+08', '2027-02-20 18:00+08', '台北大巨蛋', '台北市信義區忠孝東路四段 515 號', null, null, true, 1),
  ('meeting', '華語特會（第二天，含擘餅）', '2027-02-21 09:00+08', '2027-02-21 12:40+08', '台北大巨蛋', '台北市信義區忠孝東路四段 515 號', null, null, true, 2),
  ('meeting', '青年大會', null, null, null, null, '時間與地點待確認', null, false, 3),
  ('meal', '週六午餐', null, null, '京星港式飲茶 PART1', '台北市敦化南路一段 216 號 2 樓', '用餐時間待確認；費用為規劃值', 250, false, 4),
  ('meal', '週六晚餐', null, null, '羊成小館', '台北市忠孝東路二段 80 號 2 樓', '用餐時間待確認；費用為規劃值', 250, false, 5),
  ('meal', '主日午餐', null, null, null, null, '用餐時間與地點待確認；費用為規劃值', 250, false, 6),
  ('other', '主日晚間帶菜愛筵', null, null, null, null, '是否舉行待確認', null, false, 7);

insert into public.program_items (event_date, start_time, end_time, title, note, sort_order) values
  ('2027-02-20', '11:00', null, '開放入場', null, 1),
  ('2027-02-20', '12:30', '14:00', '第一堂聚會', null, 2),
  ('2027-02-20', '14:00', '14:30', '展覽一', null, 3),
  ('2027-02-20', '14:30', '16:00', '第二堂聚會', null, 4),
  ('2027-02-20', '16:00', '16:30', '展覽二', null, 5),
  ('2027-02-20', '16:30', '18:00', '第三堂聚會', null, 6),
  ('2027-02-21', '07:30', null, '開放入場', null, 7),
  ('2027-02-21', '09:00', '10:30', '第四堂聚會', null, 8),
  ('2027-02-21', '10:30', '12:00', '第五堂聚會', null, 9),
  ('2027-02-21', '12:00', '12:40', '擘餅聚會', null, 10),
  ('2027-02-21', '12:40', null, '散會', null, 11);

-- ===== 202611030002_registration_rpcs.sql =====

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
    set window_started_at = v_now, failed_count = 1
    where id = true;
    return true;
  end if;

  update public.query_attempts
  set failed_count = failed_count + 1,
      suspended_at = case when failed_count + 1 >= 30 then v_now else null end
  where id = true;

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

-- ===== 202611030003_public_choices_and_activity_details.sql =====

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

-- ===== 202611030004_create_rate_limit_and_test_guard.sql =====

alter table public.site_settings
  add column is_test_environment boolean not null default false;

create table public.registration_create_limits (
  id boolean primary key default true check (id),
  window_started_at timestamptz not null default now(),
  created_count integer not null default 0 check (created_count between 0 and 50)
);

alter table public.registration_create_limits enable row level security;
grant select, update on public.registration_create_limits to service_role;
insert into public.registration_create_limits default values;
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

  update public.registration_create_limits
  set window_started_at = case when window_started_at <= now() - interval '10 minutes' then now() else window_started_at end,
      created_count = case when window_started_at <= now() - interval '10 minutes' then 1 else created_count + 1 end
  where id = true
    and (window_started_at <= now() - interval '10 minutes' or created_count < 50);
  if not found then
    raise exception using errcode = 'P0001', message = 'CREATE_RATE_LIMITED';
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

-- ===== 202611040001_staff_backoffice_and_name_lookup.sql =====

-- 2026-11-04: back-office staff accounts and operations, plus the switch from query codes to
-- name-and-district lookup. Merged from seven unapplied migrations (202611040001 to 0007), each
-- kept below under its original name. Apply after 202611030001 to 202611030004.
-- Clear existing test registrations first: the active name-and-district unique index fails on duplicates.

-- ===== 202611040001_remove_status_operation =====

-- Existing record_status values remain for historical test records.
drop function if exists public.set_registration_status(text, text);

-- ===== 202611040002_staff_password_change =====

-- Ends every login of the user, so an old access or refresh token cannot outlive a password change.
create function public.staff_revoke_sessions(p_user_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from auth.sessions where user_id = p_user_id;
$$;

revoke execute on function public.staff_revoke_sessions(uuid) from public, anon, authenticated;
grant execute on function public.staff_revoke_sessions(uuid) to service_role;

-- Serves the per-user attempt count below without scanning the whole audit table.
create index audit_events_actor_action_created_at_idx
  on public.audit_events (actor_user_id, action, created_at);

-- Reserves one current-password check: 5 per user per 15 minutes. Locking the profile row
-- makes parallel requests from the same user queue, so they cannot all pass the count together.
create function public.staff_reserve_password_attempt(p_actor uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform 1 from public.staff_profiles where auth_user_id = p_actor and is_active for update;
  if not found then
    raise exception using errcode = '42501', message = 'STAFF_NOT_ACTIVE';
  end if;
  if (select count(*) from public.audit_events
      where actor_user_id = p_actor and action = 'staff.password_verify_attempt'
        and created_at > now() - interval '15 minutes') >= 5 then
    return false;
  end if;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id)
  values ('staff', p_actor, 'staff.password_verify_attempt', 'staff_profile', p_actor);
  return true;
end;
$$;

revoke execute on function public.staff_reserve_password_attempt(uuid) from public, anon, authenticated;
grant execute on function public.staff_reserve_password_attempt(uuid) to service_role;

create function public.staff_finish_password_change(p_actor uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update public.staff_profiles
  set must_change_password = false
  where auth_user_id = p_actor and is_active;
  if not found then
    raise exception using errcode = '42501', message = 'STAFF_NOT_ACTIVE';
  end if;
  perform public.staff_revoke_sessions(p_actor);

  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id)
  values ('staff', p_actor, 'staff.password_changed', 'staff_profile', p_actor);
end;
$$;

revoke execute on function public.staff_finish_password_change(uuid) from public, anon, authenticated;
grant execute on function public.staff_finish_password_change(uuid) to service_role;

-- ===== 202611040003_staff_accounts =====

create function public.staff_assert_actor(p_actor uuid, p_admin boolean default false)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if not exists (
    select 1 from public.staff_profiles
    where auth_user_id = p_actor and is_active and not must_change_password
      and (not p_admin or role = 'admin')
  ) then
    raise exception using errcode = '42501', message = 'STAFF_FORBIDDEN';
  end if;
end;
$$;

create function public.staff_create_profile(
  p_actor uuid, p_user_id uuid, p_username text, p_display_name text,
  p_role text, p_district_id integer
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform public.staff_assert_actor(p_actor, true);
  if p_role not in ('admin', 'staff') or length(p_display_name) not between 1 and 100 then
    raise exception using errcode = '22023', message = 'INVALID_STAFF_PROFILE';
  end if;
  insert into public.staff_profiles
    (auth_user_id, username, display_name, district_id, role)
  values (p_user_id, p_username, p_display_name, p_district_id, p_role);
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, after_data)
  values ('admin', p_actor, 'staff.created', 'staff_profile', p_user_id,
    jsonb_build_object('username', p_username, 'role', p_role, 'district_id', p_district_id));
end;
$$;

create function public.staff_mark_password_reset(p_actor uuid, p_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform public.staff_assert_actor(p_actor, true);
  if p_actor = p_user_id then
    raise exception using errcode = '22023', message = 'SELF_PASSWORD_RESET';
  end if;
  update public.staff_profiles set must_change_password = true where auth_user_id = p_user_id;
  if not found then
    raise exception using errcode = '22023', message = 'STAFF_NOT_FOUND';
  end if;
  perform public.staff_revoke_sessions(p_user_id);
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id)
  values ('admin', p_actor, 'staff.password_reset', 'staff_profile', p_user_id);
end;
$$;

create function public.staff_set_active(p_actor uuid, p_user_id uuid, p_is_active boolean)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_profile public.staff_profiles%rowtype;
begin
  -- Lock active admins in one fixed order first, so concurrent deactivations queue instead of deadlocking.
  perform 1 from public.staff_profiles where role = 'admin' and is_active order by auth_user_id for update;
  -- Check the actor after the locks, so an admin deactivated by the request ahead in the queue is refused.
  perform public.staff_assert_actor(p_actor, true);
  select * into v_profile from public.staff_profiles where auth_user_id = p_user_id for update;
  if not found then
    raise exception using errcode = '22023', message = 'STAFF_NOT_FOUND';
  end if;
  if v_profile.role = 'admin' and v_profile.is_active and not p_is_active then
    perform 1 from public.staff_profiles where role = 'admin' and is_active and auth_user_id <> p_user_id;
    if not found then
      raise exception using errcode = 'P0001', message = 'LAST_ACTIVE_ADMIN';
    end if;
  end if;
  update public.staff_profiles set is_active = p_is_active where auth_user_id = p_user_id;
  if not p_is_active then perform public.staff_revoke_sessions(p_user_id); end if;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  values ('admin', p_actor, 'staff.active_changed', 'staff_profile', p_user_id,
    jsonb_build_object('is_active', v_profile.is_active), jsonb_build_object('is_active', p_is_active));
end;
$$;

revoke execute on function public.staff_assert_actor(uuid,boolean) from public, anon, authenticated;
revoke execute on function public.staff_create_profile(uuid,uuid,text,text,text,integer) from public, anon, authenticated;
revoke execute on function public.staff_mark_password_reset(uuid,uuid) from public, anon, authenticated;
revoke execute on function public.staff_set_active(uuid,uuid,boolean) from public, anon, authenticated;
grant execute on function public.staff_assert_actor(uuid,boolean) to service_role;
grant execute on function public.staff_create_profile(uuid,uuid,text,text,text,integer) to service_role;
grant execute on function public.staff_mark_password_reset(uuid,uuid) to service_role;
grant execute on function public.staff_set_active(uuid,uuid,boolean) to service_role;

-- ===== 202611040004_staff_registration =====

-- Every answer must be a distinct published activity with a boolean. A new registration
-- (p_registration_id null) must answer every published activity. An edit must keep each
-- answer the registration already has, but may leave a newer activity unanswered (未回覆),
-- because only the registrant decides those.
create function public.registration_choices_valid(p_choices jsonb, p_registration_id uuid default null)
returns boolean
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare v_given integer;
begin
  if jsonb_typeof(p_choices) is distinct from 'array' then return false; end if;
  v_given := jsonb_array_length(p_choices);
  if v_given <> (
    select count(distinct activity.id)
    from jsonb_array_elements(p_choices) choice
    join public.activities activity on activity.id = (choice->>'activity_id')::bigint
    where activity.is_published and jsonb_typeof(choice->'attending') = 'boolean'
  ) then
    return false;
  end if;
  if p_registration_id is null and v_given = 0 then return false; end if;
  return not exists (
    select 1 from public.activities activity
    where activity.is_published
      and (p_registration_id is null or exists (
        select 1 from public.registration_choices answered
        where answered.registration_id = p_registration_id and answered.activity_id = activity.id))
      and not exists (
        select 1 from jsonb_array_elements(p_choices) choice
        where (choice->>'activity_id')::bigint = activity.id)
  );
end;
$$;

create function public.staff_update_registration(
  p_actor uuid, p_registration_id uuid, p_full_name text, p_district_id integer, p_choices jsonb
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
  v_before_choices jsonb;
  v_after_choices jsonb;
begin
  perform public.staff_assert_actor(p_actor);
  select * into v_registration from public.registrations
  where id = p_registration_id and record_status = 'active' for update;
  if not found then return false; end if;

  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = ''
    or not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_REGISTRATION';
  end if;
  if public.registration_choices_valid(p_choices, p_registration_id) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_before_choices
  from public.registration_choices where registration_id = p_registration_id
    and activity_id in (select id from public.activities where is_published);
  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_after_choices
  from (
    select (choice->>'activity_id')::bigint as activity_id,
      (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
  ) answers;

  if v_registration.full_name = btrim(p_full_name) and v_registration.district_id = p_district_id
    and v_before_choices = v_after_choices then return true; end if;

  update public.registrations set full_name = btrim(p_full_name), district_id = p_district_id,
    import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = p_registration_id;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select p_registration_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  on conflict (registration_id, activity_id) do update
    set attending = excluded.attending, updated_at = now();
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  values ('staff', p_actor, 'registration.staff_updated', 'registration', p_registration_id,
    jsonb_build_object('full_name', v_registration.full_name, 'district_id', v_registration.district_id,
      'choices', v_before_choices, 'import_status', v_registration.import_status),
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id, 'choices', v_after_choices,
      'import_status', case when v_registration.import_status = 'imported' then 'reimport_needed'
        else v_registration.import_status end));
  return true;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and id <> p_registration_id
        and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

create function public.staff_set_import_status(
  p_actor uuid, p_registration_id uuid, p_status text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare v_before public.registrations%rowtype;
begin
  perform public.staff_assert_actor(p_actor);
  if p_status not in ('pending', 'imported', 'reimport_needed') then
    raise exception using errcode = '22023', message = 'INVALID_IMPORT_STATUS';
  end if;
  select * into v_before from public.registrations
  where id = p_registration_id for update;
  if not found then return false; end if;
  if v_before.import_status = p_status then return true; end if;
  update public.registrations set import_status = p_status,
    -- reimport_needed keeps the last import, matching the automatic path in staff_update_registration.
    imported_at = case p_status when 'imported' then now() when 'reimport_needed' then imported_at end,
    imported_by = case p_status when 'imported' then p_actor when 'reimport_needed' then imported_by end,
    updated_at = now()
  where id = p_registration_id;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  -- before_data keeps who imported it and when, since setting pending clears both columns.
  values ('staff', p_actor, 'registration.import_status_changed', 'registration', p_registration_id,
    jsonb_build_object('import_status', v_before.import_status,
      'imported_at', v_before.imported_at, 'imported_by', v_before.imported_by),
    jsonb_build_object('import_status', p_status));
  return true;
end;
$$;

-- 作廢 is the only way to retire a registration (no hard delete). A void record stays for
-- review, leaves stats and CSV, and frees its name and district for a new registration.
create function public.staff_void_registration(
  p_actor uuid, p_registration_id uuid, p_reason text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare v_before public.registrations%rowtype;
begin
  perform public.staff_assert_actor(p_actor);
  if coalesce(length(btrim(p_reason)), 0) not between 1 and 200 then
    raise exception using errcode = '22023', message = 'INVALID_VOID_REASON';
  end if;
  select * into v_before from public.registrations where id = p_registration_id for update;
  if not found then return false; end if;
  -- Historical 'cancelled' test rows can still be voided; only an already void row is refused.
  if v_before.record_status = 'void' then
    raise exception using errcode = '22023', message = 'ALREADY_VOID';
  end if;
  update public.registrations set
    record_status = 'void',
    import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = p_registration_id;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  values ('staff', p_actor, 'registration.voided', 'registration', p_registration_id,
    jsonb_build_object('record_status', v_before.record_status, 'import_status', v_before.import_status),
    jsonb_build_object('record_status', 'void', 'reason', btrim(p_reason),
      'import_status', case when v_before.import_status = 'imported' then 'reimport_needed'
        else v_before.import_status end));
  return true;
end;
$$;

revoke execute on function public.registration_choices_valid(jsonb,uuid) from public, anon, authenticated;
grant execute on function public.registration_choices_valid(jsonb,uuid) to service_role;
revoke execute on function public.staff_update_registration(uuid,uuid,text,integer,jsonb) from public, anon, authenticated;
revoke execute on function public.staff_set_import_status(uuid,uuid,text) from public, anon, authenticated;
revoke execute on function public.staff_void_registration(uuid,uuid,text) from public, anon, authenticated;
grant execute on function public.staff_update_registration(uuid,uuid,text,integer,jsonb) to service_role;
grant execute on function public.staff_set_import_status(uuid,uuid,text) to service_role;
grant execute on function public.staff_void_registration(uuid,uuid,text) to service_role;

-- ===== 202611040005_staff_settings =====

create sequence public.district_ids;
select setval('public.district_ids', (select max(id) from public.districts));
alter table public.districts alter column id set default nextval('public.district_ids');
grant usage on sequence public.district_ids to service_role;

create function public.staff_save_reference(p_actor uuid, p_kind text, p_data jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_id bigint;
begin
  perform public.staff_assert_actor(p_actor, true);
  if jsonb_typeof(p_data) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_DATA';
  end if;

  if p_kind = 'settings' then
    select to_jsonb(s) into v_before from public.site_settings s where id for update;
    update public.site_settings set
      event_name = btrim(p_data->>'event_name'),
      venue = nullif(btrim(p_data->>'venue'), ''),
      address = nullif(btrim(p_data->>'address'), ''),
      registration_deadline_at = nullif(p_data->>'registration_deadline_at', '')::timestamptz,
      is_registration_open = (p_data->>'is_registration_open')::boolean,
      is_lookup_open = coalesce((p_data->>'is_lookup_open')::boolean, is_lookup_open),
      updated_at = now()
    where id returning to_jsonb(site_settings.*) into v_after;
  elsif p_kind = 'district' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      -- Districts are fixed for this assembly: they can be added or renamed but never deactivated.
      insert into public.districts (name, sort_order)
      values (btrim(p_data->>'name'), (p_data->>'sort_order')::integer)
      returning to_jsonb(districts.*) into v_after;
    else
      select to_jsonb(d) into v_before from public.districts d where id = v_id for update;
      update public.districts set name = btrim(p_data->>'name'),
        sort_order = (p_data->>'sort_order')::integer
      where id = v_id returning to_jsonb(districts.*) into v_after;
    end if;
  elsif p_kind = 'activity' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.activities
        (category, title, starts_at, ends_at, venue, address, map_url, description,
         fee_amount, is_published, sort_order)
      values (
        p_data->>'category', btrim(p_data->>'title'),
        nullif(p_data->>'starts_at', '')::timestamptz,
        nullif(p_data->>'ends_at', '')::timestamptz,
        nullif(btrim(p_data->>'venue'), ''), nullif(btrim(p_data->>'address'), ''),
        nullif(btrim(p_data->>'map_url'), ''), nullif(btrim(p_data->>'description'), ''),
        nullif(p_data->>'fee_amount', '')::integer,
        (p_data->>'is_published')::boolean, (p_data->>'sort_order')::integer
      ) returning to_jsonb(activities.*) into v_after;
    else
      select to_jsonb(a) into v_before from public.activities a where id = v_id for update;
      update public.activities set
        category = p_data->>'category', title = btrim(p_data->>'title'),
        starts_at = nullif(p_data->>'starts_at', '')::timestamptz,
        ends_at = nullif(p_data->>'ends_at', '')::timestamptz,
        venue = nullif(btrim(p_data->>'venue'), ''),
        address = nullif(btrim(p_data->>'address'), ''),
        map_url = nullif(btrim(p_data->>'map_url'), ''),
        description = nullif(btrim(p_data->>'description'), ''),
        fee_amount = nullif(p_data->>'fee_amount', '')::integer,
        is_published = (p_data->>'is_published')::boolean,
        sort_order = (p_data->>'sort_order')::integer,
        updated_at = now()
      where id = v_id returning to_jsonb(activities.*) into v_after;
    end if;
  elsif p_kind = 'program' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.program_items
        (event_date, start_time, end_time, title, note, sort_order, is_visible)
      values (
        (p_data->>'event_date')::date, nullif(p_data->>'start_time', '')::time,
        nullif(p_data->>'end_time', '')::time, btrim(p_data->>'title'),
        nullif(btrim(p_data->>'note'), ''), (p_data->>'sort_order')::integer,
        (p_data->>'is_visible')::boolean
      ) returning to_jsonb(program_items.*) into v_after;
    else
      select to_jsonb(p) into v_before from public.program_items p where id = v_id for update;
      update public.program_items set
        event_date = (p_data->>'event_date')::date,
        start_time = nullif(p_data->>'start_time', '')::time,
        end_time = nullif(p_data->>'end_time', '')::time,
        title = btrim(p_data->>'title'), note = nullif(btrim(p_data->>'note'), ''),
        sort_order = (p_data->>'sort_order')::integer,
        is_visible = (p_data->>'is_visible')::boolean
      where id = v_id returning to_jsonb(program_items.*) into v_after;
    end if;
  else
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_KIND';
  end if;

  if v_after is null then
    raise exception using errcode = '22023', message = 'REFERENCE_NOT_FOUND';
  end if;
  -- Spec: only a change to the activity's name, time or publish state needs a re-import.
  if p_kind = 'activity' and v_before is not null
    and (v_before->'title', v_before->'starts_at', v_before->'ends_at', v_before->'is_published')
      is distinct from (v_after->'title', v_after->'starts_at', v_after->'ends_at', v_after->'is_published') then
    with affected as (
      update public.registrations r
      set import_status = 'reimport_needed', updated_at = now()
      where r.import_status = 'imported' and r.record_status = 'active'
        and exists (
          select 1 from public.registration_choices c
          where c.registration_id = r.id and c.activity_id = (v_after->>'id')::bigint
            and c.attending
        )
      returning r.id
    )
    insert into public.audit_events
      (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
    select 'admin', p_actor, 'registration.reimport_needed', 'registration', id,
      '{"import_status":"imported"}'::jsonb,
      '{"import_status":"reimport_needed"}'::jsonb
    from affected;
  end if;
  -- updated_at always changes on save; compare without it so a save with no edits leaves no audit row.
  if (v_before - 'updated_at') is distinct from (v_after - 'updated_at') then
    insert into public.audit_events
      (actor_type, actor_user_id, action, target_type, before_data, after_data)
    values ('admin', p_actor, 'reference.saved', p_kind, v_before, v_after);
  end if;
  return v_after;
end;
$$;

revoke execute on function public.staff_save_reference(uuid,text,jsonb) from public, anon, authenticated;
grant execute on function public.staff_save_reference(uuid,text,jsonb) to service_role;

-- ===== 202611040006_staff_create_registration =====

create function public.staff_create_registration(
  p_actor uuid, p_request_id uuid, p_full_name text, p_district_id integer, p_choices jsonb
)
returns table (registration_id uuid, serial_no bigint)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
  v_serial bigint;
begin
  perform public.staff_assert_actor(p_actor);
  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = ''
    or not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_REGISTRATION';
  end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;

  insert into public.registrations
    (create_request_id, full_name, district_id)
  values (p_request_id, btrim(p_full_name), p_district_id)
  returning id, registrations.serial_no into v_id, v_serial;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, after_data)
  values ('staff', p_actor, 'registration.staff_created', 'registration', v_id,
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id));
  return query select v_id, v_serial;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where create_request_id = p_request_id) then
      raise exception using errcode = '23505', message = 'DUPLICATE_REQUEST';
    end if;
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

revoke execute on function public.staff_create_registration(uuid,uuid,text,integer,jsonb) from public, anon, authenticated;
grant execute on function public.staff_create_registration(uuid,uuid,text,integer,jsonb) to service_role;

-- ===== 202611040007_name_lookup =====

-- 2026-11-04 redesign: registrants find their record by name and district instead of a query code.
-- Apply only after clearing existing test registrations: the unique index below fails on duplicates.

-- Districts are fixed for this assembly and are never deactivated, so the flag goes away.
drop policy "read active districts" on public.districts;
create policy "read districts" on public.districts for select to anon using (true);
alter table public.districts drop column is_active;

-- Comparison key for a name: NFKC (full-width to half-width), lower case, no whitespace at all,
-- and no zero-width characters (U+200B-U+200D, U+2060, U+FEFF) that pasted text can carry.
-- full_name keeps what the person typed; only lookups and uniqueness use the key.
create function public.registration_name_key(p_name text)
returns text
language sql
immutable
parallel safe
set search_path = ''
as $$
  select regexp_replace(lower(normalize(coalesce(p_name, ''), NFKC)), '[\s\u200B-\u200D\u2060\uFEFF]', '', 'g');
$$;

-- Drop the old status check first: it does not allow 'void', so renaming rows before it is gone fails.
alter table public.registrations drop constraint registrations_record_status_check;
update public.registrations set record_status = 'void' where record_status = 'duplicate_void';
alter table public.registrations
  add constraint registrations_record_status_check check (record_status in ('active', 'cancelled', 'void')),
  drop column query_code_hash,
  drop column duplicate_review_status,
  add column name_key text generated always as (public.registration_name_key(full_name)) stored,
  -- A name of only full-width spaces or tabs passes btrim but leaves an empty key.
  add constraint registrations_name_key_not_empty check (name_key <> '');

-- One active registration per name and district; a void record frees the name for re-registration.
create unique index registrations_active_name_district_key
  on public.registrations (district_id, name_key) where record_status = 'active';

drop function public.create_registration(uuid, text, integer, text, jsonb);
drop function public.get_registration(text);
drop function public.update_registration(text, text, integer, jsonb);
drop function public.check_query_availability();
drop function public.record_query_result(boolean);
drop function public.reset_registration_query_code(bigint, text);
drop function public.reset_query_protection();
drop table public.query_attempts;

-- Per-source request counts for public create, query and update. source_key is an HMAC of the
-- client IP made with a server-only key, so the raw IP is never stored; rows older than the
-- window are deleted on every call.
create table public.public_request_limits (
  source_key text primary key,
  window_started_at timestamptz not null default now(),
  request_count integer not null default 0
);
-- Lets the expiry delete on every call find old rows without scanning the whole table.
create index public_request_limits_window_started_at_idx on public.public_request_limits (window_started_at);
alter table public.public_request_limits enable row level security;
grant select, insert, update, delete on public.public_request_limits to service_role;

create function public.consume_public_request(p_source_key text)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_global integer;
  v_source integer;
begin
  if p_source_key !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'INVALID_SOURCE_KEY';
  end if;
  delete from public.public_request_limits where window_started_at <= now() - interval '10 minutes';
  insert into public.public_request_limits as limits (source_key, request_count) values (p_source_key, 1)
  on conflict (source_key) do update set request_count = limits.request_count + 1
  returning request_count into v_source;
  -- A request refused for its own source does not count globally, so one source alone
  -- cannot use up the site-wide allowance for everyone else.
  if v_source > 60 then return false; end if;
  insert into public.public_request_limits as limits (source_key, request_count) values ('global', 1)
  on conflict (source_key) do update set request_count = limits.request_count + 1
  returning request_count into v_global;
  return v_global <= 600;
end;
$$;

create function public.create_registration(
  p_request_id uuid,
  p_full_name text,
  p_district_id integer,
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
begin
  if not exists (
    select 1 from public.site_settings
    where id and is_registration_open
      and (registration_deadline_at is null or registration_deadline_at > now())
  ) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;
  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = '' then
    raise exception using errcode = '22023', message = 'INVALID_NAME';
  end if;
  if not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_DISTRICT';
  end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;

  update public.registration_create_limits
  set window_started_at = case when window_started_at <= now() - interval '10 minutes' then now() else window_started_at end,
      created_count = case when window_started_at <= now() - interval '10 minutes' then 1 else created_count + 1 end
  where id = true
    and (window_started_at <= now() - interval '10 minutes' or created_count < 50);
  if not found then
    raise exception using errcode = 'P0001', message = 'CREATE_RATE_LIMITED';
  end if;

  insert into public.registrations (create_request_id, full_name, district_id)
  values (p_request_id, btrim(p_full_name), p_district_id)
  returning id, registrations.serial_no into v_registration_id, v_serial_no;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice;
  insert into public.audit_events (actor_type, action, target_type, target_id, after_data)
  values ('public', 'registration.created', 'registration', v_registration_id,
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id));

  return query select v_registration_id, v_serial_no;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where create_request_id = p_request_id) then
      raise exception using errcode = '23505', message = 'DUPLICATE_REQUEST';
    end if;
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- Emergency switch for the public lookup: closing registration stops create and update but
-- not lookup, so an admin can stop name-and-district lookups separately.
alter table public.site_settings add column is_lookup_open boolean not null default true;

create function public.get_registration(p_full_name text, p_district_id integer)
returns table (
  full_name text,
  district_id integer,
  can_change boolean,
  choices jsonb
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if not exists (select 1 from public.site_settings where id and is_lookup_open) then
    raise exception using errcode = 'P0001', message = 'LOOKUP_CLOSED';
  end if;
  return query
  select registration.full_name,
    registration.district_id,
    settings.is_registration_open
      and (settings.registration_deadline_at is null or settings.registration_deadline_at > now()),
    coalesce(
      jsonb_agg(
        jsonb_build_object('activity_id', activity.id, 'title', activity.title, 'attending', choice.attending)
        order by activity.sort_order
      ) filter (where activity.id is not null),
      '[]'::jsonb
    )
  from public.registrations registration
  cross join public.site_settings settings
  left join public.activities activity on activity.is_published
  left join public.registration_choices choice
    on choice.registration_id = registration.id and choice.activity_id = activity.id
  where registration.district_id = p_district_id
    and registration.name_key = public.registration_name_key(p_full_name)
    and registration.record_status = 'active'
  group by registration.id, settings.is_registration_open, settings.registration_deadline_at;
end;
$$;

-- The public can change only activity choices; name and district are the lookup key and
-- change only through staff.
create function public.update_registration(
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
  v_before_choices jsonb;
  v_after_choices jsonb;
begin
  if not exists (
    select 1 from public.site_settings
    where id and is_registration_open
      and (registration_deadline_at is null or registration_deadline_at > now())
  ) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;
  if not exists (select 1 from public.site_settings where id and is_lookup_open) then
    raise exception using errcode = 'P0001', message = 'LOOKUP_CLOSED';
  end if;

  select * into v_registration from public.registrations
  where district_id = p_district_id and name_key = public.registration_name_key(p_full_name)
    and record_status = 'active'
  for update;
  if not found then return false; end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_before_choices
  from public.registration_choices where registration_id = v_registration.id
    and activity_id in (select id from public.activities where is_published);
  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_after_choices
  from (
    select (choice->>'activity_id')::bigint as activity_id, (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
  ) answers;
  if v_before_choices = v_after_choices then return true; end if;

  update public.registrations set
    import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = v_registration.id;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration.id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  on conflict (registration_id, activity_id) do update
    set attending = excluded.attending, updated_at = now();
  insert into public.audit_events (actor_type, action, target_type, target_id, before_data, after_data)
  values ('public', 'registration.updated', 'registration', v_registration.id,
    jsonb_build_object('choices', v_before_choices, 'import_status', v_registration.import_status),
    jsonb_build_object('choices', v_after_choices,
      'import_status', case when v_registration.import_status = 'imported' then 'reimport_needed'
        else v_registration.import_status end));
  return true;
exception
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

revoke execute on function public.consume_public_request(text) from public, anon, authenticated;
revoke execute on function public.create_registration(uuid, text, integer, jsonb) from public, anon, authenticated;
revoke execute on function public.get_registration(text, integer) from public, anon, authenticated;
revoke execute on function public.update_registration(text, integer, jsonb) from public, anon, authenticated;
grant execute on function public.consume_public_request(text) to service_role;
grant execute on function public.create_registration(uuid, text, integer, jsonb) to service_role;
grant execute on function public.get_registration(text, integer) to service_role;
grant execute on function public.update_registration(text, integer, jsonb) to service_role;

-- ===== 202611040002_activity_reorder.sql =====

-- Saves a drag-and-drop order for activities in one call. The list must name every activity
-- exactly once, so a stale page (an activity added or removed elsewhere) is refused instead of
-- leaving gaps. Sort order alone never marks registrations for re-import.
create function public.staff_reorder_activities(p_actor uuid, p_activity_ids bigint[])
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
begin
  perform public.staff_assert_actor(p_actor, true);
  -- Row locks would not stop an activity inserted after the count check; this table lock does.
  lock table public.activities in share row exclusive mode;
  if p_activity_ids is null
    or cardinality(p_activity_ids) <> (select count(*) from public.activities)
    or cardinality(p_activity_ids) <> (select count(distinct given.activity_id) from unnest(p_activity_ids) as given(activity_id))
    or exists (
      select 1 from unnest(p_activity_ids) as given(activity_id)
      where not exists (select 1 from public.activities activity where activity.id = given.activity_id)
    ) then
    raise exception using errcode = '22023', message = 'INVALID_ACTIVITY_ORDER';
  end if;

  select jsonb_agg(id order by sort_order, id) into v_before from public.activities;
  update public.activities activity
  set sort_order = ordered.position::integer, updated_at = now()
  from unnest(p_activity_ids) with ordinality as ordered(activity_id, position)
  where activity.id = ordered.activity_id and activity.sort_order is distinct from ordered.position::integer;
  select jsonb_agg(id order by sort_order, id) into v_after from public.activities;

  if v_before is distinct from v_after then
    insert into public.audit_events (actor_type, actor_user_id, action, target_type, before_data, after_data)
    values ('admin', p_actor, 'reference.reordered', 'activity',
      jsonb_build_object('order', v_before), jsonb_build_object('order', v_after));
  end if;
end;
$$;

revoke execute on function public.staff_reorder_activities(uuid, bigint[]) from public, anon, authenticated;
grant execute on function public.staff_reorder_activities(uuid, bigint[]) to service_role;

-- ===== 202611040003_activity_time_precision.sql =====

-- A timestamptz alone cannot preserve whether an admin entered a date without a time.
-- Existing timestamps remain precise; new saves explicitly record the intended display precision.
alter table public.activities
  add column starts_at_has_time boolean not null default true,
  add column ends_at_has_time boolean not null default true;

create or replace function public.staff_save_reference(p_actor uuid, p_kind text, p_data jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_id bigint;
begin
  perform public.staff_assert_actor(p_actor, true);
  if jsonb_typeof(p_data) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_DATA';
  end if;

  if p_kind = 'settings' then
    select to_jsonb(s) into v_before from public.site_settings s where id for update;
    update public.site_settings set
      event_name = btrim(p_data->>'event_name'),
      venue = nullif(btrim(p_data->>'venue'), ''),
      address = nullif(btrim(p_data->>'address'), ''),
      registration_deadline_at = nullif(p_data->>'registration_deadline_at', '')::timestamptz,
      is_registration_open = (p_data->>'is_registration_open')::boolean,
      is_lookup_open = coalesce((p_data->>'is_lookup_open')::boolean, is_lookup_open),
      updated_at = now()
    where id returning to_jsonb(site_settings.*) into v_after;
  elsif p_kind = 'district' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.districts (name, sort_order)
      values (btrim(p_data->>'name'), (p_data->>'sort_order')::integer)
      returning to_jsonb(districts.*) into v_after;
    else
      select to_jsonb(d) into v_before from public.districts d where id = v_id for update;
      update public.districts set name = btrim(p_data->>'name'),
        sort_order = (p_data->>'sort_order')::integer
      where id = v_id returning to_jsonb(districts.*) into v_after;
    end if;
  elsif p_kind = 'activity' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.activities
        (category, title, starts_at, starts_at_has_time, ends_at, ends_at_has_time,
         venue, address, map_url, description, fee_amount, is_published, sort_order)
      values (
        p_data->>'category', btrim(p_data->>'title'),
        nullif(p_data->>'starts_at', '')::timestamptz,
        coalesce((p_data->>'starts_at_has_time')::boolean, nullif(p_data->>'starts_at', '') is not null),
        nullif(p_data->>'ends_at', '')::timestamptz,
        coalesce((p_data->>'ends_at_has_time')::boolean, nullif(p_data->>'ends_at', '') is not null),
        nullif(btrim(p_data->>'venue'), ''), nullif(btrim(p_data->>'address'), ''),
        nullif(btrim(p_data->>'map_url'), ''), nullif(btrim(p_data->>'description'), ''),
        nullif(p_data->>'fee_amount', '')::integer,
        (p_data->>'is_published')::boolean, (p_data->>'sort_order')::integer
      ) returning to_jsonb(activities.*) into v_after;
    else
      select to_jsonb(a) into v_before from public.activities a where id = v_id for update;
      update public.activities set
        category = p_data->>'category', title = btrim(p_data->>'title'),
        starts_at = nullif(p_data->>'starts_at', '')::timestamptz,
        starts_at_has_time = coalesce((p_data->>'starts_at_has_time')::boolean, nullif(p_data->>'starts_at', '') is not null),
        ends_at = nullif(p_data->>'ends_at', '')::timestamptz,
        ends_at_has_time = coalesce((p_data->>'ends_at_has_time')::boolean, nullif(p_data->>'ends_at', '') is not null),
        venue = nullif(btrim(p_data->>'venue'), ''),
        address = nullif(btrim(p_data->>'address'), ''),
        map_url = nullif(btrim(p_data->>'map_url'), ''),
        description = nullif(btrim(p_data->>'description'), ''),
        fee_amount = nullif(p_data->>'fee_amount', '')::integer,
        is_published = (p_data->>'is_published')::boolean,
        sort_order = (p_data->>'sort_order')::integer,
        updated_at = now()
      where id = v_id returning to_jsonb(activities.*) into v_after;
    end if;
  elsif p_kind = 'program' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.program_items
        (event_date, start_time, end_time, title, note, sort_order, is_visible)
      values (
        (p_data->>'event_date')::date, nullif(p_data->>'start_time', '')::time,
        nullif(p_data->>'end_time', '')::time, btrim(p_data->>'title'),
        nullif(btrim(p_data->>'note'), ''), (p_data->>'sort_order')::integer,
        (p_data->>'is_visible')::boolean
      ) returning to_jsonb(program_items.*) into v_after;
    else
      select to_jsonb(p) into v_before from public.program_items p where id = v_id for update;
      update public.program_items set
        event_date = (p_data->>'event_date')::date,
        start_time = nullif(p_data->>'start_time', '')::time,
        end_time = nullif(p_data->>'end_time', '')::time,
        title = btrim(p_data->>'title'), note = nullif(btrim(p_data->>'note'), ''),
        sort_order = (p_data->>'sort_order')::integer,
        is_visible = (p_data->>'is_visible')::boolean
      where id = v_id returning to_jsonb(program_items.*) into v_after;
    end if;
  else
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_KIND';
  end if;

  if v_after is null then
    raise exception using errcode = '22023', message = 'REFERENCE_NOT_FOUND';
  end if;
  if p_kind = 'activity' and v_before is not null
    and (v_before->'title', v_before->'starts_at', v_before->'starts_at_has_time',
         v_before->'ends_at', v_before->'ends_at_has_time', v_before->'is_published')
      is distinct from
        (v_after->'title', v_after->'starts_at', v_after->'starts_at_has_time',
         v_after->'ends_at', v_after->'ends_at_has_time', v_after->'is_published') then
    with affected as (
      update public.registrations r
      set import_status = 'reimport_needed', updated_at = now()
      where r.import_status = 'imported' and r.record_status = 'active'
        and exists (
          select 1 from public.registration_choices c
          where c.registration_id = r.id and c.activity_id = (v_after->>'id')::bigint
            and c.attending
        )
      returning r.id
    )
    insert into public.audit_events
      (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
    select 'admin', p_actor, 'registration.reimport_needed', 'registration', id,
      '{"import_status":"imported"}'::jsonb,
      '{"import_status":"reimport_needed"}'::jsonb
    from affected;
  end if;
  if (v_before - 'updated_at') is distinct from (v_after - 'updated_at') then
    insert into public.audit_events
      (actor_type, actor_user_id, action, target_type, before_data, after_data)
    values ('admin', p_actor, 'reference.saved', p_kind, v_before, v_after);
  end if;
  return v_after;
end;
$$;

-- ===== 202611050001_hosting.sql =====

-- 2026-11-05: 開家接待 (opening one's home to visiting saints). Each registration answers once:
-- 開家接待 with who and how many, 這次不參加開家接待, or 家人已登記接待. A family opens its home once,
-- so only one member answers 開家接待; the system cannot tell who belongs to the same family.
-- Apply after 202611040003. Deploy the registration and staff Edge Functions right after.

-- The public switch only controls the public page; staff can always edit hosting answers.
alter table public.site_settings
  add column is_hosting_open boolean not null default false,
  add column hosting_description text
    constraint site_settings_hosting_description_length check (length(hosting_description) <= 2000);

create table public.registration_hosting (
  registration_id uuid primary key references public.registrations(id) on delete cascade,
  status text not null check (status in ('hosting', 'not_hosting', 'family_registered')),
  guest_type text check (guest_type in ('brother', 'sister', 'family')),
  -- guest_count is the total of all families when guest_type is family; no upper limit was decided.
  guest_count integer check (guest_count >= 1),
  family_count integer check (family_count >= 1),
  note text check (length(note) between 1 and 200),
  updated_at timestamptz not null default now(),
  constraint registration_hosting_details check (
    case when status = 'hosting'
      then guest_type is not null and guest_count is not null
        and (guest_type = 'family') = (family_count is not null)
        and coalesce(family_count <= guest_count, true)
      else guest_type is null and guest_count is null and family_count is null and note is null
    end)
);
alter table public.registration_hosting enable row level security;
-- No public policy: only the Edge Functions (service_role) read or write hosting answers.
revoke all on public.registration_hosting from anon, authenticated;
grant select, insert, update, delete on public.registration_hosting to service_role;

-- Returns an answer in stored form, null for no answer (未回覆), or raises INVALID_HOSTING.
create function public.registration_hosting_value(p_hosting jsonb)
returns jsonb
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_status text;
  v_type text;
  v_count integer;
  v_families integer;
  v_note text;
begin
  if p_hosting is null or p_hosting = 'null'::jsonb then return null; end if;
  if jsonb_typeof(p_hosting) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;
  v_status := p_hosting->>'status';
  if v_status = 'hosting' then
    v_type := p_hosting->>'guest_type';
    -- Whole numbers only; a value too large for integer fails with 22003, also an input error.
    if coalesce(p_hosting->>'guest_count', '') !~ '^[0-9]{1,10}$'
      or (v_type = 'family' and coalesce(p_hosting->>'family_count', '') !~ '^[0-9]{1,10}$') then
      raise exception using errcode = '22023', message = 'INVALID_HOSTING';
    end if;
    v_count := (p_hosting->>'guest_count')::integer;
    if v_type = 'family' then v_families := (p_hosting->>'family_count')::integer; end if;
    v_note := nullif(btrim(p_hosting->>'note'), '');
    if v_type is null or v_type not in ('brother', 'sister', 'family') or v_count < 1
      or coalesce(v_families < 1 or v_families > v_count, false)
      or coalesce(length(v_note) > 200, false) then
      raise exception using errcode = '22023', message = 'INVALID_HOSTING';
    end if;
  elsif v_status is null or v_status not in ('not_hosting', 'family_registered') then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;
  return jsonb_build_object('status', v_status, 'guest_type', v_type, 'guest_count', v_count,
    'family_count', v_families, 'note', v_note);
end;
$$;

create function public.registration_hosting_get(p_registration_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object('status', status, 'guest_type', guest_type, 'guest_count', guest_count,
    'family_count', family_count, 'note', note)
  from public.registration_hosting where registration_id = p_registration_id;
$$;

-- p_value must come from registration_hosting_value.
create function public.registration_hosting_put(p_registration_id uuid, p_value jsonb)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.registration_hosting
    (registration_id, status, guest_type, guest_count, family_count, note)
  select p_registration_id, v.status, v.guest_type, v.guest_count, v.family_count, v.note
  from jsonb_to_record(p_value) as v(status text, guest_type text, guest_count integer, family_count integer, note text)
  on conflict (registration_id) do update set
    status = excluded.status, guest_type = excluded.guest_type, guest_count = excluded.guest_count,
    family_count = excluded.family_count, note = excluded.note, updated_at = now();
$$;

-- The public functions gain a hosting parameter (and get_registration a hosting column), so the
-- old versions are dropped. p_hosting defaults to null, so an Edge Function deployed before this
-- migration keeps working while hosting stays closed.
drop function public.create_registration(uuid, text, integer, jsonb);
drop function public.get_registration(text, integer);
drop function public.update_registration(text, integer, jsonb);
drop function public.staff_update_registration(uuid, uuid, text, integer, jsonb);
drop function public.staff_create_registration(uuid, uuid, text, integer, jsonb);

-- While hosting is open a new registration must answer it; while closed it must not send one,
-- so a page loaded before the switch closed cannot store an answer the registrant cannot see later.
create function public.create_registration(
  p_request_id uuid,
  p_full_name text,
  p_district_id integer,
  p_choices jsonb,
  p_hosting jsonb default null
)
returns table (registration_id uuid, serial_no bigint)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration_id uuid;
  v_serial_no bigint;
  v_hosting jsonb;
  v_hosting_open boolean;
begin
  if not exists (
    select 1 from public.site_settings
    where id and is_registration_open
      and (registration_deadline_at is null or registration_deadline_at > now())
  ) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;
  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = '' then
    raise exception using errcode = '22023', message = 'INVALID_NAME';
  end if;
  if not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_DISTRICT';
  end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_hosting := public.registration_hosting_value(p_hosting);
  select is_hosting_open into v_hosting_open from public.site_settings where id;
  if not v_hosting_open and v_hosting is not null then
    raise exception using errcode = 'P0001', message = 'HOSTING_CLOSED';
  end if;
  if v_hosting_open and v_hosting is null then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;

  update public.registration_create_limits
  set window_started_at = case when window_started_at <= now() - interval '10 minutes' then now() else window_started_at end,
      created_count = case when window_started_at <= now() - interval '10 minutes' then 1 else created_count + 1 end
  where id = true
    and (window_started_at <= now() - interval '10 minutes' or created_count < 50);
  if not found then
    raise exception using errcode = 'P0001', message = 'CREATE_RATE_LIMITED';
  end if;

  insert into public.registrations (create_request_id, full_name, district_id)
  values (p_request_id, btrim(p_full_name), p_district_id)
  returning id, registrations.serial_no into v_registration_id, v_serial_no;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice;
  if v_hosting is not null then perform public.registration_hosting_put(v_registration_id, v_hosting); end if;
  insert into public.audit_events (actor_type, action, target_type, target_id, after_data)
  values ('public', 'registration.created', 'registration', v_registration_id,
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id, 'hosting', v_hosting));

  return query select v_registration_id, v_serial_no;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where create_request_id = p_request_id) then
      raise exception using errcode = '23505', message = 'DUPLICATE_REQUEST';
    end if;
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- hosting is returned even while the public switch is closed, so registrants can still see their answer.
create function public.get_registration(p_full_name text, p_district_id integer)
returns table (
  full_name text,
  district_id integer,
  can_change boolean,
  choices jsonb,
  hosting jsonb
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if not exists (select 1 from public.site_settings where id and is_lookup_open) then
    raise exception using errcode = 'P0001', message = 'LOOKUP_CLOSED';
  end if;
  return query
  select registration.full_name,
    registration.district_id,
    settings.is_registration_open
      and (settings.registration_deadline_at is null or settings.registration_deadline_at > now()),
    coalesce(
      jsonb_agg(
        jsonb_build_object('activity_id', activity.id, 'title', activity.title, 'attending', choice.attending)
        order by activity.sort_order
      ) filter (where activity.id is not null),
      '[]'::jsonb
    ),
    public.registration_hosting_get(registration.id)
  from public.registrations registration
  cross join public.site_settings settings
  left join public.activities activity on activity.is_published
  left join public.registration_choices choice
    on choice.registration_id = registration.id and choice.activity_id = activity.id
  where registration.district_id = p_district_id
    and registration.name_key = public.registration_name_key(p_full_name)
    and registration.record_status = 'active'
  group by registration.id, settings.is_registration_open, settings.registration_deadline_at;
end;
$$;

-- The public can change activity choices and, while hosting is open, the hosting answer.
-- While hosting is closed an unchanged copy is accepted, so a page loaded earlier still saves its
-- activity choices; a changed answer is refused with HOSTING_CLOSED.
create function public.update_registration(
  p_full_name text,
  p_district_id integer,
  p_choices jsonb,
  p_hosting jsonb default null
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
  v_before_choices jsonb;
  v_after_choices jsonb;
  v_before_hosting jsonb;
  v_after_hosting jsonb;
  v_hosting_open boolean;
begin
  if not exists (
    select 1 from public.site_settings
    where id and is_registration_open
      and (registration_deadline_at is null or registration_deadline_at > now())
  ) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;
  if not exists (select 1 from public.site_settings where id and is_lookup_open) then
    raise exception using errcode = 'P0001', message = 'LOOKUP_CLOSED';
  end if;

  select * into v_registration from public.registrations
  where district_id = p_district_id and name_key = public.registration_name_key(p_full_name)
    and record_status = 'active'
  for update;
  if not found then return false; end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_before_hosting := public.registration_hosting_get(v_registration.id);
  v_after_hosting := public.registration_hosting_value(p_hosting);
  select is_hosting_open into v_hosting_open from public.site_settings where id;
  if v_hosting_open and v_after_hosting is null then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;
  if not v_hosting_open then
    if v_after_hosting is not null and v_after_hosting is distinct from v_before_hosting then
      raise exception using errcode = 'P0001', message = 'HOSTING_CLOSED';
    end if;
    v_after_hosting := v_before_hosting;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_before_choices
  from public.registration_choices where registration_id = v_registration.id
    and activity_id in (select id from public.activities where is_published);
  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_after_choices
  from (
    select (choice->>'activity_id')::bigint as activity_id, (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
  ) answers;
  if v_before_choices = v_after_choices and v_before_hosting is not distinct from v_after_hosting then
    return true;
  end if;

  -- Hosting answers are imported into the assembly system too, so any change needs a re-import.
  update public.registrations set
    import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = v_registration.id;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration.id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  on conflict (registration_id, activity_id) do update
    set attending = excluded.attending, updated_at = now();
  if v_after_hosting is distinct from v_before_hosting then
    perform public.registration_hosting_put(v_registration.id, v_after_hosting);
  end if;
  insert into public.audit_events (actor_type, action, target_type, target_id, before_data, after_data)
  values ('public', 'registration.updated', 'registration', v_registration.id,
    jsonb_build_object('choices', v_before_choices, 'hosting', v_before_hosting,
      'import_status', v_registration.import_status),
    jsonb_build_object('choices', v_after_choices, 'hosting', v_after_hosting,
      'import_status', case when v_registration.import_status = 'imported' then 'reimport_needed'
        else v_registration.import_status end));
  return true;
exception
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- Staff can edit hosting whether or not the public switch is open. Like an activity choice, an
-- existing answer cannot go back to 未回覆, but an unanswered one may stay unanswered.
create function public.staff_update_registration(
  p_actor uuid, p_registration_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
  v_before_choices jsonb;
  v_after_choices jsonb;
  v_before_hosting jsonb;
  v_after_hosting jsonb;
begin
  perform public.staff_assert_actor(p_actor);
  select * into v_registration from public.registrations
  where id = p_registration_id and record_status = 'active' for update;
  if not found then return false; end if;

  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = ''
    or not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_REGISTRATION';
  end if;
  if public.registration_choices_valid(p_choices, p_registration_id) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_before_hosting := public.registration_hosting_get(p_registration_id);
  v_after_hosting := public.registration_hosting_value(p_hosting);
  if v_after_hosting is null and v_before_hosting is not null then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_before_choices
  from public.registration_choices where registration_id = p_registration_id
    and activity_id in (select id from public.activities where is_published);
  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_after_choices
  from (
    select (choice->>'activity_id')::bigint as activity_id,
      (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
  ) answers;

  if v_registration.full_name = btrim(p_full_name) and v_registration.district_id = p_district_id
    and v_before_choices = v_after_choices
    and v_before_hosting is not distinct from v_after_hosting then return true; end if;

  update public.registrations set full_name = btrim(p_full_name), district_id = p_district_id,
    import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = p_registration_id;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select p_registration_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  on conflict (registration_id, activity_id) do update
    set attending = excluded.attending, updated_at = now();
  if v_after_hosting is distinct from v_before_hosting then
    perform public.registration_hosting_put(p_registration_id, v_after_hosting);
  end if;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  values ('staff', p_actor, 'registration.staff_updated', 'registration', p_registration_id,
    jsonb_build_object('full_name', v_registration.full_name, 'district_id', v_registration.district_id,
      'choices', v_before_choices, 'hosting', v_before_hosting, 'import_status', v_registration.import_status),
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id, 'choices', v_after_choices,
      'hosting', v_after_hosting,
      'import_status', case when v_registration.import_status = 'imported' then 'reimport_needed'
        else v_registration.import_status end));
  return true;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and id <> p_registration_id
        and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- A staff-created registration answers hosting like every activity, whether or not the public switch is open.
create function public.staff_create_registration(
  p_actor uuid, p_request_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null
)
returns table (registration_id uuid, serial_no bigint)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
  v_serial bigint;
  v_hosting jsonb;
begin
  perform public.staff_assert_actor(p_actor);
  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = ''
    or not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_REGISTRATION';
  end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_hosting := public.registration_hosting_value(p_hosting);
  if v_hosting is null then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;

  insert into public.registrations
    (create_request_id, full_name, district_id)
  values (p_request_id, btrim(p_full_name), p_district_id)
  returning id, registrations.serial_no into v_id, v_serial;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice;
  perform public.registration_hosting_put(v_id, v_hosting);
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, after_data)
  values ('staff', p_actor, 'registration.staff_created', 'registration', v_id,
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id, 'hosting', v_hosting));
  return query select v_id, v_serial;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where create_request_id = p_request_id) then
      raise exception using errcode = '23505', message = 'DUPLICATE_REQUEST';
    end if;
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- Same as 202611040003, plus the 'hosting' kind for the 開家接待設定 card.
create or replace function public.staff_save_reference(p_actor uuid, p_kind text, p_data jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_id bigint;
begin
  perform public.staff_assert_actor(p_actor, true);
  if jsonb_typeof(p_data) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_DATA';
  end if;

  if p_kind = 'settings' then
    select to_jsonb(s) into v_before from public.site_settings s where id for update;
    update public.site_settings set
      event_name = btrim(p_data->>'event_name'),
      venue = nullif(btrim(p_data->>'venue'), ''),
      address = nullif(btrim(p_data->>'address'), ''),
      registration_deadline_at = nullif(p_data->>'registration_deadline_at', '')::timestamptz,
      is_registration_open = (p_data->>'is_registration_open')::boolean,
      is_lookup_open = coalesce((p_data->>'is_lookup_open')::boolean, is_lookup_open),
      updated_at = now()
    where id returning to_jsonb(site_settings.*) into v_after;
  elsif p_kind = 'hosting' then
    select to_jsonb(s) into v_before from public.site_settings s where id for update;
    update public.site_settings set
      is_hosting_open = (p_data->>'is_hosting_open')::boolean,
      hosting_description = nullif(btrim(p_data->>'hosting_description'), ''),
      updated_at = now()
    where id returning to_jsonb(site_settings.*) into v_after;
  elsif p_kind = 'district' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.districts (name, sort_order)
      values (btrim(p_data->>'name'), (p_data->>'sort_order')::integer)
      returning to_jsonb(districts.*) into v_after;
    else
      select to_jsonb(d) into v_before from public.districts d where id = v_id for update;
      update public.districts set name = btrim(p_data->>'name'),
        sort_order = (p_data->>'sort_order')::integer
      where id = v_id returning to_jsonb(districts.*) into v_after;
    end if;
  elsif p_kind = 'activity' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.activities
        (category, title, starts_at, starts_at_has_time, ends_at, ends_at_has_time,
         venue, address, map_url, description, fee_amount, is_published, sort_order)
      values (
        p_data->>'category', btrim(p_data->>'title'),
        nullif(p_data->>'starts_at', '')::timestamptz,
        coalesce((p_data->>'starts_at_has_time')::boolean, nullif(p_data->>'starts_at', '') is not null),
        nullif(p_data->>'ends_at', '')::timestamptz,
        coalesce((p_data->>'ends_at_has_time')::boolean, nullif(p_data->>'ends_at', '') is not null),
        nullif(btrim(p_data->>'venue'), ''), nullif(btrim(p_data->>'address'), ''),
        nullif(btrim(p_data->>'map_url'), ''), nullif(btrim(p_data->>'description'), ''),
        nullif(p_data->>'fee_amount', '')::integer,
        (p_data->>'is_published')::boolean, (p_data->>'sort_order')::integer
      ) returning to_jsonb(activities.*) into v_after;
    else
      select to_jsonb(a) into v_before from public.activities a where id = v_id for update;
      update public.activities set
        category = p_data->>'category', title = btrim(p_data->>'title'),
        starts_at = nullif(p_data->>'starts_at', '')::timestamptz,
        starts_at_has_time = coalesce((p_data->>'starts_at_has_time')::boolean, nullif(p_data->>'starts_at', '') is not null),
        ends_at = nullif(p_data->>'ends_at', '')::timestamptz,
        ends_at_has_time = coalesce((p_data->>'ends_at_has_time')::boolean, nullif(p_data->>'ends_at', '') is not null),
        venue = nullif(btrim(p_data->>'venue'), ''),
        address = nullif(btrim(p_data->>'address'), ''),
        map_url = nullif(btrim(p_data->>'map_url'), ''),
        description = nullif(btrim(p_data->>'description'), ''),
        fee_amount = nullif(p_data->>'fee_amount', '')::integer,
        is_published = (p_data->>'is_published')::boolean,
        sort_order = (p_data->>'sort_order')::integer,
        updated_at = now()
      where id = v_id returning to_jsonb(activities.*) into v_after;
    end if;
  elsif p_kind = 'program' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.program_items
        (event_date, start_time, end_time, title, note, sort_order, is_visible)
      values (
        (p_data->>'event_date')::date, nullif(p_data->>'start_time', '')::time,
        nullif(p_data->>'end_time', '')::time, btrim(p_data->>'title'),
        nullif(btrim(p_data->>'note'), ''), (p_data->>'sort_order')::integer,
        (p_data->>'is_visible')::boolean
      ) returning to_jsonb(program_items.*) into v_after;
    else
      select to_jsonb(p) into v_before from public.program_items p where id = v_id for update;
      update public.program_items set
        event_date = (p_data->>'event_date')::date,
        start_time = nullif(p_data->>'start_time', '')::time,
        end_time = nullif(p_data->>'end_time', '')::time,
        title = btrim(p_data->>'title'), note = nullif(btrim(p_data->>'note'), ''),
        sort_order = (p_data->>'sort_order')::integer,
        is_visible = (p_data->>'is_visible')::boolean
      where id = v_id returning to_jsonb(program_items.*) into v_after;
    end if;
  else
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_KIND';
  end if;

  if v_after is null then
    raise exception using errcode = '22023', message = 'REFERENCE_NOT_FOUND';
  end if;
  if p_kind = 'activity' and v_before is not null
    and (v_before->'title', v_before->'starts_at', v_before->'starts_at_has_time',
         v_before->'ends_at', v_before->'ends_at_has_time', v_before->'is_published')
      is distinct from
        (v_after->'title', v_after->'starts_at', v_after->'starts_at_has_time',
         v_after->'ends_at', v_after->'ends_at_has_time', v_after->'is_published') then
    with affected as (
      update public.registrations r
      set import_status = 'reimport_needed', updated_at = now()
      where r.import_status = 'imported' and r.record_status = 'active'
        and exists (
          select 1 from public.registration_choices c
          where c.registration_id = r.id and c.activity_id = (v_after->>'id')::bigint
            and c.attending
        )
      returning r.id
    )
    insert into public.audit_events
      (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
    select 'admin', p_actor, 'registration.reimport_needed', 'registration', id,
      '{"import_status":"imported"}'::jsonb,
      '{"import_status":"reimport_needed"}'::jsonb
    from affected;
  end if;
  if (v_before - 'updated_at') is distinct from (v_after - 'updated_at') then
    insert into public.audit_events
      (actor_type, actor_user_id, action, target_type, before_data, after_data)
    values ('admin', p_actor, 'reference.saved', p_kind, v_before, v_after);
  end if;
  return v_after;
end;
$$;

revoke execute on function public.registration_hosting_value(jsonb) from public, anon, authenticated;
revoke execute on function public.registration_hosting_get(uuid) from public, anon, authenticated;
revoke execute on function public.registration_hosting_put(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public.create_registration(uuid, text, integer, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.get_registration(text, integer) from public, anon, authenticated;
revoke execute on function public.update_registration(text, integer, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.staff_update_registration(uuid, uuid, text, integer, jsonb, jsonb) from public, anon, authenticated;
revoke execute on function public.staff_create_registration(uuid, uuid, text, integer, jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.registration_hosting_value(jsonb) to service_role;
grant execute on function public.registration_hosting_get(uuid) to service_role;
grant execute on function public.registration_hosting_put(uuid, jsonb) to service_role;
grant execute on function public.create_registration(uuid, text, integer, jsonb, jsonb) to service_role;
grant execute on function public.get_registration(text, integer) to service_role;
grant execute on function public.update_registration(text, integer, jsonb, jsonb) to service_role;
grant execute on function public.staff_update_registration(uuid, uuid, text, integer, jsonb, jsonb) to service_role;
grant execute on function public.staff_create_registration(uuid, uuid, text, integer, jsonb, jsonb) to service_role;

-- ===== 202611050002_hosting_review_fixes.sql =====

-- 2026-11-05: code review fixes for 開家接待, applied after 202611050001_hosting.sql (already run
-- on the test project, so that file stays as it was applied). Same function signatures, so
-- create or replace keeps the existing grants.
--   * A request without a hosting answer keeps the stored one. Only a registration that never
--     answered gets HOSTING_REQUIRED while hosting is open (not INVALID_HOSTING), so a page loaded
--     before the switch opened can show the hosting fields instead of failing.
--   * Staff 補登 must answer hosting only while the switch is open, like the public form, so
--     Edge Functions deployed before this change keep working until the switch opens.
--   * Notes are trimmed like the page trims them, so an unchanged answer compares equal.
--   * site_settings is read once per call.
--   * Guest and family counts are 1 to 99 (decided 2026-11-05), checked here and by the table.

-- Fails, and the whole migration rolls back, if an existing answer is above 99; fix that row first.
alter table public.registration_hosting
  add constraint registration_hosting_counts_max check (guest_count <= 99 and family_count <= 99);

create or replace function public.registration_hosting_value(p_hosting jsonb)
returns jsonb
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_status text;
  v_type text;
  v_count integer;
  v_families integer;
  v_note text;
begin
  if p_hosting is null or p_hosting = 'null'::jsonb then return null; end if;
  if jsonb_typeof(p_hosting) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;
  v_status := p_hosting->>'status';
  if v_status = 'hosting' then
    v_type := p_hosting->>'guest_type';
    -- Whole numbers of at most two digits (1 to 99); anything else is INVALID_HOSTING.
    if coalesce(p_hosting->>'guest_count', '') !~ '^[0-9]{1,2}$'
      or (v_type = 'family' and coalesce(p_hosting->>'family_count', '') !~ '^[0-9]{1,2}$') then
      raise exception using errcode = '22023', message = 'INVALID_HOSTING';
    end if;
    v_count := (p_hosting->>'guest_count')::integer;
    if v_type = 'family' then v_families := (p_hosting->>'family_count')::integer; end if;
    -- Trims exactly what JavaScript's trim() trims (ECMAScript WhiteSpace and LineTerminator), so an
    -- answer the page sends back unchanged compares equal to the stored one. An explicit list, not
    -- the locale-dependent \s; ASCII escapes, because editors silently drop invisible characters.
    v_note := nullif(regexp_replace(p_hosting->>'note',
      '^[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+|[\t\n\v\f\r \u00a0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000\ufeff]+$',
      '', 'g'), '');
    if v_type is null or v_type not in ('brother', 'sister', 'family') or v_count < 1
      or coalesce(v_families < 1 or v_families > v_count, false)
      or coalesce(length(v_note) > 200, false) then
      raise exception using errcode = '22023', message = 'INVALID_HOSTING';
    end if;
  elsif v_status is null or v_status not in ('not_hosting', 'family_registered') then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;
  return jsonb_build_object('status', v_status, 'guest_type', v_type, 'guest_count', v_count,
    'family_count', v_families, 'note', v_note);
end;
$$;

create or replace function public.create_registration(
  p_request_id uuid,
  p_full_name text,
  p_district_id integer,
  p_choices jsonb,
  p_hosting jsonb default null
)
returns table (registration_id uuid, serial_no bigint)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration_id uuid;
  v_serial_no bigint;
  v_hosting jsonb;
  v_settings public.site_settings%rowtype;
begin
  select * into v_settings from public.site_settings where id;
  if not coalesce(v_settings.is_registration_open
      and (v_settings.registration_deadline_at is null or v_settings.registration_deadline_at > now()), false) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;
  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = '' then
    raise exception using errcode = '22023', message = 'INVALID_NAME';
  end if;
  if not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_DISTRICT';
  end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_hosting := public.registration_hosting_value(p_hosting);
  if not v_settings.is_hosting_open and v_hosting is not null then
    raise exception using errcode = 'P0001', message = 'HOSTING_CLOSED';
  end if;
  if v_settings.is_hosting_open and v_hosting is null then
    raise exception using errcode = 'P0001', message = 'HOSTING_REQUIRED';
  end if;

  update public.registration_create_limits
  set window_started_at = case when window_started_at <= now() - interval '10 minutes' then now() else window_started_at end,
      created_count = case when window_started_at <= now() - interval '10 minutes' then 1 else created_count + 1 end
  where id = true
    and (window_started_at <= now() - interval '10 minutes' or created_count < 50);
  if not found then
    raise exception using errcode = 'P0001', message = 'CREATE_RATE_LIMITED';
  end if;

  insert into public.registrations (create_request_id, full_name, district_id)
  values (p_request_id, btrim(p_full_name), p_district_id)
  returning id, registrations.serial_no into v_registration_id, v_serial_no;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice;
  if v_hosting is not null then perform public.registration_hosting_put(v_registration_id, v_hosting); end if;
  insert into public.audit_events (actor_type, action, target_type, target_id, after_data)
  values ('public', 'registration.created', 'registration', v_registration_id,
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id, 'hosting', v_hosting));

  return query select v_registration_id, v_serial_no;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where create_request_id = p_request_id) then
      raise exception using errcode = '23505', message = 'DUPLICATE_REQUEST';
    end if;
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

create or replace function public.update_registration(
  p_full_name text,
  p_district_id integer,
  p_choices jsonb,
  p_hosting jsonb default null
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
  v_before_choices jsonb;
  v_after_choices jsonb;
  v_before_hosting jsonb;
  v_after_hosting jsonb;
  v_settings public.site_settings%rowtype;
begin
  select * into v_settings from public.site_settings where id;
  if not coalesce(v_settings.is_registration_open
      and (v_settings.registration_deadline_at is null or v_settings.registration_deadline_at > now()), false) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;
  if not coalesce(v_settings.is_lookup_open, false) then
    raise exception using errcode = 'P0001', message = 'LOOKUP_CLOSED';
  end if;

  select * into v_registration from public.registrations
  where district_id = p_district_id and name_key = public.registration_name_key(p_full_name)
    and record_status = 'active'
  for update;
  if not found then return false; end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_before_hosting := public.registration_hosting_get(v_registration.id);
  v_after_hosting := public.registration_hosting_value(p_hosting);
  if not v_settings.is_hosting_open
    and v_after_hosting is not null and v_after_hosting is distinct from v_before_hosting then
    raise exception using errcode = 'P0001', message = 'HOSTING_CLOSED';
  end if;
  -- No answer sent keeps the stored one: a page loaded before the switch opened, or an older page
  -- or Edge Function, sends none. Only a registration that never answered must answer now.
  v_after_hosting := case when v_settings.is_hosting_open then coalesce(v_after_hosting, v_before_hosting)
    else v_before_hosting end;
  if v_after_hosting is null and v_settings.is_hosting_open then
    raise exception using errcode = 'P0001', message = 'HOSTING_REQUIRED';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_before_choices
  from public.registration_choices where registration_id = v_registration.id
    and activity_id in (select id from public.activities where is_published);
  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_after_choices
  from (
    select (choice->>'activity_id')::bigint as activity_id, (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
  ) answers;
  if v_before_choices = v_after_choices and v_before_hosting is not distinct from v_after_hosting then
    return true;
  end if;

  -- Hosting answers are imported into the assembly system too, so any change needs a re-import.
  update public.registrations set
    import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = v_registration.id;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration.id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  on conflict (registration_id, activity_id) do update
    set attending = excluded.attending, updated_at = now();
  if v_after_hosting is distinct from v_before_hosting then
    perform public.registration_hosting_put(v_registration.id, v_after_hosting);
  end if;
  insert into public.audit_events (actor_type, action, target_type, target_id, before_data, after_data)
  values ('public', 'registration.updated', 'registration', v_registration.id,
    jsonb_build_object('choices', v_before_choices, 'hosting', v_before_hosting,
      'import_status', v_registration.import_status),
    jsonb_build_object('choices', v_after_choices, 'hosting', v_after_hosting,
      'import_status', case when v_registration.import_status = 'imported' then 'reimport_needed'
        else v_registration.import_status end));
  return true;
exception
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

create or replace function public.staff_create_registration(
  p_actor uuid, p_request_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null
)
returns table (registration_id uuid, serial_no bigint)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
  v_serial bigint;
  v_hosting jsonb;
begin
  perform public.staff_assert_actor(p_actor);
  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = ''
    or not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_REGISTRATION';
  end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_hosting := public.registration_hosting_value(p_hosting);
  if v_hosting is null and coalesce((select is_hosting_open from public.site_settings where id), false) then
    raise exception using errcode = 'P0001', message = 'HOSTING_REQUIRED';
  end if;

  insert into public.registrations
    (create_request_id, full_name, district_id)
  values (p_request_id, btrim(p_full_name), p_district_id)
  returning id, registrations.serial_no into v_id, v_serial;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice;
  if v_hosting is not null then perform public.registration_hosting_put(v_id, v_hosting); end if;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, after_data)
  values ('staff', p_actor, 'registration.staff_created', 'registration', v_id,
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id, 'hosting', v_hosting));
  return query select v_id, v_serial;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where create_request_id = p_request_id) then
      raise exception using errcode = '23505', message = 'DUPLICATE_REQUEST';
    end if;
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- Staff can edit hosting whether or not the public switch is open. Like an activity choice, an
-- existing answer cannot go back to 未回覆 (no answer sent keeps it), and an unanswered one may stay so.
create or replace function public.staff_update_registration(
  p_actor uuid, p_registration_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
  v_before_choices jsonb;
  v_after_choices jsonb;
  v_before_hosting jsonb;
  v_after_hosting jsonb;
begin
  perform public.staff_assert_actor(p_actor);
  select * into v_registration from public.registrations
  where id = p_registration_id and record_status = 'active' for update;
  if not found then return false; end if;

  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = ''
    or not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_REGISTRATION';
  end if;
  if public.registration_choices_valid(p_choices, p_registration_id) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_before_hosting := public.registration_hosting_get(p_registration_id);
  -- No answer sent keeps the stored one (for example a cached older back-office page).
  v_after_hosting := coalesce(public.registration_hosting_value(p_hosting), v_before_hosting);

  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_before_choices
  from public.registration_choices where registration_id = p_registration_id
    and activity_id in (select id from public.activities where is_published);
  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_after_choices
  from (
    select (choice->>'activity_id')::bigint as activity_id,
      (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
  ) answers;

  if v_registration.full_name = btrim(p_full_name) and v_registration.district_id = p_district_id
    and v_before_choices = v_after_choices
    and v_before_hosting is not distinct from v_after_hosting then return true; end if;

  update public.registrations set full_name = btrim(p_full_name), district_id = p_district_id,
    import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = p_registration_id;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select p_registration_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  on conflict (registration_id, activity_id) do update
    set attending = excluded.attending, updated_at = now();
  if v_after_hosting is distinct from v_before_hosting then
    perform public.registration_hosting_put(p_registration_id, v_after_hosting);
  end if;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  values ('staff', p_actor, 'registration.staff_updated', 'registration', p_registration_id,
    jsonb_build_object('full_name', v_registration.full_name, 'district_id', v_registration.district_id,
      'choices', v_before_choices, 'hosting', v_before_hosting, 'import_status', v_registration.import_status),
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id, 'choices', v_after_choices,
      'hosting', v_after_hosting,
      'import_status', case when v_registration.import_status = 'imported' then 'reimport_needed'
        else v_registration.import_status end));
  return true;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and id <> p_registration_id
        and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- ===== 202611050003_staff_account_management.sql =====

-- 2026-11-05: admins manage staff accounts directly. An admin sets a staff password and the person
-- does not have to change it; an admin can rename an account (display name and login name).
-- Accounts no longer belong to a district; staff_profiles.district_id stays for older rows.
-- Passwords themselves live only in Supabase Auth and never reach these functions or the audit.
-- Apply after 202611050002. Deploy the staff Edge Function right after.

-- Same as 202611040001 except that a staff account keeps the admin-set password, a new admin
-- account must change it at first login (like a password set for another admin), and accounts no
-- longer have a district: p_district_id stays only for the existing signature and is ignored.
create or replace function public.staff_create_profile(
  p_actor uuid, p_user_id uuid, p_username text, p_display_name text,
  p_role text, p_district_id integer
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform public.staff_assert_actor(p_actor, true);
  if p_role not in ('admin', 'staff') or length(p_display_name) not between 1 and 100 then
    raise exception using errcode = '22023', message = 'INVALID_STAFF_PROFILE';
  end if;
  insert into public.staff_profiles
    (auth_user_id, username, display_name, district_id, role, must_change_password)
  values (p_user_id, p_username, p_display_name, null, p_role, p_role = 'admin');
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, after_data)
  values ('admin', p_actor, 'staff.created', 'staff_profile', p_user_id,
    jsonb_build_object('username', p_username, 'role', p_role));
end;
$$;

-- Renames an account. The Edge Function changes the Auth login (username@accounts.invalid) first,
-- then compares it with the name this table holds and fixes it; saving again repairs a mismatch.
create function public.staff_update_profile(
  p_actor uuid, p_user_id uuid, p_username text, p_display_name text
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_before public.staff_profiles%rowtype;
begin
  perform public.staff_assert_actor(p_actor, true);
  if coalesce(p_username, '') !~ '^[a-z][a-z0-9_-]{2,30}$'
    or coalesce(length(btrim(p_display_name)), 0) not between 1 and 100 then
    raise exception using errcode = '22023', message = 'INVALID_STAFF_PROFILE';
  end if;
  select * into v_before from public.staff_profiles where auth_user_id = p_user_id for update;
  if not found then
    raise exception using errcode = '22023', message = 'STAFF_NOT_FOUND';
  end if;
  if v_before.username = p_username and v_before.display_name = btrim(p_display_name) then return; end if;
  update public.staff_profiles set username = p_username, display_name = btrim(p_display_name)
  where auth_user_id = p_user_id;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  values ('admin', p_actor, 'staff.updated', 'staff_profile', p_user_id,
    jsonb_build_object('username', v_before.username, 'display_name', v_before.display_name),
    jsonb_build_object('username', p_username, 'display_name', btrim(p_display_name)));
exception
  when unique_violation then
    raise exception using errcode = '23505', message = 'USERNAME_TAKEN';
end;
$$;

-- Step 1 of an admin setting another account's password, before the password changes: confirms
-- the caller and target. Its only change marks an admin target to change the password, which is
-- safe even if the password then fails to change. Admins change their own password with the
-- current one instead.
create function public.staff_check_password_set(p_actor uuid, p_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform public.staff_assert_actor(p_actor, true);
  if p_actor = p_user_id then
    raise exception using errcode = '22023', message = 'SELF_PASSWORD_SET';
  end if;
  update public.staff_profiles set must_change_password = must_change_password or role = 'admin'
  where auth_user_id = p_user_id;
  if not found then
    raise exception using errcode = '22023', message = 'STAFF_NOT_FOUND';
  end if;
end;
$$;

-- Step 3, after the password changed: ends that account's logins and audits the change. A staff
-- account keeps the admin-set password. Another admin must change it at the next login, so one
-- admin cannot quietly keep a password that signs in as a different admin.
create function public.staff_mark_password_set(p_actor uuid, p_user_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_must_change boolean;
begin
  perform public.staff_assert_actor(p_actor, true);
  if p_actor = p_user_id then
    raise exception using errcode = '22023', message = 'SELF_PASSWORD_SET';
  end if;
  update public.staff_profiles set must_change_password = (role = 'admin')
  where auth_user_id = p_user_id
  returning must_change_password into v_must_change;
  if not found then
    raise exception using errcode = '22023', message = 'STAFF_NOT_FOUND';
  end if;
  perform public.staff_revoke_sessions(p_user_id);
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, after_data)
  values ('admin', p_actor, 'staff.password_set', 'staff_profile', p_user_id,
    jsonb_build_object('must_change_password', v_must_change));
  return v_must_change;
end;
$$;

-- Replaced by staff_mark_password_set; it would force a change the new policy no longer asks for.
drop function public.staff_mark_password_reset(uuid, uuid);

revoke execute on function public.staff_update_profile(uuid, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.staff_check_password_set(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.staff_mark_password_set(uuid, uuid) from public, anon, authenticated;
grant execute on function public.staff_update_profile(uuid, uuid, text, text) to service_role;
grant execute on function public.staff_check_password_set(uuid, uuid) to service_role;
grant execute on function public.staff_mark_password_set(uuid, uuid) to service_role;

-- ===== 202611050004_hosting_dropdowns_site_note_other_district.sql =====

-- 2026-11-05: changes from the test-site trial feedback. Apply after 202611050003.
-- Deploy the registration and staff Edge Functions and the site right after.
--   * 開家接待 asks 是／否／家人已登記開家接待, then 可以接待幾位 (1 to 10 people) and 接待對象
--     (夫婦／弟兄／姊妹／不拘). The family count and the free-text note are removed.
--     Existing test answers are converted (家庭 becomes 不拘, more than 10 becomes 10, family
--     count and note cleared); the conversion leaves import_status alone, since the registrant
--     changed nothing.
--   * family_count and note stay as always-null columns, because the staff Edge Function deployed
--     before this change still selects them; drop them in a later migration once both Edge
--     Functions are redeployed. The new Edge Functions read event_note, so deploy them after this.
--   * site_settings.event_note: an optional note of up to 500 characters (traffic, links) shown
--     under the address on the public page.
--   * A district 其他 for people outside the three districts.
-- Replaced functions keep their signatures, so create or replace keeps the existing grants.

alter table public.registration_hosting
  drop constraint registration_hosting_details,
  drop constraint registration_hosting_counts_max,
  drop constraint registration_hosting_guest_type_check;

update public.registration_hosting set
  guest_type = case when guest_type = 'family' then 'any' else guest_type end,
  guest_count = least(guest_count, 10),
  family_count = null,
  note = null
where guest_type = 'family' or guest_count > 10 or family_count is not null or note is not null;

alter table public.registration_hosting
  add constraint registration_hosting_removed_fields check (family_count is null and note is null),
  add constraint registration_hosting_guest_type_check
    check (guest_type in ('couple', 'brother', 'sister', 'any')),
  add constraint registration_hosting_counts_max check (guest_count <= 10),
  add constraint registration_hosting_details check (
    case when status = 'hosting' then guest_type is not null and guest_count is not null
      else guest_type is null and guest_count is null end);

-- Same contract as before: the answer in stored form, null for no answer (未回覆), or INVALID_HOSTING.
create or replace function public.registration_hosting_value(p_hosting jsonb)
returns jsonb
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_status text;
  v_type text;
  v_count integer;
begin
  if p_hosting is null or p_hosting = 'null'::jsonb then return null; end if;
  if jsonb_typeof(p_hosting) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;
  v_status := p_hosting->>'status';
  if v_status = 'hosting' then
    v_type := p_hosting->>'guest_type';
    if coalesce(p_hosting->>'guest_count', '') !~ '^([1-9]|10)$'
      or v_type is null or v_type not in ('couple', 'brother', 'sister', 'any') then
      raise exception using errcode = '22023', message = 'INVALID_HOSTING';
    end if;
    v_count := (p_hosting->>'guest_count')::integer;
  elsif v_status is null or v_status not in ('not_hosting', 'family_registered') then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;
  return jsonb_build_object('status', v_status, 'guest_type', v_type, 'guest_count', v_count);
end;
$$;

create or replace function public.registration_hosting_get(p_registration_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object('status', status, 'guest_type', guest_type, 'guest_count', guest_count)
  from public.registration_hosting where registration_id = p_registration_id;
$$;

-- p_value must come from registration_hosting_value.
create or replace function public.registration_hosting_put(p_registration_id uuid, p_value jsonb)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.registration_hosting (registration_id, status, guest_type, guest_count)
  select p_registration_id, v.status, v.guest_type, v.guest_count
  from jsonb_to_record(p_value) as v(status text, guest_type text, guest_count integer)
  on conflict (registration_id) do update set
    status = excluded.status, guest_type = excluded.guest_type, guest_count = excluded.guest_count,
    updated_at = now();
$$;

alter table public.site_settings
  add column event_note text
    constraint site_settings_event_note_length check (length(event_note) <= 500);

-- Same as 202611050001, plus event_note in 'settings'. A request without event_note (an Edge
-- Function or page from before this change) keeps the stored note instead of clearing it.
create or replace function public.staff_save_reference(p_actor uuid, p_kind text, p_data jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_id bigint;
begin
  perform public.staff_assert_actor(p_actor, true);
  if jsonb_typeof(p_data) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_DATA';
  end if;

  if p_kind = 'settings' then
    select to_jsonb(s) into v_before from public.site_settings s where id for update;
    update public.site_settings set
      event_name = btrim(p_data->>'event_name'),
      venue = nullif(btrim(p_data->>'venue'), ''),
      address = nullif(btrim(p_data->>'address'), ''),
      -- A textarea: also trims line breaks, tabs and full-width spaces (an ASCII escape, since editors
      -- drop invisible characters), so a blank note clears it.
      event_note = case when p_data ? 'event_note'
        then nullif(btrim(p_data->>'event_note', E' \t\r\n\u3000'), '') else event_note end,
      registration_deadline_at = nullif(p_data->>'registration_deadline_at', '')::timestamptz,
      is_registration_open = (p_data->>'is_registration_open')::boolean,
      is_lookup_open = coalesce((p_data->>'is_lookup_open')::boolean, is_lookup_open),
      updated_at = now()
    where id returning to_jsonb(site_settings.*) into v_after;
  elsif p_kind = 'hosting' then
    select to_jsonb(s) into v_before from public.site_settings s where id for update;
    update public.site_settings set
      is_hosting_open = (p_data->>'is_hosting_open')::boolean,
      hosting_description = nullif(btrim(p_data->>'hosting_description'), ''),
      updated_at = now()
    where id returning to_jsonb(site_settings.*) into v_after;
  elsif p_kind = 'district' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.districts (name, sort_order)
      values (btrim(p_data->>'name'), (p_data->>'sort_order')::integer)
      returning to_jsonb(districts.*) into v_after;
    else
      select to_jsonb(d) into v_before from public.districts d where id = v_id for update;
      update public.districts set name = btrim(p_data->>'name'),
        sort_order = (p_data->>'sort_order')::integer
      where id = v_id returning to_jsonb(districts.*) into v_after;
    end if;
  elsif p_kind = 'activity' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.activities
        (category, title, starts_at, starts_at_has_time, ends_at, ends_at_has_time,
         venue, address, map_url, description, fee_amount, is_published, sort_order)
      values (
        p_data->>'category', btrim(p_data->>'title'),
        nullif(p_data->>'starts_at', '')::timestamptz,
        coalesce((p_data->>'starts_at_has_time')::boolean, nullif(p_data->>'starts_at', '') is not null),
        nullif(p_data->>'ends_at', '')::timestamptz,
        coalesce((p_data->>'ends_at_has_time')::boolean, nullif(p_data->>'ends_at', '') is not null),
        nullif(btrim(p_data->>'venue'), ''), nullif(btrim(p_data->>'address'), ''),
        nullif(btrim(p_data->>'map_url'), ''), nullif(btrim(p_data->>'description'), ''),
        nullif(p_data->>'fee_amount', '')::integer,
        (p_data->>'is_published')::boolean, (p_data->>'sort_order')::integer
      ) returning to_jsonb(activities.*) into v_after;
    else
      select to_jsonb(a) into v_before from public.activities a where id = v_id for update;
      update public.activities set
        category = p_data->>'category', title = btrim(p_data->>'title'),
        starts_at = nullif(p_data->>'starts_at', '')::timestamptz,
        starts_at_has_time = coalesce((p_data->>'starts_at_has_time')::boolean, nullif(p_data->>'starts_at', '') is not null),
        ends_at = nullif(p_data->>'ends_at', '')::timestamptz,
        ends_at_has_time = coalesce((p_data->>'ends_at_has_time')::boolean, nullif(p_data->>'ends_at', '') is not null),
        venue = nullif(btrim(p_data->>'venue'), ''),
        address = nullif(btrim(p_data->>'address'), ''),
        map_url = nullif(btrim(p_data->>'map_url'), ''),
        description = nullif(btrim(p_data->>'description'), ''),
        fee_amount = nullif(p_data->>'fee_amount', '')::integer,
        is_published = (p_data->>'is_published')::boolean,
        sort_order = (p_data->>'sort_order')::integer,
        updated_at = now()
      where id = v_id returning to_jsonb(activities.*) into v_after;
    end if;
  elsif p_kind = 'program' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.program_items
        (event_date, start_time, end_time, title, note, sort_order, is_visible)
      values (
        (p_data->>'event_date')::date, nullif(p_data->>'start_time', '')::time,
        nullif(p_data->>'end_time', '')::time, btrim(p_data->>'title'),
        nullif(btrim(p_data->>'note'), ''), (p_data->>'sort_order')::integer,
        (p_data->>'is_visible')::boolean
      ) returning to_jsonb(program_items.*) into v_after;
    else
      select to_jsonb(p) into v_before from public.program_items p where id = v_id for update;
      update public.program_items set
        event_date = (p_data->>'event_date')::date,
        start_time = nullif(p_data->>'start_time', '')::time,
        end_time = nullif(p_data->>'end_time', '')::time,
        title = btrim(p_data->>'title'), note = nullif(btrim(p_data->>'note'), ''),
        sort_order = (p_data->>'sort_order')::integer,
        is_visible = (p_data->>'is_visible')::boolean
      where id = v_id returning to_jsonb(program_items.*) into v_after;
    end if;
  else
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_KIND';
  end if;

  if v_after is null then
    raise exception using errcode = '22023', message = 'REFERENCE_NOT_FOUND';
  end if;
  if p_kind = 'activity' and v_before is not null
    and (v_before->'title', v_before->'starts_at', v_before->'starts_at_has_time',
         v_before->'ends_at', v_before->'ends_at_has_time', v_before->'is_published')
      is distinct from
        (v_after->'title', v_after->'starts_at', v_after->'starts_at_has_time',
         v_after->'ends_at', v_after->'ends_at_has_time', v_after->'is_published') then
    with affected as (
      update public.registrations r
      set import_status = 'reimport_needed', updated_at = now()
      where r.import_status = 'imported' and r.record_status = 'active'
        and exists (
          select 1 from public.registration_choices c
          where c.registration_id = r.id and c.activity_id = (v_after->>'id')::bigint
            and c.attending
        )
      returning r.id
    )
    insert into public.audit_events
      (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
    select 'admin', p_actor, 'registration.reimport_needed', 'registration', id,
      '{"import_status":"imported"}'::jsonb,
      '{"import_status":"reimport_needed"}'::jsonb
    from affected;
  end if;
  if (v_before - 'updated_at') is distinct from (v_after - 'updated_at') then
    insert into public.audit_events
      (actor_type, actor_user_id, action, target_type, before_data, after_data)
    values ('admin', p_actor, 'reference.saved', p_kind, v_before, v_after);
  end if;
  return v_after;
end;
$$;

insert into public.districts (name, sort_order)
select '其他', coalesce(max(sort_order), 0) + 1 from public.districts
on conflict (name) do nothing;

-- ===== 202611050005_hosting_pickup.sql =====

-- 2026-11-05: 接機 in the 開家接待 answer. Apply after 202611050004, then deploy
-- the staff Edge Function (it selects pickup_count, so not before this), then the site (it sends
-- pickup_count, which an older database would drop). The registration Edge Function is unchanged.
--   * Every answer, whatever its status, carries pickup_count: how many visiting saints the person
--     can take from the airport on or before 2/19, 0 to 6 (0 = cannot). Existing answers get 0.
--   * A request without pickup_count comes from a page cached before this change: an update keeps
--     the stored count (update_registration and staff_update_registration below, otherwise the same
--     as 202611050002), and a new registration gets 0, the page's default.
--   * A changed pickup_count makes an imported registration 需重新匯入, like the other hosting fields,
--     because the create/update functions compare whole answers.
-- Replaced functions keep their signatures, so create or replace keeps the existing grants.

alter table public.registration_hosting
  add column pickup_count integer not null default 0
    constraint registration_hosting_pickup_count check (pickup_count between 0 and 6);

create or replace function public.registration_hosting_value(p_hosting jsonb)
returns jsonb
language plpgsql
immutable
security invoker
set search_path = ''
as $$
declare
  v_status text;
  v_type text;
  v_count integer;
begin
  if p_hosting is null or p_hosting = 'null'::jsonb then return null; end if;
  if jsonb_typeof(p_hosting) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;
  v_status := p_hosting->>'status';
  if v_status = 'hosting' then
    v_type := p_hosting->>'guest_type';
    if coalesce(p_hosting->>'guest_count', '') !~ '^([1-9]|10)$'
      or v_type is null or v_type not in ('couple', 'brother', 'sister', 'any') then
      raise exception using errcode = '22023', message = 'INVALID_HOSTING';
    end if;
    v_count := (p_hosting->>'guest_count')::integer;
  elsif v_status is null or v_status not in ('not_hosting', 'family_registered') then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;
  if coalesce(p_hosting->>'pickup_count', '0') !~ '^[0-6]$' then
    raise exception using errcode = '22023', message = 'INVALID_HOSTING';
  end if;
  return jsonb_build_object('status', v_status, 'guest_type', v_type, 'guest_count', v_count,
    'pickup_count', coalesce(p_hosting->>'pickup_count', '0')::integer);
end;
$$;

create or replace function public.registration_hosting_get(p_registration_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object('status', status, 'guest_type', guest_type, 'guest_count', guest_count,
    'pickup_count', pickup_count)
  from public.registration_hosting where registration_id = p_registration_id;
$$;

-- p_value must come from registration_hosting_value.
create or replace function public.registration_hosting_put(p_registration_id uuid, p_value jsonb)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.registration_hosting (registration_id, status, guest_type, guest_count, pickup_count)
  select p_registration_id, v.status, v.guest_type, v.guest_count, v.pickup_count
  from jsonb_to_record(p_value) as v(status text, guest_type text, guest_count integer, pickup_count integer)
  on conflict (registration_id) do update set
    status = excluded.status, guest_type = excluded.guest_type, guest_count = excluded.guest_count,
    pickup_count = excluded.pickup_count, updated_at = now();
$$;

create or replace function public.update_registration(
  p_full_name text,
  p_district_id integer,
  p_choices jsonb,
  p_hosting jsonb default null
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
  v_before_choices jsonb;
  v_after_choices jsonb;
  v_before_hosting jsonb;
  v_after_hosting jsonb;
  v_settings public.site_settings%rowtype;
begin
  select * into v_settings from public.site_settings where id;
  if not coalesce(v_settings.is_registration_open
      and (v_settings.registration_deadline_at is null or v_settings.registration_deadline_at > now()), false) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;
  if not coalesce(v_settings.is_lookup_open, false) then
    raise exception using errcode = 'P0001', message = 'LOOKUP_CLOSED';
  end if;

  select * into v_registration from public.registrations
  where district_id = p_district_id and name_key = public.registration_name_key(p_full_name)
    and record_status = 'active'
  for update;
  if not found then return false; end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_before_hosting := public.registration_hosting_get(v_registration.id);
  -- An older page sends no pickup_count; keep the stored one instead of resetting it to 0.
  -- ->> is null also covers an explicit JSON null, which registration_hosting_value would turn into 0.
  if jsonb_typeof(p_hosting) = 'object' and p_hosting->>'pickup_count' is null then
    p_hosting := p_hosting || jsonb_build_object('pickup_count', coalesce(v_before_hosting->'pickup_count', '0'));
  end if;
  v_after_hosting := public.registration_hosting_value(p_hosting);
  if not v_settings.is_hosting_open
    and v_after_hosting is not null and v_after_hosting is distinct from v_before_hosting then
    raise exception using errcode = 'P0001', message = 'HOSTING_CLOSED';
  end if;
  -- No answer sent keeps the stored one: a page loaded before the switch opened, or an older page
  -- or Edge Function, sends none. Only a registration that never answered must answer now.
  v_after_hosting := case when v_settings.is_hosting_open then coalesce(v_after_hosting, v_before_hosting)
    else v_before_hosting end;
  if v_after_hosting is null and v_settings.is_hosting_open then
    raise exception using errcode = 'P0001', message = 'HOSTING_REQUIRED';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_before_choices
  from public.registration_choices where registration_id = v_registration.id
    and activity_id in (select id from public.activities where is_published);
  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_after_choices
  from (
    select (choice->>'activity_id')::bigint as activity_id, (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
  ) answers;
  if v_before_choices = v_after_choices and v_before_hosting is not distinct from v_after_hosting then
    return true;
  end if;

  -- Hosting answers are imported into the assembly system too, so any change needs a re-import.
  update public.registrations set
    import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = v_registration.id;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration.id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  on conflict (registration_id, activity_id) do update
    set attending = excluded.attending, updated_at = now();
  if v_after_hosting is distinct from v_before_hosting then
    perform public.registration_hosting_put(v_registration.id, v_after_hosting);
  end if;
  insert into public.audit_events (actor_type, action, target_type, target_id, before_data, after_data)
  values ('public', 'registration.updated', 'registration', v_registration.id,
    jsonb_build_object('choices', v_before_choices, 'hosting', v_before_hosting,
      'import_status', v_registration.import_status),
    jsonb_build_object('choices', v_after_choices, 'hosting', v_after_hosting,
      'import_status', case when v_registration.import_status = 'imported' then 'reimport_needed'
        else v_registration.import_status end));
  return true;
exception
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

create or replace function public.staff_update_registration(
  p_actor uuid, p_registration_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
  v_before_choices jsonb;
  v_after_choices jsonb;
  v_before_hosting jsonb;
  v_after_hosting jsonb;
begin
  perform public.staff_assert_actor(p_actor);
  select * into v_registration from public.registrations
  where id = p_registration_id and record_status = 'active' for update;
  if not found then return false; end if;

  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = ''
    or not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_REGISTRATION';
  end if;
  if public.registration_choices_valid(p_choices, p_registration_id) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_before_hosting := public.registration_hosting_get(p_registration_id);
  -- An older page sends no pickup_count; keep the stored one instead of resetting it to 0.
  -- ->> is null also covers an explicit JSON null, which registration_hosting_value would turn into 0.
  if jsonb_typeof(p_hosting) = 'object' and p_hosting->>'pickup_count' is null then
    p_hosting := p_hosting || jsonb_build_object('pickup_count', coalesce(v_before_hosting->'pickup_count', '0'));
  end if;
  -- No answer sent keeps the stored one (for example a cached older back-office page).
  v_after_hosting := coalesce(public.registration_hosting_value(p_hosting), v_before_hosting);

  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_before_choices
  from public.registration_choices where registration_id = p_registration_id
    and activity_id in (select id from public.activities where is_published);
  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_after_choices
  from (
    select (choice->>'activity_id')::bigint as activity_id,
      (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
  ) answers;

  if v_registration.full_name = btrim(p_full_name) and v_registration.district_id = p_district_id
    and v_before_choices = v_after_choices
    and v_before_hosting is not distinct from v_after_hosting then return true; end if;

  update public.registrations set full_name = btrim(p_full_name), district_id = p_district_id,
    import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = p_registration_id;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select p_registration_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  on conflict (registration_id, activity_id) do update
    set attending = excluded.attending, updated_at = now();
  if v_after_hosting is distinct from v_before_hosting then
    perform public.registration_hosting_put(p_registration_id, v_after_hosting);
  end if;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  values ('staff', p_actor, 'registration.staff_updated', 'registration', p_registration_id,
    jsonb_build_object('full_name', v_registration.full_name, 'district_id', v_registration.district_id,
      'choices', v_before_choices, 'hosting', v_before_hosting, 'import_status', v_registration.import_status),
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id, 'choices', v_after_choices,
      'hosting', v_after_hosting,
      'import_status', case when v_registration.import_status = 'imported' then 'reimport_needed'
        else v_registration.import_status end));
  return true;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and id <> p_registration_id
        and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- ===== 202611050006_meal_pricing_and_audience.sql =====

-- 2026-11-05: 用餐學生價、實際成本與報名對象. Apply after 202611050005, then deploy the registration
-- and staff Edge Functions, then the site. Edge Functions deployed before this keep working: the new
-- parameters default to null and an activity saved without the new fields keeps them.
--   * activities.student_fee_amount: the student price (null = none; 0 = free). fee_amount stays the
--     general price and must be set for a student price to be set.
--   * activities.cost_amount: the real cost per person, for the back office only. anon used to read
--     every activities column; it now gets every column except this one.
--   * activities.audience: who may sign up, 'all' or 'hosting' (開家接待 answered 是 or
--     家人已登記開家接待). A text code, so a later audience is one more value and one more rule.
--     audience_note is the hint shown with a restricted activity; null shows the page's default.
--   * registrations.meal_identity ('general' or 'student'): required while the registration attends
--     a published activity with a student price, cleared otherwise. A request without it keeps the
--     stored one. Changing it alone never needs a re-import: the assembly system's fields are unknown
--     (decided 2026-11-05); comparing it in v_import_change below is the way to change that.
--   * A restricted activity refuses 參加 from anyone outside its audience, on every public or staff
--     save (AUDIENCE_RESTRICTED). Stored answers from before a restriction stay until the next save.

alter table public.activities
  add column student_fee_amount integer constraint activities_student_fee_amount check (student_fee_amount >= 0),
  add column cost_amount integer constraint activities_cost_amount check (cost_amount >= 0),
  add column audience text not null default 'all' constraint activities_audience check (audience in ('all', 'hosting')),
  add column audience_note text constraint activities_audience_note_length check (length(audience_note) <= 200),
  -- A student price is a discount on the general price, so it cannot stand alone.
  add constraint activities_student_fee_needs_fee check (student_fee_amount is null or fee_amount is not null);

alter table public.registrations
  add column meal_identity text constraint registrations_meal_identity check (meal_identity in ('general', 'student'));

-- Column privileges: a column added later stays private unless it is granted here too.
revoke select on public.activities from anon;
grant select (id, category, title, starts_at, starts_at_has_time, ends_at, ends_at_has_time, venue, address,
  map_url, description, fee_amount, student_fee_amount, audience, audience_note, is_published, sort_order,
  created_at, updated_at) on public.activities to anon;

-- The identity to store for these choices: null when no attended published activity has a student
-- price; otherwise the one sent, else p_stored, else MEAL_IDENTITY_REQUIRED.
-- p_choices must already have passed registration_choices_valid.
create function public.registration_meal_identity(p_choices jsonb, p_identity text, p_stored text default null)
returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if p_identity is not null and p_identity not in ('general', 'student') then
    raise exception using errcode = '22023', message = 'INVALID_MEAL_IDENTITY';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(p_choices) choice
    join public.activities activity on activity.id = (choice->>'activity_id')::bigint
    where activity.is_published and activity.student_fee_amount is not null and (choice->>'attending')::boolean
  ) then
    return null;
  end if;
  if coalesce(p_identity, p_stored) is null then
    raise exception using errcode = 'P0001', message = 'MEAL_IDENTITY_REQUIRED';
  end if;
  return coalesce(p_identity, p_stored);
end;
$$;

-- False when the choices attend an activity whose audience the hosting answer (stored form) is not in.
create function public.registration_audience_valid(p_choices jsonb, p_hosting jsonb)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select not exists (
    select 1 from jsonb_array_elements(p_choices) choice
    join public.activities activity on activity.id = (choice->>'activity_id')::bigint
    where activity.audience = 'hosting' and (choice->>'attending')::boolean
      and coalesce(p_hosting->>'status', '') not in ('hosting', 'family_registered')
  );
$$;

revoke execute on function public.registration_meal_identity(jsonb, text, text) from public, anon, authenticated;
revoke execute on function public.registration_audience_valid(jsonb, jsonb) from public, anon, authenticated;
grant execute on function public.registration_meal_identity(jsonb, text, text) to service_role;
grant execute on function public.registration_audience_valid(jsonb, jsonb) to service_role;

-- New parameters and a new result column change the signatures, so these are dropped and recreated
-- (create or replace would add overloads) and granted again below.
drop function public.create_registration(uuid, text, integer, jsonb, jsonb);
drop function public.update_registration(text, integer, jsonb, jsonb);
drop function public.staff_create_registration(uuid, uuid, text, integer, jsonb, jsonb);
drop function public.staff_update_registration(uuid, uuid, text, integer, jsonb, jsonb);
drop function public.get_registration(text, integer);

-- Same as 202611050002, plus p_meal_identity and the audience check.
create function public.create_registration(
  p_request_id uuid,
  p_full_name text,
  p_district_id integer,
  p_choices jsonb,
  p_hosting jsonb default null,
  p_meal_identity text default null
)
returns table (registration_id uuid, serial_no bigint)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration_id uuid;
  v_serial_no bigint;
  v_hosting jsonb;
  v_identity text;
  v_settings public.site_settings%rowtype;
begin
  select * into v_settings from public.site_settings where id;
  if not coalesce(v_settings.is_registration_open
      and (v_settings.registration_deadline_at is null or v_settings.registration_deadline_at > now()), false) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;
  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = '' then
    raise exception using errcode = '22023', message = 'INVALID_NAME';
  end if;
  if not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_DISTRICT';
  end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_hosting := public.registration_hosting_value(p_hosting);
  if not v_settings.is_hosting_open and v_hosting is not null then
    raise exception using errcode = 'P0001', message = 'HOSTING_CLOSED';
  end if;
  if v_settings.is_hosting_open and v_hosting is null then
    raise exception using errcode = 'P0001', message = 'HOSTING_REQUIRED';
  end if;
  if public.registration_audience_valid(p_choices, v_hosting) is not true then
    raise exception using errcode = 'P0001', message = 'AUDIENCE_RESTRICTED';
  end if;
  v_identity := public.registration_meal_identity(p_choices, p_meal_identity);

  update public.registration_create_limits
  set window_started_at = case when window_started_at <= now() - interval '10 minutes' then now() else window_started_at end,
      created_count = case when window_started_at <= now() - interval '10 minutes' then 1 else created_count + 1 end
  where id = true
    and (window_started_at <= now() - interval '10 minutes' or created_count < 50);
  if not found then
    raise exception using errcode = 'P0001', message = 'CREATE_RATE_LIMITED';
  end if;

  insert into public.registrations (create_request_id, full_name, district_id, meal_identity)
  values (p_request_id, btrim(p_full_name), p_district_id, v_identity)
  returning id, registrations.serial_no into v_registration_id, v_serial_no;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice;
  if v_hosting is not null then perform public.registration_hosting_put(v_registration_id, v_hosting); end if;
  insert into public.audit_events (actor_type, action, target_type, target_id, after_data)
  values ('public', 'registration.created', 'registration', v_registration_id,
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id, 'hosting', v_hosting,
      'meal_identity', v_identity));

  return query select v_registration_id, v_serial_no;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where create_request_id = p_request_id) then
      raise exception using errcode = '23505', message = 'DUPLICATE_REQUEST';
    end if;
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- Same as 202611050005, plus p_meal_identity and the audience check.
create function public.update_registration(
  p_full_name text,
  p_district_id integer,
  p_choices jsonb,
  p_hosting jsonb default null,
  p_meal_identity text default null
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
  v_before_choices jsonb;
  v_after_choices jsonb;
  v_before_hosting jsonb;
  v_after_hosting jsonb;
  v_identity text;
  v_import_change boolean;
  v_settings public.site_settings%rowtype;
begin
  select * into v_settings from public.site_settings where id;
  if not coalesce(v_settings.is_registration_open
      and (v_settings.registration_deadline_at is null or v_settings.registration_deadline_at > now()), false) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;
  if not coalesce(v_settings.is_lookup_open, false) then
    raise exception using errcode = 'P0001', message = 'LOOKUP_CLOSED';
  end if;

  select * into v_registration from public.registrations
  where district_id = p_district_id and name_key = public.registration_name_key(p_full_name)
    and record_status = 'active'
  for update;
  if not found then return false; end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_before_hosting := public.registration_hosting_get(v_registration.id);
  -- An older page sends no pickup_count; keep the stored one instead of resetting it to 0.
  -- ->> is null also covers an explicit JSON null, which registration_hosting_value would turn into 0.
  if jsonb_typeof(p_hosting) = 'object' and p_hosting->>'pickup_count' is null then
    p_hosting := p_hosting || jsonb_build_object('pickup_count', coalesce(v_before_hosting->'pickup_count', '0'));
  end if;
  v_after_hosting := public.registration_hosting_value(p_hosting);
  if not v_settings.is_hosting_open
    and v_after_hosting is not null and v_after_hosting is distinct from v_before_hosting then
    raise exception using errcode = 'P0001', message = 'HOSTING_CLOSED';
  end if;
  -- No answer sent keeps the stored one: a page loaded before the switch opened, or an older page
  -- or Edge Function, sends none. Only a registration that never answered must answer now.
  v_after_hosting := case when v_settings.is_hosting_open then coalesce(v_after_hosting, v_before_hosting)
    else v_before_hosting end;
  if v_after_hosting is null and v_settings.is_hosting_open then
    raise exception using errcode = 'P0001', message = 'HOSTING_REQUIRED';
  end if;
  if public.registration_audience_valid(p_choices, v_after_hosting) is not true then
    raise exception using errcode = 'P0001', message = 'AUDIENCE_RESTRICTED';
  end if;
  v_identity := public.registration_meal_identity(p_choices, p_meal_identity, v_registration.meal_identity);

  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_before_choices
  from public.registration_choices where registration_id = v_registration.id
    and activity_id in (select id from public.activities where is_published);
  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_after_choices
  from (
    select (choice->>'activity_id')::bigint as activity_id, (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
  ) answers;
  -- Hosting answers are imported into the assembly system too, so any change needs a re-import.
  v_import_change := v_before_choices <> v_after_choices or v_before_hosting is distinct from v_after_hosting;
  if not v_import_change and v_registration.meal_identity is not distinct from v_identity then
    return true;
  end if;

  update public.registrations set
    meal_identity = v_identity,
    import_status = case when v_import_change and import_status = 'imported' then 'reimport_needed'
      else import_status end,
    updated_at = now()
  where id = v_registration.id;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration.id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  on conflict (registration_id, activity_id) do update
    set attending = excluded.attending, updated_at = now();
  if v_after_hosting is distinct from v_before_hosting then
    perform public.registration_hosting_put(v_registration.id, v_after_hosting);
  end if;
  insert into public.audit_events (actor_type, action, target_type, target_id, before_data, after_data)
  values ('public', 'registration.updated', 'registration', v_registration.id,
    jsonb_build_object('choices', v_before_choices, 'hosting', v_before_hosting,
      'meal_identity', v_registration.meal_identity, 'import_status', v_registration.import_status),
    jsonb_build_object('choices', v_after_choices, 'hosting', v_after_hosting, 'meal_identity', v_identity,
      'import_status', case when v_import_change and v_registration.import_status = 'imported'
        then 'reimport_needed' else v_registration.import_status end));
  return true;
exception
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- Same as 202611050002, plus p_meal_identity and the audience check.
create function public.staff_create_registration(
  p_actor uuid, p_request_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null, p_meal_identity text default null
)
returns table (registration_id uuid, serial_no bigint)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
  v_serial bigint;
  v_hosting jsonb;
  v_identity text;
begin
  perform public.staff_assert_actor(p_actor);
  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = ''
    or not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_REGISTRATION';
  end if;
  if public.registration_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_hosting := public.registration_hosting_value(p_hosting);
  if v_hosting is null and coalesce((select is_hosting_open from public.site_settings where id), false) then
    raise exception using errcode = 'P0001', message = 'HOSTING_REQUIRED';
  end if;
  if public.registration_audience_valid(p_choices, v_hosting) is not true then
    raise exception using errcode = 'P0001', message = 'AUDIENCE_RESTRICTED';
  end if;
  v_identity := public.registration_meal_identity(p_choices, p_meal_identity);

  insert into public.registrations
    (create_request_id, full_name, district_id, meal_identity)
  values (p_request_id, btrim(p_full_name), p_district_id, v_identity)
  returning id, registrations.serial_no into v_id, v_serial;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice;
  if v_hosting is not null then perform public.registration_hosting_put(v_id, v_hosting); end if;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, after_data)
  values ('staff', p_actor, 'registration.staff_created', 'registration', v_id,
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id, 'hosting', v_hosting,
      'meal_identity', v_identity));
  return query select v_id, v_serial;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where create_request_id = p_request_id) then
      raise exception using errcode = '23505', message = 'DUPLICATE_REQUEST';
    end if;
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- Same as 202611050005, plus p_meal_identity and the audience check (staff follow it too, decided
-- 2026-11-05; for an exception the admin sets the activity back to 所有人).
create function public.staff_update_registration(
  p_actor uuid, p_registration_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null, p_meal_identity text default null
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_registration public.registrations%rowtype;
  v_before_choices jsonb;
  v_after_choices jsonb;
  v_before_hosting jsonb;
  v_after_hosting jsonb;
  v_identity text;
  v_import_change boolean;
begin
  perform public.staff_assert_actor(p_actor);
  select * into v_registration from public.registrations
  where id = p_registration_id and record_status = 'active' for update;
  if not found then return false; end if;

  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or public.registration_name_key(p_full_name) = ''
    or not exists (select 1 from public.districts where id = p_district_id) then
    raise exception using errcode = '22023', message = 'INVALID_REGISTRATION';
  end if;
  if public.registration_choices_valid(p_choices, p_registration_id) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;
  v_before_hosting := public.registration_hosting_get(p_registration_id);
  -- An older page sends no pickup_count; keep the stored one instead of resetting it to 0.
  -- ->> is null also covers an explicit JSON null, which registration_hosting_value would turn into 0.
  if jsonb_typeof(p_hosting) = 'object' and p_hosting->>'pickup_count' is null then
    p_hosting := p_hosting || jsonb_build_object('pickup_count', coalesce(v_before_hosting->'pickup_count', '0'));
  end if;
  -- No answer sent keeps the stored one (for example a cached older back-office page).
  v_after_hosting := coalesce(public.registration_hosting_value(p_hosting), v_before_hosting);
  if public.registration_audience_valid(p_choices, v_after_hosting) is not true then
    raise exception using errcode = 'P0001', message = 'AUDIENCE_RESTRICTED';
  end if;
  v_identity := public.registration_meal_identity(p_choices, p_meal_identity, v_registration.meal_identity);

  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_before_choices
  from public.registration_choices where registration_id = p_registration_id
    and activity_id in (select id from public.activities where is_published);
  select coalesce(jsonb_agg(jsonb_build_object('activity_id', activity_id, 'attending', attending)
    order by activity_id), '[]'::jsonb) into v_after_choices
  from (
    select (choice->>'activity_id')::bigint as activity_id,
      (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
  ) answers;

  v_import_change := v_registration.full_name <> btrim(p_full_name) or v_registration.district_id <> p_district_id
    or v_before_choices <> v_after_choices or v_before_hosting is distinct from v_after_hosting;
  if not v_import_change and v_registration.meal_identity is not distinct from v_identity then return true; end if;

  update public.registrations set full_name = btrim(p_full_name), district_id = p_district_id,
    meal_identity = v_identity,
    import_status = case when v_import_change and import_status = 'imported' then 'reimport_needed'
      else import_status end,
    updated_at = now()
  where id = p_registration_id;
  insert into public.registration_choices (registration_id, activity_id, attending)
  select p_registration_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  on conflict (registration_id, activity_id) do update
    set attending = excluded.attending, updated_at = now();
  if v_after_hosting is distinct from v_before_hosting then
    perform public.registration_hosting_put(p_registration_id, v_after_hosting);
  end if;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  values ('staff', p_actor, 'registration.staff_updated', 'registration', p_registration_id,
    jsonb_build_object('full_name', v_registration.full_name, 'district_id', v_registration.district_id,
      'choices', v_before_choices, 'hosting', v_before_hosting, 'meal_identity', v_registration.meal_identity,
      'import_status', v_registration.import_status),
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id, 'choices', v_after_choices,
      'hosting', v_after_hosting, 'meal_identity', v_identity,
      'import_status', case when v_import_change and v_registration.import_status = 'imported'
        then 'reimport_needed' else v_registration.import_status end));
  return true;
exception
  when unique_violation then
    if exists (select 1 from public.registrations where district_id = p_district_id
        and record_status = 'active' and id <> p_registration_id
        and name_key = public.registration_name_key(p_full_name)) then
      raise exception using errcode = '23505', message = 'NAME_TAKEN';
    end if;
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

-- Same as 202611050001, plus meal_identity.
create function public.get_registration(p_full_name text, p_district_id integer)
returns table (
  full_name text,
  district_id integer,
  can_change boolean,
  choices jsonb,
  hosting jsonb,
  meal_identity text
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
begin
  if not exists (select 1 from public.site_settings where id and is_lookup_open) then
    raise exception using errcode = 'P0001', message = 'LOOKUP_CLOSED';
  end if;
  return query
  select registration.full_name,
    registration.district_id,
    settings.is_registration_open
      and (settings.registration_deadline_at is null or settings.registration_deadline_at > now()),
    coalesce(
      jsonb_agg(
        jsonb_build_object('activity_id', activity.id, 'title', activity.title, 'attending', choice.attending)
        order by activity.sort_order
      ) filter (where activity.id is not null),
      '[]'::jsonb
    ),
    public.registration_hosting_get(registration.id),
    registration.meal_identity
  from public.registrations registration
  cross join public.site_settings settings
  left join public.activities activity on activity.is_published
  left join public.registration_choices choice
    on choice.registration_id = registration.id and choice.activity_id = activity.id
  where registration.district_id = p_district_id
    and registration.name_key = public.registration_name_key(p_full_name)
    and registration.record_status = 'active'
  group by registration.id, settings.is_registration_open, settings.registration_deadline_at;
end;
$$;

revoke execute on function public.create_registration(uuid, text, integer, jsonb, jsonb, text) from public, anon, authenticated;
revoke execute on function public.update_registration(text, integer, jsonb, jsonb, text) from public, anon, authenticated;
revoke execute on function public.staff_create_registration(uuid, uuid, text, integer, jsonb, jsonb, text) from public, anon, authenticated;
revoke execute on function public.staff_update_registration(uuid, uuid, text, integer, jsonb, jsonb, text) from public, anon, authenticated;
revoke execute on function public.get_registration(text, integer) from public, anon, authenticated;
grant execute on function public.create_registration(uuid, text, integer, jsonb, jsonb, text) to service_role;
grant execute on function public.update_registration(text, integer, jsonb, jsonb, text) to service_role;
grant execute on function public.staff_create_registration(uuid, uuid, text, integer, jsonb, jsonb, text) to service_role;
grant execute on function public.staff_update_registration(uuid, uuid, text, integer, jsonb, jsonb, text) to service_role;
grant execute on function public.get_registration(text, integer) to service_role;

-- Same as 202611050004, plus the activity's student_fee_amount, cost_amount, audience and
-- audience_note. An activity saved without one of them (an older page) keeps the stored value.
create or replace function public.staff_save_reference(p_actor uuid, p_kind text, p_data jsonb)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
  v_id bigint;
begin
  perform public.staff_assert_actor(p_actor, true);
  if jsonb_typeof(p_data) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_DATA';
  end if;

  if p_kind = 'settings' then
    select to_jsonb(s) into v_before from public.site_settings s where id for update;
    update public.site_settings set
      event_name = btrim(p_data->>'event_name'),
      venue = nullif(btrim(p_data->>'venue'), ''),
      address = nullif(btrim(p_data->>'address'), ''),
      -- A textarea: also trims line breaks, tabs and full-width spaces (an ASCII escape, since editors
      -- drop invisible characters), so a blank note clears it.
      event_note = case when p_data ? 'event_note'
        then nullif(btrim(p_data->>'event_note', E' \t\r\n\u3000'), '') else event_note end,
      registration_deadline_at = nullif(p_data->>'registration_deadline_at', '')::timestamptz,
      is_registration_open = (p_data->>'is_registration_open')::boolean,
      is_lookup_open = coalesce((p_data->>'is_lookup_open')::boolean, is_lookup_open),
      updated_at = now()
    where id returning to_jsonb(site_settings.*) into v_after;
  elsif p_kind = 'hosting' then
    select to_jsonb(s) into v_before from public.site_settings s where id for update;
    update public.site_settings set
      is_hosting_open = (p_data->>'is_hosting_open')::boolean,
      hosting_description = nullif(btrim(p_data->>'hosting_description'), ''),
      updated_at = now()
    where id returning to_jsonb(site_settings.*) into v_after;
  elsif p_kind = 'district' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.districts (name, sort_order)
      values (btrim(p_data->>'name'), (p_data->>'sort_order')::integer)
      returning to_jsonb(districts.*) into v_after;
    else
      select to_jsonb(d) into v_before from public.districts d where id = v_id for update;
      update public.districts set name = btrim(p_data->>'name'),
        sort_order = (p_data->>'sort_order')::integer
      where id = v_id returning to_jsonb(districts.*) into v_after;
    end if;
  elsif p_kind = 'activity' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.activities
        (category, title, starts_at, starts_at_has_time, ends_at, ends_at_has_time,
         venue, address, map_url, description, fee_amount, student_fee_amount, cost_amount,
         audience, audience_note, is_published, sort_order)
      values (
        p_data->>'category', btrim(p_data->>'title'),
        nullif(p_data->>'starts_at', '')::timestamptz,
        coalesce((p_data->>'starts_at_has_time')::boolean, nullif(p_data->>'starts_at', '') is not null),
        nullif(p_data->>'ends_at', '')::timestamptz,
        coalesce((p_data->>'ends_at_has_time')::boolean, nullif(p_data->>'ends_at', '') is not null),
        nullif(btrim(p_data->>'venue'), ''), nullif(btrim(p_data->>'address'), ''),
        nullif(btrim(p_data->>'map_url'), ''), nullif(btrim(p_data->>'description'), ''),
        nullif(p_data->>'fee_amount', '')::integer,
        nullif(p_data->>'student_fee_amount', '')::integer,
        nullif(p_data->>'cost_amount', '')::integer,
        coalesce(nullif(p_data->>'audience', ''), 'all'),
        nullif(btrim(p_data->>'audience_note'), ''),
        (p_data->>'is_published')::boolean, (p_data->>'sort_order')::integer
      ) returning to_jsonb(activities.*) into v_after;
    else
      select to_jsonb(a) into v_before from public.activities a where id = v_id for update;
      update public.activities set
        category = p_data->>'category', title = btrim(p_data->>'title'),
        starts_at = nullif(p_data->>'starts_at', '')::timestamptz,
        starts_at_has_time = coalesce((p_data->>'starts_at_has_time')::boolean, nullif(p_data->>'starts_at', '') is not null),
        ends_at = nullif(p_data->>'ends_at', '')::timestamptz,
        ends_at_has_time = coalesce((p_data->>'ends_at_has_time')::boolean, nullif(p_data->>'ends_at', '') is not null),
        venue = nullif(btrim(p_data->>'venue'), ''),
        address = nullif(btrim(p_data->>'address'), ''),
        map_url = nullif(btrim(p_data->>'map_url'), ''),
        description = nullif(btrim(p_data->>'description'), ''),
        fee_amount = nullif(p_data->>'fee_amount', '')::integer,
        student_fee_amount = case when p_data ? 'student_fee_amount'
          then nullif(p_data->>'student_fee_amount', '')::integer else student_fee_amount end,
        cost_amount = case when p_data ? 'cost_amount'
          then nullif(p_data->>'cost_amount', '')::integer else cost_amount end,
        audience = case when p_data ? 'audience'
          then coalesce(nullif(p_data->>'audience', ''), 'all') else audience end,
        audience_note = case when p_data ? 'audience_note'
          then nullif(btrim(p_data->>'audience_note'), '') else audience_note end,
        is_published = (p_data->>'is_published')::boolean,
        sort_order = (p_data->>'sort_order')::integer,
        updated_at = now()
      where id = v_id returning to_jsonb(activities.*) into v_after;
    end if;
  elsif p_kind = 'program' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
      insert into public.program_items
        (event_date, start_time, end_time, title, note, sort_order, is_visible)
      values (
        (p_data->>'event_date')::date, nullif(p_data->>'start_time', '')::time,
        nullif(p_data->>'end_time', '')::time, btrim(p_data->>'title'),
        nullif(btrim(p_data->>'note'), ''), (p_data->>'sort_order')::integer,
        (p_data->>'is_visible')::boolean
      ) returning to_jsonb(program_items.*) into v_after;
    else
      select to_jsonb(p) into v_before from public.program_items p where id = v_id for update;
      update public.program_items set
        event_date = (p_data->>'event_date')::date,
        start_time = nullif(p_data->>'start_time', '')::time,
        end_time = nullif(p_data->>'end_time', '')::time,
        title = btrim(p_data->>'title'), note = nullif(btrim(p_data->>'note'), ''),
        sort_order = (p_data->>'sort_order')::integer,
        is_visible = (p_data->>'is_visible')::boolean
      where id = v_id returning to_jsonb(program_items.*) into v_after;
    end if;
  else
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_KIND';
  end if;

  if v_after is null then
    raise exception using errcode = '22023', message = 'REFERENCE_NOT_FOUND';
  end if;
  if p_kind = 'activity' and v_before is not null
    and (v_before->'title', v_before->'starts_at', v_before->'starts_at_has_time',
         v_before->'ends_at', v_before->'ends_at_has_time', v_before->'is_published')
      is distinct from
        (v_after->'title', v_after->'starts_at', v_after->'starts_at_has_time',
         v_after->'ends_at', v_after->'ends_at_has_time', v_after->'is_published') then
    with affected as (
      update public.registrations r
      set import_status = 'reimport_needed', updated_at = now()
      where r.import_status = 'imported' and r.record_status = 'active'
        and exists (
          select 1 from public.registration_choices c
          where c.registration_id = r.id and c.activity_id = (v_after->>'id')::bigint
            and c.attending
        )
      returning r.id
    )
    insert into public.audit_events
      (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
    select 'admin', p_actor, 'registration.reimport_needed', 'registration', id,
      '{"import_status":"imported"}'::jsonb,
      '{"import_status":"reimport_needed"}'::jsonb
    from affected;
  end if;
  if (v_before - 'updated_at') is distinct from (v_after - 'updated_at') then
    insert into public.audit_events
      (actor_type, actor_user_id, action, target_type, before_data, after_data)
    values ('admin', p_actor, 'reference.saved', p_kind, v_before, v_after);
  end if;
  return v_after;
end;
$$;

-- ===== 202611060001_independent_pickup.sql =====

-- 2026-11-06: 接機接待 becomes its own answer with its own switch. Apply after 202611050006, then
-- deploy the registration and staff Edge Functions (they call the *_with_pickup RPCs and read
-- registration_pickup, so not before this), then the site (an older Edge Function drops its pickup).
--   * registration_pickup: one row per answered registration; 是 carries 1～6 seats, 否 carries 0.
--     Legacy registration_hosting.pickup_count 1～6 becomes 是; legacy 0 was a default, so it becomes
--     unanswered. The legacy column stays (old Edge Functions still write it) and is no longer read.
--   * The *_with_pickup wrappers run the existing RPC first, so its closed/invalid errors win, then
--     check and save pickup in the same transaction.

alter table public.site_settings
  add column is_pickup_open boolean not null default false,
  add column pickup_description text constraint site_settings_pickup_description_length
    check (char_length(pickup_description) <= 2000);

create table public.registration_pickup (
  registration_id uuid primary key references public.registrations(id) on delete cascade,
  status text not null check (status in ('yes', 'no')),
  count integer not null check ((status = 'yes' and count between 1 and 6)
    or (status = 'no' and count = 0)),
  updated_at timestamptz not null default now()
);
alter table public.registration_pickup enable row level security;
revoke all on public.registration_pickup from public, anon, authenticated;
grant select, insert, update on public.registration_pickup to service_role;

insert into public.registration_pickup (registration_id, status, count)
select registration_id, 'yes', pickup_count from public.registration_hosting where pickup_count between 1 and 6;

create function public.registration_pickup_value(p_pickup jsonb)
returns jsonb language plpgsql immutable security invoker set search_path = '' as $$
declare v_status text; v_count text;
begin
  if p_pickup is null or p_pickup = 'null'::jsonb then return null; end if;
  if jsonb_typeof(p_pickup) <> 'object' then
    raise exception using errcode = '22023', message = 'INVALID_PICKUP';
  end if;
  v_status := p_pickup->>'status';
  v_count := p_pickup->>'count';
  if v_status = 'yes' and coalesce(v_count, '') ~ '^[1-6]$' then
    return jsonb_build_object('status', 'yes', 'count', v_count::integer);
  elsif v_status = 'no' and coalesce(v_count, '0') = '0' then
    return jsonb_build_object('status', 'no', 'count', 0);
  end if;
  raise exception using errcode = '22023', message = 'INVALID_PICKUP';
end;
$$;

create function public.registration_pickup_get(p_registration_id uuid)
returns jsonb language sql stable security invoker set search_path = '' as $$
  select jsonb_build_object('status', status, 'count', count)
  from public.registration_pickup where registration_id = p_registration_id;
$$;

create function public.registration_pickup_put(p_registration_id uuid, p_value jsonb)
returns void language sql security invoker set search_path = '' as $$
  insert into public.registration_pickup (registration_id, status, count)
  values (p_registration_id, p_value->>'status', (p_value->>'count')::integer)
  on conflict (registration_id) do update set status = excluded.status,
    count = excluded.count, updated_at = now();
$$;

create function public.create_registration_with_pickup(
  p_request_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null, p_meal_identity text default null, p_pickup jsonb default null
) returns table (registration_id uuid, serial_no bigint)
language plpgsql security invoker set search_path = '' as $$
declare v_pickup jsonb; v_id uuid; v_serial bigint; v_open boolean;
begin
  select c.registration_id, c.serial_no into v_id, v_serial
  from public.create_registration(p_request_id, p_full_name, p_district_id, p_choices, p_hosting, p_meal_identity) c;
  v_pickup := public.registration_pickup_value(p_pickup);
  select is_pickup_open into v_open from public.site_settings where id;
  if not v_open and v_pickup is not null then
    raise exception using errcode = 'P0001', message = 'PICKUP_CLOSED';
  end if;
  if v_open and v_pickup is null then
    raise exception using errcode = 'P0001', message = 'PICKUP_REQUIRED';
  end if;
  if v_pickup is not null then
    perform public.registration_pickup_put(v_id, v_pickup);
    insert into public.audit_events (actor_type, action, target_type, target_id, after_data)
    values ('public', 'registration.pickup_updated', 'registration', v_id, jsonb_build_object('pickup', v_pickup));
  end if;
  return query select v_id, v_serial;
end;
$$;

create function public.update_registration_with_pickup(
  p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null, p_meal_identity text default null, p_pickup jsonb default null
) returns boolean language plpgsql security invoker set search_path = '' as $$
declare v_id uuid; v_before jsonb; v_after jsonb; v_open boolean;
begin
  -- Locks the registration and raises its own closed/invalid errors first.
  if not public.update_registration(p_full_name, p_district_id, p_choices, p_hosting, p_meal_identity) then
    return false;
  end if;
  select id into v_id from public.registrations
  where district_id = p_district_id and name_key = public.registration_name_key(p_full_name)
    and record_status = 'active';
  select is_pickup_open into v_open from public.site_settings where id;
  v_before := public.registration_pickup_get(v_id);
  v_after := public.registration_pickup_value(p_pickup);
  if not v_open and v_after is not null and v_after is distinct from v_before then
    raise exception using errcode = 'P0001', message = 'PICKUP_CLOSED';
  end if;
  if v_open and coalesce(v_after, v_before) is null then
    raise exception using errcode = 'P0001', message = 'PICKUP_REQUIRED';
  end if;
  if v_open and v_after is not null and v_after is distinct from v_before then
    perform public.registration_pickup_put(v_id, v_after);
    update public.registrations set updated_at = now(),
      import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end
    where id = v_id;
    insert into public.audit_events (actor_type, action, target_type, target_id, before_data, after_data)
    values ('public', 'registration.pickup_updated', 'registration', v_id,
      jsonb_build_object('pickup', v_before), jsonb_build_object('pickup', v_after));
  end if;
  return true;
end;
$$;

-- Staff may answer pickup while the survey is closed, like hosting.
create function public.staff_create_registration_with_pickup(
  p_actor uuid, p_request_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null, p_meal_identity text default null, p_pickup jsonb default null
) returns table (registration_id uuid, serial_no bigint)
language plpgsql security invoker set search_path = '' as $$
declare v_pickup jsonb; v_id uuid; v_serial bigint;
begin
  select c.registration_id, c.serial_no into v_id, v_serial
  from public.staff_create_registration(p_actor, p_request_id, p_full_name,
    p_district_id, p_choices, p_hosting, p_meal_identity) c;
  v_pickup := public.registration_pickup_value(p_pickup);
  if v_pickup is null and coalesce((select is_pickup_open from public.site_settings where id), false) then
    raise exception using errcode = 'P0001', message = 'PICKUP_REQUIRED';
  end if;
  if v_pickup is not null then
    perform public.registration_pickup_put(v_id, v_pickup);
    insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, after_data)
    values ('staff', p_actor, 'registration.pickup_updated', 'registration', v_id, jsonb_build_object('pickup', v_pickup));
  end if;
  return query select v_id, v_serial;
end;
$$;

create function public.staff_update_registration_with_pickup(
  p_actor uuid, p_registration_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null, p_meal_identity text default null, p_pickup jsonb default null
) returns boolean language plpgsql security invoker set search_path = '' as $$
declare v_before jsonb; v_after jsonb;
begin
  -- Checks the actor, locks an active registration and validates the rest first.
  if not public.staff_update_registration(p_actor, p_registration_id, p_full_name,
    p_district_id, p_choices, p_hosting, p_meal_identity) then
    return false;
  end if;
  v_before := public.registration_pickup_get(p_registration_id);
  -- No answer sent keeps the stored one, so an existing answer cannot be cleared.
  v_after := public.registration_pickup_value(p_pickup);
  if v_after is not null and v_after is distinct from v_before then
    perform public.registration_pickup_put(p_registration_id, v_after);
    update public.registrations set updated_at = now(),
      import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end
    where id = p_registration_id;
    insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
    values ('staff', p_actor, 'registration.pickup_updated', 'registration', p_registration_id,
      jsonb_build_object('pickup', v_before), jsonb_build_object('pickup', v_after));
  end if;
  return true;
end;
$$;

create function public.get_registration_pickup(p_full_name text, p_district_id integer)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare v_pickup jsonb;
begin
  if not exists (select 1 from public.site_settings where id and is_lookup_open) then
    raise exception using errcode = 'P0001', message = 'LOOKUP_CLOSED';
  end if;
  select public.registration_pickup_get(r.id) into v_pickup from public.registrations r
  where r.district_id = p_district_id and r.name_key = public.registration_name_key(p_full_name)
    and r.record_status = 'active';
  return v_pickup;
end;
$$;

-- The staff Edge Function sends kind 'hosting' here; staff_save_reference keeps the other kinds.
create or replace function public.staff_save_reception_settings(p_actor uuid, p_kind text, p_data jsonb)
returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_before jsonb; v_after jsonb;
begin
  perform public.staff_assert_actor(p_actor, true);
  if p_kind <> 'hosting' then
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_DATA';
  end if;
  if jsonb_typeof(p_data) <> 'object' or jsonb_typeof(p_data->'is_hosting_open') <> 'boolean'
    or jsonb_typeof(p_data->'is_pickup_open') <> 'boolean' then
    raise exception using errcode = '22023', message = 'INVALID_REFERENCE_DATA';
  end if;
  select to_jsonb(s) into v_before from public.site_settings s where id for update;
  update public.site_settings set
    is_hosting_open = (p_data->>'is_hosting_open')::boolean,
    hosting_description = nullif(btrim(p_data->>'hosting_description'), ''),
    is_pickup_open = (p_data->>'is_pickup_open')::boolean,
    pickup_description = nullif(btrim(p_data->>'pickup_description'), ''),
    updated_at = now()
  where id returning to_jsonb(site_settings.*) into v_after;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  values ('admin', p_actor, 'reference.saved', 'hosting', null, v_before, v_after);
  return v_after;
end;
$$;

revoke execute on function public.registration_pickup_value(jsonb), public.registration_pickup_get(uuid),
  public.registration_pickup_put(uuid, jsonb),
  public.create_registration_with_pickup(uuid, text, integer, jsonb, jsonb, text, jsonb),
  public.update_registration_with_pickup(text, integer, jsonb, jsonb, text, jsonb),
  public.staff_create_registration_with_pickup(uuid, uuid, text, integer, jsonb, jsonb, text, jsonb),
  public.staff_update_registration_with_pickup(uuid, uuid, text, integer, jsonb, jsonb, text, jsonb),
  public.get_registration_pickup(text, integer), public.staff_save_reception_settings(uuid, text, jsonb)
  from public, anon, authenticated;
grant execute on function public.registration_pickup_value(jsonb), public.registration_pickup_get(uuid),
  public.registration_pickup_put(uuid, jsonb),
  public.create_registration_with_pickup(uuid, text, integer, jsonb, jsonb, text, jsonb),
  public.update_registration_with_pickup(text, integer, jsonb, jsonb, text, jsonb),
  public.staff_create_registration_with_pickup(uuid, uuid, text, integer, jsonb, jsonb, text, jsonb),
  public.staff_update_registration_with_pickup(uuid, uuid, text, integer, jsonb, jsonb, text, jsonb),
  public.get_registration_pickup(text, integer), public.staff_save_reception_settings(uuid, text, jsonb)
  to service_role;

-- ===== 202611060002_activity_audiences.sql =====

-- One audience per activity for now. Activity prerequisites use the stable activity ID.

alter table public.activities drop constraint activities_audience;
alter table public.activities add constraint activities_audience
  check (audience in ('all', 'hosting', 'pickup') or audience ~ '^activity:[1-9][0-9]*$');

-- Serialize audience changes so concurrent edits cannot introduce a cycle.
create function public.check_activity_audience()
returns trigger language plpgsql security invoker set search_path = '' as $$
declare v_target bigint; v_seen bigint[] := array[new.id];
begin
  if new.audience !~ '^activity:[1-9][0-9]*$' then return new; end if;
  perform pg_advisory_xact_lock(2027, 1);
  v_target := substring(new.audience from 10)::bigint;
  loop
    if v_target = any(v_seen) then
      raise exception using errcode = '22023', message = 'ACTIVITY_AUDIENCE_CYCLE';
    end if;
    v_seen := array_append(v_seen, v_target);
    select case when audience ~ '^activity:[1-9][0-9]*$'
      then substring(audience from 10)::bigint else null end into v_target
    from public.activities where id = v_target;
    if not found then
      raise exception using errcode = '22023', message = 'ACTIVITY_AUDIENCE_NOT_FOUND';
    end if;
    if v_target is null then return new; end if;
  end loop;
end;
$$;
create trigger check_activity_audience before insert or update of audience on public.activities
for each row execute function public.check_activity_audience();

create function public.registration_audience_valid(p_choices jsonb, p_hosting jsonb, p_pickup jsonb)
returns boolean language sql stable security invoker set search_path = '' as $$
  select not exists (
    select 1 from jsonb_array_elements(p_choices) choice
    join public.activities activity on activity.id = (choice->>'activity_id')::bigint
    where (choice->>'attending')::boolean and (
      (activity.audience = 'hosting' and coalesce(p_hosting->>'status', '')
        not in ('hosting', 'family_registered'))
      or (activity.audience = 'pickup' and coalesce(p_pickup->>'status', '') <> 'yes')
      or (activity.audience like 'activity:%' and not exists (
        select 1 from public.activities prerequisite
        join jsonb_array_elements(p_choices) required_choice
          on (required_choice->>'activity_id')::bigint = prerequisite.id
        where prerequisite.id = nullif(substring(activity.audience from 10), '')::bigint
          and prerequisite.is_published and (required_choice->>'attending')::boolean
      ))
    )
  );
$$;
revoke execute on function public.registration_audience_valid(jsonb,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.registration_audience_valid(jsonb,jsonb,jsonb) to service_role;

-- The original Sunday activity is now Friday. Preserve its ID and existing answers.
update public.activities set title = '週五晚間帶菜愛筵', updated_at = now()
where title = '主日晚間帶菜愛筵'
  and not exists (select 1 from public.activities where title = '週五晚間帶菜愛筵');

create or replace function public.create_registration_with_pickup(
  p_request_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null, p_meal_identity text default null, p_pickup jsonb default null
) returns table (registration_id uuid, serial_no bigint)
language plpgsql security invoker set search_path = '' as $$
declare v_pickup jsonb; v_id uuid; v_serial bigint; v_open boolean;
begin
  select c.registration_id, c.serial_no into v_id, v_serial
  from public.create_registration(p_request_id, p_full_name, p_district_id, p_choices, p_hosting, p_meal_identity) c;
  v_pickup := public.registration_pickup_value(p_pickup);
  select is_pickup_open into v_open from public.site_settings where id;
  if not v_open and v_pickup is not null then
    raise exception using errcode = 'P0001', message = 'PICKUP_CLOSED';
  end if;
  if v_open and v_pickup is null then
    raise exception using errcode = 'P0001', message = 'PICKUP_REQUIRED';
  end if;
  if v_pickup is not null then
    perform public.registration_pickup_put(v_id, v_pickup);
    insert into public.audit_events (actor_type, action, target_type, target_id, after_data)
    values ('public', 'registration.pickup_updated', 'registration', v_id, jsonb_build_object('pickup', v_pickup));
  end if;
  if not public.registration_audience_valid(p_choices, public.registration_hosting_get(v_id),
    public.registration_pickup_get(v_id)) then
    raise exception using errcode = 'P0001', message = 'AUDIENCE_RESTRICTED';
  end if;
  return query select v_id, v_serial;
end;
$$;

create or replace function public.update_registration_with_pickup(
  p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null, p_meal_identity text default null, p_pickup jsonb default null
) returns boolean language plpgsql security invoker set search_path = '' as $$
declare v_id uuid; v_before jsonb; v_after jsonb; v_open boolean;
begin
  if not public.update_registration(p_full_name, p_district_id, p_choices, p_hosting, p_meal_identity) then
    return false;
  end if;
  select id into v_id from public.registrations
  where district_id = p_district_id and name_key = public.registration_name_key(p_full_name)
    and record_status = 'active';
  select is_pickup_open into v_open from public.site_settings where id;
  v_before := public.registration_pickup_get(v_id);
  v_after := public.registration_pickup_value(p_pickup);
  if not v_open and v_after is not null and v_after is distinct from v_before then
    raise exception using errcode = 'P0001', message = 'PICKUP_CLOSED';
  end if;
  if v_open and coalesce(v_after, v_before) is null then
    raise exception using errcode = 'P0001', message = 'PICKUP_REQUIRED';
  end if;
  if v_open and v_after is not null and v_after is distinct from v_before then
    perform public.registration_pickup_put(v_id, v_after);
    update public.registrations set updated_at = now(),
      import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end
    where id = v_id;
    insert into public.audit_events (actor_type, action, target_type, target_id, before_data, after_data)
    values ('public', 'registration.pickup_updated', 'registration', v_id,
      jsonb_build_object('pickup', v_before), jsonb_build_object('pickup', v_after));
  end if;
  if not public.registration_audience_valid(p_choices, public.registration_hosting_get(v_id),
    public.registration_pickup_get(v_id)) then
    raise exception using errcode = 'P0001', message = 'AUDIENCE_RESTRICTED';
  end if;
  return true;
end;
$$;

create or replace function public.staff_create_registration_with_pickup(
  p_actor uuid, p_request_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null, p_meal_identity text default null, p_pickup jsonb default null
) returns table (registration_id uuid, serial_no bigint)
language plpgsql security invoker set search_path = '' as $$
declare v_pickup jsonb; v_id uuid; v_serial bigint;
begin
  select c.registration_id, c.serial_no into v_id, v_serial
  from public.staff_create_registration(p_actor, p_request_id, p_full_name,
    p_district_id, p_choices, p_hosting, p_meal_identity) c;
  v_pickup := public.registration_pickup_value(p_pickup);
  if v_pickup is null and coalesce((select is_pickup_open from public.site_settings where id), false) then
    raise exception using errcode = 'P0001', message = 'PICKUP_REQUIRED';
  end if;
  if v_pickup is not null then
    perform public.registration_pickup_put(v_id, v_pickup);
    insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, after_data)
    values ('staff', p_actor, 'registration.pickup_updated', 'registration', v_id, jsonb_build_object('pickup', v_pickup));
  end if;
  if not public.registration_audience_valid(p_choices, public.registration_hosting_get(v_id),
    public.registration_pickup_get(v_id)) then
    raise exception using errcode = 'P0001', message = 'AUDIENCE_RESTRICTED';
  end if;
  return query select v_id, v_serial;
end;
$$;

create or replace function public.staff_update_registration_with_pickup(
  p_actor uuid, p_registration_id uuid, p_full_name text, p_district_id integer, p_choices jsonb,
  p_hosting jsonb default null, p_meal_identity text default null, p_pickup jsonb default null
) returns boolean language plpgsql security invoker set search_path = '' as $$
declare v_before jsonb; v_after jsonb;
begin
  if not public.staff_update_registration(p_actor, p_registration_id, p_full_name,
    p_district_id, p_choices, p_hosting, p_meal_identity) then
    return false;
  end if;
  v_before := public.registration_pickup_get(p_registration_id);
  v_after := public.registration_pickup_value(p_pickup);
  if v_after is not null and v_after is distinct from v_before then
    perform public.registration_pickup_put(p_registration_id, v_after);
    update public.registrations set updated_at = now(),
      import_status = case when import_status = 'imported' then 'reimport_needed' else import_status end
    where id = p_registration_id;
    insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
    values ('staff', p_actor, 'registration.pickup_updated', 'registration', p_registration_id,
      jsonb_build_object('pickup', v_before), jsonb_build_object('pickup', v_after));
  end if;
  if not public.registration_audience_valid(p_choices, public.registration_hosting_get(p_registration_id),
    public.registration_pickup_get(p_registration_id)) then
    raise exception using errcode = 'P0001', message = 'AUDIENCE_RESTRICTED';
  end if;
  return true;
end;
$$;

-- ===== 202611060003_revoke_default_api_grants.sql =====

-- 2026-11-06: Supabase grants every new object in public to anon and authenticated by default.
-- The site reaches data only through the Edge Functions (service_role), so those defaults left
-- RLS as the only barrier: anon held SELECT/INSERT/UPDATE/DELETE/TRUNCATE on private tables.
-- Keep only the public reads granted on purpose (202611030001, 202611050006), and stop new
-- objects from being granted automatically. Apply before the Edge Functions; nothing else changes.

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
-- PUBLIC holds EXECUTE on functions by default; the Edge Functions run as service_role.
revoke all on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

grant select on public.districts, public.site_settings, public.program_items to anon;
grant select (id, category, title, starts_at, starts_at_has_time, ends_at, ends_at_has_time, venue, address,
  map_url, description, fee_amount, student_fee_amount, audience, audience_note, is_published, sort_order,
  created_at, updated_at) on public.activities to anon;

-- Objects created later by this role: no automatic access for the API roles.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;
alter default privileges in schema public grant execute on functions to service_role;

commit;
