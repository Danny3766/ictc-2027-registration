begin;

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

commit;
