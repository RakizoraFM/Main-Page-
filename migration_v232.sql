begin;
-- V232: incremental Excel source import; requires V231. Never writes field work.
create table if not exists public.fm_ticket_imports232 (
 id uuid primary key default gen_random_uuid(), region text not null,
 by_id uuid not null default auth.uid(), at timestamptz not null default now(), summary jsonb not null
);
alter table public.fm_ticket_imports232 enable row level security;
drop policy if exists p_import232 on public.fm_ticket_imports232;
create policy p_import232 on public.fm_ticket_imports232 for select to authenticated using(public.fm_can_upload(region));
revoke insert,update,delete on public.fm_ticket_imports232 from anon,authenticated;
create or replace function public.fm_tickets_import232(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r text; x jsonb; n int; added int:=0; updated int:=0; unchanged int:=0; retained int; old public.tickets; v public.tickets; conflicts jsonb; result jsonb;
begin
 if auth.uid() is null or not public.fm_plan_ok() or not public.fm_mod('tickets') or coalesce(public.fm_role(),'pending')='pending' then raise exception 'not allowed';end if;
 if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'array required';end if;
 n:=jsonb_array_length(p_rows);if n<1 or n>50000 then raise exception 'import requires 1..50000 rows';end if;
 r:=p_rows->0->>'region';
 if r not in ('riyadh','qassim') or r is null or not coalesce(public.fm_can_upload(r),false) then raise exception 'not allowed';end if;
 if exists(select 1 from jsonb_array_elements(p_rows) a where jsonb_typeof(a)<>'object' or a->>'region' is distinct from r or coalesce(btrim(a->>'ticket_id'),'')='' or jsonb_typeof(a->'raw') is distinct from 'object') then raise exception 'invalid ticket row';end if;
 if exists(select 1 from jsonb_array_elements(p_rows) a group by btrim(a->>'ticket_id') having count(*)>1) then raise exception 'duplicate ticket id';end if;
 perform pg_advisory_xact_lock(232,hashtext(r));
 select count(*) into retained from public.tickets t where t.region=r and not exists(select 1 from jsonb_array_elements(p_rows) a where btrim(a->>'ticket_id')=t.ticket_id);
 for x in select value from jsonb_array_elements(p_rows) loop
  v:=jsonb_populate_record(null::public.tickets,x);v.ticket_id:=btrim(v.ticket_id);
  select * into old from public.tickets t where t.region=r and t.ticket_id=v.ticket_id for update;
  if not found then added:=added+1;
  elsif (to_jsonb(old)-array['uploaded_at','uploaded_by'])=(to_jsonb(v)-array['uploaded_at','uploaded_by']) then unchanged:=unchanged+1;continue;
  else updated:=updated+1;end if;
  insert into public.tickets(region,ticket_id,school,building_id,supervisor,engineer,contractor,priority,sub_category,status,created_at,raw,uploaded_at,uploaded_by)
  values(r,v.ticket_id,v.school,v.building_id,v.supervisor,v.engineer,v.contractor,v.priority,v.sub_category,v.status,v.created_at,v.raw,now(),auth.uid())
  on conflict(region,ticket_id) do update set school=excluded.school,building_id=excluded.building_id,supervisor=excluded.supervisor,engineer=excluded.engineer,contractor=excluded.contractor,priority=excluded.priority,sub_category=excluded.sub_category,status=excluded.status,created_at=excluded.created_at,raw=excluded.raw,uploaded_at=excluded.uploaded_at,uploaded_by=excluded.uploaded_by;
 end loop;
 select coalesce(jsonb_agg(jsonb_build_object('ticket_id',t.ticket_id,'source',t.status,'stage',w.stage) order by t.ticket_id),'[]') into conflicts
 from public.tickets t join public.ticket_work w using(region,ticket_id)
 where t.region=r and exists(select 1 from jsonb_array_elements(p_rows) a where btrim(a->>'ticket_id')=t.ticket_id)
 and w.stage in ('assigned','inspected','progress','parts','reopened','resolved','closed','cancelled')
 and coalesce(t.status,'')<>case w.stage when 'assigned' then 'تم التعيين' when 'resolved' then 'تم حله' when 'closed' then 'مغلق' when 'cancelled' then 'ملغى' else 'قيد التنفيذ' end;
 result:=jsonb_build_object('received',n,'added',added,'updated',updated,'unchanged',unchanged,'retained',retained,'conflicts',conflicts,'max_created_at',(select max(created_at) from public.tickets where region=r),'at',now());
 insert into public.fm_ticket_imports232(region,summary) values(r,result);
 return result;
end $$;
revoke all on function public.fm_tickets_import232(jsonb) from public,anon;
grant execute on function public.fm_tickets_import232(jsonb) to authenticated;
-- Block old clients' destructive "delete tickets missing from this file" behavior.
-- Explicit administrative wipe is a separate permission-checked security-definer RPC.
drop policy if exists p_tickets_write on public.tickets;
drop policy if exists p_tickets_insert232 on public.tickets;
drop policy if exists p_tickets_update232 on public.tickets;
create policy p_tickets_insert232 on public.tickets for insert to authenticated with check(public.fm_can_upload(region));
create policy p_tickets_update232 on public.tickets for update to authenticated using(public.fm_can_upload(region)) with check(public.fm_can_upload(region));

-- Field stage is authoritative for escalation eligibility as well as field/desktop display.
create or replace function public.fm231_open(r text,t text) returns boolean language sql stable security definer set search_path=public as $$
 select case when exists(select 1 from public.ticket_work w where w.region=r and w.ticket_id=t and w.stage in('assigned','inspected','progress','parts','reopened','resolved','closed','cancelled'))
 then exists(select 1 from public.ticket_work w where w.region=r and w.ticket_id=t and w.resolved_at is null and w.stage in('assigned','inspected','progress','parts','reopened'))
 else not exists(select 1 from public.ticket_work w where w.region=r and w.ticket_id=t and w.resolved_at is not null)
 and not exists(select 1 from public.tickets k where k.region=r and k.ticket_id=t and lower(btrim(coalesce(k.status,''))) in('مغلق','تم حله','ملغى','خارج النطاق','closed','resolved','cancelled','canceled','out of scope')) end $$;

commit;
