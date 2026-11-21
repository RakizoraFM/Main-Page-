-- V430 — section 147: assigning work that needs a valid certificate, LOCAL database only.
\set ON_ERROR_STOP 1
create temp table t430 (n serial, name text, pass boolean, detail text);
grant all on t430 to authenticated; grant usage on sequence t430_n_seq to authenticated;
insert into auth.users (id, email, raw_user_meta_data) values ('43000000-0000-4000-8000-000000000001','c.adm@rakizora.test','{"full_name":"أدمن"}'),
  ('43000000-0000-4000-8000-000000000002','c.tech@rakizora.test','{"full_name":"فني الكهرباء"}'),('43000000-0000-4000-8000-000000000003','c.new@rakizora.test','{"full_name":"شخص خارج السجل"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '43000000-%' on conflict (id) do nothing;
update public.profiles set role = 'admin', job_title = 'sysadmin', active = true where id = '43000000-0000-4000-8000-000000000001';
update public.profiles set job_title = 'supervisor', active = true, emp_no = 'E-430' where id in ('43000000-0000-4000-8000-000000000002','43000000-0000-4000-8000-000000000003');
update public.profiles set emp_no = null where id = '43000000-0000-4000-8000-000000000003';
insert into public.fm_people334 (id, region, full_name, employer, job_title, employee_code, active) values ('43000000-0000-4000-8000-0000000000a1','riyadh','فني الكهرباء','الشركة','فني','E-430',true) on conflict do nothing;
insert into public.fm_workforce337_qualifications (region, person_id, kind, title, expires_on) values ('riyadh','43000000-0000-4000-8000-0000000000a1','certificate','رخصة فني كهرباء', current_date - 10);
insert into public.fm_settings (key, value) values ('cert_rules', '{"enabled":true,"mode":"block"}') on conflict (key) do update set value = excluded.value;
do $$ declare e text; j jsonb; begin
  begin insert into public.work_orders (title, assignee, status, created_by) values ('صيانة لوحة الكهرباء الرئيسية', '43000000-0000-4000-8000-000000000002', 'assigned', '43000000-0000-4000-8000-000000000001'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t430 (name, pass, detail) values ('شهادة منتهية → رفض الإسناد', e like 'certificate required:%', e);
  begin insert into public.work_orders (title, assignee, status, created_by) values ('تنظيف الفصول', '43000000-0000-4000-8000-000000000002', 'assigned', '43000000-0000-4000-8000-000000000001'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t430 (name, pass, detail) values ('عمل لا يحتاج شهادة → مسموح', e = 'none', e);
  begin insert into public.work_orders (title, assignee, status, created_by) values ('فحص المصعد', '43000000-0000-4000-8000-000000000003', 'assigned', '43000000-0000-4000-8000-000000000001'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t430 (name, pass, detail) values ('شخص غير موجود في سجل القوى العاملة → لا يُمنع', e = 'none', e);
  update public.fm_workforce337_qualifications set expires_on = current_date + 30 where person_id = '43000000-0000-4000-8000-0000000000a1';
  begin insert into public.work_orders (title, assignee, status, created_by) values ('صيانة لوحة الكهرباء الرئيسية', '43000000-0000-4000-8000-000000000002', 'assigned', '43000000-0000-4000-8000-000000000001'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t430 (name, pass, detail) values ('شهادة سارية → مسموح', e = 'none', e);
  update public.fm_workforce337_qualifications set expires_on = current_date - 1 where person_id = '43000000-0000-4000-8000-0000000000a1';
  update public.fm_settings set value = '{"enabled":true,"mode":"warn"}' where key = 'cert_rules';
  begin insert into public.work_orders (title, assignee, status, created_by) values ('صيانة لوحة الكهرباء', '43000000-0000-4000-8000-000000000002', 'assigned', '43000000-0000-4000-8000-000000000001'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t430 (name, pass, detail) values ('وضع التنبيه فقط → مسموح', e = 'none', e);
  perform set_config('request.jwt.claim.sub', '43000000-0000-4000-8000-000000000001', true); set local role authenticated;
  j := public.fm_wo_cert_check('43000000-0000-4000-8000-000000000002', 'تركيب قواطع كهرباء');
  insert into t430 (name, pass, detail) values ('الفحص قبل الحفظ يذكر الشهادة الناقصة', (j->>'known')::boolean and jsonb_array_length(j->'missing') = 1 and j->>'mode' = 'warn', j::text);
  reset role;
end $$;
select n, name, case when pass then 'PASS' else 'FAIL' end res, detail from t430 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t430;
