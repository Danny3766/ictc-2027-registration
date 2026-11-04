-- 2026-11-04: back-office staff accounts and operations, plus the switch from query codes to
-- name-and-district lookup. Merged from seven unapplied migrations (202611040001 to 0007), each
-- kept below under its original name. Apply after 202611030001 to 202611030004.
-- Clear existing test registrations first: the active name-and-district unique index fails on duplicates.
begin;

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

commit;
