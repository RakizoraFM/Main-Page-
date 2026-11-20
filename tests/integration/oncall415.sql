-- V415 — on-call escalation (section 141), LOCAL database only.
\set ON_ERROR_STOP 1
create temp table t415 (n serial, name text, pass boolean, detail text);
grant all on t415 to authenticated; grant usage on sequence t415_n_seq to authenticated;
insert into auth.users (id, email, raw_user_meta_data) values
 ('41500000-0000-4000-8000-000000000001','o.am@rakizora.test','{"full_name":"مدير منطقة المناوبة"}'),
 ('41500000-0000-4000-8000-000000000002','o.eng@rakizora.test','{"full_name":"مهندس مناوب"}'),
 ('41500000-0000-4000-8000-000000000003','o.sup@rakizora.test','{"full_name":"مشرف"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '41500000-%' on conflict (id) do nothing;
update public.profiles p set job_title = x.t, regions = '{qassim}', active = true, phone = '0551234567' from (values ('41500000-0000-4000-8000-000000000001'::uuid,'area_manager'),('41500000-0000-4000-8000-000000000002','area_engineer'),('41500000-0000-4000-8000-000000000003','supervisor')) x(id,t) where p.id = x.id;
update public.profiles set reports_to = '41500000-0000-4000-8000-000000000001' where id = '41500000-0000-4000-8000-000000000002';
insert into public.fm_settings (key, value) values ('wa', '{"enabled":true,"templates":{"oncall":"fm_oncall"}}') on conflict (key) do update set value = excluded.value;
insert into public.tickets (region, ticket_id, school, priority, status, created_at, raw) values
 ('qassim','U1','مدرسة 1','طارئ','جديد', now() - interval '40 minutes','{}'),
 ('qassim','U2','مدرسة 2','طارئ','جديد', now() - interval '70 minutes','{}'),
 ('qassim','U3','مدرسة 3','متوسط','جديد', now() - interval '70 minutes','{}'),
 ('qassim','U4','مدرسة 4','طارئ','جديد', now() - interval '70 minutes','{}'),
 ('qassim','U5','مدرسة 5','طارئ','جديد', now() - interval '10 minutes','{}');
insert into public.ticket_work (region, ticket_id, stage, rec) values ('qassim','U4','assigned','{}');
do $$ declare n int; e text; v uuid; begin
  select public.fm_v415_oncall() into n;
  insert into t415 (name, pass, detail) values ('بلا مناوبة لا شيء', n = 0, n::text);
  perform set_config('request.jwt.claim.sub', '41500000-0000-4000-8000-000000000003', true); set local role authenticated;
  begin perform public.fm_oncall_save(jsonb_build_object('region','qassim','user_id','41500000-0000-4000-8000-000000000002','from',now()-interval '1 hour','to',now()+interval '8 hours')); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t415 (name, pass, detail) values ('المشرف لا يضيف مناوبة', e = 'not allowed', e);
  perform set_config('request.jwt.claim.sub', '41500000-0000-4000-8000-000000000001', true);
  v := public.fm_oncall_save(jsonb_build_object('region','qassim','user_id','41500000-0000-4000-8000-000000000002','from',now()-interval '1 hour','to',now()+interval '8 hours'));
  reset role;
  select public.fm_v415_oncall() into n;
  insert into t415 (name, pass, detail) values ('U1 مستوى 1، U2 مستويان، لا للمتوسط ولا المستلم ولا الحديث', n = 3, n::text);
  select count(*) into n from public.fm_oncall_alerts where ticket_id = 'U2' and level = 2 and '41500000-0000-4000-8000-000000000001' = any(sent_to);
  insert into t415 (name, pass, detail) values ('المستوى 2 لمدير المناوب', n = 1, n::text);
  select public.fm_v415_oncall() into n;
  insert into t415 (name, pass, detail) values ('لا تكرار في التشغيل التالي', n = 0, n::text);
  select count(*) into n from public.fm_wa_queue where kind = 'oncall';
  insert into t415 (name, pass, detail) values ('واتساب عند عدم وجود جهاز', n >= 3, n::text);
end $$;
select n, name, case when pass then 'PASS' else 'FAIL' end res, detail from t415 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t415;
