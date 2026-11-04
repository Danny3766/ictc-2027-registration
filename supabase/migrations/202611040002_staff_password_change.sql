begin;

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

commit;
