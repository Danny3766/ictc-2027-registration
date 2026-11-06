begin;

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

commit;
