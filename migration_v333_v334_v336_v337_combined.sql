-- RakizoraFM combined database migrations: V333, V334, V336, V337
-- Apply in this order to a database with the required prior baseline.
-- V333 requires V332; V334 requires V333; V337 requires V336.
-- Original per-file transaction markers have been consolidated into one transaction.
-- IMPORTANT: Do not run if any included migration has already been applied.
-- This merged copy is for convenience; retain the source migrations for audit.
BEGIN;

-- -----------------------------------------------------------------------------
-- V333 — workforce planning
-- Source file: Rakizora_migration_v333_workforce.sql
-- -----------------------------------------------------------------------------
-- RakizoraFM V333 workforce planning fields.
-- Run once on an existing V332 company database before deploying the updated index.html.
-- Existing headcount values are preserved and classified as maintenance groups by default.

alter table public.fm_workforce233 add column if not exists category text not null default 'maintenance';
alter table public.fm_workforce233 add column if not exists planned_headcount int;

alter table public.fm_workforce233 drop constraint if exists fm_workforce233_category_check;
alter table public.fm_workforce233 add constraint fm_workforce233_category_check
 check(category in('maintenance','light_services','administrative','support'));
alter table public.fm_workforce233 drop constraint if exists fm_workforce233_planned_headcount_check;
alter table public.fm_workforce233 add constraint fm_workforce233_planned_headcount_check
 check(planned_headcount is null or planned_headcount between 0 and 100000);

drop index if exists public.fm_workforce233_group;
create unique index fm_workforce233_group
 on public.fm_workforce233(region,category,lower(btrim(contractor)),lower(btrim(trade)),lower(btrim(supervisor)))
 where active;

create or replace function public.fm_workforce233_save(p jsonb) returns jsonb
 language plpgsql security definer set search_path=public as $$
declare
 v public.fm_workforce233;
 old public.fm_workforce233;
 k uuid:=nullif(p->>'id','')::uuid;
 r text:=p->>'region';
 c text:=coalesce(nullif(p->>'category',''),'maintenance');
 planned int:=nullif(p->>'planned_headcount','')::int;
begin
 if not public.fm233_manage(r) then raise exception 'not allowed';end if;
 if btrim(coalesce(p->>'note',''))='' or length(p->>'note')>2000 then raise exception 'note required';end if;
 if c not in('maintenance','light_services','administrative','support') then raise exception 'invalid workforce category';end if;
 if coalesce(p->>'headcount','')!~'^\d{1,6}$' then raise exception 'invalid headcount';end if;
 if planned is not null and (planned<0 or planned>100000) then raise exception 'invalid planned headcount';end if;
 if k is not null then
  select * into old from public.fm_workforce233 where id=k for update;
  if not found or not public.fm233_manage(old.region) then raise exception 'not allowed';end if;
  if old.revision is distinct from (p->>'revision')::int then raise exception 'stale revision';end if;
 end if;
 insert into public.fm_workforce233(id,region,category,contractor,trade,supervisor,planned_headcount,headcount,active,note,revision,updated_at,updated_by)
 values(coalesce(k,gen_random_uuid()),r,c,btrim(p->>'contractor'),btrim(p->>'trade'),btrim(coalesce(p->>'supervisor','')),planned,(p->>'headcount')::int,coalesce((p->>'active')::boolean,true),btrim(p->>'note'),coalesce(old.revision,0)+1,now(),auth.uid())
 on conflict(id) do update set region=excluded.region,category=excluded.category,contractor=excluded.contractor,trade=excluded.trade,supervisor=excluded.supervisor,planned_headcount=excluded.planned_headcount,headcount=excluded.headcount,active=excluded.active,note=excluded.note,revision=excluded.revision,updated_at=excluded.updated_at,updated_by=excluded.updated_by returning * into v;
 insert into public.fm_workforce_events233(group_id,region,old_value,new_value)
 values(v.id,r,case when old.id is not null then to_jsonb(old) end,to_jsonb(v));
 return to_jsonb(v);
end $$;

revoke all on function public.fm_workforce233_save(jsonb) from public,anon;
grant execute on function public.fm_workforce233_save(jsonb) to authenticated;

-- -----------------------------------------------------------------------------
-- V334 — people, teams, and building coverage
-- Source file: Rakizora_migration_v334_workforce.sql
-- -----------------------------------------------------------------------------
-- V334: individual workforce, teams, and building coverage.
-- Run once on a database that already has V333 installed.

create table if not exists public.fm_teams334(
 id uuid primary key default gen_random_uuid(), region text not null check(region in('riyadh','qassim')),
 name text not null check(length(btrim(name)) between 1 and 160), category text not null check(category in('maintenance','light_services','administrative','support')),
 supervisor text not null default '' check(length(supervisor)<=160), planned_headcount int check(planned_headcount is null or planned_headcount between 0 and 100000),
 active boolean not null default true, note text not null default '' check(length(note)<=2000), revision int not null default 1,
 updated_at timestamptz not null default now(), updated_by uuid default auth.uid());
create unique index if not exists fm_teams334_active_name on public.fm_teams334(region,lower(btrim(name))) where active;

create table if not exists public.fm_people334(
 id uuid primary key default gen_random_uuid(), region text not null check(region in('riyadh','qassim')),
 employee_code text not null default '' check(length(employee_code)<=80), full_name text not null check(length(btrim(full_name)) between 1 and 160),
 employer text not null check(length(btrim(employer)) between 1 and 160), job_title text not null check(length(btrim(job_title)) between 1 and 160),
 phone text not null default '' check(length(phone)<=40), team_id uuid references public.fm_teams334(id), direct_manager text not null default '' check(length(direct_manager)<=160),
 active boolean not null default true, note text not null default '' check(length(note)<=2000), revision int not null default 1,
 updated_at timestamptz not null default now(), updated_by uuid default auth.uid());
create unique index if not exists fm_people334_code on public.fm_people334(region,lower(btrim(employer)),lower(btrim(employee_code))) where employee_code<>'' and active;

create table if not exists public.fm_coverage334(
 id uuid primary key default gen_random_uuid(), region text not null check(region in('riyadh','qassim')),
 team_id uuid not null references public.fm_teams334(id), building_code text not null check(length(btrim(building_code)) between 1 and 100),
 building_name text not null check(length(btrim(building_name)) between 1 and 200), education_office text not null default '' check(length(education_office)<=160),
 service text not null check(service in('maintenance','light_services','administrative','support')), active boolean not null default true,
 note text not null default '' check(length(note)<=2000), revision int not null default 1,
 updated_at timestamptz not null default now(), updated_by uuid default auth.uid());
create unique index if not exists fm_coverage334_active_assignment on public.fm_coverage334(region,team_id,lower(btrim(building_code)),service) where active;

create table if not exists public.fm_workforce_events334(
 id uuid primary key default gen_random_uuid(), entity_type text not null, entity_id uuid not null,
 region text not null, old_value jsonb, new_value jsonb, at timestamptz not null default now(), by_id uuid not null default auth.uid());

alter table public.fm_teams334 enable row level security;
alter table public.fm_people334 enable row level security;
alter table public.fm_coverage334 enable row level security;
alter table public.fm_workforce_events334 enable row level security;
drop policy if exists p_fm_teams334_read on public.fm_teams334;
create policy p_fm_teams334_read on public.fm_teams334 for select to authenticated using(public.fm233_read(region));
drop policy if exists p_fm_people334_read on public.fm_people334;
create policy p_fm_people334_read on public.fm_people334 for select to authenticated using(public.fm233_read(region));
drop policy if exists p_fm_coverage334_read on public.fm_coverage334;
create policy p_fm_coverage334_read on public.fm_coverage334 for select to authenticated using(public.fm233_read(region));
drop policy if exists p_fm_workforce_events334_read on public.fm_workforce_events334;
create policy p_fm_workforce_events334_read on public.fm_workforce_events334 for select to authenticated using(public.fm233_read(region));
revoke insert,update,delete on public.fm_teams334,public.fm_people334,public.fm_coverage334,public.fm_workforce_events334 from anon,authenticated;

create or replace function public.fm_workforce334_data(r text) returns jsonb
 language plpgsql security definer set search_path=public as $$
begin
 if not public.fm233_read(r) then raise exception 'not allowed'; end if;
 return jsonb_build_object(
  'teams',coalesce((select jsonb_agg(to_jsonb(t) order by t.name) from public.fm_teams334 t where t.region=r),'[]'::jsonb),
  'people',coalesce((select jsonb_agg(to_jsonb(p) order by p.full_name) from public.fm_people334 p where p.region=r),'[]'::jsonb),
  'coverage',coalesce((select jsonb_agg(to_jsonb(c) order by c.building_name) from public.fm_coverage334 c where c.region=r),'[]'::jsonb));
end $$;

create or replace function public.fm_workforce334_save(p jsonb) returns jsonb
 language plpgsql security definer set search_path=public as $$
declare k text:=p->>'kind'; r text:=p->>'region'; idv uuid:=nullif(p->>'id','')::uuid;
 oldv jsonb; newv jsonb; rev int; tid uuid;
begin
 if not public.fm233_manage(r) then raise exception 'not allowed'; end if;
 if k='team' then
  if btrim(coalesce(p->>'name',''))='' or p->>'category' not in('maintenance','light_services','administrative','support') then raise exception 'بيانات الفريق غير مكتملة'; end if;
  if idv is not null then select to_jsonb(t),t.revision into oldv,rev from public.fm_teams334 t where t.id=idv and t.region=r for update; if oldv is null then raise exception 'not allowed'; end if; if rev is distinct from (p->>'revision')::int then raise exception 'تغير السجل؛ حدّث الصفحة ثم أعد المحاولة'; end if; end if;
  insert into public.fm_teams334(id,region,name,category,supervisor,planned_headcount,active,note,revision,updated_at,updated_by)
  values(coalesce(idv,gen_random_uuid()),r,btrim(p->>'name'),p->>'category',btrim(coalesce(p->>'supervisor','')),nullif(p->>'planned_headcount','')::int,coalesce((p->>'active')::boolean,true),btrim(coalesce(p->>'note','')),coalesce(rev,0)+1,now(),auth.uid())
  on conflict(id) do update set name=excluded.name,category=excluded.category,supervisor=excluded.supervisor,planned_headcount=excluded.planned_headcount,active=excluded.active,note=excluded.note,revision=excluded.revision,updated_at=excluded.updated_at,updated_by=excluded.updated_by returning to_jsonb(fm_teams334.*) into newv;
 elsif k='person' then
  tid:=nullif(p->>'team_id','')::uuid;
  if tid is not null and not exists(select 1 from public.fm_teams334 t where t.id=tid and t.region=r and t.active) then raise exception 'اختر فريقاً نشطاً من المنطقة نفسها'; end if;
  if btrim(coalesce(p->>'full_name',''))='' or btrim(coalesce(p->>'employer',''))='' or btrim(coalesce(p->>'job_title',''))='' then raise exception 'الاسم وجهة العمل والمسمى الوظيفي مطلوبة'; end if;
  oldv:=null;rev:=null;if idv is not null then select to_jsonb(x),x.revision into oldv,rev from public.fm_people334 x where x.id=idv and x.region=r for update; if oldv is null then raise exception 'not allowed'; end if; if rev is distinct from (p->>'revision')::int then raise exception 'تغير السجل؛ حدّث الصفحة ثم أعد المحاولة'; end if; end if;
  insert into public.fm_people334(id,region,employee_code,full_name,employer,job_title,phone,team_id,direct_manager,active,note,revision,updated_at,updated_by)
  values(coalesce(idv,gen_random_uuid()),r,btrim(coalesce(p->>'employee_code','')),btrim(p->>'full_name'),btrim(p->>'employer'),btrim(p->>'job_title'),btrim(coalesce(p->>'phone','')),tid,btrim(coalesce(p->>'direct_manager','')),coalesce((p->>'active')::boolean,true),btrim(coalesce(p->>'note','')),coalesce(rev,0)+1,now(),auth.uid())
  on conflict(id) do update set employee_code=excluded.employee_code,full_name=excluded.full_name,employer=excluded.employer,job_title=excluded.job_title,phone=excluded.phone,team_id=excluded.team_id,direct_manager=excluded.direct_manager,active=excluded.active,note=excluded.note,revision=excluded.revision,updated_at=excluded.updated_at,updated_by=excluded.updated_by returning to_jsonb(fm_people334.*) into newv;
 elsif k='coverage' then
  tid:=nullif(p->>'team_id','')::uuid;
  if not exists(select 1 from public.fm_teams334 t where t.id=tid and t.region=r and t.active) then raise exception 'اختر فريقاً نشطاً من المنطقة نفسها'; end if;
  if btrim(coalesce(p->>'building_code',''))='' or btrim(coalesce(p->>'building_name',''))='' or p->>'service' not in('maintenance','light_services','administrative','support') then raise exception 'بيانات تغطية المبنى غير مكتملة'; end if;
  oldv:=null;rev:=null;if idv is not null then select to_jsonb(x),x.revision into oldv,rev from public.fm_coverage334 x where x.id=idv and x.region=r for update; if oldv is null then raise exception 'not allowed'; end if; if rev is distinct from (p->>'revision')::int then raise exception 'تغير السجل؛ حدّث الصفحة ثم أعد المحاولة'; end if; end if;
  insert into public.fm_coverage334(id,region,team_id,building_code,building_name,education_office,service,active,note,revision,updated_at,updated_by)
  values(coalesce(idv,gen_random_uuid()),r,tid,btrim(p->>'building_code'),btrim(p->>'building_name'),btrim(coalesce(p->>'education_office','')),p->>'service',coalesce((p->>'active')::boolean,true),btrim(coalesce(p->>'note','')),coalesce(rev,0)+1,now(),auth.uid())
  on conflict(id) do update set team_id=excluded.team_id,building_code=excluded.building_code,building_name=excluded.building_name,education_office=excluded.education_office,service=excluded.service,active=excluded.active,note=excluded.note,revision=excluded.revision,updated_at=excluded.updated_at,updated_by=excluded.updated_by returning to_jsonb(fm_coverage334.*) into newv;
 else raise exception 'نوع سجل غير معروف'; end if;
 insert into public.fm_workforce_events334(entity_type,entity_id,region,old_value,new_value) values(k,coalesce(idv,(newv->>'id')::uuid),r,oldv,newv);
 return newv;
end $$;
revoke all on function public.fm_workforce334_data(text),public.fm_workforce334_save(jsonb) from public,anon;
grant execute on function public.fm_workforce334_data(text),public.fm_workforce334_save(jsonb) to authenticated;
notify pgrst,'reload schema';

-- -----------------------------------------------------------------------------
-- V336 — building history and workforce classification
-- Source file: Rakizora_migration_v336_building_history.sql
-- -----------------------------------------------------------------------------
-- V336: permanent building change history with approval-gated invoice adjustments.
-- Financial adjustment amounts are signed and entered before VAT.
create table if not exists public.fm_building_history336 (
  id uuid primary key default gen_random_uuid(),
  region text not null check (region in ('riyadh','qassim')),
  building_key text not null,
  building_name text not null default '',
  invoice_month text check (invoice_month is null or invoice_month ~ '^\d{4}-\d{2}$'),
  event_date date not null,
  event_type text not null default 'general',
  description text not null,
  old_values jsonb not null default '{}',
  new_values jsonb not null default '{}',
  financial_impact text not null default 'none' check (financial_impact in ('none','base','adjustment')),
  adjustment_amount numeric(14,2),
  scope text check (scope is null or scope in ('clean','maint','ac')),
  contractor text,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_by uuid,
  created_by_name text,
  created_at timestamptz not null default now(),
  reviewed_by uuid,
  reviewed_by_name text,
  reviewed_at timestamptz,
  review_note text
);
create index if not exists fm_building_history336_lookup
  on public.fm_building_history336(region, building_key, event_date desc);
create index if not exists fm_building_history336_invoice
  on public.fm_building_history336(region, invoice_month, status)
  where financial_impact in ('base','adjustment');
alter table public.fm_building_history336 enable row level security;
revoke all on public.fm_building_history336 from anon, authenticated;

create or replace function public.fm_building_history336_get(p_region text, p_building_key text default null, p_month text default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not (public.fm_bill_can('read',p_region) or public.fm_bill_can('prep',p_region) or public.fm_bill_can('contract',p_region)) then raise exception 'not allowed'; end if;
  return coalesce((select jsonb_agg(to_jsonb(h) order by h.event_date desc,h.created_at desc)
    from public.fm_building_history336 h where h.region=p_region
      and (p_building_key is null or h.building_key=p_building_key)
      and (p_month is null or h.invoice_month=p_month or h.invoice_month is null)), '[]'::jsonb);
end $$;

create or replace function public.fm_building_history336_add(p_event jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r text; k text; mn text; d date; typ text; impact text; amt numeric; sid uuid;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  r:=p_event->>'region'; k:=left(trim(coalesce(p_event->>'building_key','')),220);
  mn:=nullif(p_event->>'invoice_month',''); d:=nullif(p_event->>'event_date','')::date;
  typ:=left(trim(coalesce(p_event->>'event_type','general')),40);
  impact:=coalesce(p_event->>'financial_impact','none');
  if r is null or r not in ('riyadh','qassim') or k='' or d is null or length(trim(coalesce(p_event->>'description','')))<3 then raise exception 'invalid event'; end if;
  if mn is not null and mn !~ '^\d{4}-\d{2}$' then raise exception 'invalid month'; end if;
  if not (public.fm_bill_can('read',r) or public.fm_bill_can('prep',r) or public.fm_bill_can('contract',r)) then raise exception 'not allowed'; end if;
  if impact not in ('none','base','adjustment') then raise exception 'invalid impact'; end if;
  if impact='base' and mn is null then raise exception 'invalid month'; end if;
  if impact in ('base','adjustment') and to_char(d,'YYYY-MM')<>mn then raise exception 'invalid month'; end if;
  if impact='adjustment' then
    if not public.fm_bill_can('prep',r) or mn is null then raise exception 'not allowed'; end if;
    amt:=nullif(p_event->>'adjustment_amount','')::numeric;
    if amt is null or abs(amt)>10000000 or coalesce(p_event->>'scope','') not in ('clean','maint','ac') or length(trim(coalesce(p_event->>'contractor','')))=0 then raise exception 'invalid adjustment'; end if;
  end if;
  insert into public.fm_building_history336(region,building_key,building_name,invoice_month,event_date,event_type,description,old_values,new_values,financial_impact,adjustment_amount,scope,contractor,created_by,created_by_name)
  values(r,k,left(coalesce(p_event->>'building_name',''),300),mn,d,typ,left(trim(p_event->>'description'),2000),coalesce(p_event->'old_values','{}'),coalesce(p_event->'new_values','{}'),impact,amt,nullif(p_event->>'scope',''),nullif(left(trim(coalesce(p_event->>'contractor','')),240),''),auth.uid(),public.fm_me_name()) returning id into sid;
  return jsonb_build_object('ok',true,'id',sid,'status','pending');
end $$;

create or replace function public.fm_building_history336_review(p_id uuid,p_decision text,p_note text default '')
returns jsonb language plpgsql security definer set search_path = public as $$
declare h public.fm_building_history336;
begin
  if auth.uid() is null or p_decision not in ('approved','rejected') then raise exception 'not allowed'; end if;
  select * into h from public.fm_building_history336 where id=p_id for update;
  if h.id is null or not public.fm_bill_can('prep',h.region) then raise exception 'not allowed'; end if;
  if h.status <> 'pending' then raise exception 'invalid status'; end if;
  if p_decision='approved' and h.invoice_month is not null and public.fm_rate_snap_locked(h.region,h.invoice_month) then raise exception 'snapshot locked'; end if;
  update public.fm_building_history336 set status=p_decision,reviewed_by=auth.uid(),reviewed_by_name=public.fm_me_name(),reviewed_at=now(),review_note=left(coalesce(p_note,''),1000) where id=p_id;
  return jsonb_build_object('ok',true,'status',p_decision);
end $$;

revoke all on function public.fm_building_history336_get(text,text,text), public.fm_building_history336_add(jsonb), public.fm_building_history336_review(uuid,text,text) from public, anon;
grant execute on function public.fm_building_history336_get(text,text,text), public.fm_building_history336_add(jsonb), public.fm_building_history336_review(uuid,text,text) to authenticated;
notify pgrst, 'reload schema';

-- V336 workforce classification: separate company staff from subcontractor personnel.
alter table public.fm_people334 add column if not exists person_type text not null default 'staff'
  check (person_type in ('staff','contractor'));

create or replace function public.fm_workforce334_save(p jsonb) returns jsonb
 language plpgsql security definer set search_path=public as $$
declare k text:=p->>'kind'; r text:=p->>'region'; idv uuid:=nullif(p->>'id','')::uuid;
 oldv jsonb; newv jsonb; rev int; tid uuid; ptype text;
begin
 if not public.fm233_manage(r) then raise exception 'not allowed'; end if;
 if k='team' then
  if btrim(coalesce(p->>'name',''))='' or p->>'category' not in('maintenance','light_services','administrative','support') then raise exception 'بيانات الفريق غير مكتملة'; end if;
  if idv is not null then select to_jsonb(t),t.revision into oldv,rev from public.fm_teams334 t where t.id=idv and t.region=r for update; if oldv is null then raise exception 'not allowed'; end if; if rev is distinct from (p->>'revision')::int then raise exception 'تغير السجل؛ حدّث الصفحة ثم أعد المحاولة'; end if; end if;
  insert into public.fm_teams334(id,region,name,category,supervisor,planned_headcount,active,note,revision,updated_at,updated_by)
  values(coalesce(idv,gen_random_uuid()),r,btrim(p->>'name'),p->>'category',btrim(coalesce(p->>'supervisor','')),nullif(p->>'planned_headcount','')::int,coalesce((p->>'active')::boolean,true),btrim(coalesce(p->>'note','')),coalesce(rev,0)+1,now(),auth.uid())
  on conflict(id) do update set name=excluded.name,category=excluded.category,supervisor=excluded.supervisor,planned_headcount=excluded.planned_headcount,active=excluded.active,note=excluded.note,revision=excluded.revision,updated_at=excluded.updated_at,updated_by=excluded.updated_by returning to_jsonb(fm_teams334.*) into newv;
 elsif k='person' then
  tid:=nullif(p->>'team_id','')::uuid; ptype:=coalesce(nullif(p->>'person_type',''),'staff');
  if ptype not in ('staff','contractor') then raise exception 'تصنيف الفرد غير صحيح'; end if;
  if tid is not null and not exists(select 1 from public.fm_teams334 t where t.id=tid and t.region=r and t.active) then raise exception 'اختر فريقاً نشطاً من المنطقة نفسها'; end if;
  if btrim(coalesce(p->>'full_name',''))='' or btrim(coalesce(p->>'employer',''))='' or btrim(coalesce(p->>'job_title',''))='' then raise exception 'الاسم وجهة العمل والمسمى الوظيفي مطلوبة'; end if;
  oldv:=null;rev:=null;if idv is not null then select to_jsonb(x),x.revision into oldv,rev from public.fm_people334 x where x.id=idv and x.region=r for update; if oldv is null then raise exception 'not allowed'; end if; if rev is distinct from (p->>'revision')::int then raise exception 'تغير السجل؛ حدّث الصفحة ثم أعد المحاولة'; end if; end if;
  insert into public.fm_people334(id,region,employee_code,full_name,employer,job_title,phone,team_id,direct_manager,active,note,revision,updated_at,updated_by,person_type)
  values(coalesce(idv,gen_random_uuid()),r,btrim(coalesce(p->>'employee_code','')),btrim(p->>'full_name'),btrim(p->>'employer'),btrim(p->>'job_title'),btrim(coalesce(p->>'phone','')),tid,btrim(coalesce(p->>'direct_manager','')),coalesce((p->>'active')::boolean,true),btrim(coalesce(p->>'note','')),coalesce(rev,0)+1,now(),auth.uid(),ptype)
  on conflict(id) do update set employee_code=excluded.employee_code,full_name=excluded.full_name,employer=excluded.employer,job_title=excluded.job_title,phone=excluded.phone,team_id=excluded.team_id,direct_manager=excluded.direct_manager,active=excluded.active,note=excluded.note,person_type=excluded.person_type,revision=excluded.revision,updated_at=excluded.updated_at,updated_by=excluded.updated_by returning to_jsonb(fm_people334.*) into newv;
 elsif k='coverage' then
  tid:=nullif(p->>'team_id','')::uuid;
  if not exists(select 1 from public.fm_teams334 t where t.id=tid and t.region=r and t.active) then raise exception 'اختر فريقاً نشطاً من المنطقة نفسها'; end if;
  if btrim(coalesce(p->>'building_code',''))='' or btrim(coalesce(p->>'building_name',''))='' or p->>'service' not in('maintenance','light_services','administrative','support') then raise exception 'بيانات تغطية المبنى غير مكتملة'; end if;
  oldv:=null;rev:=null;if idv is not null then select to_jsonb(x),x.revision into oldv,rev from public.fm_coverage334 x where x.id=idv and x.region=r for update; if oldv is null then raise exception 'not allowed'; end if; if rev is distinct from (p->>'revision')::int then raise exception 'تغير السجل؛ حدّث الصفحة ثم أعد المحاولة'; end if; end if;
  insert into public.fm_coverage334(id,region,team_id,building_code,building_name,education_office,service,active,note,revision,updated_at,updated_by)
  values(coalesce(idv,gen_random_uuid()),r,tid,btrim(p->>'building_code'),btrim(p->>'building_name'),btrim(coalesce(p->>'education_office','')),p->>'service',coalesce((p->>'active')::boolean,true),btrim(coalesce(p->>'note','')),coalesce(rev,0)+1,now(),auth.uid())
  on conflict(id) do update set team_id=excluded.team_id,building_code=excluded.building_code,building_name=excluded.building_name,education_office=excluded.education_office,service=excluded.service,active=excluded.active,note=excluded.note,revision=excluded.revision,updated_at=excluded.updated_at,updated_by=excluded.updated_by returning to_jsonb(fm_coverage334.*) into newv;
 else raise exception 'نوع سجل غير معروف'; end if;
 insert into public.fm_workforce_events334(entity_type,entity_id,region,old_value,new_value) values(k,coalesce(idv,(newv->>'id')::uuid),r,oldv,newv);
 return newv;
end $$;
revoke all on function public.fm_workforce334_save(jsonb) from public,anon;
grant execute on function public.fm_workforce334_save(jsonb) to authenticated;
notify pgrst, 'reload schema';

-- -----------------------------------------------------------------------------
-- V337 — workforce lifecycle and Excel import
-- Source file: Rakizora_V337_Workforce_Migration.sql
-- -----------------------------------------------------------------------------
-- RakizoraFM V337 workforce lifecycle management.
-- Apply after V336 on an existing company database. For a fresh install,
-- apply supabase_setup.sql first, then this migration.

alter table public.fm_people334
  add column if not exists department text not null default '' check(length(department)<=160),
  add column if not exists specialty text not null default '' check(length(specialty)<=160),
  add column if not exists employment_type text not null default 'other'
    check(employment_type in ('permanent','fixed_term','daily','outsourced','other')),
  add column if not exists start_date date,
  add column if not exists contract_end_date date,
  add column if not exists exit_date date;

create table if not exists public.fm_workforce337_plans (
  id uuid primary key default gen_random_uuid(),
  region text not null check(region in ('riyadh','qassim')),
  plan_month text not null check(plan_month ~ '^\d{4}-\d{2}$'),
  category text not null check(category in ('maintenance','light_services','administrative','support')),
  job_title text not null check(length(btrim(job_title)) between 1 and 160),
  employer text not null default '' check(length(employer)<=160),
  required_count int not null default 0 check(required_count between 0 and 100000),
  approved_count int not null default 0 check(approved_count between 0 and 100000),
  active boolean not null default true,
  note text not null default '' check(length(note)<=1000),
  revision int not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
create unique index if not exists fm_workforce337_plan_unique
  on public.fm_workforce337_plans(region,plan_month,category,lower(btrim(job_title)),lower(btrim(employer)))
  where active;

create table if not exists public.fm_workforce337_leaves (
  id uuid primary key default gen_random_uuid(),
  region text not null check(region in ('riyadh','qassim')),
  person_id uuid not null references public.fm_people334(id),
  leave_type text not null default 'annual' check(leave_type in ('annual','personal','sick','other')),
  starts_on date not null,
  ends_on date not null,
  substitute_person_id uuid references public.fm_people334(id),
  status text not null default 'pending' check(status in ('pending','approved','rejected','cancelled')),
  note text not null default '' check(length(note)<=1000),
  revision int not null default 1,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid(),
  reviewed_at timestamptz,
  reviewed_by uuid,
  review_note text not null default '' check(length(review_note)<=1000),
  check(ends_on>=starts_on)
);
create index if not exists fm_workforce337_leaves_lookup
  on public.fm_workforce337_leaves(region,starts_on,ends_on,status);

create table if not exists public.fm_workforce337_qualifications (
  id uuid primary key default gen_random_uuid(),
  region text not null check(region in ('riyadh','qassim')),
  person_id uuid not null references public.fm_people334(id),
  kind text not null check(kind in ('training','license','certificate')),
  title text not null check(length(btrim(title)) between 1 and 200),
  issuer text not null default '' check(length(issuer)<=160),
  completed_on date,
  expires_on date,
  note text not null default '' check(length(note)<=1000),
  revision int not null default 1,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);
create index if not exists fm_workforce337_qualifications_expiry
  on public.fm_workforce337_qualifications(region,expires_on);

create table if not exists public.fm_workforce337_events (
  id uuid primary key default gen_random_uuid(),
  region text not null check(region in ('riyadh','qassim')),
  person_id uuid references public.fm_people334(id),
  event_type text not null check(event_type in ('profile_update','transfer','exit','reactivate','plan_update','leave_review','qualification_update')),
  effective_date date not null default current_date,
  reason text not null check(length(btrim(reason)) between 3 and 1000),
  old_value jsonb not null default '{}'::jsonb,
  new_value jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid()
);
create index if not exists fm_workforce337_events_person
  on public.fm_workforce337_events(region,person_id,effective_date desc,created_at desc);

alter table public.fm_workforce337_plans enable row level security;
alter table public.fm_workforce337_leaves enable row level security;
alter table public.fm_workforce337_qualifications enable row level security;
alter table public.fm_workforce337_events enable row level security;

drop policy if exists p_fm_workforce337_plans_read on public.fm_workforce337_plans;
create policy p_fm_workforce337_plans_read on public.fm_workforce337_plans
  for select to authenticated using(public.fm233_read(region));
drop policy if exists p_fm_workforce337_leaves_read on public.fm_workforce337_leaves;
create policy p_fm_workforce337_leaves_read on public.fm_workforce337_leaves
  for select to authenticated using(public.fm233_read(region));
drop policy if exists p_fm_workforce337_qualifications_read on public.fm_workforce337_qualifications;
create policy p_fm_workforce337_qualifications_read on public.fm_workforce337_qualifications
  for select to authenticated using(public.fm233_read(region));
drop policy if exists p_fm_workforce337_events_read on public.fm_workforce337_events;
create policy p_fm_workforce337_events_read on public.fm_workforce337_events
  for select to authenticated using(public.fm233_read(region));
revoke all on public.fm_workforce337_plans,public.fm_workforce337_leaves,public.fm_workforce337_qualifications,public.fm_workforce337_events from public,anon,authenticated;

create or replace function public.fm_workforce337_data(r text) returns jsonb
language plpgsql stable security definer set search_path=public as $$
begin
 if auth.uid() is null or not public.fm233_read(r) then raise exception 'not allowed'; end if;
 return jsonb_build_object(
  'plans',coalesce((select jsonb_agg(to_jsonb(x) order by x.plan_month desc,x.category,x.job_title) from public.fm_workforce337_plans x where x.region=r),'[]'::jsonb),
  'leaves',coalesce((select jsonb_agg(to_jsonb(x)||jsonb_build_object('person_name',p.full_name,'substitute_name',s.full_name) order by x.starts_on desc)
    from public.fm_workforce337_leaves x join public.fm_people334 p on p.id=x.person_id
    left join public.fm_people334 s on s.id=x.substitute_person_id where x.region=r),'[]'::jsonb),
  'qualifications',coalesce((select jsonb_agg(to_jsonb(x)||jsonb_build_object('person_name',p.full_name,'person_active',p.active) order by x.expires_on nulls last,p.full_name)
    from public.fm_workforce337_qualifications x join public.fm_people334 p on p.id=x.person_id where x.region=r),'[]'::jsonb),
  'events',coalesce((select jsonb_agg(to_jsonb(x)||jsonb_build_object('person_name',p.full_name) order by x.effective_date desc,x.created_at desc)
    from public.fm_workforce337_events x left join public.fm_people334 p on p.id=x.person_id where x.region=r),'[]'::jsonb));
end $$;

create or replace function public.fm_workforce337_person_save(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r text:=p->>'region'; idv uuid:=nullif(p->>'id','')::uuid; beforev jsonb; afterv jsonb; basev jsonb; why text;
begin
 if auth.uid() is null or not public.fm233_manage(r) then raise exception 'not allowed'; end if;
 if idv is not null then select to_jsonb(x) into beforev from public.fm_people334 x where x.id=idv and x.region=r for update; if beforev is null then raise exception 'not allowed'; end if; end if;
 basev:=public.fm_workforce334_save(p);
 idv:=(basev->>'id')::uuid;
 update public.fm_people334 set department=left(btrim(coalesce(p->>'department','')),160),
  specialty=left(btrim(coalesce(p->>'specialty','')),160),
  employment_type=coalesce(nullif(p->>'employment_type',''),'other'),
  start_date=nullif(p->>'start_date','')::date,
  contract_end_date=nullif(p->>'contract_end_date','')::date,
  exit_date=case when coalesce((p->>'active')::boolean,true) then null else nullif(p->>'exit_date','')::date end
  where id=idv and region=r returning to_jsonb(fm_people334.*) into afterv;
 if beforev is distinct from afterv then
  why:=left(btrim(coalesce(p->>'change_reason','')),1000);
  if length(why)<3 then why:='تحديث بيانات الفرد'; end if;
  insert into public.fm_workforce337_events(region,person_id,event_type,effective_date,reason,old_value,new_value)
  values(r,idv,'profile_update',coalesce(nullif(p->>'effective_date','')::date,current_date),why,coalesce(beforev,'{}'::jsonb),afterv);
 end if;
 return afterv;
end $$;

create or replace function public.fm_workforce337_plan_save(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r text:=p->>'region'; idv uuid:=nullif(p->>'id','')::uuid; oldv jsonb; outv public.fm_workforce337_plans; rev int;
begin
 if auth.uid() is null or not public.fm233_manage(r) then raise exception 'not allowed'; end if;
 if coalesce(p->>'plan_month','') !~ '^\d{4}-\d{2}$' or p->>'category' not in('maintenance','light_services','administrative','support')
  or length(btrim(coalesce(p->>'job_title','')))=0 then raise exception 'بيانات خطة الاحتياج غير مكتملة'; end if;
 if idv is not null then select to_jsonb(x),x.revision into oldv,rev from public.fm_workforce337_plans x where x.id=idv and x.region=r for update; if oldv is null then raise exception 'not allowed'; end if; if rev is distinct from (p->>'revision')::int then raise exception 'تغير السجل؛ حدّث الصفحة'; end if; end if;
 insert into public.fm_workforce337_plans(id,region,plan_month,category,job_title,employer,required_count,approved_count,active,note,revision,updated_at,updated_by)
 values(coalesce(idv,gen_random_uuid()),r,p->>'plan_month',p->>'category',left(btrim(p->>'job_title'),160),left(btrim(coalesce(p->>'employer','')),160),
  (p->>'required_count')::int,(p->>'approved_count')::int,coalesce((p->>'active')::boolean,true),left(btrim(coalesce(p->>'note','')),1000),coalesce(rev,0)+1,now(),auth.uid())
 on conflict(id) do update set plan_month=excluded.plan_month,category=excluded.category,job_title=excluded.job_title,employer=excluded.employer,required_count=excluded.required_count,approved_count=excluded.approved_count,active=excluded.active,note=excluded.note,revision=excluded.revision,updated_at=now(),updated_by=auth.uid()
 returning * into outv;
 insert into public.fm_workforce337_events(region,event_type,effective_date,reason,old_value,new_value)
 values(r,'plan_update',to_date(p->>'plan_month'||'-01','YYYY-MM-DD'),left(btrim(coalesce(p->>'reason','تحديث خطة القوى العاملة')),1000),coalesce(oldv,'{}'::jsonb),to_jsonb(outv));
 return to_jsonb(outv);
end $$;

create or replace function public.fm_workforce337_leave_save(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r text:=p->>'region'; pid uuid:=nullif(p->>'person_id','')::uuid; sid uuid:=nullif(p->>'substitute_person_id','')::uuid;
 d1 date:=nullif(p->>'starts_on','')::date; d2 date:=nullif(p->>'ends_on','')::date; typ text:=coalesce(nullif(p->>'leave_type',''),'annual'); outv public.fm_workforce337_leaves;
begin
 if auth.uid() is null or not public.fm233_manage(r) then raise exception 'not allowed'; end if;
 if pid is null or d1 is null or d2 is null or d2<d1 or typ not in('annual','personal','sick','other') then raise exception 'بيانات الإجازة غير صحيحة'; end if;
 perform 1 from public.fm_people334 x where x.id=pid and x.region=r and x.active for update; if not found then raise exception 'الفرد غير نشط أو خارج المنطقة'; end if;
 if sid is not null and (sid=pid or not exists(select 1 from public.fm_people334 x where x.id=sid and x.region=r and x.active)) then raise exception 'اختر بديلاً نشطاً من المنطقة نفسها'; end if;
 if exists(select 1 from public.fm_workforce337_leaves x where x.person_id=pid and x.status in('pending','approved') and daterange(x.starts_on,x.ends_on,'[]') && daterange(d1,d2,'[]')) then raise exception 'يوجد طلب إجازة متداخل للفرد'; end if;
 insert into public.fm_workforce337_leaves(region,person_id,leave_type,starts_on,ends_on,substitute_person_id,note)
 values(r,pid,typ,d1,d2,sid,left(btrim(coalesce(p->>'note','')),1000)) returning * into outv;
 return to_jsonb(outv);
end $$;

create or replace function public.fm_workforce337_leave_review(p_id uuid,p_decision text,p_substitute uuid default null,p_note text default '')
returns jsonb language plpgsql security definer set search_path=public as $$
declare x public.fm_workforce337_leaves;
begin
 if auth.uid() is null or p_decision not in('approved','rejected','cancelled') then raise exception 'not allowed'; end if;
 select * into x from public.fm_workforce337_leaves where id=p_id for update;
 if x.id is null or not public.fm233_manage(x.region) or x.status<>'pending' then raise exception 'not allowed'; end if;
 if p_decision='approved' and p_substitute is not null and (p_substitute=x.person_id or not exists(select 1 from public.fm_people334 p where p.id=p_substitute and p.region=x.region and p.active) or exists(select 1 from public.fm_workforce337_leaves l where l.person_id=p_substitute and l.status in('pending','approved') and daterange(l.starts_on,l.ends_on,'[]') && daterange(x.starts_on,x.ends_on,'[]'))) then raise exception 'البديل غير صالح أو لديه إجازة متداخلة'; end if;
 update public.fm_workforce337_leaves set status=p_decision,substitute_person_id=coalesce(p_substitute,substitute_person_id),reviewed_at=now(),reviewed_by=auth.uid(),review_note=left(coalesce(p_note,''),1000),revision=revision+1 where id=p_id returning * into x;
 insert into public.fm_workforce337_events(region,person_id,event_type,effective_date,reason,old_value,new_value)
 values(x.region,x.person_id,'leave_review',x.starts_on,'مراجعة طلب الإجازة: '||p_decision,to_jsonb(x),jsonb_build_object('leave_id',x.id,'status',x.status,'substitute_person_id',x.substitute_person_id));
 return to_jsonb(x);
end $$;

create or replace function public.fm_workforce337_qualification_save(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r text:=p->>'region'; idv uuid:=nullif(p->>'id','')::uuid; pid uuid:=nullif(p->>'person_id','')::uuid; oldv jsonb; rev int; outv public.fm_workforce337_qualifications;
begin
 if auth.uid() is null or not public.fm233_manage(r) then raise exception 'not allowed'; end if;
 if not exists(select 1 from public.fm_people334 x where x.id=pid and x.region=r) then raise exception 'الفرد غير موجود في المنطقة'; end if;
 if p->>'kind' not in('training','license','certificate') or length(btrim(coalesce(p->>'title','')))<2 then raise exception 'نوع أو اسم المؤهل غير صحيح'; end if;
 if idv is not null then select to_jsonb(x),x.revision into oldv,rev from public.fm_workforce337_qualifications x where x.id=idv and x.region=r for update; if oldv is null then raise exception 'not allowed'; end if; if rev is distinct from (p->>'revision')::int then raise exception 'تغير السجل؛ حدّث الصفحة'; end if; end if;
 insert into public.fm_workforce337_qualifications(id,region,person_id,kind,title,issuer,completed_on,expires_on,note,revision,updated_at,updated_by)
 values(coalesce(idv,gen_random_uuid()),r,pid,p->>'kind',left(btrim(p->>'title'),200),left(btrim(coalesce(p->>'issuer','')),160),nullif(p->>'completed_on','')::date,nullif(p->>'expires_on','')::date,left(btrim(coalesce(p->>'note','')),1000),coalesce(rev,0)+1,now(),auth.uid())
 on conflict(id) do update set person_id=excluded.person_id,kind=excluded.kind,title=excluded.title,issuer=excluded.issuer,completed_on=excluded.completed_on,expires_on=excluded.expires_on,note=excluded.note,revision=excluded.revision,updated_at=now(),updated_by=auth.uid()
 returning * into outv;
 insert into public.fm_workforce337_events(region,person_id,event_type,reason,old_value,new_value)
 values(r,pid,'qualification_update','إضافة أو تحديث مؤهل وظيفي',coalesce(oldv,'{}'::jsonb),to_jsonb(outv));
 return to_jsonb(outv);
end $$;

create or replace function public.fm_workforce337_move(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare pid uuid:=nullif(p->>'person_id','')::uuid; oldv jsonb; oldr text; newr text:=coalesce(nullif(p->>'new_region',''),p->>'region'); act text:=p->>'action'; team uuid:=nullif(p->>'team_id','')::uuid; why text:=btrim(coalesce(p->>'reason','')); eff date:=coalesce(nullif(p->>'effective_date','')::date,current_date); outv jsonb;
begin
 select to_jsonb(x),x.region into oldv,oldr from public.fm_people334 x where x.id=pid for update;
 if oldv is null or auth.uid() is null or not public.fm233_manage(oldr) or (act='transfer' and not public.fm233_manage(newr)) then raise exception 'not allowed'; end if;
 if act not in('transfer','exit','reactivate') or length(why)<3 then raise exception 'حدد الحركة وسببها'; end if;
 if act='transfer' and team is not null and not exists(select 1 from public.fm_teams334 t where t.id=team and t.region=newr and t.active) then raise exception 'الفريق لا يتبع المنطقة الجديدة'; end if;
 if act='transfer' then update public.fm_people334 set region=newr,team_id=team,active=true,exit_date=null,revision=revision+1,updated_at=now(),updated_by=auth.uid() where id=pid returning to_jsonb(fm_people334.*) into outv;
 elsif act='exit' then update public.fm_people334 set active=false,exit_date=eff,revision=revision+1,updated_at=now(),updated_by=auth.uid() where id=pid returning to_jsonb(fm_people334.*) into outv;
 else update public.fm_people334 set active=true,exit_date=null,revision=revision+1,updated_at=now(),updated_by=auth.uid() where id=pid returning to_jsonb(fm_people334.*) into outv;
 end if;
 insert into public.fm_workforce337_events(region,person_id,event_type,effective_date,reason,old_value,new_value)
 values(oldr,pid,case act when 'transfer' then 'transfer' when 'exit' then 'exit' else 'reactivate' end,eff,why,oldv,outv);
 if act='transfer' and newr<>oldr then insert into public.fm_workforce337_events(region,person_id,event_type,effective_date,reason,old_value,new_value) values(newr,pid,'transfer',eff,why,oldv,outv); end if;
 return outv;
end $$;

create or replace function public.fm_workforce337_import_people(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare rowv jsonb; saved jsonb; pid uuid; person_rev int; role_rev int; n int:=0; idx int:=0; r text; emp text; code text; emp_type text;
begin
 if auth.uid() is null or jsonb_typeof(p->'rows')<>'array' then raise exception 'ملف الاستيراد غير صالح'; end if;
 if jsonb_array_length(p->'rows')>5000 then raise exception 'ملف الاستيراد تجاوز 5000 صف'; end if;
 for rowv in select value from jsonb_array_elements(p->'rows') loop
  idx:=idx+1;r:=rowv->>'region';emp:=btrim(coalesce(rowv->>'employer',''));code:=btrim(coalesce(rowv->>'employee_code',''));
  emp_type:=coalesce(nullif(rowv->>'employment_type',''),'other');
  if not public.fm233_manage(r) then raise exception 'الصف %: لا توجد صلاحية للمنطقة',idx; end if;
  if emp='' or code='' or btrim(coalesce(rowv->>'full_name',''))='' or btrim(coalesce(rowv->>'job_title',''))='' then raise exception 'الصف %: الرقم الوظيفي والاسم وجهة العمل والمسمى مطلوبة',idx; end if;
  if coalesce(rowv->>'person_type','staff') not in('staff','contractor') or emp_type not in('permanent','fixed_term','daily','outsourced','other') then raise exception 'الصف %: تصنيف الفرد أو نوع التعاقد غير صحيح',idx; end if;
  select x.id,x.revision into pid,person_rev from public.fm_people334 x where x.region=r and lower(btrim(x.employer))=lower(emp) and lower(btrim(x.employee_code))=lower(code) for update;
  begin
   saved:=public.fm_workforce337_person_save(jsonb_build_object('kind','person','region',r,'id',pid,'revision',person_rev,'employee_code',code,'full_name',btrim(rowv->>'full_name'),'person_type',coalesce(nullif(rowv->>'person_type',''),'staff'),'employer',emp,'department',coalesce(rowv->>'department',''),'job_title',btrim(rowv->>'job_title'),'specialty',coalesce(rowv->>'specialty',''),'employment_type',emp_type,'start_date',nullif(rowv->>'start_date',''),'contract_end_date',nullif(rowv->>'contract_end_date',''),'phone',coalesce(rowv->>'phone',''),'direct_manager',coalesce(rowv->>'direct_manager',''),'team_id',nullif(rowv->>'team_id',''),'active',true,'note','استيراد جماعي V337','change_reason','استيراد جماعي'));
   pid:=(saved->>'id')::uuid;
   select m.revision into role_rev from public.fm_person_roles335 m where m.person_id=pid;
   perform public.fm_workforce335_role_save(jsonb_build_object('person_id',pid,'region',r,'job_family',coalesce(nullif(rowv->>'job_family',''),'other'),'profile_id',nullif(rowv->>'profile_id',''),'revision',role_rev));
  exception when others then raise exception 'الصف %: %',idx,sqlerrm; end;
  n:=n+1;
 end loop;
 return jsonb_build_object('saved',n,'atomic',true);
end $$;

revoke all on function public.fm_workforce337_data(text),public.fm_workforce337_person_save(jsonb),public.fm_workforce337_plan_save(jsonb),public.fm_workforce337_leave_save(jsonb),public.fm_workforce337_leave_review(uuid,text,uuid,text),public.fm_workforce337_qualification_save(jsonb),public.fm_workforce337_move(jsonb),public.fm_workforce337_import_people(jsonb) from public,anon;
grant execute on function public.fm_workforce337_data(text),public.fm_workforce337_person_save(jsonb),public.fm_workforce337_plan_save(jsonb),public.fm_workforce337_leave_save(jsonb),public.fm_workforce337_leave_review(uuid,text,uuid,text),public.fm_workforce337_qualification_save(jsonb),public.fm_workforce337_move(jsonb),public.fm_workforce337_import_people(jsonb) to authenticated;
notify pgrst,'reload schema';

COMMIT;
