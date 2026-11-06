-- Beck's Hub: team admin role ("editor"). Creates and edits jobs, clients, plans and marketing.
-- Never sees money: no quote lines, rates, costs, orders, crew costs, invoices or Xero fields.

-- 1. Role
alter table public.profiles drop constraint if exists profiles_role_check;
alter table public.profiles add constraint profiles_role_check check (role in ('owner','admin','editor','crew','marketing','pending'));

create or replace function public.can_edit()
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select role in ('owner','admin','editor') from public.profiles where id = auth.uid()), false)
$$;

-- 2. Jobs without money. Money columns come back empty.
create or replace view public.jobs_safe as
  select j.id, j.job_no, j.client_id, j.title, j.address, j.suburb, j.stage, j.notes, j.crew_size,
         j.start_date, j.end_date, j.created_by, j.created_at, j.updated_at, j.closed_at,
         j.quoted_crew_days, j.lead_source, j.lost_reason, j.quote_no, j.quote_date, j.enquiry,
         j.promised_on, j.promised_weeks_min, j.promised_weeks_max, j.contacted_at, j.site_notes,
         j.est_days, j.tools, j.plan_transcript, j.quote_sent_at, j.quote_accepted_at, j.quote_accepted_name
  from public.jobs j
  where public.can_edit();
revoke all on public.jobs_safe from anon;
grant select on public.jobs_safe to authenticated;

-- 3. Save a job: only the non-money fields, and no money stages
create or replace function public.editor_save_job(p_id uuid, p jsonb)
returns uuid language plpgsql security definer set search_path = public as $$
declare
  allowed text[] := array['client_id','title','address','suburb','stage','notes','crew_size','start_date','end_date',
    'closed_at','lead_source','lost_reason','enquiry','promised_on','promised_weeks_min','promised_weeks_max',
    'contacted_at','site_notes','est_days','tools','plan_transcript'];
  k text; typ text; rid uuid := p_id;
begin
  if not public.can_edit() then raise exception 'Not allowed.'; end if;
  for k in select jsonb_object_keys(p) loop
    if not k = any(allowed) then raise exception 'Greg or Kaitlin changes %.', k; end if;
  end loop;
  if p ? 'stage' and not public.is_staff() and p->>'stage' in ('Accepted','Deposit in','Invoiced','Paid') then
    raise exception 'Greg or Kaitlin moves a job to %.', p->>'stage';
  end if;
  if rid is null then
    insert into public.jobs (stage, created_by) values (coalesce(p->>'stage','Lead'), auth.uid()) returning id into rid;
  end if;
  for k in select jsonb_object_keys(p) loop
    select format_type(a.atttypid, a.atttypmod) into typ from pg_attribute a
      where a.attrelid = 'public.jobs'::regclass and a.attname = k and not a.attisdropped;
    if typ is null then continue; end if;
    if typ in ('jsonb','json') then
      execute format('update public.jobs set %I = $1->%L where id = $2', k, k) using p, rid;
    elsif typ like '%[]' then
      execute format('update public.jobs set %I = case when jsonb_typeof($1->%L) = ''array'' then array(select jsonb_array_elements_text($1->%L))::%s else null end where id = $2', k, k, k, typ) using p, rid;
    else
      execute format('update public.jobs set %I = ($1->>%L)::%s where id = $2', k, k, typ) using p, rid;
    end if;
  end loop;
  return rid;
end $$;
revoke all on function public.editor_save_job(uuid, jsonb) from anon;
grant execute on function public.editor_save_job(uuid, jsonb) to authenticated;

-- 4. Tables the team admin can work in
create policy "editor clients" on public.clients for all to authenticated using (public.can_edit()) with check (public.can_edit());
create policy "editor notes" on public.client_notes for all to authenticated using (public.can_edit()) with check (public.can_edit());
create policy "editor plan days" on public.job_plan_days for all to authenticated using (public.can_edit()) with check (public.can_edit());
create policy "editor checkpoints" on public.checkpoints for insert to authenticated with check (public.can_edit());
create policy "editor issues" on public.issues for all to authenticated using (public.can_edit()) with check (public.can_edit());
create policy "editor attachments" on public.attachments for all to authenticated using (public.can_edit()) with check (public.can_edit());
create policy "editor files" on storage.objects for all to authenticated using (bucket_id = 'job-files' and public.can_edit()) with check (bucket_id = 'job-files' and public.can_edit());
create policy "editor campaigns" on public.campaigns for all to authenticated using (public.my_role() = 'editor') with check (public.my_role() = 'editor');

-- 5. Marketing: the team admin sends for approval like Lauren always has. Greg or Kaitlin approve.
create or replace function public.marketing_leads()
returns table(id uuid, first_name text, suburb text, lead_source text, stage text, created_at timestamptz, project_types jsonb, start_pref text, enquiring_as text)
language sql stable security definer set search_path = public as $$
  select j.id, split_part(coalesce(c.name, ''), ' ', 1), j.suburb, j.lead_source, j.stage, j.created_at,
         j.enquiry->'project_types', j.enquiry->>'start_pref', j.enquiry->>'enquiring_as'
  from public.jobs j left join public.clients c on c.id = j.client_id
  where public.my_role() in ('owner', 'admin', 'editor', 'marketing') and j.lead_source is not null
  order by j.created_at desc
$$;

create or replace function public.campaign_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare r text := public.my_role(); nm text;
begin
  if r in ('marketing','editor') then
    if new.status in ('Approved','Changes') and new.status is distinct from coalesce(old.status,'') then
      raise exception 'Greg or Kaitlin approves this one.';
    end if;
    if new.status in ('Live','Done') and coalesce(old.status,'') not in ('Approved','Live','Done') then
      raise exception 'It needs approving before it goes live.';
    end if;
    if tg_op = 'UPDATE' and old.status in ('Approved','Live') and new.status = old.status
       and (new.copy is distinct from old.copy or new.asset_url is distinct from old.asset_url or new.title is distinct from old.title) then
      new.status := 'For approval';
    end if;
    if new.status = 'For approval' and (tg_op = 'INSERT' or old.status is distinct from 'For approval') then
      new.sent_for_approval_at := now();
    end if;
  elsif r in ('owner','admin') then
    if new.status in ('Approved','Changes') and (tg_op = 'INSERT' or old.status is distinct from new.status) then
      select name into nm from public.profiles where id = auth.uid();
      new.reviewed_by := nm; new.reviewed_at := now();
    end if;
  end if;
  return new;
end $$;

-- 6. Lauren becomes team admin
update public.profiles set role = 'editor' where id = (select id from auth.users where email = 'hattonlauren1995@gmail.com');
