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
begin;

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

commit;
