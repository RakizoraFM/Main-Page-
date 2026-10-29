-- V239: the approved cause of an SLA breach, chosen per ticket from a drop-list by an authorised person (section 51).
-- Needs the earlier sections (fm_role, fm_my_pos, fm_region_ok, fm_mod, fm_settings). Idempotent.
create table if not exists public.fm_breach_reasons(
 region text not null, ticket_id text not null check(length(ticket_id) between 1 and 120),
 cause text not null check(length(cause) between 1 and 120), note text not null default '' check(length(note)<=500),
 by_id uuid not null default auth.uid(), by_name text not null default '', at timestamptz not null default now(),
 revision int not null default 1, primary key(region, ticket_id));
create table if not exists public.fm_breach_reason_log(
 id bigserial primary key, region text not null, ticket_id text not null, old_cause text, new_cause text, old_note text, new_note text,
 by_id uuid, by_name text, at timestamptz not null default now());
alter table public.fm_breach_reasons enable row level security;
alter table public.fm_breach_reason_log enable row level security;
revoke all on public.fm_breach_reasons, public.fm_breach_reason_log from anon, authenticated;

-- the drop-list: fm_settings.breach_reasons (array of text) written by the system admin, else the defaults
create or replace function public.fm_breach_reason_list() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce((select value from public.fm_settings where key='breach_reasons' and jsonb_typeof(value)='array' and jsonb_array_length(value)>0),
  '["تأخر توفير قطع الغيار","تأخر المقاول في المباشرة","نقص العمالة أو الفنيين","يحتاج مقاول أو فني متخصص","تعذر الوصول للمدرسة أو المدرسة مغلقة","بانتظار اعتماد أو موافقة","بانتظار موافقة الاستشاري","عطل كبير يحتاج وقتاً أطول من المهلة","خطأ في تسجيل البلاغ أو الأولوية","بلاغ مكرر","تأخر الإغلاق في النظام رغم التنفيذ","ظروف جوية أو قاهرة","أخرى"]'::jsonb) $$;

-- who may set / change a cause: system admin, department / project / ops / QA managers, area manager and area engineer of the region
create or replace function public.fm_breach_can(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role() not in ('pending','viewer') and
  (public.fm_role()='admin' or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager','qa_manager')
   or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_region_ok(r))),false) $$;

create or replace function public.fm_breach_reasons_get(p_region text) returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if auth.uid() is null or public.fm_role()='pending' then raise exception 'not allowed'; end if;
 if not (public.fm_role()='admin' or public.fm_region_ok(p_region)) then raise exception 'not allowed'; end if;
 return jsonb_build_object('can',public.fm_breach_can(p_region),'list',public.fm_breach_reason_list(),
  'rows',coalesce((select jsonb_agg(jsonb_build_object('t',ticket_id,'c',cause,'n',note,'by',by_name,'at',at,'rev',revision)) from public.fm_breach_reasons where region=p_region),'[]'::jsonb));
end $$;

create or replace function public.fm_breach_reason_set(p_region text, p_ticket text, p_cause text, p_note text default '', p_rev int default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare o public.fm_breach_reasons; nm text; c text:=nullif(btrim(coalesce(p_cause,'')),''); n text:=btrim(coalesce(p_note,''));
begin
 if not public.fm_breach_can(p_region) then raise exception 'not allowed'; end if;
 if exists(select 1 from pg_proc where proname='fm_mod') and not public.fm_mod('tickets') then raise exception 'module disabled'; end if;
 if p_region is null or btrim(p_region)='' or p_ticket is null or btrim(p_ticket)='' then raise exception 'invalid ticket'; end if;
 if length(n)>500 then raise exception 'note too long'; end if;
 select * into o from public.fm_breach_reasons where region=p_region and ticket_id=p_ticket for update;
 if found and p_rev is not null and o.revision<>p_rev then raise exception 'version conflict'; end if;
 select coalesce(nullif(full_name,''),email,'') into nm from public.profiles where id=auth.uid();
 if c is null then
  if found then delete from public.fm_breach_reasons where region=p_region and ticket_id=p_ticket;
   insert into public.fm_breach_reason_log(region,ticket_id,old_cause,new_cause,old_note,new_note,by_id,by_name) values(p_region,p_ticket,o.cause,null,o.note,null,auth.uid(),nm); end if;
  return jsonb_build_object('ok',true,'cleared',true);
 end if;
 if not (public.fm_breach_reason_list() ? c) then raise exception 'unknown cause'; end if;
 if c='أخرى' and length(n)<3 then raise exception 'note required'; end if;
 if found and o.cause=c and o.note=n then return jsonb_build_object('ok',true,'rev',o.revision); end if;
 insert into public.fm_breach_reasons(region,ticket_id,cause,note,by_id,by_name,at,revision) values(p_region,p_ticket,c,n,auth.uid(),coalesce(nm,''),now(),1)
  on conflict(region,ticket_id) do update set cause=excluded.cause,note=excluded.note,by_id=excluded.by_id,by_name=excluded.by_name,at=now(),revision=public.fm_breach_reasons.revision+1;
 insert into public.fm_breach_reason_log(region,ticket_id,old_cause,new_cause,old_note,new_note,by_id,by_name) values(p_region,p_ticket,o.cause,c,o.note,n,auth.uid(),nm);
 return jsonb_build_object('ok',true,'rev',(select revision from public.fm_breach_reasons where region=p_region and ticket_id=p_ticket));
end $$;

create or replace function public.fm_breach_reason_history(p_region text, p_ticket text) returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if auth.uid() is null or public.fm_role()='pending' or not (public.fm_role()='admin' or public.fm_region_ok(p_region)) then raise exception 'not allowed'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('old',old_cause,'new',new_cause,'note',new_note,'by',by_name,'at',at) order by at desc) from public.fm_breach_reason_log where region=p_region and ticket_id=p_ticket),'[]'::jsonb);
end $$;

revoke all on function public.fm_breach_reason_list(),public.fm_breach_can(text),public.fm_breach_reasons_get(text),public.fm_breach_reason_set(text,text,text,text,int),public.fm_breach_reason_history(text,text) from public,anon;
grant execute on function public.fm_breach_reason_list(),public.fm_breach_can(text),public.fm_breach_reasons_get(text),public.fm_breach_reason_set(text,text,text,text,int),public.fm_breach_reason_history(text,text) to authenticated;
notify pgrst,'reload schema';
