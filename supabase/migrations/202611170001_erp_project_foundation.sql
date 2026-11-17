-- ERP001: additive project registry. Apply to a TEST tenant after supabase_setup.sql.
-- This registry does not replace existing work-order authorization or auto-assign old data.
begin;
create table if not exists public.fm_erp_projects (
 id uuid primary key default gen_random_uuid(),
 code text not null unique check(code ~ '^[A-Z0-9][A-Z0-9_-]{1,39}$'),
 name text not null check(length(btrim(name)) between 1 and 200),
 region text not null check(length(btrim(region)) between 1 and 100),
 active boolean not null default true,
 created_by uuid not null references public.profiles(id),
 created_at timestamptz not null default now()
);
create table if not exists public.fm_erp_project_members (
 project_id uuid not null references public.fm_erp_projects(id),
 user_id uuid not null references public.profiles(id),
 primary key(project_id,user_id)
);
create index if not exists fm_erp_members_user on public.fm_erp_project_members(user_id,project_id);
create table if not exists public.fm_erp_work_order_projects (
 wo_id uuid primary key references public.work_orders(id) on delete cascade,
 project_id uuid not null references public.fm_erp_projects(id),
 revision integer not null default 1 check(revision>0),
 updated_by uuid not null references public.profiles(id),
 updated_at timestamptz not null default now()
);
create index if not exists fm_erp_wo_project on public.fm_erp_work_order_projects(project_id);
create table if not exists public.fm_erp_project_events (
 id bigint generated always as identity primary key,
 project_id uuid not null references public.fm_erp_projects(id),
 actor uuid not null references public.profiles(id),
 action text not null,
 entity_id uuid not null,
 reason text not null,
 old_value jsonb,
 new_value jsonb,
 at timestamptz not null default now()
);
create index if not exists fm_erp_events_project on public.fm_erp_project_events(project_id,id);

create or replace function public.fm_erp_admin() returns boolean
language sql stable security definer set search_path=public as $$
 select auth.uid() is not null and exists(select 1 from public.profiles
 where id=auth.uid() and active and deleted_at is null and role='admin')
$$;
create or replace function public.fm_erp_project_can_read(p_project uuid) returns boolean
language sql stable security definer set search_path=public as $$
 select auth.uid() is not null and exists(select 1 from public.profiles
 where id=auth.uid() and active and deleted_at is null and role<>'pending')
 and (public.fm_erp_admin() or exists(select 1 from public.fm_erp_project_members
 where project_id=p_project and user_id=auth.uid()))
$$;
alter table public.fm_erp_projects enable row level security;
alter table public.fm_erp_project_members enable row level security;
alter table public.fm_erp_work_order_projects enable row level security;
alter table public.fm_erp_project_events enable row level security;
revoke all on public.fm_erp_projects,public.fm_erp_project_members,
 public.fm_erp_work_order_projects,public.fm_erp_project_events from public,anon,authenticated;
grant select on public.fm_erp_projects,public.fm_erp_project_members,
 public.fm_erp_work_order_projects,public.fm_erp_project_events to authenticated;
drop policy if exists fm_erp_projects_read on public.fm_erp_projects;
create policy fm_erp_projects_read on public.fm_erp_projects for select to authenticated
 using(public.fm_erp_project_can_read(id));
drop policy if exists fm_erp_members_read on public.fm_erp_project_members;
create policy fm_erp_members_read on public.fm_erp_project_members for select to authenticated
 using(public.fm_erp_admin() or (user_id=auth.uid() and public.fm_erp_project_can_read(project_id)));
drop policy if exists fm_erp_links_read on public.fm_erp_work_order_projects;
create policy fm_erp_links_read on public.fm_erp_work_order_projects for select to authenticated
 using(public.fm_erp_project_can_read(project_id) and public.fm_wo_can_see(wo_id));
drop policy if exists fm_erp_events_read on public.fm_erp_project_events;
create policy fm_erp_events_read on public.fm_erp_project_events for select to authenticated
 using(public.fm_erp_admin());

create or replace function public.fm_erp_project_create(p_code text,p_name text,p_region text)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
 if not public.fm_erp_admin() then raise exception 'not allowed' using errcode='42501'; end if;
 insert into public.fm_erp_projects(code,name,region,created_by)
 values(upper(btrim(p_code)),btrim(p_name),btrim(p_region),auth.uid()) returning id into v_id;
 insert into public.fm_erp_project_events(project_id,actor,action,entity_id,reason,new_value)
 values(v_id,auth.uid(),'project_created',v_id,'create',jsonb_build_object('code',upper(btrim(p_code)),'name',btrim(p_name),'region',btrim(p_region)));
 return v_id;
end $$;
create or replace function public.fm_erp_project_member_set(p_project uuid,p_user uuid,p_enabled boolean,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare existed boolean;
begin
 if not public.fm_erp_admin() then raise exception 'not allowed' using errcode='42501'; end if;
 if p_enabled is null or coalesce(length(btrim(p_reason)),0) not between 3 and 1000 then raise exception 'valid decision and reason required'; end if;
 perform 1 from public.fm_erp_projects where id=p_project for update;
 if not found then raise exception 'project not found'; end if;
 if p_enabled and not exists(select 1 from public.profiles where id=p_user and active and deleted_at is null and role<>'pending') then raise exception 'active user required'; end if;
 select exists(select 1 from public.fm_erp_project_members where project_id=p_project and user_id=p_user) into existed;
 if existed=p_enabled then return; end if;
 if p_enabled then insert into public.fm_erp_project_members values(p_project,p_user);
 else delete from public.fm_erp_project_members where project_id=p_project and user_id=p_user; end if;
 insert into public.fm_erp_project_events(project_id,actor,action,entity_id,reason,old_value,new_value)
 values(p_project,auth.uid(),'membership',p_user,btrim(p_reason),jsonb_build_object('member',existed),jsonb_build_object('member',p_enabled));
end $$;
create or replace function public.fm_erp_work_order_project_set(p_wo uuid,p_project uuid,p_expected_revision integer,p_reason text)
returns integer language plpgsql security definer set search_path=public as $$
declare w public.work_orders; pr public.fm_erp_projects; prev public.fm_erp_work_order_projects; next_revision integer;
begin
 if not public.fm_erp_admin() then raise exception 'not allowed' using errcode='42501'; end if;
 if coalesce(length(btrim(p_reason)),0) not between 3 and 1000 then raise exception 'reason required'; end if;
 -- Serializes initial assignment as well as corrections; protects against stale writes.
 select * into w from public.work_orders where id=p_wo for update;
 if not found then raise exception 'work order not found'; end if;
 select * into pr from public.fm_erp_projects where id=p_project for share;
 if not found or not pr.active then raise exception 'active project required'; end if;
 if w.region is distinct from pr.region then raise exception 'project region mismatch'; end if;
 select * into prev from public.fm_erp_work_order_projects where wo_id=p_wo;
 if p_expected_revision is null or p_expected_revision<>coalesce(prev.revision,0) then raise exception 'stale project assignment'; end if;
 if prev.project_id=p_project then return prev.revision; end if;
 next_revision:=coalesce(prev.revision,0)+1;
 insert into public.fm_erp_work_order_projects(wo_id,project_id,revision,updated_by)
 values(p_wo,p_project,next_revision,auth.uid()) on conflict(wo_id) do update
 set project_id=excluded.project_id,revision=excluded.revision,updated_by=excluded.updated_by,updated_at=now();
 insert into public.fm_erp_project_events(project_id,actor,action,entity_id,reason,old_value,new_value)
 values(p_project,auth.uid(),'work_order_project',p_wo,btrim(p_reason),
 case when prev.wo_id is not null then to_jsonb(prev) else null end,
 jsonb_build_object('project_id',p_project,'revision',next_revision));
 return next_revision;
end $$;
-- Keep a later regional edit from silently invalidating an existing assignment.
create or replace function public.fm_erp_work_order_region_guard() returns trigger
language plpgsql security definer set search_path=public as $$
begin
 if exists(select 1 from public.fm_erp_work_order_projects l
 join public.fm_erp_projects p on p.id=l.project_id
 where l.wo_id=new.id and p.region is distinct from new.region) then
  raise exception 'linked project region mismatch';
 end if;
 return new;
end $$;
drop trigger if exists fm_erp_region_guard on public.work_orders;
create trigger fm_erp_region_guard before update of region on public.work_orders
 for each row execute function public.fm_erp_work_order_region_guard();
revoke all on function public.fm_erp_work_order_region_guard() from public,anon,authenticated;
revoke all on function public.fm_erp_admin(),public.fm_erp_project_can_read(uuid),
 public.fm_erp_project_create(text,text,text),public.fm_erp_project_member_set(uuid,uuid,boolean,text),
 public.fm_erp_work_order_project_set(uuid,uuid,integer,text) from public,anon;
grant execute on function public.fm_erp_admin(),public.fm_erp_project_can_read(uuid),
 public.fm_erp_project_create(text,text,text),public.fm_erp_project_member_set(uuid,uuid,boolean,text),
 public.fm_erp_work_order_project_set(uuid,uuid,integer,text) to authenticated;
notify pgrst,'reload schema';
commit;
