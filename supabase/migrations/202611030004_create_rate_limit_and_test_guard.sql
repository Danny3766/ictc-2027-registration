begin;

alter table public.site_settings
  add column is_test_environment boolean not null default false;

create table public.registration_create_limits (
  id boolean primary key default true check (id),
  window_started_at timestamptz not null default now(),
  created_count integer not null default 0 check (created_count between 0 and 50)
);

alter table public.registration_create_limits enable row level security;
grant select, update on public.registration_create_limits to service_role;
insert into public.registration_create_limits default values;
create or replace function public.create_registration(
  p_request_id uuid,
  p_full_name text,
  p_district_id integer,
  p_query_code_hash text,
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
  v_published_count integer;
  v_answered_count integer;
begin
  if not exists (
    select 1 from public.site_settings
    where id and is_registration_open
      and (registration_deadline_at is null or registration_deadline_at > now())
  ) then
    raise exception using errcode = 'P0001', message = 'REGISTRATION_CLOSED';
  end if;

  if length(btrim(p_full_name)) not between 1 and 100 then
    raise exception using errcode = '22023', message = 'INVALID_NAME';
  end if;

  if not exists (
    select 1 from public.districts where id = p_district_id and is_active
  ) then
    raise exception using errcode = '22023', message = 'INVALID_DISTRICT';
  end if;

  if jsonb_typeof(p_choices) <> 'array' then
    raise exception using errcode = '22023', message = 'INVALID_CHOICES';
  end if;

  select count(*) into v_published_count
  from public.activities where is_published;

  select count(*) into v_answered_count
  from (
    select distinct (choice->>'activity_id')::bigint as activity_id,
      (choice->>'attending')::boolean as attending
    from jsonb_array_elements(p_choices) choice
    where choice ? 'activity_id' and choice ? 'attending'
  ) answers
  join public.activities activity on activity.id = answers.activity_id
  where activity.is_published;

  if v_published_count = 0
    or jsonb_array_length(p_choices) <> v_published_count
    or v_answered_count <> v_published_count then
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
  insert into public.registrations (
    create_request_id, full_name, district_id, query_code_hash
  ) values (
    p_request_id, btrim(p_full_name), p_district_id, p_query_code_hash
  )
  returning id, registrations.serial_no into v_registration_id, v_serial_no;

  insert into public.registration_choices (registration_id, activity_id, attending)
  select v_registration_id, (choice->>'activity_id')::bigint, (choice->>'attending')::boolean
  from jsonb_array_elements(p_choices) choice
  join public.activities activity on activity.id = (choice->>'activity_id')::bigint
  where activity.is_published;

  insert into public.audit_events (actor_type, action, target_type, target_id, after_data)
  values ('public', 'registration.created', 'registration', v_registration_id,
    jsonb_build_object('full_name', btrim(p_full_name), 'district_id', p_district_id));

  return query select v_registration_id, v_serial_no;
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

commit;
