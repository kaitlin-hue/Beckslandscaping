-- Activity log: who changed what and when, on every key table. Forms show as "Website form", the overnight run as "Automation".
create table if not exists public.activity_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  table_name text not null,
  row_id text,
  action text not null,
  changed jsonb,
  label text,
  job_id uuid,
  client_id uuid,
  by uuid,
  by_name text
);
alter table public.activity_log enable row level security;
create policy "staff read activity" on public.activity_log for select using (public.is_staff());
create index if not exists activity_at on public.activity_log(at desc);
create index if not exists activity_job on public.activity_log(job_id, at desc);
create index if not exists activity_client on public.activity_log(client_id, at desc);

create or replace function public.log_activity() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  o jsonb := case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) else null end;
  n jsonb := case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) else null end;
  r jsonb := coalesce(n, o);
  diff jsonb := '{}'::jsonb; k text; uid uuid := auth.uid(); who text;
  skip text[] := array['updated_at','created_at','id','transcript','plan_transcript','enquiry','quote_token','tasks'];
  lbl text;
begin
  if tg_op = 'UPDATE' then
    for k in select jsonb_object_keys(n) loop
      if k = any(skip) then continue; end if;
      if (o->k) is distinct from (n->k) then
        diff := diff || jsonb_build_object(k, jsonb_build_array(left(coalesce(o->>k,''),160), left(coalesce(n->>k,''),160)));
      end if;
    end loop;
    if diff = '{}'::jsonb then return new; end if;
  elsif tg_op = 'INSERT' then
    for k in select jsonb_object_keys(n) loop
      if k = any(skip) or n->k is null or n->>k = '' then continue; end if;
      diff := diff || jsonb_build_object(k, jsonb_build_array('', left(n->>k,160)));
    end loop;
  end if;
  if uid is not null then select name into who from public.profiles where id = uid; end if;
  who := coalesce(who, case when auth.role() = 'anon' then 'Website form' when auth.role() = 'service_role' then 'Automation' else 'System' end);
  lbl := coalesce(r->>'title', r->>'name', r->>'note', r->>'item', r->>'kind');
  insert into public.activity_log(table_name,row_id,action,changed,label,job_id,client_id,by,by_name)
  values (tg_table_name, r->>'id', lower(tg_op), diff, left(lbl,120),
    case when tg_table_name='jobs' then (r->>'id')::uuid else nullif(r->>'job_id','')::uuid end,
    case when tg_table_name='clients' then (r->>'id')::uuid else nullif(r->>'client_id','')::uuid end,
    uid, who);
  return coalesce(new, old);
end $$;

-- attach to each table (fresh triggers, nothing removed)
create trigger log_activity after insert or update or delete on public.jobs for each row execute function public.log_activity();
create trigger log_activity after insert or update or delete on public.clients for each row execute function public.log_activity();
create trigger log_activity after insert or update or delete on public.client_notes for each row execute function public.log_activity();
create trigger log_activity after insert or update or delete on public.crew_days for each row execute function public.log_activity();
create trigger log_activity after insert or update or delete on public.quote_lines for each row execute function public.log_activity();
create trigger log_activity after insert or update or delete on public.campaigns for each row execute function public.log_activity();
create trigger log_activity after insert or update or delete on public.brain for each row execute function public.log_activity();
create trigger log_activity after insert or update or delete on public.purchase_orders for each row execute function public.log_activity();
create trigger log_activity after insert or update or delete on public.issues for each row execute function public.log_activity();
create trigger log_activity after insert or update or delete on public.settings for each row execute function public.log_activity();
create trigger log_activity after insert or update or delete on public.job_plan_days for each row execute function public.log_activity();
