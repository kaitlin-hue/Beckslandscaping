-- Forgotten password from the login screen: logs a request Kaitlin sees on To check
create or replace function public.request_password_reset(p_login text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v text := lower(left(trim(coalesce(p_login,'')), 60));
begin
  if v = '' then return jsonb_build_object('ok', true); end if;
  if (select count(*) from public.automation_log where action='reset_request' and created_at > now() - interval '1 hour') >= 20 then return jsonb_build_object('ok', true); end if;
  if exists (select 1 from public.automation_log where action='reset_request' and ref=v and created_at > now() - interval '15 minutes') then return jsonb_build_object('ok', true); end if;
  insert into public.automation_log(action, detail, ref, needs_check) values ('reset_request', 'Asked for a new password from the login screen', v, true);
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.request_password_reset(text) from public;
grant execute on function public.request_password_reset(text) to anon, authenticated;
