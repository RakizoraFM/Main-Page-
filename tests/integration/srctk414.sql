-- V414 — sources with a tickets target (section 140), LOCAL database only.
\set ON_ERROR_STOP 1
create temp table t414 (n serial, name text, pass boolean, detail text);
insert into auth.users (id, email, raw_user_meta_data) values ('41400000-0000-4000-8000-000000000001','s.adm@rakizora.test','{"full_name":"مدير النظام"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) values ('41400000-0000-4000-8000-000000000001','s.adm@rakizora.test','مدير النظام','admin') on conflict (id) do nothing;
update public.profiles set role = 'admin', job_title = 'sysadmin', active = true where id = '41400000-0000-4000-8000-000000000001';
do $$ declare v uuid; e text; r public.fm_sources; begin
  perform set_config('request.jwt.claim.sub', '41400000-0000-4000-8000-000000000001', true); set local role authenticated;
  v := public.fm_source_save('{"name":"بلاغات القصيم","url":"https://docs.google.com/spreadsheets/d/x/edit","target":"tickets:qassim","full_list":true}');
  begin perform public.fm_source_save('{"name":"x","url":"https://docs.google.com/spreadsheets/d/x/edit","target":"tickets:Q-1"}'); e := 'none'; exception when others then e := sqlerrm; end;
  perform public.fm_source_tickets_done(v, 120, null);
  reset role;
  select * into r from public.fm_sources where id = v;
  insert into t414 (name, pass, detail) values ('حفظ مصدر بوجهة بلاغات منطقة', r.target = 'tickets:qassim' and not r.full_list, r.target || ' ' || r.full_list),
    ('وجهة غير صحيحة مرفوضة', e = 'bad source', e), ('تسجيل نتيجة السحب', r.last_rows = 120 and r.last_ok, r.last_rows || ' ' || r.last_ok);
  set local role authenticated;
  v := public.fm_source_save('{"name":"مدارس","url":"https://docs.google.com/spreadsheets/d/y/edit"}');
  reset role;
  insert into t414 (name, pass, detail) select 'المصدر القديم بلا وجهة = قاعدة المدارس', target = 'schooldb', target from public.fm_sources where id = v;
end $$;
select n, name, case when pass then 'PASS' else 'FAIL' end res, detail from t414 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t414;
