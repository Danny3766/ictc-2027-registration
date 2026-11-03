-- 先核對 Dashboard 的 Project Reference，再將下方 placeholder 換成該測試專案的值。
do $$
declare
  v_confirmed_project_ref text := 'REPLACE_WITH_TEST_PROJECT_REF';
begin
  if v_confirmed_project_ref !~ '^[a-z0-9]{20}$' then
    raise exception 'CONFIRM_TEST_PROJECT_REF_FIRST';
  end if;

  update public.site_settings
  set is_test_environment = true, updated_at = now()
  where id = true and not is_test_environment;
end;
$$;
