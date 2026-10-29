-- V231 / F53: configurable pre-breach recipients, durable account inbox, WhatsApp and Push.
begin;
create or replace function public.fm231_manage(r text) returns boolean language sql stable security definer set search_path=public as $$
 select auth.uid() is not null and public.fm_role()<>'pending' and public.fm_mod('tickets') and
 (public.fm_role()='admin' or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager') or
 (r is not null and public.fm_my_pos()='area_manager' and public.fm_region_ok(r))) $$;
create or replace function public.fm231_target(u uuid,r text) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.profiles p where p.id=u and p.active and p.role<>'pending' and
 (r is null or cardinality(coalesce(p.regions,'{}'))=0 or r=any(p.regions) or public.fm_posx(p.role,p.job_title) in ('sysadmin','dept_manager','project_manager','ops_manager'))) $$;
create table if not exists public.fm_sla_rules231(
 id uuid primary key default gen_random_uuid(),name text not null check(length(name) between 1 and 120),region text,
 lead_minutes int not null check(lead_minutes between 5 and 10080),recipients uuid[] not null check(cardinality(recipients) between 1 and 30),
 whatsapp boolean not null default true,push boolean not null default true,enabled boolean not null default false,
 max_age_hours int not null default 24 check(max_age_hours between 1 and 168),revision int not null default 1,
 updated_at timestamptz not null default now(),updated_by uuid references public.profiles(id) on delete set null);
alter table public.fm_sla_rules231 enable row level security;
revoke insert,update,delete on public.fm_sla_rules231 from anon,authenticated;
grant select on public.fm_sla_rules231 to authenticated;
drop policy if exists p_rule231 on public.fm_sla_rules231;
create policy p_rule231 on public.fm_sla_rules231 for select to authenticated using(public.fm231_manage(region));
create table if not exists public.fm_sla_inbox231(
 id uuid primary key default gen_random_uuid(),rule_id uuid references public.fm_sla_rules231(id) on delete set null,
 region text not null,ticket_id text not null,due_at timestamptz not null,recipient uuid not null references public.profiles(id) on delete cascade,
 lead_minutes int not null,school text,priority text,descr text,title text not null,body text not null,created_at timestamptz not null default now(),read_at timestamptz,
 whatsapp boolean not null,push boolean not null,wa_state text not null default 'pending',wa_reason text,wa_id bigint references public.fm_wa_queue(id) on delete set null,
 push_state text not null default 'pending',push_id bigint references public.fm_push_queue(id) on delete set null,
 unique(region,ticket_id,due_at,recipient,lead_minutes));
create index if not exists fm_sla_inbox231_user on public.fm_sla_inbox231(recipient,created_at desc);
alter table public.fm_sla_inbox231 enable row level security;
revoke insert,update,delete on public.fm_sla_inbox231 from anon,authenticated;
grant select on public.fm_sla_inbox231 to authenticated;
drop policy if exists p_inbox231 on public.fm_sla_inbox231;
create policy p_inbox231 on public.fm_sla_inbox231 for select to authenticated using(public.fm_role()<>'pending' and public.fm_mod('tickets') and(recipient=auth.uid() or public.fm231_manage(region)));
create or replace function public.fm231_open(r text,t text) returns boolean language sql stable security definer set search_path=public as $$
 select not exists(select 1 from public.ticket_work w where w.region=r and w.ticket_id=t and(w.resolved_at is not null or w.stage in('resolved','closed','cancelled')))
 and not exists(select 1 from public.tickets k where k.region=r and k.ticket_id=t and lower(btrim(coalesce(k.status,''))) in('مغلق','تم حله','ملغى','خارج النطاق','closed','resolved','cancelled','canceled','out of scope')) $$;
create or replace function public.fm_sla231_rule_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare old public.fm_sla_rules231;v public.fm_sla_rules231;r text:=nullif(btrim(p->>'region'),'');ids uuid[];u uuid;k uuid:=nullif(p->>'id','')::uuid;
begin
 if not public.fm231_manage(r) then raise exception 'not allowed';end if;
 if jsonb_typeof(p->'recipients') is distinct from 'array' then raise exception 'select recipients';end if;
 select array_agg(distinct x::uuid) into ids from jsonb_array_elements_text(p->'recipients') x;
 if cardinality(ids) is null or cardinality(ids) not between 1 and 30 or array_position(ids,null) is not null then raise exception 'select 1 to 30 recipients';end if;
 foreach u in array ids loop if coalesce((p->>'enabled')::boolean,false) and not public.fm231_target(u,r) then raise exception 'recipient inactive or outside region';end if;end loop;
 if k is not null then
  select * into old from public.fm_sla_rules231 where id=k for update;
  if not found or not public.fm231_manage(old.region) then raise exception 'not allowed';end if;
  if (p->>'revision')::int is distinct from old.revision then raise exception 'version conflict: reload';end if;
 else k:=gen_random_uuid();end if;
 perform pg_advisory_xact_lock(231,2);
 if coalesce((p->>'enabled')::boolean,false) and exists(select 1 from public.fm_sla_rules231 q where q.id<>k and q.enabled and(q.region is null or r is null or q.region=r) and q.lead_minutes=(p->>'lead_minutes')::int and q.recipients&&ids) then raise exception 'duplicate stage recipient: edit the existing stage';end if;
 insert into public.fm_sla_rules231(id,name,region,lead_minutes,recipients,whatsapp,push,enabled,max_age_hours,updated_by)
 values(k,btrim(p->>'name'),r,(p->>'lead_minutes')::int,ids,coalesce((p->>'whatsapp')::boolean,true),coalesce((p->>'push')::boolean,true),coalesce((p->>'enabled')::boolean,false),coalesce((p->>'max_age_hours')::int,24),auth.uid())
 on conflict(id) do update set name=excluded.name,region=excluded.region,lead_minutes=excluded.lead_minutes,recipients=excluded.recipients,whatsapp=excluded.whatsapp,push=excluded.push,enabled=excluded.enabled,max_age_hours=excluded.max_age_hours,revision=public.fm_sla_rules231.revision+1,updated_at=now(),updated_by=auth.uid() returning * into v;
 return to_jsonb(v);
end $$;
create or replace function public.fm_sla231_template(n text) returns boolean language plpgsql security definer set search_path=public as $$
declare s jsonb:=coalesce(public.fm_setting('wa'),'{}');
begin
 if not public.fm231_manage(null) then raise exception 'not allowed';end if;
 if n is null or n!~'^[a-z0-9_]{1,100}$' then raise exception 'invalid template name';end if;
 s:=jsonb_set(s,'{templates}',coalesce(s->'templates','{}')||jsonb_build_object('sla_prebreach',n));
 insert into public.fm_settings(key,value) values('wa',s) on conflict(key) do update set value=excluded.value;
 return true;
end $$;
-- Only the recipient may acknowledge their alert. Admin visibility does not confer that acknowledgement.
create or replace function public.fm_sla231_read(k uuid) returns boolean language plpgsql security definer set search_path=public as $$
begin
 if public.fm_role()='pending' or not public.fm_mod('tickets') then raise exception 'not allowed';end if;
 update public.fm_sla_inbox231 set read_at=coalesce(read_at,now()) where id=k and recipient=auth.uid();return found;
end $$;
-- Worker and retry loop: one durable inbox event for each ticket/deadline/recipient/threshold.
create or replace function public.fm_sla231_run(p_region text default null) returns int language plpgsql security definer set search_path=public as $$
declare rr record;e public.fm_sla_inbox231;n int:=0;ph text;wa jsonb:=coalesce(public.fm_setting('wa'),'{}');ok boolean;event_ref text;pk bigint;
begin
 if not public.fm_plan_ok() or not public.fm_mod('tickets') then return 0;end if;
 if not pg_try_advisory_xact_lock(231,1) then return 0;end if;
 for rr in select q.id rule_id,q.lead_minutes,q.whatsapp,q.push,w.*,u.uid recipient from public.fm_sla_rules231 q
 join public.fm_sla_watch w on(q.region is null or q.region=w.region) cross join lateral unnest(q.recipients) u(uid)
 where q.enabled and(p_region is null or w.region=p_region) and w.due_at>now() and w.due_at<=now()+make_interval(mins=>q.lead_minutes)
 and w.updated_at>=now()-make_interval(hours=>q.max_age_hours) and public.fm231_target(u.uid,w.region) and public.fm231_open(w.region,w.ticket_id)
 order by w.region,w.ticket_id,q.id,u.uid loop
  insert into public.fm_sla_inbox231(rule_id,region,ticket_id,due_at,recipient,lead_minutes,school,priority,descr,title,body,whatsapp,push)
  values(rr.rule_id,rr.region,rr.ticket_id,rr.due_at,rr.recipient,rr.lead_minutes,rr.school,rr.priority,rr.descr,
   '⏰ تصعيد قبل اختراق البلاغ '||rr.ticket_id,
   coalesce(rr.school,'')||' • البلاغ '||rr.ticket_id||' • الأولوية '||coalesce(rr.priority,'')||' • يتبقى '||greatest(1,ceil(extract(epoch from rr.due_at-now())/60))::int||' دقيقة • نهاية المهلة '||to_char(rr.due_at at time zone 'Asia/Riyadh','YYYY-MM-DD HH24:MI'),rr.whatsapp,rr.push)
  on conflict(region,ticket_id,due_at,recipient,lead_minutes) do nothing;
  if found then n:=n+1;end if;
 end loop;
 for e in select i.* from public.fm_sla_inbox231 i join public.fm_sla_rules231 q on q.id=i.rule_id
 where q.enabled and(p_region is null or i.region=p_region) and q.lead_minutes=i.lead_minutes and(q.region is null or q.region=i.region) and i.recipient=any(q.recipients) and i.due_at>now() and public.fm231_target(i.recipient,i.region) and public.fm231_open(i.region,i.ticket_id)
 and exists(select 1 from public.fm_sla_watch w where w.region=i.region and w.ticket_id=i.ticket_id and w.due_at=i.due_at and w.updated_at>=now()-make_interval(hours=>q.max_age_hours))
 and (i.wa_state in('pending','blocked') or i.push_state='pending') order by i.created_at,i.id for update of i loop
  event_ref:='sla231-'||e.id::text;
  if e.push_state='pending' then
   if not e.push or not (select push from public.fm_sla_rules231 where id=e.rule_id) then update public.fm_sla_inbox231 set push_state='not_requested' where id=e.id;
   else
    begin
     -- Honor the recipient's notification preferences; inbox delivery is independent of Push.
     if not exists(select 1 from public.fm_push_prefs where user_id=e.recipient and 'sla_due'=any(off)) and not coalesce((public.fm_setting('push')->'off')?'sla_due',false) and public.fm_push_add(e.recipient,'sla_due',e.title,e.body,'sla-escalation',event_ref,true) then
      select id into pk from public.fm_push_queue where user_id=e.recipient and tag=event_ref order by id desc limit 1;
      update public.fm_sla_inbox231 set push_state='queued',push_id=pk where id=e.id;
     else update public.fm_sla_inbox231 set push_state='unavailable' where id=e.id;end if;
    exception when others then update public.fm_sla_inbox231 set push_state='unavailable' where id=e.id;end;
   end if;
  end if;
  if e.wa_state in('pending','blocked') then
   if not e.whatsapp or not (select whatsapp from public.fm_sla_rules231 where id=e.rule_id) then update public.fm_sla_inbox231 set wa_state='not_requested',wa_reason=null where id=e.id;
   else
    select public.fm_wa_norm(phone) into ph from public.profiles where id=e.recipient;
    if not coalesce((wa->>'enabled')::boolean,false) then update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='whatsapp_disabled' where id=e.id;
    elsif ph is null then update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='invalid_profile_phone' where id=e.id;
    elsif nullif(wa->'templates'->>'sla_prebreach','') is null then update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='template_missing' where id=e.id;
    elsif not exists(select 1 from public.fm_wa_cfg where id=1 and fn_url is not null and hook_secret is not null) then update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='sender_not_configured' where id=e.id;
    else
     begin
      ok:=public.fm_wa_add(ph,'sla_prebreach',array[coalesce((select coalesce(full_name,email) from public.profiles where id=e.recipient),''),e.ticket_id,coalesce(e.school,''),coalesce(e.priority,''),to_char(e.due_at at time zone 'Asia/Riyadh','YYYY-MM-DD HH24:MI'),greatest(1,ceil(extract(epoch from e.due_at-now())/60))::int::text],'sla_prebreach',event_ref);
      select id into pk from public.fm_wa_queue where kind='sla_prebreach' and ref=event_ref and phone=ph order by id desc limit 1;
      if pk is not null then update public.fm_sla_inbox231 set wa_state='queued',wa_reason=null,wa_id=pk where id=e.id;
      else update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='queue_rejected' where id=e.id;end if;
     exception when others then update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='queue_error' where id=e.id;end;
    end if;
   end if;
  end if;
 end loop;
 return n;
end $$;
create or replace function public.fm_sla231_run_now(r text) returns int language plpgsql security definer set search_path=public as $$
begin if not public.fm231_manage(r) then raise exception 'not allowed';end if;return public.fm_sla231_run(r);end $$;
-- Expiration/closure check immediately before channel workers claim an escalation message.
create or replace function public.fm231_valid(k uuid) returns boolean language sql stable security definer set search_path=public as $$
 select public.fm_plan_ok() and public.fm_mod('tickets') and exists(select 1 from public.fm_sla_inbox231 i join public.fm_sla_rules231 q on q.id=i.rule_id join public.fm_sla_watch w on w.region=i.region and w.ticket_id=i.ticket_id and w.due_at=i.due_at
 where i.id=k and q.enabled and q.lead_minutes=i.lead_minutes and(q.region is null or q.region=i.region) and i.recipient=any(q.recipients) and public.fm231_target(i.recipient,i.region) and public.fm231_open(i.region,i.ticket_id) and i.due_at>now() and w.updated_at>=now()-make_interval(hours=>q.max_age_hours)) $$;
create or replace function public.fm_sla231_setup() returns jsonb language plpgsql stable security definer set search_path=public as $$
declare mgr boolean:=public.fm231_manage(null);wa jsonb:=coalesce(public.fm_setting('wa'),'{}');cron_on boolean:=false;
begin
 if auth.uid() is null or public.fm_role()='pending' or not public.fm_mod('tickets') then raise exception 'not allowed';end if;
 begin execute 'select exists(select 1 from cron.job where jobname=''fm-sla-escalation231'' and active)' into cron_on;exception when undefined_table or invalid_schema_name or insufficient_privilege then cron_on:=false;end;
 return jsonb_build_object('all_regions',mgr,'can_manage',mgr or public.fm_my_pos()='area_manager',
 'regions',case when mgr or cardinality(public.fm_regions())=0 then array['riyadh','qassim'] else public.fm_regions() end,
 'rules',coalesce((select jsonb_agg(to_jsonb(q) order by q.updated_at desc) from public.fm_sla_rules231 q where public.fm231_manage(q.region)),'[]'),
 'people',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(p.full_name,p.email),'title',public.fm_posx(p.role,p.job_title),'regions',p.regions,'phone_ready',public.fm_wa_norm(p.phone) is not null) order by p.full_name) from public.profiles p where p.active and p.role<>'pending' and(mgr or(public.fm_my_pos()='area_manager' and(cardinality(public.fm_regions())=0 or p.regions&&public.fm_regions() or cardinality(coalesce(p.regions,'{}'))=0)))),'[]'),
 'meta',coalesce((select jsonb_agg(to_jsonb(m)) from public.fm_sla_watch_meta m where public.fm231_manage(m.region)),'[]'),
 'cron',cron_on,'whatsapp_enabled',coalesce((wa->>'enabled')::boolean,false),'template',wa->'templates'->>'sla_prebreach',
 'sender_configured',exists(select 1 from public.fm_wa_cfg where id=1 and fn_url is not null and hook_secret is not null));
end $$;
create or replace function public.fm_sla231_list(p_all boolean default false,p_offset int default 0) returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if auth.uid() is null or public.fm_role()='pending' or not public.fm_mod('tickets') then raise exception 'not allowed';end if;
 return jsonb_build_object('unread',(select count(*) from public.fm_sla_inbox231 where recipient=auth.uid() and read_at is null),
 'total',(select count(*) from public.fm_sla_inbox231 i where i.recipient=auth.uid() or(p_all and public.fm231_manage(i.region))),
 'items',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc) from(
 select i.id,i.region,i.ticket_id,i.school,i.priority,i.due_at,i.lead_minutes,i.title,i.body,i.created_at,i.read_at,i.recipient,
 coalesce(p.full_name,p.email) recipient_name,i.recipient=auth.uid() mine,public.fm231_open(i.region,i.ticket_id) source_open,
 case when i.wa_id is not null then w.status else i.wa_state end wa_state,coalesce(w.err,i.wa_reason) wa_reason,w.sent_at wa_sent_at,
 case when q.sent_at is not null then 'sent' when q.tries>=5 then 'failed' else i.push_state end push_state
 from public.fm_sla_inbox231 i left join public.profiles p on p.id=i.recipient left join public.fm_wa_queue w on w.id=i.wa_id left join public.fm_push_queue q on q.id=i.push_id
 where i.recipient=auth.uid() or(p_all and public.fm231_manage(i.region)) order by i.created_at desc,i.id desc offset greatest(0,coalesce(p_offset,0)) limit 100)x),'[]'));
end $$;
revoke all on function public.fm231_manage(text),public.fm231_target(uuid,text),public.fm231_open(text,text),public.fm_sla231_run(text),public.fm231_valid(uuid),public.fm_sla231_rule_save(jsonb),public.fm_sla231_template(text),public.fm_sla231_read(uuid),public.fm_sla231_run_now(text),public.fm_sla231_setup(),public.fm_sla231_list(boolean,int) from public,anon,authenticated;
grant execute on function public.fm231_manage(text),public.fm_sla231_rule_save(jsonb),public.fm_sla231_template(text),public.fm_sla231_read(uuid),public.fm_sla231_run_now(text),public.fm_sla231_setup(),public.fm_sla231_list(boolean,int) to authenticated;
-- The scheduled job does not depend on an open browser. Existing general SLA warnings are preserved.
do $do$ begin
 begin execute 'select cron.unschedule(''fm-sla-escalation231'')';exception when others then null;end;
 begin execute 'select cron.schedule(''fm-sla-escalation231'',''* * * * *'',''select public.fm_sla231_run(null)'')';
 exception when others then raise notice 'pg_cron is unavailable; configure the job to enable unattended SLA escalations';end;
end $do$;

create or replace function public.fm_wa_claim(n int) returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  update public.fm_wa_queue set status='failed',err='SLA event no longer current' where kind='sla_prebreach' and status='queued' and exists(select 1 from public.fm_sla_inbox231 i where fm_wa_queue.ref='sla231-'||i.id::text and (not public.fm231_valid(i.id) or not (select whatsapp from public.fm_sla_rules231 where id=i.rule_id)));
  with c as (
    update public.fm_wa_queue q set claimed_at = now(), tries = q.tries + 1
     where q.id in (select id from public.fm_wa_queue where status = 'queued' and tries < 5 and created_at > now() - interval '2 days'
                      and (claimed_at is null or claimed_at < now() - interval '2 minutes') order by id limit greatest(1, least(coalesce(n,50), 200)) for update skip locked)
    returning q.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'phone', c.phone, 'template', c.template, 'lang', c.lang, 'params', c.params)), '[]'::jsonb) into r from c;
  return r;
end $$;

create or replace function public.fm_push_claim(n int) returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  update public.fm_push_queue set tries=5,err='SLA event no longer current' where tag like 'sla231-%' and sent_at is null and exists(select 1 from public.fm_sla_inbox231 i where fm_push_queue.tag='sla231-'||i.id::text and (not public.fm231_valid(i.id) or not (select push from public.fm_sla_rules231 where id=i.rule_id)));
  with c as (
    update public.fm_push_queue q set claimed_at = now(), tries = q.tries + 1
     where q.id in (select id from public.fm_push_queue where sent_at is null and tries < 5 and created_at > now() - interval '1 day'
                      and (claimed_at is null or claimed_at < now() - interval '2 minutes') order by id limit greatest(1, least(coalesce(n,100), 500)) for update skip locked)
    returning q.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'body', c.body, 'url', c.url, 'tag', c.tag, 'kind', c.kind,
           'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) from public.fm_push_subs s where s.user_id = c.user_id), '[]'))), '[]')
    into r from c;
  return r;
end $$;

notify pgrst,'reload schema';
commit;
