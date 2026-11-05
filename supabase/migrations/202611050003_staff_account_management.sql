-- 2026-11-05: admins manage staff accounts directly. An admin sets a staff password and the person
-- does not have to change it; an admin can rename an account (display name and login name).
-- Accounts no longer belong to a district; staff_profiles.district_id stays for older rows.
-- Passwords themselves live only in Supabase Auth and never reach these functions or the audit.
-- Apply after 202611050002. Deploy the staff Edge Function right after.
begin;

-- Same as 202611040001 except that a staff account keeps the admin-set password, a new admin
-- account must change it at first login (like a password set for another admin), and accounts no
-- longer have a district: p_district_id stays only for the existing signature and is ignored.
create or replace function public.staff_create_profile(
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
    (auth_user_id, username, display_name, district_id, role, must_change_password)
  values (p_user_id, p_username, p_display_name, null, p_role, p_role = 'admin');
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, after_data)
  values ('admin', p_actor, 'staff.created', 'staff_profile', p_user_id,
    jsonb_build_object('username', p_username, 'role', p_role));
end;
$$;

-- Renames an account. The Edge Function changes the Auth login (username@accounts.invalid) first,
-- then compares it with the name this table holds and fixes it; saving again repairs a mismatch.
create function public.staff_update_profile(
  p_actor uuid, p_user_id uuid, p_username text, p_display_name text
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_before public.staff_profiles%rowtype;
begin
  perform public.staff_assert_actor(p_actor, true);
  if coalesce(p_username, '') !~ '^[a-z][a-z0-9_-]{2,30}$'
    or coalesce(length(btrim(p_display_name)), 0) not between 1 and 100 then
    raise exception using errcode = '22023', message = 'INVALID_STAFF_PROFILE';
  end if;
  select * into v_before from public.staff_profiles where auth_user_id = p_user_id for update;
  if not found then
    raise exception using errcode = '22023', message = 'STAFF_NOT_FOUND';
  end if;
  if v_before.username = p_username and v_before.display_name = btrim(p_display_name) then return; end if;
  update public.staff_profiles set username = p_username, display_name = btrim(p_display_name)
  where auth_user_id = p_user_id;
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, before_data, after_data)
  values ('admin', p_actor, 'staff.updated', 'staff_profile', p_user_id,
    jsonb_build_object('username', v_before.username, 'display_name', v_before.display_name),
    jsonb_build_object('username', p_username, 'display_name', btrim(p_display_name)));
exception
  when unique_violation then
    raise exception using errcode = '23505', message = 'USERNAME_TAKEN';
end;
$$;

-- Step 1 of an admin setting another account's password, before the password changes: confirms
-- the caller and target. Its only change marks an admin target to change the password, which is
-- safe even if the password then fails to change. Admins change their own password with the
-- current one instead.
create function public.staff_check_password_set(p_actor uuid, p_user_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform public.staff_assert_actor(p_actor, true);
  if p_actor = p_user_id then
    raise exception using errcode = '22023', message = 'SELF_PASSWORD_SET';
  end if;
  update public.staff_profiles set must_change_password = must_change_password or role = 'admin'
  where auth_user_id = p_user_id;
  if not found then
    raise exception using errcode = '22023', message = 'STAFF_NOT_FOUND';
  end if;
end;
$$;

-- Step 3, after the password changed: ends that account's logins and audits the change. A staff
-- account keeps the admin-set password. Another admin must change it at the next login, so one
-- admin cannot quietly keep a password that signs in as a different admin.
create function public.staff_mark_password_set(p_actor uuid, p_user_id uuid)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_must_change boolean;
begin
  perform public.staff_assert_actor(p_actor, true);
  if p_actor = p_user_id then
    raise exception using errcode = '22023', message = 'SELF_PASSWORD_SET';
  end if;
  update public.staff_profiles set must_change_password = (role = 'admin')
  where auth_user_id = p_user_id
  returning must_change_password into v_must_change;
  if not found then
    raise exception using errcode = '22023', message = 'STAFF_NOT_FOUND';
  end if;
  perform public.staff_revoke_sessions(p_user_id);
  insert into public.audit_events (actor_type, actor_user_id, action, target_type, target_id, after_data)
  values ('admin', p_actor, 'staff.password_set', 'staff_profile', p_user_id,
    jsonb_build_object('must_change_password', v_must_change));
  return v_must_change;
end;
$$;

-- Replaced by staff_mark_password_set; it would force a change the new policy no longer asks for.
drop function public.staff_mark_password_reset(uuid, uuid);

revoke execute on function public.staff_update_profile(uuid, uuid, text, text) from public, anon, authenticated;
revoke execute on function public.staff_check_password_set(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.staff_mark_password_set(uuid, uuid) from public, anon, authenticated;
grant execute on function public.staff_update_profile(uuid, uuid, text, text) to service_role;
grant execute on function public.staff_check_password_set(uuid, uuid) to service_role;
grant execute on function public.staff_mark_password_set(uuid, uuid) to service_role;

commit;
