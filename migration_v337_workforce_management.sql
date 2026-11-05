-- RakizoraFM V337 workforce lifecycle management.
-- Apply after V336 on an existing company database. For a fresh install,
-- apply supabase_setup.sql first, then this migration.
begin;

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
language plpgsql security definer set search_path=public as $
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
end $;

revoke all on function public.fm_workforce337_data(text),public.fm_workforce337_person_save(jsonb),public.fm_workforce337_plan_save(jsonb),public.fm_workforce337_leave_save(jsonb),public.fm_workforce337_leave_review(uuid,text,uuid,text),public.fm_workforce337_qualification_save(jsonb),public.fm_workforce337_move(jsonb),public.fm_workforce337_import_people(jsonb) from public,anon;
grant execute on function public.fm_workforce337_data(text),public.fm_workforce337_person_save(jsonb),public.fm_workforce337_plan_save(jsonb),public.fm_workforce337_leave_save(jsonb),public.fm_workforce337_leave_review(uuid,text,uuid,text),public.fm_workforce337_qualification_save(jsonb),public.fm_workforce337_move(jsonb),public.fm_workforce337_import_people(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
