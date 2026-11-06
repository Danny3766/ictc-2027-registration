-- 2026-11-06: Supabase grants every new object in public to anon and authenticated by default.
-- The site reaches data only through the Edge Functions (service_role), so those defaults left
-- RLS as the only barrier: anon held SELECT/INSERT/UPDATE/DELETE/TRUNCATE on private tables.
-- Keep only the public reads granted on purpose (202611030001, 202611050006), and stop new
-- objects from being granted automatically. Apply before the Edge Functions; nothing else changes.
begin;

revoke all on all tables in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;
-- PUBLIC holds EXECUTE on functions by default; the Edge Functions run as service_role.
revoke all on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

grant select on public.districts, public.site_settings, public.program_items to anon;
grant select (id, category, title, starts_at, starts_at_has_time, ends_at, ends_at_has_time, venue, address,
  map_url, description, fee_amount, student_fee_amount, audience, audience_note, is_published, sort_order,
  created_at, updated_at) on public.activities to anon;

-- Objects created later by this role: no automatic access for the API roles.
alter default privileges in schema public revoke all on tables from anon, authenticated;
alter default privileges in schema public revoke all on sequences from anon, authenticated;
alter default privileges in schema public revoke all on functions from public, anon, authenticated;
alter default privileges in schema public grant execute on functions to service_role;

commit;
