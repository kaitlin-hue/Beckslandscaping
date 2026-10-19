-- Beck's Hub: finance password, money locked to owner and admin,
-- website enquiries, quote timing and promised start windows.
-- Safe to run more than once.

------------------------------------------------------------------
-- 1. Finance password (one shared password, hashed, checked on the server)
------------------------------------------------------------------
create table if not exists public.finance_lock (
  id int primary key default 1 check (id = 1),
  pass_hash text not null,
  failed_attempts int not null default 0,
  last_failed_at timestamptz,
  updated_at timestamptz not null default now(),
  updated_by uuid
);
alter table public.finance_lock enable row level security;
revoke all on public.finance_lock from anon, authenticated;

create or replace function public.finance_password_set()
returns boolean language sql stable security definer set search_path = public as $$
  select case when public.is_staff() then exists(select 1 from public.finance_lock) else null end
$$;

create or replace function public.set_finance_password(new_pass text, old_pass text default null)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare cur text;
begin
  if not public.is_staff() then raise exception 'Not allowed'; end if;
  if new_pass is null or length(new_pass) < 6 then raise exception 'Use at least 6 characters'; end if;
  select pass_hash into cur from public.finance_lock where id = 1;
  if cur is not null and (old_pass is null or crypt(old_pass, cur) <> cur) then
    raise exception 'Current password is wrong';
  end if;
  insert into public.finance_lock (id, pass_hash, updated_at, updated_by, failed_attempts)
  values (1, crypt(new_pass, gen_salt('bf', 10)), now(), auth.uid(), 0)
  on conflict (id) do update set pass_hash = excluded.pass_hash, updated_at = now(),
    updated_by = auth.uid(), failed_attempts = 0, last_failed_at = null;
  return true;
end $$;

create or replace function public.check_finance_password(pass text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare r public.finance_lock;
begin
  if not public.is_staff() then return false; end if;
  select * into r from public.finance_lock where id = 1;
  if r is null then return false; end if;
  if r.failed_attempts >= 5 and r.last_failed_at > now() - interval '15 minutes' then
    raise exception 'Too many tries. Try again in 15 minutes.';
  end if;
  if crypt(pass, r.pass_hash) = r.pass_hash then
    update public.finance_lock set failed_attempts = 0, last_failed_at = null where id = 1;
    return true;
  end if;
  update public.finance_lock
    set failed_attempts = case when last_failed_at > now() - interval '15 minutes' then failed_attempts + 1 else 1 end,
        last_failed_at = now()
    where id = 1;
  return false;
end $$;

------------------------------------------------------------------
-- 2. New columns: enquiry answers, promised start window, timing settings
------------------------------------------------------------------
alter table public.jobs add column if not exists enquiry jsonb;
alter table public.jobs add column if not exists promised_on date;
alter table public.jobs add column if not exists promised_weeks_min int;
alter table public.jobs add column if not exists promised_weeks_max int;
alter table public.jobs add column if not exists contacted_at timestamptz;

alter table public.settings add column if not exists reply_due_days int not null default 2;
alter table public.settings add column if not exists quote_due_days int not null default 7;
alter table public.settings add column if not exists promise_warn_days int not null default 14;

------------------------------------------------------------------
-- 3. Crew and marketing see the board and leads without any money
------------------------------------------------------------------
create or replace function public.board_jobs()
returns table (id uuid, stage text, suburb text, title text, start_date date, end_date date,
  crew_size int, created_at timestamptz, promised_on date, promised_weeks_min int, promised_weeks_max int)
language sql stable security definer set search_path = public as $$
  select j.id, j.stage, j.suburb, j.title, j.start_date, j.end_date, j.crew_size, j.created_at,
         j.promised_on, j.promised_weeks_min, j.promised_weeks_max
  from public.jobs j where public.my_role() is not null
  order by j.created_at desc
$$;

create or replace function public.board_tasks()
returns table (id uuid, job_id uuid, seq int, task_type text, est_hours numeric, crew_size int, start_date date, end_date date)
language sql stable security definer set search_path = public as $$
  select t.id, t.job_id, t.seq, t.task_type, t.est_hours, t.crew_size, t.start_date, t.end_date
  from public.job_tasks t where public.my_role() is not null
  order by t.seq
$$;

-- Lauren: every enquiry with its source and where it got to. First name and suburb only, no money.
create or replace function public.marketing_leads()
returns table (id uuid, first_name text, suburb text, lead_source text, stage text, created_at timestamptz,
  project_types jsonb, start_pref text, enquiring_as text)
language sql stable security definer set search_path = public as $$
  select j.id, split_part(coalesce(c.name, ''), ' ', 1), j.suburb, j.lead_source, j.stage, j.created_at,
         j.enquiry->'project_types', j.enquiry->>'start_pref', j.enquiry->>'enquiring_as'
  from public.jobs j left join public.clients c on c.id = j.client_id
  where public.my_role() in ('owner', 'admin', 'marketing') and j.lead_source is not null
  order by j.created_at desc
$$;

drop policy if exists "team read jobs" on public.jobs;
drop policy if exists "staff read jobs" on public.jobs;
create policy "staff read jobs" on public.jobs for select using (public.is_staff());
drop policy if exists "team read job_tasks" on public.job_tasks;
drop policy if exists "staff read job_tasks" on public.job_tasks;
create policy "staff read job_tasks" on public.job_tasks for select using (public.is_staff());

------------------------------------------------------------------
-- 4. Website enquiry form posts here (no login). Lands as a Lead.
------------------------------------------------------------------
create table if not exists public.enquiry_log (
  id bigint generated always as identity primary key,
  email text, created_at timestamptz not null default now()
);
alter table public.enquiry_log enable row level security;
revoke all on public.enquiry_log from anon, authenticated;

create or replace function public.submit_enquiry(p jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_name text := left(trim(coalesce(p->>'name', '')), 120);
  v_email text := lower(left(trim(coalesce(p->>'email', '')), 160));
  v_phone text := left(trim(coalesce(p->>'phone', '')), 40);
  v_address text := left(trim(coalesce(p->>'address', '')), 200);
  v_suburb text := initcap(left(trim(coalesce(p->>'suburb', '')), 80));
  v_desc text := left(trim(coalesce(p->>'description', '')), 4000);
  v_types jsonb := case when jsonb_typeof(p->'project_types') = 'array' then p->'project_types' else '[]'::jsonb end;
  v_client uuid; v_job uuid;
begin
  -- spam guards: hidden field must be empty, form must take a few seconds, no flood
  if coalesce(p->>'website', '') <> '' then return jsonb_build_object('ok', true); end if;
  if coalesce((p->>'elapsed_ms')::int, 0) < 3000 then return jsonb_build_object('ok', true); end if;
  if (select count(*) from public.enquiry_log where created_at > now() - interval '1 hour') > 30 then
    raise exception 'Too many enquiries right now. Please call Greg on 0438 456 320.';
  end if;
  if exists (select 1 from public.enquiry_log where email = v_email and created_at > now() - interval '10 minutes') then
    return jsonb_build_object('ok', true);
  end if;
  if v_name = '' or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' or v_phone = '' or v_suburb = '' or v_desc = '' then
    raise exception 'Please fill in your name, mobile, email, suburb and a few words about the project.';
  end if;

  insert into public.enquiry_log (email) values (v_email);

  insert into public.clients (name, phone, email, address, suburb)
  values (v_name, v_phone, v_email, nullif(v_address, ''), v_suburb)
  returning id into v_client;

  insert into public.jobs (client_id, title, address, suburb, stage, notes, lead_source, enquiry)
  values (
    v_client,
    left(coalesce(nullif((select string_agg(x, ', ') from jsonb_array_elements_text(v_types) x), ''), 'Website enquiry'), 120),
    nullif(v_address, ''), v_suburb, 'Lead', v_desc,
    coalesce(nullif(left(p->>'source', 40), ''), 'Website'),
    jsonb_build_object(
      'project_types', v_types,
      'budget', left(p->>'budget', 40),
      'start_pref', left(p->>'start_pref', 40),
      'contact_pref', left(p->>'contact_pref', 20),
      'enquiring_as', left(p->>'enquiring_as', 30),
      'source', left(p->>'source', 40),
      'from', 'website',
      'submitted_at', now()
    )
  )
  returning id into v_job;

  insert into public.checkpoints (job_id, stage, note) values (v_job, 'Lead', 'Website enquiry');
  return jsonb_build_object('ok', true);
end $$;

------------------------------------------------------------------
-- 5. Who can call what
------------------------------------------------------------------
revoke all on function public.finance_password_set() from public, anon;
revoke all on function public.set_finance_password(text, text) from public, anon;
revoke all on function public.check_finance_password(text) from public, anon;
revoke all on function public.board_jobs() from public, anon;
revoke all on function public.board_tasks() from public, anon;
revoke all on function public.marketing_leads() from public, anon;
revoke all on function public.submit_enquiry(jsonb) from public;
grant execute on function public.finance_password_set() to authenticated;
grant execute on function public.set_finance_password(text, text) to authenticated;
grant execute on function public.check_finance_password(text) to authenticated;
grant execute on function public.board_jobs() to authenticated;
grant execute on function public.board_tasks() to authenticated;
grant execute on function public.marketing_leads() to authenticated;
grant execute on function public.submit_enquiry(jsonb) to anon, authenticated;
