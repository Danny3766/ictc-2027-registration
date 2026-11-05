-- 2026-11-05: changes from the test-site trial feedback. Apply after 202611050003.
-- Deploy the registration and staff Edge Functions and the site right after.
--   * 開家接待 asks 是／否／家人已登記開家接待, then 可以接待幾位 (1 to 10 people) and 接待對象
--     (夫婦／弟兄／姊妹／不拘). The family count and the free-text note are removed.
--     Existing test answers are converted (家庭 becomes 不拘, more than 10 becomes 10, family
--     count and note cleared); the conversion leaves import_status alone, since the registrant
--     changed nothing.
--   * family_count and note stay as always-null columns, because the staff Edge Function deployed
--     before this change still selects them; drop them in a later migration once both Edge
--     Functions are redeployed. The new Edge Functions read event_note, so deploy them after this.
--   * site_settings.event_note: an optional note of up to 500 characters (traffic, links) shown
--     under the address on the public page.
--   * A district 其他 for people outside the three districts.
-- Replaced functions keep their signatures, so create or replace keeps the existing grants.
begin;

alter table public.registration_hosting
  drop constraint registration_hosting_details,
  drop constraint registration_hosting_counts_max,
  drop constraint registration_hosting_guest_type_check;

update public.registration_hosting set
  guest_type = case when guest_type = 'family' then 'any' else guest_type end,
  guest_count = least(guest_count, 10),
  family_count = null,
  note = null
where guest_type = 'family' or guest_count > 10 or family_count is not null or note is not null;

alter table public.registration_hosting
  add constraint registration_hosting_removed_fields check (family_count is null and note is null),
  add constraint registration_hosting_guest_type_check
    check (guest_type in ('couple', 'brother', 'sister', 'any')),
  add constraint registration_hosting_counts_max check (guest_count <= 10),
  add constraint registration_hosting_details check (
    case when status = 'hosting' then guest_type is not null and guest_count is not null
      else guest_type is null and guest_count is null end);

-- Same contract as before: the answer in stored form, null for no answer (未回覆), or INVALID_HOSTING.
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
  return jsonb_build_object('status', v_status, 'guest_type', v_type, 'guest_count', v_count);
end;
$$;

create or replace function public.registration_hosting_get(p_registration_id uuid)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object('status', status, 'guest_type', guest_type, 'guest_count', guest_count)
  from public.registration_hosting where registration_id = p_registration_id;
$$;

-- p_value must come from registration_hosting_value.
create or replace function public.registration_hosting_put(p_registration_id uuid, p_value jsonb)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into public.registration_hosting (registration_id, status, guest_type, guest_count)
  select p_registration_id, v.status, v.guest_type, v.guest_count
  from jsonb_to_record(p_value) as v(status text, guest_type text, guest_count integer)
  on conflict (registration_id) do update set
    status = excluded.status, guest_type = excluded.guest_type, guest_count = excluded.guest_count,
    updated_at = now();
$$;

alter table public.site_settings
  add column event_note text
    constraint site_settings_event_note_length check (length(event_note) <= 500);

-- Same as 202611050001, plus event_note in 'settings'. A request without event_note (an Edge
-- Function or page from before this change) keeps the stored note instead of clearing it.
create or replace function public.staff_save_reference(p_actor uuid, p_kind text, p_data jsonb)
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
      -- A textarea: also trims line breaks, tabs and full-width spaces (an ASCII escape, since editors
      -- drop invisible characters), so a blank note clears it.
      event_note = case when p_data ? 'event_note'
        then nullif(btrim(p_data->>'event_note', E' \t\r\n\u3000'), '') else event_note end,
      registration_deadline_at = nullif(p_data->>'registration_deadline_at', '')::timestamptz,
      is_registration_open = (p_data->>'is_registration_open')::boolean,
      is_lookup_open = coalesce((p_data->>'is_lookup_open')::boolean, is_lookup_open),
      updated_at = now()
    where id returning to_jsonb(site_settings.*) into v_after;
  elsif p_kind = 'hosting' then
    select to_jsonb(s) into v_before from public.site_settings s where id for update;
    update public.site_settings set
      is_hosting_open = (p_data->>'is_hosting_open')::boolean,
      hosting_description = nullif(btrim(p_data->>'hosting_description'), ''),
      updated_at = now()
    where id returning to_jsonb(site_settings.*) into v_after;
  elsif p_kind = 'district' then
    v_id := nullif(p_data->>'id', '')::bigint;
    if v_id is null then
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
        (category, title, starts_at, starts_at_has_time, ends_at, ends_at_has_time,
         venue, address, map_url, description, fee_amount, is_published, sort_order)
      values (
        p_data->>'category', btrim(p_data->>'title'),
        nullif(p_data->>'starts_at', '')::timestamptz,
        coalesce((p_data->>'starts_at_has_time')::boolean, nullif(p_data->>'starts_at', '') is not null),
        nullif(p_data->>'ends_at', '')::timestamptz,
        coalesce((p_data->>'ends_at_has_time')::boolean, nullif(p_data->>'ends_at', '') is not null),
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
        starts_at_has_time = coalesce((p_data->>'starts_at_has_time')::boolean, nullif(p_data->>'starts_at', '') is not null),
        ends_at = nullif(p_data->>'ends_at', '')::timestamptz,
        ends_at_has_time = coalesce((p_data->>'ends_at_has_time')::boolean, nullif(p_data->>'ends_at', '') is not null),
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
  if p_kind = 'activity' and v_before is not null
    and (v_before->'title', v_before->'starts_at', v_before->'starts_at_has_time',
         v_before->'ends_at', v_before->'ends_at_has_time', v_before->'is_published')
      is distinct from
        (v_after->'title', v_after->'starts_at', v_after->'starts_at_has_time',
         v_after->'ends_at', v_after->'ends_at_has_time', v_after->'is_published') then
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
  if (v_before - 'updated_at') is distinct from (v_after - 'updated_at') then
    insert into public.audit_events
      (actor_type, actor_user_id, action, target_type, before_data, after_data)
    values ('admin', p_actor, 'reference.saved', p_kind, v_before, v_after);
  end if;
  return v_after;
end;
$$;

insert into public.districts (name, sort_order)
select '其他', coalesce(max(sort_order), 0) + 1 from public.districts
on conflict (name) do nothing;

commit;
