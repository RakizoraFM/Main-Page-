-- V197: subscription enforcement discovered through local PostgreSQL integration tests.
-- Run after V195 on the company project. No user data is changed.
begin;
-- Position-based helpers must honor the same plan state as fm_role().
create or replace function public.fm_my_pos() returns text
language sql stable security definer set search_path=public as $$
 select case when p.active and public.fm_plan_ok() then public.fm_posx(p.role,p.job_title) end
 from public.profiles p where p.id=auth.uid()
$$;
-- Some old SECURITY DEFINER writes check the stored profile directly. Guard the target tables too.
create or replace function public.fm_mod_guard() returns trigger
language plpgsql security definer set search_path=public as $$
begin
 if not public.fm_plan_ok() then raise exception 'subscription expired' using errcode='42501';end if;
 if not public.fm_mod(tg_argv[0]) then raise exception 'module disabled: %',tg_argv[0] using errcode='42501';end if;
 if tg_op='DELETE' then return old;end if;
 return new;
end $$;
do $$ declare x text[];begin
 foreach x slice 1 in array array[
 ['tickets','tickets'],['work_orders','wo'],['wo_schedules','wo'],['wo_issue_requests','wh'],['wo_purchase_requests','wh'],
 ['wo_stock_moves','wh'],['wo_custody_moves','wh'],['fm_eng_logs','eng'],['fm_school_links','portal'],['fm_school_requests','portal'],['fm_expenses','costs'],['fm_budgets','costs']
 ] loop
  if to_regclass('public.'||x[1]) is not null then
   execute format('drop trigger if exists fm_mod_guard on public.%I',x[1]);
   execute format('create trigger fm_mod_guard before insert or update or delete on public.%I for each row execute function public.fm_mod_guard(%L)',x[1],x[2]);
  end if;
 end loop;
end $$;
revoke all on function public.fm_mod_guard() from public,anon,authenticated;
-- Authenticated calls to renewal remain governed by fm_plan_activate's explicit active-admin check.
notify pgrst,'reload schema';
commit;
