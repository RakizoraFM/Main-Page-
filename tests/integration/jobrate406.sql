-- V406 — school rating per closed ticket / work order on a LOCAL database after supabase_setup.sql
-- runner: bash tests/integration/onaizah402.sh <db> tests/integration/jobrate406.sql   (never a real project)
\set ON_ERROR_STOP 1
create temp table t406 (n serial, area text, name text, pass boolean, detail text);
grant all on t406 to anon, authenticated; grant usage on sequence t406_n_seq to anon, authenticated;
insert into auth.users (id, email, raw_user_meta_data) values
 ('40600000-0000-4000-8000-000000000001','r.am@rakizora.test','{"full_name":"مدير منطقة التقييم"}'),
 ('40600000-0000-4000-8000-000000000002','r.eng@rakizora.test','{"full_name":"مهندس التقييم"}'),
 ('40600000-0000-4000-8000-000000000003','r.sup@rakizora.test','{"full_name":"مشرف التقييم"}'),
 ('40600000-0000-4000-8000-000000000004','r.osup@rakizora.test','{"full_name":"مشرف منطقة أخرى"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '40600000-%' on conflict (id) do nothing;
update public.profiles p set full_name = x.nm, job_title = x.t, regions = x.r, active = true, person_names = array[x.nm], phone = '0500000' || right(x.id::text, 3)
from (values ('40600000-0000-4000-8000-000000000001'::uuid,'مدير منطقة التقييم','area_manager','{qassim}'::text[]),
 ('40600000-0000-4000-8000-000000000002','مهندس التقييم','area_engineer','{qassim}'),('40600000-0000-4000-8000-000000000003','مشرف التقييم','supervisor','{qassim}'),
 ('40600000-0000-4000-8000-000000000004','مشرف منطقة أخرى','supervisor','{riyadh}')) x(id, nm, t, r) where p.id = x.id;
update public.profiles set reports_to = '40600000-0000-4000-8000-000000000002' where id = '40600000-0000-4000-8000-000000000003';
update public.profiles set reports_to = '40600000-0000-4000-8000-000000000001' where id = '40600000-0000-4000-8000-000000000002';
insert into public.app_kv (key, value) values ('fm_school_master_db_v1', '[{"buildingId":"S406001","school":"مدرسة التقييم الأولى","principalPhone":"0551112223","contractor":"مقاول التقييم","region":"القصيم"}]')
 on conflict (key) do update set value = excluded.value;
insert into public.fm_settings (key, value) values ('wa', '{"enabled":true,"base_url":"https://example.test","templates":{"job_rate":"fm_job_rate"}}')
 on conflict (key) do update set value = excluded.value;
-- 1) a work order closed → one rating + one WhatsApp
do $$ declare w uuid; n int; q int; begin
  perform set_config('request.jwt.claim.sub', '40600000-0000-4000-8000-000000000001', true); set local role authenticated;
  w := public.fm_wo_create(jsonb_build_object('title','إصلاح إنارة','type','repair','assignee','40600000-0000-4000-8000-000000000003','approver','40600000-0000-4000-8000-000000000002',
    'school','مدرسة التقييم الأولى','building_id','S406001','region','qassim','priority','عالي'));
  reset role;
  perform set_config('t406.wo', w::text, false);
  update public.work_orders set status = 'done', done_at = now() where id = w;
  select count(*) into n from public.fm_job_ratings where kind = 'wo' and ref = w::text;
  insert into t406 (area,name,pass,detail) values ('أمر العمل','«تم الإجراء» لا يُنشئ تقييماً', n = 0, n::text);
  update public.work_orders set status = 'closed', closed_at = now() where id = w;
  update public.work_orders set status = 'closed', updated_at = now() where id = w;
  select count(*) into n from public.fm_job_ratings where kind = 'wo' and ref = w::text and sup_id = '40600000-0000-4000-8000-000000000003' and contractor = 'مقاول التقييم';
  select count(*) into q from public.fm_wa_queue where kind = 'job_rate' and phone like '9665%';
  insert into t406 (area,name,pass,detail) values ('أمر العمل','اعتماد الأمر يُنشئ تقييماً واحداً بالمشرف والمقاول من القاعدة', n = 1, n::text),
    ('أمر العمل','رسالة واتساب واحدة لمدير المدرسة', q = 1, q::text);
end $$;
-- 2) tickets: a closed first upload asks nothing; open → closed asks once; a ticket closed through its order is skipped
insert into public.tickets (region, ticket_id, school, building_id, supervisor, engineer, contractor, priority, sub_category, status, created_at, raw) values
 ('qassim','T406-1','مدرسة التقييم الأولى','S406001','مشرف التقييم','مهندس التقييم',null,'متوسط','كهرباء','مغلق', now() - interval '2 days','{}'),
 ('qassim','T406-2','مدرسة التقييم الأولى','S406001','مشرف التقييم','مهندس التقييم',null,'متوسط','سباكة','جديد', now() - interval '2 days','{}'),
 ('qassim','T406-3','مدرسة التقييم الأولى','S406001','مشرف التقييم','مهندس التقييم',null,'متوسط','تكييف','جديد', now() - interval '2 days','{}'),
 ('qassim','T406-4','مدرسة التقييم الأولى','S406001','مشرف التقييم','مهندس التقييم',null,'متوسط','تكييف','جديد', now() - interval '2 days','{}'),
 ('qassim','T406-5','مدرسة التقييم الأولى','S406001','مشرف التقييم','مهندس التقييم',null,'متوسط','تكييف','جديد', now() - interval '200 days','{}');
update public.tickets set status = 'مغلق' where ticket_id in ('T406-2','T406-5');
update public.tickets set status = 'مغلق' where ticket_id = 'T406-2';
insert into public.ticket_work (region, ticket_id, stage, rec) values ('qassim','T406-3','resolved','{}'), ('qassim','T406-4','resolved','{"woCode":"WO-1"}');
insert into t406 (area,name,pass,detail) select 'البلاغات','بلاغ مرفوع مغلقاً من البداية بلا تقييم', count(*) = 0, count(*)::text from public.fm_job_ratings where ref = 'T406-1';
insert into t406 (area,name,pass,detail) select 'البلاغات','تحوّل الحالة إلى مغلق يُنشئ تقييماً واحداً', count(*) = 1, count(*)::text from public.fm_job_ratings where ref = 'T406-2';
insert into t406 (area,name,pass,detail) select 'البلاغات','بلاغ أقدم من 60 يوماً بلا تقييم', count(*) = 0, count(*)::text from public.fm_job_ratings where ref = 'T406-5';
insert into t406 (area,name,pass,detail) select 'البلاغات','إغلاق السجل الميداني يُنشئ تقييماً بالمشرف المطابق للحساب', count(*) = 1, count(*)::text from public.fm_job_ratings where ref = 'T406-3' and sup_id = '40600000-0000-4000-8000-000000000003';
insert into t406 (area,name,pass,detail) select 'البلاغات','البلاغ المغلق بأمر عمله لا يُقيَّم مرتين', count(*) = 0, count(*)::text from public.fm_job_ratings where ref = 'T406-4';
insert into t406 (area,name,pass,detail) select 'واتساب','حد 3 رسائل يومياً لكل مدرسة', count(*) = 3, count(*)::text from public.fm_job_ratings where bkey = public.fm_bkey('S406001', null) and wa_at is not null;
-- 3) anon link
do $$ declare tk text; i jsonb; e text; begin
  select token into tk from public.fm_job_ratings where ref = current_setting('t406.wo');
  set local role anon;
  i := public.fm_job_rate_info(tk);
  insert into t406 (area,name,pass,detail) values ('الرابط','معلومات الرابط للزائر', i->>'state' = 'ok' and i->>'school' = 'مدرسة التقييم الأولى', i::text);
  begin perform public.fm_job_rate_submit(tk, '{"score":7}'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t406 (area,name,pass,detail) values ('الرابط','درجة خارج 1–5 مرفوضة', e = 'invalid rating', e);
  perform public.fm_job_rate_submit(tk, '{"score":2,"q_speed":1,"comment":"تأخر التنفيذ"}');
  begin perform public.fm_job_rate_submit(tk, '{"score":5}'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t406 (area,name,pass,detail) values ('الرابط','لا يُستخدم الرابط مرتين', e = 'already rated', e);
  reset role;
end $$;
insert into t406 (area,name,pass,detail) select 'المتابعة','تقييم ≤ 2 يفتح متابعة', fu_status = 'open', coalesce(fu_status,'-') from public.fm_job_ratings where ref = current_setting('t406.wo');
insert into t406 (area,name,pass,detail) select 'المتابعة','إشعار مدير المشرف بالتقييم المنخفض (واتساب عند عدم وجود جهاز)', count(*) >= 1, count(*)::text
  from public.fm_wa_queue where kind = 'job_rate' and ref like 'jr-%';
-- 4) school portal
do $$ declare j jsonb; e text; rid bigint; begin
  insert into public.fm_school_links (token, bkey, school_name, region) values (repeat('a',64), public.fm_bkey('S406001', null), 'مدرسة التقييم الأولى', 'qassim'),
    (repeat('b',64), public.fm_bkey('S999', null), 'مدرسة أخرى', 'qassim');
  set local role anon;
  j := public.fm_school_jobs(repeat('a',64));
  insert into t406 (area,name,pass,detail) values ('البوابة','البوابة تعرض الأعمال بانتظار التقييم والمقيّمة', jsonb_array_length(j->'wait') = 2 and jsonb_array_length(j->'done') = 1, j::text);
  rid := (j->'wait'->0->>'id')::bigint;
  begin perform public.fm_school_job_rate(repeat('b',64), rid, '{"score":4}'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t406 (area,name,pass,detail) values ('البوابة','مدرسة أخرى لا تقيّم عمل غيرها', e = 'invalid link', e);
  perform public.fm_school_job_rate(repeat('a',64), rid, '{"score":5}');
  reset role;
  insert into t406 (area,name,pass,detail) select 'البوابة','التقييم من البوابة محفوظ', score = 5 and src = 'portal', score || src from public.fm_job_ratings where id = rid;
end $$;
-- 5) staff visibility and follow-up
do $$ declare j jsonb; e text; rid bigint; begin
  select id into rid from public.fm_job_ratings where ref = current_setting('t406.wo');
  perform set_config('request.jwt.claim.sub', '40600000-0000-4000-8000-000000000003', true); set local role authenticated;
  j := public.fm_job_ratings_list(90);
  insert into t406 (area,name,pass,detail) values ('الصلاحيات','المشرف يرى تقييمات أعماله', jsonb_array_length(j->'rows') = 3, jsonb_array_length(j->'rows')::text);
  begin perform public.fm_job_rate_follow(rid, 'تمت المعالجة'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t406 (area,name,pass,detail) values ('الصلاحيات','المشرف لا يغلق متابعة تقييمه بنفسه', e = 'not allowed', e);
  perform set_config('request.jwt.claim.sub', '40600000-0000-4000-8000-000000000004', true);
  j := public.fm_job_ratings_list(90);
  insert into t406 (area,name,pass,detail) values ('الصلاحيات','مشرف آخر لا يرى شيئاً', jsonb_array_length(j->'rows') = 0, jsonb_array_length(j->'rows')::text);
  perform set_config('request.jwt.claim.sub', '40600000-0000-4000-8000-000000000002', true);
  j := public.fm_job_ratings_list(90);
  perform public.fm_job_rate_follow(rid, 'تمت زيارة المدرسة ومعالجة التأخير');
  insert into t406 (area,name,pass,detail) values ('الصلاحيات','المهندس يرى (فريقه ومنطقته) ويغلق المتابعة', jsonb_array_length(j->'rows') = 3, jsonb_array_length(j->'rows')::text);
  reset role;
  set local role anon;
  begin perform public.fm_job_ratings_list(90); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t406 (area,name,pass,detail) values ('الصلاحيات','الزائر لا يقرأ القائمة', e like 'permission denied%', e);
  reset role;
end $$;
insert into t406 (area,name,pass,detail) select 'المتابعة','إغلاق المتابعة بملاحظة', fu_status = 'closed' and fu_name = 'مهندس التقييم', fu_status from public.fm_job_ratings where ref = current_setting('t406.wo');
select n, area, name, case when pass then 'PASS' else 'FAIL' end res, left(detail, 140) detail from t406 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t406;
