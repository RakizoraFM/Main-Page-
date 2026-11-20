-- V402 — Onaizah trial (140 schools) on a LOCAL database that already ran supabase_setup.sql (never on a real project:
-- it writes the school DB in app_kv and test accounts). Run with:  bash tests/integration/onaizah402.sh
-- Accounts (fictitious): project manager, area manager (qassim), area engineer «م. مهندس عنيزة», 4 supervisors
-- (35 schools each), plus an engineer and a supervisor of riyadh for the negative checks.
-- Tickets: per school one طارئ (created 23 h ago → due in 1 h), one عالي (created 50 h ago → 2 h late) and one متوسط
-- (created 10 h ago → due in 62 h). Each check writes one row into t402 (pass / fail + detail); the last query prints them.
\set ON_ERROR_STOP 1
create temp table t402 (n serial, area text, name text, pass boolean, detail text);
grant all on t402 to authenticated; grant usage on sequence t402_n_seq to authenticated;

-- ---------- accounts ----------
insert into auth.users (id, email, raw_user_meta_data) values
 ('40200000-0000-4000-8000-000000000001','onz.pm@rakizora.test','{"full_name":"مدير مشروع عنيزة"}'),
 ('40200000-0000-4000-8000-000000000002','onz.am@rakizora.test','{"full_name":"مدير منطقة القصيم"}'),
 ('40200000-0000-4000-8000-000000000003','onz.eng@rakizora.test','{"full_name":"م. مهندس عنيزة"}'),
 ('40200000-0000-4000-8000-000000000011','onz.sup1@rakizora.test','{"full_name":"مشرف عنيزة 1"}'),
 ('40200000-0000-4000-8000-000000000012','onz.sup2@rakizora.test','{"full_name":"مشرف عنيزة 2"}'),
 ('40200000-0000-4000-8000-000000000013','onz.sup3@rakizora.test','{"full_name":"مشرف عنيزة 3"}'),
 ('40200000-0000-4000-8000-000000000014','onz.sup4@rakizora.test','{"full_name":"مشرف عنيزة 4"}'),
 ('40200000-0000-4000-8000-000000000021','onz.rengr@rakizora.test','{"full_name":"م. مهندس الرياض"}'),
 ('40200000-0000-4000-8000-000000000022','onz.rsup@rakizora.test','{"full_name":"مشرف الرياض"}')
on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '40200000-%' on conflict (id) do nothing;
update public.profiles p set full_name = x.nm, job_title = x.t, regions = x.r, active = true, person_names = array[x.nm], email = x.em
from (values
 ('40200000-0000-4000-8000-000000000001'::uuid,'مدير مشروع عنيزة','project_manager','{}'::text[],'onz.pm@rakizora.test'),
 ('40200000-0000-4000-8000-000000000002','مدير منطقة القصيم','area_manager','{qassim}','onz.am@rakizora.test'),
 ('40200000-0000-4000-8000-000000000003','م. مهندس عنيزة','area_engineer','{qassim}','onz.eng@rakizora.test'),
 ('40200000-0000-4000-8000-000000000011','مشرف عنيزة 1','supervisor','{qassim}','onz.sup1@rakizora.test'),
 ('40200000-0000-4000-8000-000000000012','مشرف عنيزة 2','supervisor','{qassim}','onz.sup2@rakizora.test'),
 ('40200000-0000-4000-8000-000000000013','مشرف عنيزة 3','supervisor','{qassim}','onz.sup3@rakizora.test'),
 ('40200000-0000-4000-8000-000000000014','مشرف عنيزة 4','supervisor','{qassim}','onz.sup4@rakizora.test'),
 ('40200000-0000-4000-8000-000000000021','م. مهندس الرياض','area_engineer','{riyadh}','onz.rengr@rakizora.test'),
 ('40200000-0000-4000-8000-000000000022','مشرف الرياض','supervisor','{riyadh}','onz.rsup@rakizora.test')) x(id, nm, t, r, em) where p.id = x.id;
update public.profiles set reports_to = '40200000-0000-4000-8000-000000000002' where id = '40200000-0000-4000-8000-000000000003';
update public.profiles set reports_to = '40200000-0000-4000-8000-000000000003' where id::text between '40200000-0000-4000-8000-000000000011' and '40200000-0000-4000-8000-000000000014';
update public.profiles set reports_to = '40200000-0000-4000-8000-000000000021' where id = '40200000-0000-4000-8000-000000000022';

-- ---------- 140 schools (school DB) and 420 tickets ----------
insert into public.app_kv (key, value) select 'fm_school_master_db_v1', jsonb_agg(jsonb_build_object(
   'school', 'مدرسة عنيزة ' || g, 'buildingId', 'ONZ' || (1000 + g), 'region', 'qassim', 'office', 'مكتب تعليم عنيزة',
   'supervisor', 'مشرف عنيزة ' || (1 + (g - 1) / 35), 'engineer', 'م. مهندس عنيزة', 'contractor', 'مقاول عنيزة (تجريبي)') order by g)
 from generate_series(1, 140) g
on conflict (key) do update set value = excluded.value, updated_at = now();
delete from public.tickets where ticket_id like 'ONZ-%';
insert into public.tickets (region, ticket_id, school, building_id, supervisor, engineer, contractor, priority, sub_category, status, created_at, raw)
select 'qassim', 'ONZ-' || g || '-' || k, 'مدرسة عنيزة ' || g, 'ONZ' || (1000 + g), 'مشرف عنيزة ' || (1 + (g - 1) / 35), 'م. مهندس عنيزة', 'مقاول عنيزة (تجريبي)',
  (array['طارئ','عالي','متوسط'])[k], 'تكييف', 'جديد', now() - (array[23, 50, 10])[k] * interval '1 hour', '{}'::jsonb
from generate_series(1, 140) g cross join generate_series(1, 3) k;

-- ---------- 1) each supervisor sees his 35 schools and his 105 tickets only ----------
do $$ declare i int; uid uuid; nm text; db jsonb; n int; bad int; tk int; other int;
begin
  for i in 1..4 loop
    uid := ('40200000-0000-4000-8000-00000000001' || i)::uuid; nm := 'مشرف عنيزة ' || i;
    perform set_config('request.jwt.claim.sub', uid::text, true); set local role authenticated;
    db := public.fm_my_school_db(); n := jsonb_array_length(db);
    select count(*) into bad from jsonb_array_elements(db) x where x->>'supervisor' <> nm;
    select count(*) into tk from public.tickets where ticket_id like 'ONZ-%';
    select count(*) into other from public.tickets where ticket_id like 'ONZ-%' and supervisor <> nm;
    reset role;
    insert into t402 (area, name, pass, detail) values ('المشرف', nm || ': مدارسه في قاعدة المدارس', n = 35 and bad = 0, n || ' مدرسة، ' || bad || ' لغيره'),
      ('المشرف', nm || ': بلاغاته فقط', tk = 105 and other = 0, tk || ' بلاغ، ' || other || ' لغيره');
  end loop;
end $$;
-- the engineer sees the whole team (420), riyadh accounts see nothing of Onaizah
do $$ declare tk int; r1 int; r2 int; begin
  perform set_config('request.jwt.claim.sub', '40200000-0000-4000-8000-000000000003', true); set local role authenticated;
  select count(*) into tk from public.tickets where ticket_id like 'ONZ-%'; reset role;
  perform set_config('request.jwt.claim.sub', '40200000-0000-4000-8000-000000000021', true); set local role authenticated;
  select count(*) into r1 from public.tickets where ticket_id like 'ONZ-%'; reset role;
  perform set_config('request.jwt.claim.sub', '40200000-0000-4000-8000-000000000022', true); set local role authenticated;
  select count(*) into r2 from public.tickets where ticket_id like 'ONZ-%'; reset role;
  insert into t402 (area, name, pass, detail) values ('المهندس', 'مهندس عنيزة يرى بلاغات فريقه كلها', tk = 420, tk || ' بلاغ'),
    ('العزل', 'مهندس ومشرف الرياض لا يريان بلاغات عنيزة', r1 = 0 and r2 = 0, r1 || ' / ' || r2);
end $$;

-- ---------- 2) the deadlines 24 / 48 / 72 in the alert list (fm_sla_watch: due = created + the priority's hours) ----------
insert into public.fm_settings (key, value) values ('sla_warn', '{"enabled":true,"hours":2,"quiet_from":0,"quiet_to":0,"morning":0}')
  on conflict (key) do update set value = excluded.value;
do $$ declare n int; begin
  perform set_config('request.jwt.claim.sub', '40200000-0000-4000-8000-000000000002', true); set local role authenticated;
  n := public.fm_sla_watch_set('qassim', jsonb_build_object('rows', (select jsonb_agg(jsonb_build_object('t', ticket_id, 's', school, 'b', building_id, 'p', priority, 'c', 'تكييف',
         'due', to_char((created_at + (case priority when 'طارئ' then 24 when 'عالي' then 48 else 72 end) * interval '1 hour') at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
         'sup', supervisor, 'eng', engineer)) from public.tickets where ticket_id like 'ONZ-%' and priority <> 'عالي')));
  reset role;
  insert into t402 (area, name, pass, detail) values ('المهل', 'رفع قائمة المهل المفتوحة (280 بلاغ غير متأخر)', n = 280, n || ' صف');
end $$;
do $$ declare j jsonb; mine int; h24 int; h72 int; bad int; begin
  perform set_config('request.jwt.claim.sub', '40200000-0000-4000-8000-000000000011', true); set local role authenticated;
  j := public.fm_sla_watch_list(); reset role;
  select count(*) filter (where (x->>'mine')::boolean), count(*) filter (where x->>'p' = 'طارئ'), count(*) filter (where x->>'p' = 'متوسط')
    into mine, h24, h72 from jsonb_array_elements(j->'rows') x;
  select count(*) into bad from jsonb_array_elements(j->'rows') x join public.tickets t on t.region = x->>'region' and t.ticket_id = x->>'t'
   where abs(extract(epoch from (x->>'due')::timestamptz - t.created_at) / 3600 - case t.priority when 'طارئ' then 24 when 'عالي' then 48 else 72 end) > 0.01;
  insert into t402 (area, name, pass, detail) values ('المهل', 'المشرف 1 يرى مهل بلاغاته فقط في قائمة التنبيه', mine = 70 and h24 = 35 and h72 = 35 and jsonb_array_length(j->'rows') = 70,
      jsonb_array_length(j->'rows') || ' صف (طارئ ' || h24 || '، متوسط ' || h72 || ')'),
    ('المهل', 'كل مهلة = وقت البلاغ + 24 / 48 / 72 ساعة حسب الأولوية', bad = 0, bad || ' مخالفة');
end $$;
-- the alert itself: a fake device per supervisor, push on; the run warns about the طارئ tickets due within 2 h only
insert into public.fm_settings (key, value) values ('push', '{"enabled":true}') on conflict (key) do update set value = public.fm_settings.value || '{"enabled":true}';
insert into public.fm_push_subs (user_id, endpoint, p256dh, auth)
select ('40200000-0000-4000-8000-00000000001' || i)::uuid, 'https://push.invalid/onz' || i, 'x', 'y' from generate_series(1, 4) i on conflict do nothing;
delete from public.fm_push_queue where user_id::text like '40200000-%';
select public.fm_sla_warn_run();
do $$ declare n int; m int; t text; begin
  select count(*), count(distinct user_id), min(title) into n, m, t from public.fm_push_queue where user_id::text like '40200000-0000-4000-8000-00000000001%' and kind = 'sla_due' and tag = 'sla';
  insert into t402 (area, name, pass, detail) values ('التنبيه', 'تنبيه قبل التجاوز لكل مشرف (35 بلاغاً طارئاً تنتهي خلال ساعتين)', m = 4 and t like '%35 بلاغات%', n || ' تنبيه — ' || coalesce(t, '—'));
  select count(*) into n from public.fm_sla_watch where ticket_id like 'ONZ-%' and warned_at is not null;
  insert into t402 (area, name, pass, detail) values ('التنبيه', 'لا تنبيه لبلاغات 72 ساعة (ما زال أمامها 62 ساعة)', n = 140, n || ' بلاغ نُبّه عليه');
end $$;
select public.fm_sla_warn_run() as second_run \gset
insert into t402 (area, name, pass, detail) select 'التنبيه', 'لا يتكرر التنبيه في التشغيل التالي', (select count(*) from public.fm_push_queue where user_id::text like '40200000-%' and kind = 'sla_due' and tag = 'sla') = 4, '';
-- the morning digest («☀️ يومي») lists today's deadlines of the supervisor
do $$ declare j jsonb; begin
  perform set_config('request.jwt.claim.sub', '40200000-0000-4000-8000-000000000012', true); set local role authenticated;
  j := public.fm_digest_lists(); reset role;
  insert into t402 (area, name, pass, detail) values ('التنبيه', 'صفحة «☀️ يومي» للمشرف 2 تعرض بلاغات تنتهي مهلتها اليوم', jsonb_array_length(coalesce(j->'sla_today','[]')) between 1 and 20,
    jsonb_array_length(coalesce(j->'sla_today','[]')) || ' (يعرض حتى 20)');
end $$;

-- ---------- 3) the engineer reviews the closure of an urgent ticket ----------
insert into public.app_kv (key, value) values ('fm_work_rules_v135', '{"urgent":true}') on conflict (key) do update set value = public.app_kv.value || '{"urgent":true}';
do $$ declare id1 uuid; id2 uuid; ok text; l jsonb; e text := ''; begin
  perform set_config('request.jwt.claim.sub', '40200000-0000-4000-8000-000000000011', true); set local role authenticated;
  insert into public.ticket_work (region, ticket_id, stage, rec, resolved_at) values
    ('qassim', 'ONZ-1-1', 'resolved', '{"stage":"resolved","resolution":{"desc":"تنظيف وتعبئة غاز"}}', now()),
    ('qassim', 'ONZ-2-1', 'resolved', '{"stage":"resolved","resolution":{"desc":"تغيير مكثف"}}', now());
  reset role;
  select id into id1 from public.fm_tk_close_rev where ticket_id = 'ONZ-1-1'; select id into id2 from public.fm_tk_close_rev where ticket_id = 'ONZ-2-1';
  set local role authenticated;
  begin perform public.fm_tk_close_act(id1, 'approve', ''); e := 'allowed'; exception when others then e := sqlerrm; end;
  reset role;
  insert into t402 (area, name, pass, detail) values ('مراجعة الإغلاق', 'إغلاق بلاغ طارئ ينشئ طلب مراجعة', (select count(*) from public.fm_tk_close_rev where ticket_id in ('ONZ-1-1','ONZ-2-1') and status = 'pending') = 2, ''),
    ('مراجعة الإغلاق', 'المشرف لا يعتمد إغلاقه بنفسه', e <> 'allowed', e);
  perform set_config('request.jwt.claim.sub', '40200000-0000-4000-8000-000000000003', true); set local role authenticated;
  l := public.fm_tk_close_list('qassim');
  ok := public.fm_tk_close_act(id1, 'approve', '');
  perform public.fm_tk_close_act(id2, 'return', 'لم تُرفق صورة بعد الإصلاح');
  reset role;
  insert into t402 (area, name, pass, detail) values ('مراجعة الإغلاق', 'المهندس يرى طلبات المراجعة لمنطقته', l::text like '%ONZ-1-1%', ''),
    ('مراجعة الإغلاق', 'المهندس يعتمد الإغلاق', (select status from public.fm_tk_close_rev where id = id1) = 'approved', ok),
    ('مراجعة الإغلاق', 'المهندس يعيد الإغلاق للتنفيذ بملاحظة', (select stage from public.ticket_work where ticket_id = 'ONZ-2-1') = 'progress'
      and (select rec->>'returnNote' from public.ticket_work where ticket_id = 'ONZ-2-1') like 'لم تُرفق%', (select stage from public.ticket_work where ticket_id = 'ONZ-2-1'));
  perform set_config('request.jwt.claim.sub', '40200000-0000-4000-8000-000000000021', true); set local role authenticated;
  e := ''; begin perform public.fm_tk_close_list('qassim'); l := public.fm_tk_close_list('qassim'); exception when others then e := sqlerrm; end;
  reset role;
  insert into t402 (area, name, pass, detail) values ('مراجعة الإغلاق', 'مهندس الرياض لا يرى مراجعات عنيزة', e <> '' or coalesce(l::text, '') not like '%ONZ-1-1%', coalesce(nullif(e,''), 'قائمة فارغة'));
end $$;

select n, area, name, case when pass then 'PASS' else 'FAIL' end res, detail from t402 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t402;
