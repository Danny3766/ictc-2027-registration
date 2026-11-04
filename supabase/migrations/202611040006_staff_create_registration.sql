begin;

create function public.staff_create_registration(
  p_actor uuid, p_request_id uuid, p_full_name text, p_district_id integer,
  p_query_code_hash text, p_choices jsonb
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
    or p_query_code_hash !~ '^[0-9a-f]{64}$'
    or not exists (select 1 from public.districts where id = p_district_id and is_active) then
    raise exception using errcode = '22023', message = 'INVALID_REGISTRATION';
  end if;
  if public.staff_choices_valid(p_choices) is not true then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;

  insert into public.registrations
    (create_request_id, full_name, district_id, query_code_hash)
  values (p_request_id, btrim(p_full_name), p_district_id, p_query_code_hash)
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
    raise;
  when invalid_text_representation then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
end;
$$;

revoke execute on function public.staff_create_registration(uuid,uuid,text,integer,text,jsonb) from public, anon, authenticated;
grant execute on function public.staff_create_registration(uuid,uuid,text,integer,text,jsonb) to service_role;

commit;
