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
