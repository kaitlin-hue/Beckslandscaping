-- Beck's Hub: day plan, tools, quote builder, client quote link, supplier orders, marketing approvals

-- 1. Day by day plan and tools
alter table public.jobs add column if not exists tools text[] not null default '{}';
alter table public.jobs add column if not exists est_days numeric;
alter table public.jobs add column if not exists plan_transcript text;

create table if not exists public.job_plan_days (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  day_no int not null,
  work_date date,
  title text,
  steps text[] not null default '{}',
  crew int,
  tools text[] not null default '{}',
  done boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists job_plan_days_job on public.job_plan_days(job_id, day_no);
alter table public.job_plan_days enable row level security;
drop policy if exists "staff all plan days" on public.job_plan_days;
create policy "staff all plan days" on public.job_plan_days for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- 2. Suppliers
create table if not exists public.suppliers (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  email text, phone text, account_no text, notes text,
  created_at timestamptz not null default now()
);
alter table public.suppliers enable row level security;
drop policy if exists "staff all suppliers" on public.suppliers;
create policy "staff all suppliers" on public.suppliers for all to authenticated using (public.is_staff()) with check (public.is_staff());
insert into public.suppliers (name)
  select distinct supplier from public.rates where supplier is not null and supplier <> ''
  on conflict (name) do nothing;

-- 3. Quote lines (cost, markup, sell) and quote fields on the job
create table if not exists public.quote_lines (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  seq int not null default 0,
  kind text not null default 'Materials' check (kind in ('Labour','Materials','Plant and hire','Subcontractor','Other')),
  item text not null,
  description text,
  qty numeric not null default 1,
  unit text,
  unit_cost numeric,
  markup_pct numeric,
  unit_price numeric,
  supplier text,
  show_on_quote boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists quote_lines_job on public.quote_lines(job_id, seq);
alter table public.quote_lines enable row level security;
drop policy if exists "staff all quote lines" on public.quote_lines;
create policy "staff all quote lines" on public.quote_lines for all to authenticated using (public.is_staff()) with check (public.is_staff());

alter table public.settings add column if not exists default_markup_pct numeric not null default 25;
alter table public.settings add column if not exists deposit_pct numeric not null default 30;
alter table public.settings add column if not exists quote_valid_days int not null default 30;
alter table public.settings add column if not exists quote_terms text;

alter table public.jobs add column if not exists quote_token uuid;
alter table public.jobs add column if not exists quote_intro text;
alter table public.jobs add column if not exists quote_exclusions text;
alter table public.jobs add column if not exists quote_valid_until date;
alter table public.jobs add column if not exists quote_sent_at timestamptz;
alter table public.jobs add column if not exists quote_viewed_at timestamptz;
alter table public.jobs add column if not exists quote_accepted_at timestamptz;
alter table public.jobs add column if not exists quote_accepted_name text;
alter table public.jobs add column if not exists deposit_pct numeric;
create unique index if not exists jobs_quote_token on public.jobs(quote_token) where quote_token is not null;

-- Client facing quote: sell prices only, never cost or markup
create or replace function public.quote_sell(l public.quote_lines, mk numeric)
returns numeric language sql immutable as $$
  select round(coalesce(l.unit_price, coalesce(l.unit_cost,0) * (1 + coalesce(l.markup_pct, mk, 0)/100.0)) * coalesce(l.qty,1), 2)
$$;

create or replace function public.get_quote(p_token uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare j public.jobs; c public.clients; s public.settings; sub numeric; res jsonb;
begin
  select * into j from public.jobs where quote_token = p_token;
  if j.id is null then return null; end if;
  select * into c from public.clients where id = j.client_id;
  select * into s from public.settings where id = 1;
  if j.quote_viewed_at is null and j.quote_sent_at is not null and not public.is_staff() then
    update public.jobs set quote_viewed_at = now() where id = j.id;
  end if;
  select coalesce(sum(public.quote_sell(l, s.default_markup_pct)),0) into sub from public.quote_lines l where l.job_id = j.id;
  res := jsonb_build_object(
    'quote_no', coalesce(j.quote_no, 'Q' || j.job_no),
    'quote_date', coalesce(j.quote_date, j.quote_sent_at::date, current_date),
    'valid_until', j.quote_valid_until,
    'client', c.name, 'address', j.address, 'suburb', j.suburb, 'title', j.title,
    'intro', j.quote_intro, 'exclusions', j.quote_exclusions, 'terms', s.quote_terms,
    'est_days', j.est_days, 'crew_size', j.crew_size,
    'deposit_pct', coalesce(j.deposit_pct, s.deposit_pct),
    'gst_rate', coalesce(s.gst_rate, 0.10),
    'subtotal', sub,
    'accepted_at', j.quote_accepted_at, 'accepted_name', j.quote_accepted_name,
    'sections', coalesce((
      select jsonb_agg(jsonb_build_object('kind', k.kind, 'lines', k.lines, 'total', k.total) order by k.ord)
      from (
        select l.kind,
          min(case l.kind when 'Labour' then 1 when 'Materials' then 2 when 'Plant and hire' then 3 when 'Subcontractor' then 4 else 5 end) as ord,
          jsonb_agg(jsonb_build_object('item', l.item, 'description', l.description, 'qty', l.qty, 'unit', l.unit,
             'amount', public.quote_sell(l, s.default_markup_pct)) order by l.seq) filter (where l.show_on_quote) as lines,
          sum(public.quote_sell(l, s.default_markup_pct)) as total
        from public.quote_lines l where l.job_id = j.id group by l.kind) k), '[]'::jsonb),
    'days', coalesce((select jsonb_agg(jsonb_build_object('day_no', d.day_no, 'title', d.title) order by d.day_no)
                      from public.job_plan_days d where d.job_id = j.id), '[]'::jsonb)
  );
  return res;
end $$;

create or replace function public.accept_quote(p_token uuid, p_name text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare j public.jobs;
begin
  if coalesce(trim(p_name),'') = '' then raise exception 'Please type your name to accept.'; end if;
  select * into j from public.jobs where quote_token = p_token;
  if j.id is null then raise exception 'This quote link is not valid.'; end if;
  if j.quote_accepted_at is not null then return jsonb_build_object('ok', true, 'already', true); end if;
  if j.quote_valid_until is not null and j.quote_valid_until < current_date then
    raise exception 'This quote has expired. Please call Greg on 0438 456 320 for an updated price.';
  end if;
  update public.jobs set quote_accepted_at = now(), quote_accepted_name = left(trim(p_name),120),
    stage = case when stage in ('Lead','Design','Quoted') then 'Accepted' else stage end
  where id = j.id;
  insert into public.checkpoints (job_id, stage, note, done_by) values (j.id, 'Accepted', 'Accepted online by ' || left(trim(p_name),120), null);
  return jsonb_build_object('ok', true);
end $$;
grant execute on function public.get_quote(uuid) to anon, authenticated;
grant execute on function public.accept_quote(uuid, text) to anon, authenticated;

-- 4. Supplier orders
create table if not exists public.purchase_orders (
  id uuid primary key default gen_random_uuid(),
  job_id uuid not null references public.jobs(id) on delete cascade,
  supplier text not null,
  status text not null default 'Draft' check (status in ('Draft','Ordered','Delivered','Invoiced')),
  needed_by date,
  lines jsonb not null default '[]',
  total numeric,
  note text,
  ordered_at timestamptz, delivered_at timestamptz, invoiced_amount numeric,
  created_at timestamptz not null default now()
);
create index if not exists purchase_orders_job on public.purchase_orders(job_id);
alter table public.purchase_orders enable row level security;
drop policy if exists "staff all orders" on public.purchase_orders;
create policy "staff all orders" on public.purchase_orders for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- 5. Crew see the day plan and tools (no money)
create or replace function public.crew_job(p_job uuid)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when public.my_role() is null then null else (
    select jsonb_build_object(
      'id', j.id, 'title', j.title, 'address', j.address, 'suburb', j.suburb, 'stage', j.stage,
      'client', split_part(coalesce(c.name, ''), ' ', 1),
      'start_date', j.start_date, 'end_date', j.end_date, 'crew_size', j.crew_size, 'site_notes', j.site_notes,
      'tools', to_jsonb(j.tools), 'est_days', j.est_days,
      'plan', coalesce((select jsonb_agg(jsonb_build_object('day_no', d.day_no, 'work_date', d.work_date, 'title', d.title,
                 'steps', to_jsonb(d.steps), 'tools', to_jsonb(d.tools), 'crew', d.crew, 'done', d.done) order by d.day_no)
                 from public.job_plan_days d where d.job_id = j.id), '[]'::jsonb),
      'tasks', coalesce((select jsonb_agg(jsonb_build_object('task_type', t.task_type, 'description', t.description, 'qty', t.qty,
                 'unit', t.unit, 'est_hours', t.est_hours, 'start_date', t.start_date, 'end_date', t.end_date) order by t.seq)
                 from public.job_tasks t where t.job_id = j.id), '[]'::jsonb),
      'issues', coalesce((select jsonb_agg(jsonb_build_object('category', i.category, 'note', i.note, 'status', i.status, 'work_date', i.work_date) order by i.created_at desc)
                 from public.issues i where i.job_id = j.id and i.status <> 'sorted'), '[]'::jsonb))
    from public.jobs j left join public.clients c on c.id = j.client_id where j.id = p_job) end
$$;

-- 6. Marketing approvals: Lauren sends, Greg or Kaitlin approve
alter table public.campaigns drop constraint if exists campaigns_status_check;
alter table public.campaigns add constraint campaigns_status_check check (status in ('Planned','Drafted','For approval','Changes','Approved','Live','Done'));
alter table public.campaigns add column if not exists copy text;
alter table public.campaigns add column if not exists asset_url text;
alter table public.campaigns add column if not exists review_note text;
alter table public.campaigns add column if not exists sent_for_approval_at timestamptz;
alter table public.campaigns add column if not exists reviewed_by text;
alter table public.campaigns add column if not exists reviewed_at timestamptz;

create or replace function public.campaign_guard()
returns trigger language plpgsql security definer set search_path = public as $$
declare r text := public.my_role(); nm text;
begin
  if r = 'marketing' then
    if new.status in ('Approved','Changes') and new.status is distinct from coalesce(old.status,'') then
      raise exception 'Greg or Kaitlin approves this one.';
    end if;
    if new.status in ('Live','Done') and coalesce(old.status,'') not in ('Approved','Live','Done') then
      raise exception 'It needs approving before it goes live.';
    end if;
    -- editing an approved piece sends it back for approval
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
drop trigger if exists campaign_guard on public.campaigns;
create trigger campaign_guard before insert or update on public.campaigns for each row execute function public.campaign_guard();
