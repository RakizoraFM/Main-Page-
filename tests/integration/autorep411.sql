-- V411 — automatic repair order on approval (section 139), LOCAL database only.  runner: bash tests/integration/onaizah402.sh <db> this-file
\set ON_ERROR_STOP 1
create temp table t411 (n serial, name text, pass boolean, detail text);
insert into auth.users (id, email, raw_user_meta_data) values
 ('41100000-0000-4000-8000-000000000001','a.eng@rakizora.test','{"full_name":"مهندس الإصلاح"}'),
 ('41100000-0000-4000-8000-000000000002','a.sup@rakizora.test','{"full_name":"مشرف الإصلاح"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '41100000-%' on conflict (id) do nothing;
update public.profiles p set job_title = x.t, regions = '{qassim}', active = true from (values ('41100000-0000-4000-8000-000000000001'::uuid,'area_engineer'),('41100000-0000-4000-8000-000000000002','supervisor')) x(id,t) where p.id = x.id;
update public.profiles set reports_to = '41100000-0000-4000-8000-000000000001' where id = '41100000-0000-4000-8000-000000000002';
do $$ declare w1 uuid; w2 uuid; n int; t text; begin
  perform set_config('request.jwt.claim.sub', '41100000-0000-4000-8000-000000000001', true); set local role authenticated;
  w1 := public.fm_wo_create(jsonb_build_object('title','وقائية 1','type','preventive','assignee','41100000-0000-4000-8000-000000000002','school','مدرسة أ','region','qassim',
    'checklist','[{"t":"فحص المضخة","res":"fix","note":"تسريب"},{"t":"فحص اللوحة","res":"ok"}]'::jsonb));
  w2 := public.fm_wo_create(jsonb_build_object('title','وقائية 2','type','preventive','assignee','41100000-0000-4000-8000-000000000002','school','مدرسة ب','region','qassim',
    'checklist','[{"t":"فحص المضخة","res":"fix"}]'::jsonb));
  reset role;
  update public.work_orders set status = 'closed', closed_at = now() where id = w1;
  select count(*) into n from public.work_orders where source_wo = w1;
  insert into t411 (name, pass, detail) values ('الإعداد مغلق افتراضياً: لا أمر إصلاح', n = 0, n::text);
  insert into public.fm_settings (key, value) values ('wo_auto_repair', '{"enabled":true}') on conflict (key) do update set value = excluded.value;
  update public.work_orders set status = 'closed', closed_at = now() where id = w2;
  select count(*), min(type) || '/' || min(assignee::text) into n, t from public.work_orders where source_wo = w2;
  insert into t411 (name, pass, detail) values ('مع التفعيل: أمر إصلاح واحد للمنفّذ نفسه', n = 1 and t = 'repair/41100000-0000-4000-8000-000000000002', n || ' ' || t);
  select count(*) into n from public.work_orders where id = w2 and checklist->0->>'rwo' like 'WO-%';
  insert into t411 (name, pass, detail) values ('البند يحمل رقم أمر الإصلاح ويُسجَّل حدث', n = 1 and exists (select 1 from public.wo_events where wo_id = w2 and text like '🤖%'), n::text);
  update public.work_orders set status = 'in_progress' where id = w2; update public.work_orders set status = 'closed' where id = w2;
  select count(*) into n from public.work_orders where source_wo = w2;
  insert into t411 (name, pass, detail) values ('إعادة الاعتماد لا تكرر أمر الإصلاح', n = 1, n::text);
end $$;
select n, name, case when pass then 'PASS' else 'FAIL' end res, detail from t411 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t411;
