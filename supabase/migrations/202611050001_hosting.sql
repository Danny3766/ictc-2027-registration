-- 2026-11-05: 開家接待 (opening one's home to visiting saints). Each registration answers once:
-- 開家接待 with who and how many, 這次不參加開家接待, or 家人已登記接待. A family opens its home once,
-- so only one member answers 開家接待; the system cannot tell who belongs to the same family.
-- Apply after 202611040003. Deploy the registration and staff Edge Functions right after.
begin;

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

commit;
