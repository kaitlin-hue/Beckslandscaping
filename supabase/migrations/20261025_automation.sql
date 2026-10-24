-- Automation: invoice and review tracking on jobs, plus a log Kaitlin cross-checks

alter table public.jobs add column if not exists deposit_invoice_no text;
alter table public.jobs add column if not exists deposit_invoice_at timestamptz;
alter table public.jobs add column if not exists deposit_paid_at timestamptz;
alter table public.jobs add column if not exists final_invoice_no text;
alter table public.jobs add column if not exists final_invoice_at timestamptz;
alter table public.jobs add column if not exists paid_at timestamptz;
alter table public.jobs add column if not exists review_sent_at timestamptz;

create table if not exists public.automation_log (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  job_id uuid references public.jobs(id) on delete set null,
  action text not null,            -- deposit_invoice, deposit_paid, final_invoice, review_draft, note
  detail text,                     -- what happened, in plain words
  amount numeric,                  -- ex GST where it applies
  ref text,                        -- Xero invoice number or Gmail draft id
  needs_check boolean not null default true,
  checked_at timestamptz,
  checked_by uuid references public.profiles(id)
);
alter table public.automation_log enable row level security;

create policy "staff read log" on public.automation_log for select using (public.is_staff());

create policy "staff write log" on public.automation_log for all using (public.is_staff()) with check (public.is_staff());
create index if not exists automation_log_created on public.automation_log(created_at desc);

-- What the daily automation has to do next. Service role reads this.
create or replace function public.automation_queue()
returns table (job_id uuid, job_no int, client_name text, client_email text, suburb text, stage text,
  action text, quote_total numeric, deposit_pct numeric, deposit_invoice_no text, final_invoice_no text, paid_at timestamptz)
language sql stable security definer set search_path = public as $$
  select j.id, j.job_no, c.name, c.email, j.suburb, j.stage,
    case
      when j.stage='Accepted' and j.deposit_invoice_no is null then 'deposit_invoice'
      when j.stage='Accepted' and j.deposit_invoice_no is not null and j.deposit_paid_at is null then 'check_deposit_paid'
      when j.stage='Complete' and j.final_invoice_no is null then 'final_invoice'
      when j.stage='Invoiced' and j.paid_at is null then 'check_final_paid'
      when j.stage='Paid' and j.review_sent_at is null and coalesce(j.paid_at, j.updated_at, j.created_at) <= now() - interval '7 days' then 'review_draft'
    end as action,
    j.quote_total, coalesce(j.deposit_pct, (select s.deposit_pct from public.settings s limit 1), 30),
    j.deposit_invoice_no, j.final_invoice_no, j.paid_at
  from public.jobs j left join public.clients c on c.id=j.client_id
  where j.stage in ('Accepted','Complete','Invoiced','Paid')
$$;
