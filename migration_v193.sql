-- V193: follow up existing issue requests, without changing stock or SLA.
-- Prerequisites: current supabase_setup.sql through V192 (or migration_v192.sql).
begin;
create table if not exists public.fm_parts_followup (
 request_id uuid primary key references public.wo_issue_requests(id) on delete cascade,
 owner_id uuid not null references public.profiles(id), due_at timestamptz not null,
 stage text not null check(stage in ('stock','purchase','ordered','available','hold')),
 supplier text not null default '' check(length(supplier)<=200), team_id uuid references public.fm_team_readiness(id) on delete set null,
 note text not null check(length(trim(note)) between 1 and 4000),
 revision int not null default 1, updated_by uuid references public.profiles(id), updated_at timestamptz not null default now(),
 escalated_to uuid references public.profiles(id), escalated_by uuid references public.profiles(id), escalated_at timestamptz
);
create table if not exists public.fm_parts_events (
 id bigint generated always as identity primary key, request_id uuid not null references public.wo_issue_requests(id) on delete cascade,
 at timestamptz not null default now(), by_user uuid references public.profiles(id), kind text not null check(kind in ('followup','escalation')),
 old_value jsonb, new_value jsonb not null
);
create index if not exists fm_parts_events_request_at on public.fm_parts_events(request_id,at desc);
alter table public.fm_parts_followup enable row level security;
alter table public.fm_parts_events enable row level security;
revoke all on public.fm_parts_followup,public.fm_parts_events from anon,authenticated;
create or replace function public.fm_parts_region(k uuid) returns text language sql stable security definer set search_path=public as $$
 select coalesce(nullif(w.region,''),nullif(s.region,''),case when cardinality(p.regions)=1 then p.regions[1] end,'')
 from public.wo_issue_requests r left join public.work_orders w on w.id=r.wo_id left join public.wo_stores s on s.id=r.store_id left join public.profiles p on p.id=r.holder where r.id=k $$;
create or replace function public.fm_parts_can(k uuid, write_access boolean default false) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role()<>'pending' and public.fm_mod('wh') and exists(select 1 from public.wo_issue_requests r where r.id=k and (
 public.fm_role()='admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager')
 or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_parts_region(k)<>'' and public.fm_region_ok(public.fm_parts_region(k)))
 or (public.fm_my_pos()='storekeeper' and public.fm_wh_keeper(r.store_id))
 or (not write_access and (r.requested_by=auth.uid() or r.holder=auth.uid() or public.fm_my_pos() in ('dept_manager','qa_manager','owner_rep')))
 )),false) $$;
create or replace function public.fm_parts_person(k uuid,p_user uuid,escalation boolean default false) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.profiles p where p.id=p_user and p.active and public.fm_posx(p.role,p.job_title)=any(case when escalation then array['sysadmin','project_manager','ops_manager','area_manager'] else array['sysadmin','project_manager','ops_manager','area_manager','area_engineer','storekeeper'] end)
 and (public.fm_posx(p.role,p.job_title) in ('sysadmin','project_manager','ops_manager') or cardinality(p.regions)=0 or public.fm_parts_region(k)=any(p.regions))) $$;
create or replace function public.fm_parts_list() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('region',public.fm_parts_region(r.id),'can_edit',public.fm_parts_can(r.id,true),'followup',case when f.request_id is null then null else to_jsonb(f)||jsonb_build_object('owner_name',o.full_name,'team_name',t.name,'escalated_name',ep.full_name) end,
 'items',coalesce((select jsonb_agg(l||jsonb_build_object('name',m.name,'unit',m.unit)) from jsonb_array_elements(r.lines) as lines(l) left join public.wo_materials m on m.id=nullif(l->>'material_id','')::uuid),'[]'::jsonb)) order by r.at desc),'[]'::jsonb)
 from public.wo_issue_requests r left join public.fm_parts_followup f on f.request_id=r.id left join public.profiles o on o.id=f.owner_id left join public.fm_team_readiness t on t.id=f.team_id left join public.profiles ep on ep.id=f.escalated_to where public.fm_parts_can(r.id,false) $$;
create or replace function public.fm_parts_options(k uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
 begin
 if not public.fm_parts_can(k,true) then raise exception 'not allowed';end if;
 return jsonb_build_object('people',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(p.full_name,p.email),'can_escalate',public.fm_parts_person(k,p.id,true)) order by p.full_name),'[]'::jsonb) from public.profiles p where public.fm_parts_person(k,p.id,false)),
 'teams',(select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'name',t.name) order by t.name),'[]'::jsonb) from public.fm_team_readiness t where t.region=public.fm_parts_region(k) and public.fm_ready_read(t.region)));
 end $$;
create or replace function public.fm_parts_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
 declare k uuid:=(p->>'request_id')::uuid; r public.wo_issue_requests; old public.fm_parts_followup; v public.fm_parts_followup; own uuid:=(p->>'owner_id')::uuid; team uuid:=nullif(p->>'team_id','')::uuid;
 begin
 -- Lock the source request as well, so first-time follow-up creation cannot race.
 select * into r from public.wo_issue_requests where id=k for update;
 if not found or not public.fm_parts_can(k,true) then raise exception 'not allowed'; end if;
 if r.status not in ('requested','partial','issued') then raise exception 'request finished';end if;
 if not public.fm_parts_person(k,own,false) then raise exception 'invalid owner';end if;
 if team is not null and not exists(select 1 from public.fm_team_readiness t where t.id=team and t.region=public.fm_parts_region(k) and public.fm_ready_read(t.region)) then raise exception 'invalid team';end if;
 select * into old from public.fm_parts_followup where request_id=k for update;
 if coalesce(old.revision,0)<>coalesce((p->>'revision')::int,0) then raise exception 'version conflict: reload';end if;
 insert into public.fm_parts_followup(request_id,owner_id,due_at,stage,supplier,team_id,note,revision,updated_by)
 values(k,own,(p->>'due_at')::timestamptz,p->>'stage',coalesce(p->>'supplier',''),team,trim(p->>'note'),coalesce(old.revision,0)+1,auth.uid())
 on conflict(request_id) do update set owner_id=excluded.owner_id,due_at=excluded.due_at,stage=excluded.stage,supplier=excluded.supplier,team_id=excluded.team_id,note=excluded.note,revision=excluded.revision,updated_by=excluded.updated_by,updated_at=now() returning * into v;
 insert into public.fm_parts_events(request_id,by_user,kind,old_value,new_value) values(k,auth.uid(),'followup',case when old.request_id is null then null else to_jsonb(old) end,to_jsonb(v));return to_jsonb(v);
 end $$;
create or replace function public.fm_parts_escalate(k uuid,p_to uuid,p_note text,p_revision int) returns jsonb language plpgsql security definer set search_path=public as $$
 declare r public.wo_issue_requests; old public.fm_parts_followup; v public.fm_parts_followup;
 begin
 select * into r from public.wo_issue_requests where id=k for update;
 if not found or not public.fm_parts_can(k,true) then raise exception 'not allowed';end if;
 if r.status not in ('requested','partial','issued') then raise exception 'request finished';end if;
 if not public.fm_parts_person(k,p_to,true) or length(trim(coalesce(p_note,''))) not between 1 and 4000 then raise exception 'invalid escalation';end if;
 select * into old from public.fm_parts_followup where request_id=k for update;
 if not found then raise exception 'save followup first';end if;
 if old.revision is distinct from p_revision then raise exception 'version conflict: reload';end if;
 update public.fm_parts_followup set escalated_to=p_to,escalated_by=auth.uid(),escalated_at=now(),note=trim(p_note),revision=revision+1,updated_by=auth.uid(),updated_at=now() where request_id=k returning * into v;
 insert into public.fm_parts_events(request_id,by_user,kind,old_value,new_value) values(k,auth.uid(),'escalation',to_jsonb(old),to_jsonb(v));return to_jsonb(v);
 end $$;
create or replace function public.fm_parts_history(k uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
 begin if not public.fm_parts_can(k,false) then raise exception 'not allowed';end if;
 return (select coalesce(jsonb_agg(to_jsonb(e) order by e.at desc,e.id desc),'[]'::jsonb) from public.fm_parts_events e where e.request_id=k);end $$;
revoke all on function public.fm_parts_region(uuid),public.fm_parts_can(uuid,boolean),public.fm_parts_person(uuid,uuid,boolean),public.fm_parts_list(),public.fm_parts_options(uuid),public.fm_parts_save(jsonb),public.fm_parts_escalate(uuid,uuid,text,int),public.fm_parts_history(uuid) from public,anon;
grant execute on function public.fm_parts_can(uuid,boolean),public.fm_parts_list(),public.fm_parts_options(uuid),public.fm_parts_save(jsonb),public.fm_parts_escalate(uuid,uuid,text,int),public.fm_parts_history(uuid) to authenticated;
notify pgrst, 'reload schema';
commit;
