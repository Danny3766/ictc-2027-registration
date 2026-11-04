begin;

-- Existing record_status values remain for historical test records.
drop function if exists public.set_registration_status(text, text);

commit;
