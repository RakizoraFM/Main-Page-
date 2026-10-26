-- V194: quality-review annotations and contractor-payment follow-up.
begin;
create table if not exists public.fm_close_reviews (
 region text not null, old_id text not null, new_id text not null,
 result text not null check(result in ('pending','confirmed','different','actioned')),
 note text not null check(length(trim(note)) between 1 and 4000), revision int not null default 1,
 updated_by uuid references public.profiles(id),updated_at timestamptz not null default now(),
 primary key(region,old_id,new_id),check(lower(trim(old_id))<>lower(trim(new_id)))
);
create table if not exists public.fm_close_review_events (
 id bigint generated always as identity primary key, region text not null,old_id text not null,new_id text not null,
 at timestamptz not null default now(),by_user uuid references public.profiles(id),old_value jsonb,new_value jsonb not null
);
alter table public.fm_close_reviews enable row level security;
alter table public.fm_close_review_events enable row level security;
revoke all on public.fm_close_reviews,public.fm_close_review_events from anon,authenticated;
create or replace function public.fm_close_can(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role()<>'pending' and public.fm_mod('tickets') and (public.fm_role()='admin' or public.fm_my_pos() in ('sysadmin','qa_manager','project_manager','ops_manager') or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_region_ok(r))),false) $$;
create or replace function public.fm_close_list(r text) returns jsonb language plpgsql stable security definer set search_path=public as $$
 begin if not public.fm_close_can(r) then raise exception 'not allowed';end if;return (select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.fm_close_reviews x where x.region=r);end $$;
create or replace function public.fm_close_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
 declare rg text:=p->>'region';o text:=trim(p->>'old_id');n text:=trim(p->>'new_id');old public.fm_close_reviews;v public.fm_close_reviews;
 begin
 if not public.fm_close_can(rg) then raise exception 'not allowed';end if;
 if lower(o)=lower(n) or o is null or n is null then raise exception 'distinct tickets required';end if;
 if not exists(select 1 from public.tickets t where t.region=rg and t.ticket_id=o) or not exists(select 1 from public.tickets t where t.region=rg and t.ticket_id=n) then raise exception 'upload both tickets to cloud first';end if;
 perform pg_advisory_xact_lock(hashtextextended('fmclose:'||rg||':'||o||':'||n,0));
 select * into old from public.fm_close_reviews where region=rg and old_id=o and new_id=n for update;
 if coalesce(old.revision,0)<>coalesce((p->>'revision')::int,0) then raise exception 'version conflict: reload';end if;
 insert into public.fm_close_reviews(region,old_id,new_id,result,note,revision,updated_by)
 values(rg,o,n,p->>'result',trim(p->>'note'),coalesce(old.revision,0)+1,auth.uid())
 on conflict(region,old_id,new_id) do update set result=excluded.result,note=excluded.note,revision=excluded.revision,updated_by=excluded.updated_by,updated_at=now() returning * into v;
 insert into public.fm_close_review_events(region,old_id,new_id,by_user,old_value,new_value) values(rg,o,n,auth.uid(),case when old.old_id is null then null else to_jsonb(old) end,to_jsonb(v));return to_jsonb(v);
 end $$;
create or replace function public.fm_close_history(r text,o text,n text) returns jsonb language plpgsql stable security definer set search_path=public as $$
 begin if not public.fm_close_can(r) then raise exception 'not allowed';end if;return(select coalesce(jsonb_agg(to_jsonb(e) order by e.at desc,e.id desc),'[]'::jsonb) from public.fm_close_review_events e where e.region=r and e.old_id=o and e.new_id=n);end $$;
create table if not exists public.fm_bill_followup (
 bill_id uuid primary key references public.fm_bills(id) on delete cascade,
 owner_id uuid not null references public.profiles(id),due_at timestamptz not null,
 documents jsonb not null default '[]' check(jsonb_typeof(documents)='array' and jsonb_array_length(documents)<=20),
 hold_reason text not null default '' check(length(hold_reason)<=1000),impact_note text not null default '' check(length(impact_note)<=2000),
 team_id uuid references public.fm_team_readiness(id) on delete set null,
 note text not null check(length(trim(note)) between 1 and 4000),revision int not null default 1,
 updated_by uuid references public.profiles(id),updated_at timestamptz not null default now()
);
create table if not exists public.fm_bill_followup_events (
 id bigint generated always as identity primary key,bill_id uuid not null references public.fm_bills(id) on delete cascade,
 at timestamptz not null default now(),by_user uuid references public.profiles(id),old_value jsonb,new_value jsonb not null
);
alter table public.fm_bill_followup enable row level security;alter table public.fm_bill_followup_events enable row level security;
revoke all on public.fm_bill_followup,public.fm_bill_followup_events from anon,authenticated;
create or replace function public.fm_bfollow_can(k uuid,w boolean default false) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(public.fm_role()<>'pending' and public.fm_mod('bill') and exists(select 1 from public.fm_bills b join public.fm_contracts c on c.id=b.contract_id where b.id=k and case when w then public.fm_bill_can('prep',c.region) or public.fm_bill_can('pay',c.region) or public.fm_bill_can('review',c.region) else public.fm_bill_can('read',c.region) or c.contractor_id=auth.uid() end),false) $$;
create or replace function public.fm_bfollow_list() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(b)||jsonb_build_object('region',c.region,'contractor_name',c.contractor_name,'contract_name',c.name,'can_edit',public.fm_bfollow_can(b.id,true),'followup',case when f.bill_id is null then null else to_jsonb(f)||jsonb_build_object('owner_name',p.full_name,'team_name',t.name) end) order by b.created_at desc),'[]'::jsonb)
 from public.fm_bills b join public.fm_contracts c on c.id=b.contract_id left join public.fm_bill_followup f on f.bill_id=b.id left join public.profiles p on p.id=f.owner_id left join public.fm_team_readiness t on t.id=f.team_id where public.fm_bfollow_can(b.id,false) $$;
create or replace function public.fm_bfollow_options(k uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
 declare rg text;begin
 if not public.fm_bfollow_can(k,true) then raise exception 'not allowed';end if;
 select c.region into rg from public.fm_contracts c join public.fm_bills b on b.contract_id=c.id where b.id=k;
 return jsonb_build_object('people',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(p.full_name,p.email)) order by p.full_name),'[]'::jsonb) from public.profiles p where p.active and public.fm_posx(p.role,p.job_title) in ('sysadmin','accountant','project_manager','ops_manager','area_manager','area_engineer') and (public.fm_posx(p.role,p.job_title) in ('sysadmin','accountant','project_manager','ops_manager') or cardinality(p.regions)=0 or rg=any(p.regions))),
 'teams',(select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'name',t.name)),'[]'::jsonb) from public.fm_team_readiness t where t.region=rg and public.fm_ready_read(t.region)));
 end $$;
create or replace function public.fm_bfollow_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
 declare k uuid:=(p->>'bill_id')::uuid; old public.fm_bill_followup;v public.fm_bill_followup;bl public.fm_bills;rg text;own uuid:=(p->>'owner_id')::uuid;tm uuid:=nullif(p->>'team_id','')::uuid;doc jsonb;
 begin
 select * into bl from public.fm_bills where id=k for update;
 if not found or not public.fm_bfollow_can(k,true) then raise exception 'not allowed';end if;
 if bl.status in ('paid','cancelled') then raise exception 'bill finished';end if;
 select c.region into rg from public.fm_contracts c where c.id=bl.contract_id;
 if not exists(select 1 from public.profiles pr where pr.id=own and pr.active and public.fm_posx(pr.role,pr.job_title) in ('sysadmin','accountant','project_manager','ops_manager','area_manager','area_engineer') and (public.fm_posx(pr.role,pr.job_title) in ('sysadmin','accountant','project_manager','ops_manager') or cardinality(pr.regions)=0 or rg=any(pr.regions))) then raise exception 'invalid owner';end if;
 if tm is not null and not exists(select 1 from public.fm_team_readiness t where t.id=tm and t.region=rg and public.fm_ready_read(t.region)) then raise exception 'invalid team';end if;
 if jsonb_typeof(p->'documents') is distinct from 'array' or jsonb_array_length(p->'documents')>20 then raise exception 'invalid documents';end if;
 if (select count(distinct x->>'key') from jsonb_array_elements(p->'documents') x)<>jsonb_array_length(p->'documents') then raise exception 'duplicate document keys';end if;
 for doc in select * from jsonb_array_elements(p->'documents') loop
 if coalesce(doc->>'key','') not in ('scene','invoice','warranty','other') or jsonb_typeof(doc->'required') is distinct from 'boolean' or jsonb_typeof(doc->'received') is distinct from 'boolean' or length(coalesce(doc->>'reference',''))>500 then raise exception 'invalid document';end if;
 if (doc->>'received')::boolean and length(trim(coalesce(doc->>'reference','')))=0 then raise exception 'document reference required';end if;
 end loop;
 select * into old from public.fm_bill_followup where bill_id=k for update;
 if coalesce(old.revision,0)<>coalesce((p->>'revision')::int,0) then raise exception 'version conflict: reload';end if;
 insert into public.fm_bill_followup(bill_id,owner_id,due_at,documents,hold_reason,impact_note,team_id,note,revision,updated_by)
 values(k,own,(p->>'due_at')::timestamptz,p->'documents',coalesce(p->>'hold_reason',''),coalesce(p->>'impact_note',''),tm,trim(p->>'note'),coalesce(old.revision,0)+1,auth.uid())
 on conflict(bill_id) do update set owner_id=excluded.owner_id,due_at=excluded.due_at,documents=excluded.documents,hold_reason=excluded.hold_reason,impact_note=excluded.impact_note,team_id=excluded.team_id,note=excluded.note,revision=excluded.revision,updated_by=excluded.updated_by,updated_at=now() returning * into v;
 insert into public.fm_bill_followup_events(bill_id,by_user,old_value,new_value) values(k,auth.uid(),case when old.bill_id is null then null else to_jsonb(old) end,to_jsonb(v));return to_jsonb(v);
 end $$;
create or replace function public.fm_bfollow_history(k uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
 begin if not public.fm_bfollow_can(k,false) then raise exception 'not allowed';end if;return(select coalesce(jsonb_agg(to_jsonb(e) order by e.at desc,e.id desc),'[]'::jsonb) from public.fm_bill_followup_events e where e.bill_id=k);end $$;
revoke all on function public.fm_close_can(text),public.fm_close_list(text),public.fm_close_save(jsonb),public.fm_close_history(text,text,text),public.fm_bfollow_can(uuid,boolean),public.fm_bfollow_list(),public.fm_bfollow_options(uuid),public.fm_bfollow_save(jsonb),public.fm_bfollow_history(uuid) from public,anon;
grant execute on function public.fm_close_can(text),public.fm_close_list(text),public.fm_close_save(jsonb),public.fm_close_history(text,text,text),public.fm_bfollow_list(),public.fm_bfollow_options(uuid),public.fm_bfollow_save(jsonb),public.fm_bfollow_history(uuid) to authenticated;
notify pgrst,'reload schema';
commit;
