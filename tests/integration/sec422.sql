-- V422 — section 145: permission functions answer false (never NULL) and the scheduled-jobs health, LOCAL database only.
\set ON_ERROR_STOP 1
create temp table t422 (n serial, name text, pass boolean, detail text);
grant all on t422 to authenticated; grant usage on sequence t422_n_seq to authenticated;
insert into auth.users (id, email, raw_user_meta_data) values ('42200000-0000-4000-8000-000000000001','s.adm@rakizora.test','{"full_name":"أدمن"}'),
  ('42200000-0000-4000-8000-000000000002','s.pend@rakizora.test','{"full_name":"جديد"}'),('42200000-0000-4000-8000-000000000003','s.acc@rakizora.test','{"full_name":"محاسب"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '42200000-%' on conflict (id) do nothing;
update public.profiles set role = 'admin', job_title = 'sysadmin', active = true where id = '42200000-0000-4000-8000-000000000001';
update public.profiles set role = 'pending', job_title = null, active = true where id = '42200000-0000-4000-8000-000000000002';
update public.profiles set job_title = 'accountant', active = true where id = '42200000-0000-4000-8000-000000000003';
create or replace function public.fm_try_bool(f text) returns boolean language plpgsql as $f$ declare v boolean; begin execute format('select public.%I()', f) into v; return v; exception when others then return false; end $f$;
grant execute on function public.fm_try_bool(text) to authenticated;
-- a fake pg_cron when the extension is not installed locally
do $$ begin if to_regclass('cron.job') is null then
  create schema cron; create table cron.job(jobid bigserial primary key, schedule text, command text, jobname text, active boolean default true);
  create table cron.job_run_details(runid bigserial, jobid bigint, start_time timestamptz, end_time timestamptz, status text, return_message text);
  insert into cron.job(schedule, command, jobname) values ('* * * * *','select 1','fm-push-flush'),('0 5 * * *','select 2','fm-push-daily');
  insert into cron.job_run_details(jobid, start_time, end_time, status, return_message) values (1, now() - interval '1 minute', now(), 'succeeded', '1'), (2, now() - interval '2 hours', now(), 'failed', 'ERROR: boom');
end if; end $$;
do $$ declare e text; j jsonb; u text; begin
  -- 1) a pending account and a signed-in account without a profile are refused
  foreach u in array array['42200000-0000-4000-8000-000000000002','42200000-0000-4000-8000-0000000000ff'] loop
    perform set_config('request.jwt.claim.sub', u, true); set local role authenticated;
    begin perform public.fm_acct_journal(current_date - 5, current_date); e := 'none'; exception when others then e := sqlerrm; end;
    insert into t422 (name, pass, detail) values ('القيود المحاسبية مرفوضة — ' || right(u, 2), e = 'not allowed', e);
    begin perform public.fm_gov_report(30); e := 'none'; exception when others then e := sqlerrm; end;
    insert into t422 (name, pass, detail) values ('تقرير الحوكمة مرفوض — ' || right(u, 2), e = 'not allowed', e);
    begin perform public.fm_payroll(to_char(now(), 'YYYY-MM')); e := 'none'; exception when others then e := sqlerrm; end;
    insert into t422 (name, pass, detail) values ('ملف الرواتب مرفوض — ' || right(u, 2), e = 'not allowed', e);
    begin perform public.fm_jobs_health(); e := 'none'; exception when others then e := sqlerrm; end;
    insert into t422 (name, pass, detail) values ('صحة المهام لمدير النظام فقط — ' || right(u, 2), e = 'not allowed', e);
    insert into t422 (name, pass, detail) values ('fm_my_pos = none / fm_role = pending — ' || right(u, 2), public.fm_my_pos() = 'none' and public.fm_role() = 'pending', public.fm_my_pos() || ' / ' || public.fm_role());
    reset role;
  end loop;
  -- 2) every boolean fm_* function of no argument answers false (never NULL) for the pending account
  perform set_config('request.jwt.claim.sub', '42200000-0000-4000-8000-000000000002', true);
  select string_agg(p.proname, ' ') into e from pg_proc p where p.pronamespace = 'public'::regnamespace and p.prorettype = 'bool'::regtype and p.pronargs = 0 and p.proname like 'fm\_%'
    and p.proname not in ('fm_plan_ok','fm_wo_visit_on','fm_v374_ok','fm_v422_watch') and public.fm_try_bool(p.proname) is distinct from false;
  insert into t422 (name, pass, detail) values ('كل دوال الصلاحيات بلا معامل = false للحساب الجديد', e is null, coalesce(e, '—'));
  -- 3) the accountant and the system admin keep their access
  perform set_config('request.jwt.claim.sub', '42200000-0000-4000-8000-000000000003', true); set local role authenticated;
  begin perform public.fm_acct_journal(current_date - 5, current_date); e := 'ok'; exception when others then e := sqlerrm; end;
  insert into t422 (name, pass, detail) values ('المحاسب يقرأ القيود', e = 'ok', e);
  perform set_config('request.jwt.claim.sub', '42200000-0000-4000-8000-000000000001', true);
  j := public.fm_jobs_health();
  insert into t422 (name, pass, detail) values ('مدير النظام يرى المهام', jsonb_array_length(j->'jobs') >= 2, jsonb_array_length(j->'jobs')::text);
  insert into t422 (name, pass, detail) values ('مهمة فاشلة تظهر في المشكلات', j->'problems' ? 'fail:fm-push-daily', (j->'problems')::text);
  insert into t422 (name, pass, detail) values ('المهام الناقصة تظهر', jsonb_array_length(j->'missing') > 0, (j->'missing')::text);
  reset role;
  -- 4) the watcher alerts once per day per list of problems
  insert into t422 (name, pass, detail) values ('التنبيه مرة واحدة لنفس المشكلات', public.fm_v422_watch() >= 1 and public.fm_v422_watch() = 0, (select count(*) from public.fm_jobs_alerts)::text);
end $$;
select n, name, case when pass then 'PASS' else 'FAIL' end res, detail from t422 order by n;
drop function public.fm_try_bool(text);
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t422;
