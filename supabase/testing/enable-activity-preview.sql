-- 只在開發／測試 Supabase 專案執行；正式環境維持未確認活動不公開。
begin;

do $$
begin
  if not coalesce((select is_test_environment from public.site_settings where id = true), false) then
    raise exception 'TEST_PROJECT_NOT_CONFIRMED';
  end if;
end;
$$;

update public.activities
set is_published = true, updated_at = now()
where (category = 'meal' and title in ('週六午餐', '週六晚餐', '主日午餐'))
   or (category = 'other' and title = '主日晚間帶菜愛筵');

update public.site_settings
set is_registration_open = true,
    registration_deadline_at = case
      when registration_deadline_at <= now() then null
      else registration_deadline_at
    end,
    updated_at = now()
where id = true;

commit;
