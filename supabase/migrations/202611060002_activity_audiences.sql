-- One audience per activity for now. Activity prerequisites use the stable activity ID.
begin;

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

commit;
