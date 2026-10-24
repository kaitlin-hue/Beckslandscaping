-- CRM: client notes and follow ups, client source, photos against a client

alter table public.clients add column if not exists source text;
alter table public.attachments add column if not exists client_id uuid references public.clients(id) on delete set null;
create index if not exists attachments_client on public.attachments(client_id);

create table if not exists public.client_notes (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  client_id uuid not null references public.clients(id) on delete cascade,
  job_id uuid references public.jobs(id) on delete set null,
  kind text not null default 'Note',          -- Note, Call, Text, Email, Site visit
  note text,
  follow_up_on date,
  done_at timestamptz,
  by uuid references public.profiles(id),
  by_name text
);
alter table public.client_notes enable row level security;
create policy "staff notes" on public.client_notes for all using (public.is_staff()) with check (public.is_staff());
create index if not exists client_notes_client on public.client_notes(client_id, created_at desc);
create index if not exists client_notes_follow on public.client_notes(follow_up_on) where done_at is null;

-- Brain: things Greg must watch, supplier issues, lessons
create table if not exists public.brain (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  kind text not null default 'Other',
  note text not null,
  supplier_id uuid references public.suppliers(id) on delete set null,
  job_id uuid references public.jobs(id) on delete set null,
  watch boolean not null default true,
  resolved_at timestamptz,
  by uuid references public.profiles(id),
  by_name text
);
alter table public.brain enable row level security;
create policy "staff brain" on public.brain for all using (public.is_staff()) with check (public.is_staff());
create policy "crew read brain" on public.brain for select using (public.my_role() is not null);
create index if not exists brain_open on public.brain(created_at desc) where resolved_at is null;
