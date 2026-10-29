begin;
-- V233: explicitly recorded workforce deployment groups. Never infer labour from login accounts.
create or replace function public.fm233_manage(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role()<>'pending' and
 (public.fm_role()='admin' or public.fm_my_pos() in('dept_manager','project_manager','ops_manager') or (public.fm_my_pos()='area_manager' and public.fm_region_ok(r))),false) $$;
create or replace function public.fm233_read(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role()<>'pending' and (public.fm_scope_region(r) or public.fm_role()='admin'),false) $$;
create table if not exists public.fm_workforce233(
 id uuid primary key default gen_random_uuid(),region text not null check(region in('riyadh','qassim')),
 contractor text not null check(length(btrim(contractor)) between 1 and 160),
 trade text not null check(length(btrim(trade)) between 1 and 160),
 supervisor text not null default '' check(length(supervisor)<=160),headcount int not null check(headcount between 0 and 100000),
 active boolean not null default true,note text not null default '',revision int not null default 1,
 updated_at timestamptz not null default now(),updated_by uuid default auth.uid()
);
create unique index if not exists fm_workforce233_group on public.fm_workforce233(region,lower(btrim(contractor)),lower(btrim(trade)),lower(btrim(supervisor))) where active;
create table if not exists public.fm_workforce_events233(id uuid primary key default gen_random_uuid(),group_id uuid not null,at timestamptz not null default now(),by_id uuid not null default auth.uid(),region text not null,old_value jsonb,new_value jsonb);
alter table public.fm_workforce233 enable row level security;
alter table public.fm_workforce_events233 enable row level security;
drop policy if exists p_workforce233 on public.fm_workforce233;
create policy p_workforce233 on public.fm_workforce233 for select to authenticated using(public.fm233_read(region));
drop policy if exists p_workforce_events233 on public.fm_workforce_events233;
create policy p_workforce_events233 on public.fm_workforce_events233 for select to authenticated using(public.fm233_read(region));
revoke insert,update,delete on public.fm_workforce233,public.fm_workforce_events233 from anon,authenticated;
create or replace function public.fm_workforce233_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.fm_workforce233;old public.fm_workforce233;k uuid:=nullif(p->>'id','')::uuid;r text:=p->>'region';
begin
 if not public.fm233_manage(r) then raise exception 'not allowed';end if;
 if btrim(coalesce(p->>'note',''))='' or length(p->>'note')>2000 then raise exception 'note required';end if;
 if coalesce(p->>'headcount','')!~'^\d{1,6}$' then raise exception 'invalid headcount';end if;
 if k is not null then
  select * into old from public.fm_workforce233 where id=k for update;
  if not found or not public.fm233_manage(old.region) then raise exception 'not allowed';end if;
  if old.revision is distinct from (p->>'revision')::int then raise exception 'stale revision';end if;
 end if;
 insert into public.fm_workforce233(id,region,contractor,trade,supervisor,headcount,active,note,revision,updated_at,updated_by)
 values(coalesce(k,gen_random_uuid()),r,btrim(p->>'contractor'),btrim(p->>'trade'),btrim(coalesce(p->>'supervisor','')),(p->>'headcount')::int,coalesce((p->>'active')::boolean,true),btrim(p->>'note'),coalesce(old.revision,0)+1,now(),auth.uid())
 on conflict(id) do update set region=excluded.region,contractor=excluded.contractor,trade=excluded.trade,supervisor=excluded.supervisor,headcount=excluded.headcount,active=excluded.active,note=excluded.note,revision=excluded.revision,updated_at=excluded.updated_at,updated_by=excluded.updated_by returning * into v;
 insert into public.fm_workforce_events233(group_id,region,old_value,new_value) values(v.id,r,case when old.id is not null then to_jsonb(old) end,to_jsonb(v));
 return to_jsonb(v);
end $$;
revoke all on function public.fm233_manage(text),public.fm233_read(text),public.fm_workforce233_save(jsonb) from public,anon;
grant execute on function public.fm233_manage(text),public.fm233_read(text),public.fm_workforce233_save(jsonb) to authenticated;
commit;
