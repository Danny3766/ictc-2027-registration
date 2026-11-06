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
begin;

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

commit;
