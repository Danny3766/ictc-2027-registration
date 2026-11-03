-- 在測試專案 SQL Editor 執行；整個驗證交易最後回滾，不留下登記資料。
begin;

do $$
declare
  v_choices jsonb;
  v_district_id integer;
  v_code_hash text := replace(gen_random_uuid()::text, '-', '')
    || replace(gen_random_uuid()::text, '-', '');
  v_registration_id uuid;
begin
  if not coalesce((select is_test_environment from public.site_settings where id = true), false) then
    raise exception 'TEST_PROJECT_NOT_CONFIRMED';
  end if;

  select id into v_district_id
  from public.districts where is_active order by sort_order limit 1;
  select jsonb_agg(jsonb_build_object('activity_id', id, 'attending', false))
  into v_choices from public.activities where is_published;
  if v_district_id is null or v_choices is null then
    raise exception 'TEST_DATA_NOT_READY';
  end if;

  update public.registration_create_limits
  set window_started_at = now(), created_count = 0 where id = true;

  select registration_id into v_registration_id
  from public.create_registration(gen_random_uuid(), '安全驗收測試', v_district_id, v_code_hash, v_choices);
  if v_registration_id is null or
    (select count(*) from public.registration_choices where registration_id = v_registration_id) <> jsonb_array_length(v_choices) or
    exists (select 1 from public.registration_choices where registration_id = v_registration_id and attending) then
    raise exception 'ALL_NO_CREATE_FAILED';
  end if;

  if not public.update_registration(v_code_hash, '安全驗收測試修改', v_district_id, v_choices) then
    raise exception 'ALL_NO_UPDATE_FAILED';
  end if;
  if not public.set_registration_status(v_code_hash, 'cancelled') or
    not public.set_registration_status(v_code_hash, 'active') then
    raise exception 'ALL_NO_RESTORE_FAILED';
  end if;

  update public.registration_create_limits
  set window_started_at = now(), created_count = 50 where id = true;
  begin
    perform public.create_registration(gen_random_uuid(), '限流驗收測試', v_district_id,
      replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), v_choices);
    raise exception 'RATE_LIMIT_DID_NOT_BLOCK';
  exception when others then
    if sqlerrm <> 'CREATE_RATE_LIMITED' then raise; end if;
  end;

  raise notice 'ALL_NO_AND_RATE_LIMIT_OK';
end;
$$;

rollback;
