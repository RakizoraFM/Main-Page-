-- V192: shared team readiness, region-scoped permissions and optimistic concurrency.
begin;
create table if not exists public.fm_team_readiness (
 id uuid primary key default gen_random_uuid(), name text not null check(length(trim(name)) between 1 and 120),
 region text not null check(region in ('riyadh','qassim')), leader text not null default '',
 status text not null default 'ready' check(status in ('ready','limited','stopped')),
 reason text not null default '' check(reason in ('','vehicle','labor','materials','other')),
 owner_name text not null default '', due_at timestamptz, schools text[] not null default '{}',
 note text not null default '', blocked_since timestamptz, revision int not null default 1,
 updated_by uuid references public.profiles(id), updated_at timestamptz not null default now(),
 check(status='ready' or (reason<>'' and length(trim(owner_name))>0 and due_at is not null)),
 check(cardinality(schools)<=500),check(length(note)<=4000),check(length(leader)<=120),check(length(owner_name)<=120)
);
create table if not exists public.fm_team_readiness_events (
 id bigint generated always as identity primary key, team_id uuid not null references public.fm_team_readiness(id),
 at timestamptz not null default now(), by_user uuid references public.profiles(id), old_value jsonb, new_value jsonb not null
);
alter table public.fm_team_readiness enable row level security;
alter table public.fm_team_readiness_events enable row level security;
revoke all on public.fm_team_readiness, public.fm_team_readiness_events from anon, authenticated;
create or replace function public.fm_ready_read(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(public.fm_role()<>'pending' and (public.fm_role()='admin' or public.fm_my_pos() in ('dept_manager','project_manager','ops_manager','qa_manager','hse_manager','owner_rep') or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_region_ok(r))),false) $$;
create or replace function public.fm_ready_write(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(public.fm_role()<>'pending' and (public.fm_role()='admin' or public.fm_my_pos() in ('project_manager','ops_manager') or (public.fm_my_pos()='area_manager' and public.fm_region_ok(r))),false) $$;
create or replace function public.fm_ready_list() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('can_edit',public.fm_ready_write(t.region)) order by t.updated_at desc),'[]'::jsonb) from public.fm_team_readiness t where public.fm_ready_read(t.region) $$;
create or replace function public.fm_ready_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
 declare old public.fm_team_readiness; v public.fm_team_readiness; k uuid; rg text:=p->>'region';
 begin
 if not public.fm_ready_write(rg) then raise exception 'not allowed'; end if;
 if nullif(p->>'id','') is not null then
  select * into old from public.fm_team_readiness where id=(p->>'id')::uuid for update;
  if not found or not public.fm_ready_write(old.region) then raise exception 'not allowed'; end if;
  if old.revision<>coalesce((p->>'revision')::int,0) then raise exception 'version conflict: reload'; end if;
  k:=old.id;
 else k:=gen_random_uuid(); end if;
 insert into public.fm_team_readiness(id,name,region,leader,status,reason,owner_name,due_at,schools,note,blocked_since,revision,updated_by)
 values(k,trim(p->>'name'),rg,coalesce(p->>'leader',''),p->>'status',case when p->>'status'='ready' then '' else coalesce(p->>'reason','') end,
 coalesce(p->>'owner_name',''),nullif(p->>'due_at','')::timestamptz,
 array(select distinct trim(x) from jsonb_array_elements_text(coalesce(p->'schools','[]')) as codes(x) where trim(x)<>''),coalesce(p->>'note',''),
 case when p->>'status'='ready' then null else coalesce(old.blocked_since,now()) end,coalesce(old.revision,0)+1,auth.uid())
 on conflict(id) do update set name=excluded.name,region=excluded.region,leader=excluded.leader,status=excluded.status,reason=excluded.reason,owner_name=excluded.owner_name,due_at=excluded.due_at,schools=excluded.schools,note=excluded.note,blocked_since=excluded.blocked_since,revision=excluded.revision,updated_by=excluded.updated_by,updated_at=now() returning * into v;
 insert into public.fm_team_readiness_events(team_id,by_user,old_value,new_value) values(k,auth.uid(),case when old.id is null then null else to_jsonb(old) end,to_jsonb(v));
 return to_jsonb(v);
 end $$;
create or replace function public.fm_ready_history(p_id uuid) returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(e) order by e.at desc,e.id desc),'[]'::jsonb) from public.fm_team_readiness_events e join public.fm_team_readiness t on t.id=e.team_id where e.team_id=p_id and public.fm_ready_read(t.region) $$;
revoke all on function public.fm_ready_read(text),public.fm_ready_write(text),public.fm_ready_list(),public.fm_ready_save(jsonb),public.fm_ready_history(uuid) from public,anon;
grant execute on function public.fm_ready_read(text),public.fm_ready_write(text),public.fm_ready_list(),public.fm_ready_save(jsonb),public.fm_ready_history(uuid) to authenticated;
commit;
