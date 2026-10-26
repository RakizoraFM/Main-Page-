-- V195: source-linked operational escalation inbox. Depends on V192-V194.
begin;
create table if not exists public.fm_ops_escalations (
 id uuid primary key default gen_random_uuid(), kind text not null check(kind in ('ticket','wo','parts','bill','team')),
 source_key text not null, region text not null check(region in ('riyadh','qassim')),
 recipient uuid not null references public.profiles(id), due_at timestamptz not null,
 status text not null check(status in ('open','acknowledged','resolved')) default 'open',
 note text not null check(length(trim(note)) between 1 and 4000),
 revision int not null default 1, updated_by uuid references public.profiles(id), updated_at timestamptz not null default now(),
 unique(kind,source_key,region)
);
create table if not exists public.fm_ops_events (
 id bigint generated always as identity primary key, escalation_id uuid not null references public.fm_ops_escalations(id) on delete cascade,
 at timestamptz not null default now(), by_user uuid references public.profiles(id), old_value jsonb, new_value jsonb not null,
 push_queued boolean not null default false
);
alter table public.fm_ops_escalations enable row level security;
alter table public.fm_ops_events enable row level security;
revoke all on public.fm_ops_escalations,public.fm_ops_events from anon,authenticated;
create or replace function public.fm195_manager(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role()<>'pending' and (public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager') or (public.fm_my_pos()='area_manager' and public.fm_region_ok(r))),false) $$;
create or replace function public.fm195_source(k text,s text,r text,w boolean default false) returns boolean language plpgsql stable security definer set search_path=public as $$
begin
 if auth.uid() is null or public.fm_role()='pending' or r not in ('riyadh','qassim') or (w and not public.fm195_manager(r)) then return false;end if;
 if k='ticket' then return public.fm_close_can(r) and exists(select 1 from public.tickets t where t.ticket_id=s and t.region=r);
 elsif k='wo' then return public.fm_mod('wo') and exists(select 1 from public.work_orders x where x.id=public.fm_uuid_or_null(s) and x.region=r and public.fm_wo_can_see(x.id));
 elsif k='parts' then return coalesce(public.fm_parts_can(public.fm_uuid_or_null(s),w) and public.fm_parts_region(public.fm_uuid_or_null(s))=r,false);
 elsif k='bill' then return public.fm_bfollow_can(public.fm_uuid_or_null(s),w) and exists(select 1 from public.fm_bills b join public.fm_contracts c on c.id=b.contract_id where b.id=public.fm_uuid_or_null(s) and c.region=r);
 elsif k='team' then return (case when w then public.fm_ready_write(r) else public.fm_ready_read(r) end) and exists(select 1 from public.fm_team_readiness t where t.id=public.fm_uuid_or_null(s) and t.region=r);
 end if;return false;
end $$;
create or replace function public.fm195_people(r text,k text) returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if not public.fm195_manager(r) then raise exception 'not allowed';end if;
 return(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(p.full_name,p.email)) order by p.full_name),'[]'::jsonb) from public.profiles p where p.active and public.fm_posx(p.role,p.job_title) in ('sysadmin','project_manager','ops_manager','area_manager') and (public.fm_posx(p.role,p.job_title)<>'area_manager' or cardinality(p.regions)=0 or r=any(p.regions)));
end $$;
create or replace function public.fm195_inbox() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(e)||jsonb_build_object('recipient_name',p.full_name,'can_edit',public.fm195_source(e.kind,e.source_key,e.region,true)) order by e.updated_at desc),'[]'::jsonb) from public.fm_ops_escalations e join public.profiles p on p.id=e.recipient where public.fm195_source(e.kind,e.source_key,e.region,false) $$;
create or replace function public.fm195_escalate(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare k text:=p->>'kind';s text:=trim(p->>'source_key');r text:=p->>'region';u uuid:=(p->>'recipient')::uuid;
 old public.fm_ops_escalations;v public.fm_ops_escalations;queued boolean:=false;st text:=p->>'status';
begin
 if not public.fm195_source(k,s,r,true) then raise exception 'not allowed or source missing';end if;
 if not exists(select 1 from jsonb_array_elements(public.fm195_people(r,k)) x where (x->>'id')::uuid=u) then raise exception 'invalid recipient';end if;
 perform pg_advisory_xact_lock(hashtextextended('fm195:'||k||':'||s||':'||r,0));
 select * into old from public.fm_ops_escalations where kind=k and source_key=s and region=r for update;
 if (p->>'revision')::int is distinct from coalesce(old.revision,0) then raise exception 'version conflict: reload';end if;
 if old.id is null and st<>'open' then raise exception 'new escalation must be open';end if;
 insert into public.fm_ops_escalations(kind,source_key,region,recipient,due_at,status,note,revision,updated_by)
 values(k,s,r,u,(p->>'due_at')::timestamptz,st,trim(p->>'note'),coalesce(old.revision,0)+1,auth.uid())
 on conflict(kind,source_key,region) do update set recipient=excluded.recipient,due_at=excluded.due_at,status=excluded.status,note=excluded.note,revision=excluded.revision,updated_by=excluded.updated_by,updated_at=now() returning * into v;
 -- Each revision is saved once. Push is only attempted for a new/reopened/reassigned escalation.
 if st='open' and (old.id is null or old.status<>'open' or old.recipient<>u) then
  begin queued:=public.fm_push_add(u,'ops_due','تصعيد تشغيلي يحتاج متابعة','المرجع: '||s||' — افتح مركز التنبيهات للمراجعة.','ops195','ops195-'||v.id::text||'-'||v.revision::text);exception when others then queued:=false;end;
 end if;
 insert into public.fm_ops_events(escalation_id,by_user,old_value,new_value,push_queued) values(v.id,auth.uid(),case when old.id is null then null else to_jsonb(old) end,to_jsonb(v),queued);
 return to_jsonb(v)||jsonb_build_object('push_queued',queued);
end $$;
create or replace function public.fm195_ack(k uuid,p_revision int,p_note text) returns jsonb language plpgsql security definer set search_path=public as $$
declare old public.fm_ops_escalations;v public.fm_ops_escalations;
begin
 select * into old from public.fm_ops_escalations where id=k for update;
 if old.id is null or old.recipient<>auth.uid() or not public.fm195_source(old.kind,old.source_key,old.region,false) then raise exception 'not allowed';end if;
 if p_revision is distinct from old.revision then raise exception 'version conflict: reload';end if;
 if old.status<>'open' then raise exception 'escalation is not open';end if;
 if length(trim(coalesce(p_note,''))) not between 1 and 4000 then raise exception 'note required';end if;
 update public.fm_ops_escalations set status='acknowledged',note=trim(p_note),revision=revision+1,updated_by=auth.uid(),updated_at=now() where id=k returning * into v;
 insert into public.fm_ops_events(escalation_id,by_user,old_value,new_value) values(k,auth.uid(),to_jsonb(old),to_jsonb(v));return to_jsonb(v);
end $$;
create or replace function public.fm195_history(k uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare e public.fm_ops_escalations;begin select * into e from public.fm_ops_escalations where id=k;
 if e.id is null or not public.fm195_source(e.kind,e.source_key,e.region,false) then raise exception 'not allowed';end if;
 return(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('by_name',pr.full_name) order by x.at desc,x.id desc),'[]'::jsonb) from public.fm_ops_events x left join public.profiles pr on pr.id=x.by_user where x.escalation_id=k);end $$;
-- Complete JSON arrays avoid silently truncating a paginated PostgREST table read.
create or replace function public.fm195_orders() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(w) order by w.created_at desc,w.id),'[]'::jsonb) from public.work_orders w where public.fm_role()<>'pending' and public.fm_mod('wo') and public.fm_wo_can_see(w.id) $$;
create or replace function public.fm195_schedules() returns jsonb language sql stable security invoker set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(s) order by s.next_run_at,s.id),'[]'::jsonb) from public.wo_schedules s where public.fm_role()<>'pending' and public.fm_mod('wo') $$;
revoke all on function public.fm195_manager(text),public.fm195_source(text,text,text,boolean),public.fm195_people(text,text),public.fm195_inbox(),public.fm195_escalate(jsonb),public.fm195_ack(uuid,int,text),public.fm195_history(uuid),public.fm195_orders(),public.fm195_schedules() from public,anon;
grant execute on function public.fm195_manager(text),public.fm195_people(text,text),public.fm195_inbox(),public.fm195_escalate(jsonb),public.fm195_ack(uuid,int,text),public.fm195_history(uuid),public.fm195_orders(),public.fm195_schedules() to authenticated;
notify pgrst,'reload schema';
commit;
