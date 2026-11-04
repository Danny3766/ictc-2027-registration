begin;

-- Saves a drag-and-drop order for activities in one call. The list must name every activity
-- exactly once, so a stale page (an activity added or removed elsewhere) is refused instead of
-- leaving gaps. Sort order alone never marks registrations for re-import.
create function public.staff_reorder_activities(p_actor uuid, p_activity_ids bigint[])
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_before jsonb;
  v_after jsonb;
begin
  perform public.staff_assert_actor(p_actor, true);
  -- Row locks would not stop an activity inserted after the count check; this table lock does.
  lock table public.activities in share row exclusive mode;
  if p_activity_ids is null
    or cardinality(p_activity_ids) <> (select count(*) from public.activities)
    or cardinality(p_activity_ids) <> (select count(distinct given.activity_id) from unnest(p_activity_ids) as given(activity_id))
    or exists (
      select 1 from unnest(p_activity_ids) as given(activity_id)
      where not exists (select 1 from public.activities activity where activity.id = given.activity_id)
    ) then
    raise exception using errcode = '22023', message = 'INVALID_ACTIVITY_ORDER';
  end if;

  select jsonb_agg(id order by sort_order, id) into v_before from public.activities;
  update public.activities activity
  set sort_order = ordered.position::integer, updated_at = now()
  from unnest(p_activity_ids) with ordinality as ordered(activity_id, position)
  where activity.id = ordered.activity_id and activity.sort_order is distinct from ordered.position::integer;
  select jsonb_agg(id order by sort_order, id) into v_after from public.activities;

  if v_before is distinct from v_after then
    insert into public.audit_events (actor_type, actor_user_id, action, target_type, before_data, after_data)
    values ('admin', p_actor, 'reference.reordered', 'activity',
      jsonb_build_object('order', v_before), jsonb_build_object('order', v_after));
  end if;
end;
$$;

revoke execute on function public.staff_reorder_activities(uuid, bigint[]) from public, anon, authenticated;
grant execute on function public.staff_reorder_activities(uuid, bigint[]) to service_role;

commit;
