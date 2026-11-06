-- 2026-11-06: 接機接待 becomes its own answer with its own switch. Apply after 202611050006, then
-- deploy the registration and staff Edge Functions (they call the *_with_pickup RPCs and read
-- registration_pickup, so not before this), then the site (an older Edge Function drops its pickup).
--   * registration_pickup: one row per answered registration; 是 carries 1～6 seats, 否 carries 0.
--     Legacy registration_hosting.pickup_count 1～6 becomes 是; legacy 0 was a default, so it becomes
--     unanswered. The legacy column stays (old Edge Functions still write it) and is no longer read.
--   * The *_with_pickup wrappers run the existing RPC first, so its closed/invalid errors win, then
--     check and save pickup in the same transaction.
begin;

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

commit;
