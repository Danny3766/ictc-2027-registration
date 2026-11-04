begin;

-- Every answer must be a distinct published activity with a boolean. A new registration
-- (p_registration_id null) must answer every published activity. An edit must keep each
-- answer the registration already has, but may leave a newer activity unanswered (未回覆),
-- because only the registrant decides those.
create function public.staff_choices_valid(p_choices jsonb, p_registration_id uuid default null)
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
  where id = p_registration_id and record_status <> 'duplicate_void' for update;
  if not found then return false; end if;

  -- Keeping an inactive district is allowed; moving someone into one is not.
  if coalesce(length(btrim(p_full_name)), 0) not between 1 and 100
    or not exists (select 1 from public.districts where id = p_district_id
      and (is_active or id = v_registration.district_id)) then
    raise exception using errcode = '22023', message = 'INVALID_REGISTRATION';
  end if;
  if public.staff_choices_valid(p_choices, p_registration_id) is not true then
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

create function public.staff_mark_duplicate(
  p_actor uuid, p_registration_id uuid, p_resolution text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare v_before public.registrations%rowtype;
begin
  perform public.staff_assert_actor(p_actor);
  if p_resolution not in ('confirmed_distinct', 'duplicate_void') then
    raise exception using errcode = '22023', message = 'INVALID_DUPLICATE_RESOLUTION';
  end if;
  select * into v_before from public.registrations where id = p_registration_id for update;
  if not found then return false; end if;
  if v_before.record_status = 'duplicate_void' then
    raise exception using errcode = '22023', message = 'DUPLICATE_ALREADY_VOID';
  end if;
  if p_resolution = 'confirmed_distinct' and v_before.duplicate_review_status = 'confirmed_distinct' then return true; end if;
  update public.registrations set
    record_status = case when p_resolution = 'duplicate_void' then 'duplicate_void' else record_status end,
    duplicate_review_status = case when p_resolution = 'confirmed_distinct' then 'confirmed_distinct' else duplicate_review_status end,
    import_status = case when p_resolution = 'duplicate_void' and import_status = 'imported' then 'reimport_needed' else import_status end,
    updated_at = now()
  where id = p_registration_id;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  values ('staff', p_actor, 'registration.duplicate_resolved', 'registration', p_registration_id,
    jsonb_build_object('record_status', v_before.record_status,
      'duplicate_review_status', v_before.duplicate_review_status, 'import_status', v_before.import_status),
    jsonb_build_object('resolution', p_resolution,
      'import_status', case when p_resolution = 'duplicate_void' and v_before.import_status = 'imported'
        then 'reimport_needed' else v_before.import_status end));
  return true;
end;
$$;

create function public.staff_reset_query_code(
  p_actor uuid, p_serial_no bigint, p_query_code_hash text
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare v_registration_id uuid;
begin
  perform public.staff_assert_actor(p_actor);
  if p_query_code_hash !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'INVALID_QUERY_CODE_HASH';
  end if;
  select id into v_registration_id from public.registrations
  where serial_no = p_serial_no and record_status <> 'duplicate_void' for update;
  if not found then return false; end if;
  update public.registrations set query_code_hash = p_query_code_hash, updated_at = now()
  where id = v_registration_id;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id)
  values ('staff', p_actor, 'registration.query_code_reset', 'registration', v_registration_id);
  return true;
end;
$$;

revoke execute on function public.staff_choices_valid(jsonb,uuid) from public, anon, authenticated;
grant execute on function public.staff_choices_valid(jsonb,uuid) to service_role;
revoke execute on function public.staff_update_registration(uuid,uuid,text,integer,jsonb) from public, anon, authenticated;
revoke execute on function public.staff_set_import_status(uuid,uuid,text) from public, anon, authenticated;
revoke execute on function public.staff_mark_duplicate(uuid,uuid,text) from public, anon, authenticated;
revoke execute on function public.staff_reset_query_code(uuid,bigint,text) from public, anon, authenticated;
grant execute on function public.staff_update_registration(uuid,uuid,text,integer,jsonb) to service_role;
grant execute on function public.staff_set_import_status(uuid,uuid,text) to service_role;
grant execute on function public.staff_mark_duplicate(uuid,uuid,text) to service_role;
grant execute on function public.staff_reset_query_code(uuid,bigint,text) to service_role;

commit;
