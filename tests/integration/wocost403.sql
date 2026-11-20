-- V403 — work-order cost ledger on a LOCAL database after supabase_setup.sql (runner: tests/integration/onaizah402.sh <db> this-file).
-- Path: an approved order → its checklist part taken out at approval, a spare part issued afterwards, a contractor service →
-- the cost on the building and the project. Main check: a retry with the same client id never records the same cost twice.
\set ON_ERROR_STOP 1
create temp table t403 (n serial, area text, name text, pass boolean, detail text);
grant all on t403 to authenticated; grant usage on sequence t403_n_seq to authenticated;
insert into auth.users (id, email, raw_user_meta_data) values
 ('40300000-0000-4000-8000-000000000001','c.am@rakizora.test','{"full_name":"مدير منطقة التكلفة"}'),
 ('40300000-0000-4000-8000-000000000002','c.eng@rakizora.test','{"full_name":"م. مهندس التكلفة"}'),
 ('40300000-0000-4000-8000-000000000003','c.sup@rakizora.test','{"full_name":"مشرف التكلفة"}'),
 ('40300000-0000-4000-8000-000000000004','c.store@rakizora.test','{"full_name":"أمين مستودع التكلفة"}'),
 ('40300000-0000-4000-8000-000000000005','c.acc@rakizora.test','{"full_name":"محاسب التكلفة"}'),
 ('40300000-0000-4000-8000-000000000006','c.rsup@rakizora.test','{"full_name":"مشرف منطقة أخرى"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '40300000-%' on conflict (id) do nothing;
update public.profiles p set full_name = x.nm, job_title = x.t, regions = x.r, active = true, person_names = array[x.nm]
from (values ('40300000-0000-4000-8000-000000000001'::uuid,'مدير منطقة التكلفة','area_manager','{qassim}'::text[]),
 ('40300000-0000-4000-8000-000000000002','م. مهندس التكلفة','area_engineer','{qassim}'),('40300000-0000-4000-8000-000000000003','مشرف التكلفة','supervisor','{qassim}'),
 ('40300000-0000-4000-8000-000000000004','أمين مستودع التكلفة','storekeeper','{qassim}'),('40300000-0000-4000-8000-000000000005','محاسب التكلفة','accountant','{qassim}'),
 ('40300000-0000-4000-8000-000000000006','مشرف منطقة أخرى','supervisor','{riyadh}')) x(id, nm, t, r) where p.id = x.id;
update public.profiles set reports_to = '40300000-0000-4000-8000-000000000001' where id = '40300000-0000-4000-8000-000000000002';
update public.profiles set reports_to = '40300000-0000-4000-8000-000000000002' where id = '40300000-0000-4000-8000-000000000003';
-- a store with a keeper, an approved item at 100 SAR, 10 received; an ERP project
insert into public.wo_stores (id, name, region, is_default, active, keeper) values ('40300000-0000-4000-8000-0000000000a1', 'مستودع عنيزة', 'qassim', true, true, '40300000-0000-4000-8000-000000000004') on conflict (id) do nothing;
insert into public.wo_materials (id, code, name, unit, price, category, active, approval, approved_at) values ('40300000-0000-4000-8000-0000000000b1', 'SP-40301', 'كمبروسر اختبار', 'حبة', 100, 'تكييف', true, 'approved', now()) on conflict (id) do nothing;
insert into public.fm_erp_projects (id, code, name, region, created_by) values ('40300000-0000-4000-8000-0000000000c1', 'PRJ-ONZ', 'مشروع مدارس عنيزة', 'qassim', '40300000-0000-4000-8000-000000000001') on conflict (id) do nothing;
do $$ begin
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000004', true); set local role authenticated;
  perform public.fm_stock_move('{"kind":"in","store_id":"40300000-0000-4000-8000-0000000000a1","lines":[{"material_id":"40300000-0000-4000-8000-0000000000b1","qty":10,"price":100}]}');
  reset role;
end $$;
-- the order: the area manager creates it (assignee the supervisor, approver the engineer), checklist uses 2 from the store
do $$ declare w uuid; e text; begin
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000001', true); set local role authenticated;
  w := public.fm_wo_create(jsonb_build_object('title','إصلاح تكييف','type','repair','assignee','40300000-0000-4000-8000-000000000003','approver','40300000-0000-4000-8000-000000000002',
    'school','مدرسة عنيزة 1','building_id','ONZ1001','region','qassim','priority','عالي','checklist',
    '[{"t":"استبدال الكمبروسر","done":false,"materials":[{"id":"40300000-0000-4000-8000-0000000000b1","n":"كمبروسر اختبار","q":2,"u":"حبة","src":"store","price":100}]}]'::jsonb));
  reset role;
  perform set_config('fm403.wo', w::text, false);
  insert into public.fm_erp_work_order_projects (wo_id, project_id, updated_by) values (w, '40300000-0000-4000-8000-0000000000c1', '40300000-0000-4000-8000-000000000001');
  -- before approval: no part issue
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000004', true); set local role authenticated;
  begin perform public.fm_wo_part_issue(w, '40300000-0000-4000-8000-0000000000a1', '40300000-0000-4000-8000-0000000000b1', 1, gen_random_uuid()); e := 'allowed'; exception when others then e := sqlerrm; end;
  reset role;
  insert into t403 (area, name, pass, detail) values ('الاعتماد', 'لا صرف لأمر غير معتمد', e = 'order not approved', e);
  -- the supervisor does it, the engineer approves → the closure takes the 2 out and costs them
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000003', true); set local role authenticated;
  perform public.fm_wo_act(w, 'accept'); perform public.fm_wo_act(w, 'start');
  reset role;
  insert into public.wo_photos (wo_id, kind, path, tag, by_id) values (w, 'arrival', 'x/s.jpg', 'sign', '40300000-0000-4000-8000-000000000003');
  insert into public.wo_photos (wo_id, kind, path, item, by_id) values (w, 'before', 'x/b.jpg', 0, '40300000-0000-4000-8000-000000000003'), (w, 'after', 'x/a.jpg', 0, '40300000-0000-4000-8000-000000000003');
  set local role authenticated;
  perform public.fm_wo_act(w, 'checklist', null, null, '[{"t":"استبدال الكمبروسر","done":true,"res":"fixed","materials":[{"id":"40300000-0000-4000-8000-0000000000b1","n":"كمبروسر اختبار","q":2,"u":"حبة","src":"store","price":100}]}]');
  perform public.fm_wo_act(w, 'done');
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000002', true);
  perform public.fm_wo_act(w, 'review', null, null, '{"items":[]}');
  reset role;
  insert into t403 (area, name, pass, detail) values ('الاعتماد', 'اعتماد الأمر يخرج مواده ويحمّل تكلفتها تلقائياً (2 × 100)',
    (select status from public.work_orders where id = w) = 'closed' and (select count(*) from public.fm_wo_costs where wo_id = w and kind = 'part') = 1
    and (select sum(amount) from public.fm_wo_costs where wo_id = w) = 200, (select string_agg(src || '=' || amount, ' ') from public.fm_wo_costs where wo_id = w));
end $$;
-- the part issue after approval, then the same call again (lost answer → retry)
do $$ declare w uuid := current_setting('fm403.wo')::uuid; c1 uuid := gen_random_uuid(); c2 uuid := gen_random_uuid(); r1 jsonb; r2 jsonb; e text; bal numeric; begin
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000004', true); set local role authenticated;
  r1 := public.fm_wo_part_issue(w, '40300000-0000-4000-8000-0000000000a1', '40300000-0000-4000-8000-0000000000b1', 3, c1, 'كمبروسر احتياطي');
  r2 := public.fm_wo_part_issue(w, '40300000-0000-4000-8000-0000000000a1', '40300000-0000-4000-8000-0000000000b1', 3, c1, 'كمبروسر احتياطي');
  reset role;
  select qty into bal from public.wo_stock where store_id = '40300000-0000-4000-8000-0000000000a1' and material_id = '40300000-0000-4000-8000-0000000000b1';
  insert into t403 (area, name, pass, detail) values ('الصرف', 'صرف قطعة لأمر معتمد يحمّل تكلفتها (3 × 100)', (r1->>'amount')::numeric = 300, r1::text),
    ('إعادة المحاولة', 'إعادة نفس الطلب (نفس المعرّف) ترجع النتيجة نفسها ولا تسجل شيئاً', (r2->>'dup')::boolean and r2->>'id' = r1->>'id', r2::text),
    ('إعادة المحاولة', 'الرصيد نقص مرة واحدة فقط (10 − 2 − 3 = 5)', bal = 5, bal::text),
    ('إعادة المحاولة', 'حركتا صرف فقط (الاعتماد + الطلب) وسطر تكلفة واحد للطلب', (select count(*) from public.wo_stock_moves where wo_id = w and kind = 'out') = 2
      and (select count(*) from public.fm_wo_costs where client_id = c1) = 1, (select count(*) from public.wo_stock_moves where wo_id = w and kind = 'out') || ' حركة');
  -- a failed call records nothing, so the retry with the same id is executed for real
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000004', true); set local role authenticated;
  begin perform public.fm_wo_part_issue(w, '40300000-0000-4000-8000-0000000000a1', '40300000-0000-4000-8000-0000000000b1', 50, c2); e := 'allowed'; exception when others then e := sqlerrm; end;
  r1 := public.fm_wo_part_issue(w, '40300000-0000-4000-8000-0000000000a1', '40300000-0000-4000-8000-0000000000b1', 1, c2);
  reset role;
  insert into t403 (area, name, pass, detail) values ('إعادة المحاولة', 'طلب فشل (رصيد غير كافٍ) لا يسجل شيئاً، وإعادته بعد التصحيح تُنفَّذ', e like 'insufficient stock%' and not coalesce((r1->>'dup')::boolean, false)
      and (select qty from public.wo_stock where store_id = '40300000-0000-4000-8000-0000000000a1' and material_id = '40300000-0000-4000-8000-0000000000b1') = 4, e || ' ← ' || r1::text);
end $$;
-- the contractor service (accountant), the same call twice, a supervisor may not, a void with a reason
do $$ declare w uuid := current_setting('fm403.wo')::uuid; c3 uuid := gen_random_uuid(); r1 jsonb; r2 jsonb; e text; vid uuid; begin
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000005', true); set local role authenticated;
  r1 := public.fm_wo_service_add(w, '{"vendor":"مؤسسة تكييف عنيزة","descr":"شحن غاز وفحص ضغط","qty":2,"unit_price":450}', c3);
  r2 := public.fm_wo_service_add(w, '{"vendor":"مؤسسة تكييف عنيزة","descr":"شحن غاز وفحص ضغط","qty":2,"unit_price":450}', c3);
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000003', true);
  begin perform public.fm_wo_service_add(w, '{"vendor":"س","descr":"خدمة إضافية","qty":1,"unit_price":10}', gen_random_uuid()); e := 'allowed'; exception when others then e := sqlerrm; end;
  reset role;
  insert into t403 (area, name, pass, detail) values ('خدمة المقاول', 'تسجيل خدمة مقاول على الأمر المعتمد (2 × 450)', (r1->>'amount')::numeric = 900, r1::text),
    ('إعادة المحاولة', 'إعادة تسجيل الخدمة بنفس المعرّف لا تكررها', (r2->>'dup')::boolean and (select count(*) from public.fm_wo_costs where wo_id = w and kind = 'service') = 1, r2::text),
    ('الصلاحيات', 'المشرف المنفّذ لا يسجل تكلفة خدمة', e = 'not allowed', e);
end $$;
-- on the building and the project
do $$ declare s jsonb; b jsonb; p jsonb; g jsonb; e text; sv uuid; pt uuid; begin
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000001', true); set local role authenticated;
  s := public.fm_wo_cost_summary(current_date - 1, current_date + 1);
  g := public.fm_wo_costs_get(current_setting('fm403.wo')::uuid);
  reset role;
  select x into b from jsonb_array_elements(s->'buildings') x where x->>'bkey' = 'ONZ1001';
  select x into p from jsonb_array_elements(s->'projects') x where x->>'code' = 'PRJ-ONZ';
  insert into t403 (area, name, pass, detail) values ('التحميل', 'تكلفة المبنى ONZ1001 = 200 + 300 + 100 + 900 = 1500 (قطع 600، خدمات 900)',
      (b->>'total')::numeric = 1500 and (b->>'parts')::numeric = 600 and (b->>'services')::numeric = 900, b::text),
    ('التحميل', 'تكلفة المشروع PRJ-ONZ = 1500 من أمر واحد ومبنى واحد', (p->>'total')::numeric = 1500 and (p->>'orders')::int = 1 and (p->>'buildings')::int = 1, p::text),
    ('التحميل', 'تفاصيل الأمر: 4 أسطر، الإجمالي 1500، المشروع مرتبط', jsonb_array_length(g->'lines') = 4 and (g->>'total')::numeric = 1500 and g->'project'->>'code' = 'PRJ-ONZ', (g->>'total'));
  -- void the service (reason), a part cannot be voided here
  select id into sv from public.fm_wo_costs where wo_id = current_setting('fm403.wo')::uuid and kind = 'service';
  select id into pt from public.fm_wo_costs where wo_id = current_setting('fm403.wo')::uuid and kind = 'part' limit 1;
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000005', true); set local role authenticated;
  perform public.fm_wo_cost_void(sv, 'سُجّلت بالخطأ على هذا الأمر');
  begin perform public.fm_wo_cost_void(pt, 'خطأ'); e := 'allowed'; exception when others then e := sqlerrm; end;
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000001', true);
  s := public.fm_wo_cost_summary(current_date - 1, current_date + 1);
  reset role;
  insert into t403 (area, name, pass, detail) values ('الإلغاء', 'إلغاء الخدمة بسبب يُخرجها من التكلفة (1500 → 600) ويبقى سجلها', (s->>'total')::numeric = 600
      and (select status from public.fm_wo_costs where wo_id = current_setting('fm403.wo')::uuid and kind = 'service') = 'void', s->>'total'),
    ('الإلغاء', 'القطعة لا تُلغى من هنا (ترجع عبر المستودع)', e like 'parts are returned%', e);
  -- another region's supervisor: no access to the order's costs
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000006', true); set local role authenticated;
  begin perform public.fm_wo_costs_get(current_setting('fm403.wo')::uuid); e := 'allowed'; exception when others then e := sqlerrm; end;
  reset role;
  insert into t403 (area, name, pass, detail) values ('الصلاحيات', 'مشرف منطقة أخرى لا يرى تكلفة الأمر', e = 'not allowed', e);
end $$;
-- consistency with «📊 تكلفة المشروعات» (V353): its store-material figure for the order = the parts in the ledger
do $$ declare j jsonb; r jsonb; begin
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000001', true); set local role authenticated;
  j := public.fm_erp_cost(current_date - 1, current_date + 1, null, false);
  reset role;
  select x into r from jsonb_array_elements(j->'rows') x where x->>'id' = current_setting('fm403.wo') or x->>'wo_id' = current_setting('fm403.wo');
  insert into t403 (area, name, pass, detail) values ('الاتساق', 'تقرير تكلفة المشروعات يحسب نفس مواد الأمر (600)', coalesce((r->>'mat_store')::numeric, -1) = 600, coalesce(r::text, 'لا صف'));
end $$;
-- ---------- V404: a part goes back, services in the budget and the journal ----------
do $$ declare w uuid := current_setting('fm403.wo')::uuid; ln uuid; r1 jsonb; r2 jsonb; e text; bal0 numeric; bal1 numeric; x jsonb; rcid uuid := gen_random_uuid(); begin
  select id into ln from public.fm_wo_costs where wo_id = w and kind = 'part' and qty = 3;
  select qty into bal0 from public.wo_stock where store_id = '40300000-0000-4000-8000-0000000000a1' and material_id = '40300000-0000-4000-8000-0000000000b1';
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000004', true); set local role authenticated;
  r1 := public.fm_wo_part_return(ln, 2, rcid, 'لم تُستخدم — رجعت سليمة');
  r2 := public.fm_wo_part_return(ln, 2, rcid, 'لم تُستخدم — رجعت سليمة');
  begin perform public.fm_wo_part_return(ln, 2, gen_random_uuid(), 'إرجاع زائد'); e := 'allowed'; exception when others then e := sqlerrm; end;
  reset role;
  select qty into bal1 from public.wo_stock where store_id = '40300000-0000-4000-8000-0000000000a1' and material_id = '40300000-0000-4000-8000-0000000000b1';
  insert into t403 (area, name, pass, detail) values ('الإرجاع', 'إرجاع قطعتين للمستودع بسعر الصرف (−200) والرصيد يزيد 2', (r1->>'amount')::numeric = -200 and bal1 = bal0 + 2, r1::text),
    ('الإرجاع', 'إعادة نفس الإرجاع بنفس المعرّف لا تكرره', (r2->>'dup')::boolean and (select count(*) from public.fm_wo_costs where client_id = rcid) = 1, ''),
    ('الإرجاع', 'لا يُرجَع أكثر مما صُرف (بقيت قطعة واحدة)', e like 'more than issued: 1%', e);
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000001', true); set local role authenticated;
  x := public.fm_wo_costs_get(w);
  select r into x from (select x r) z;
  reset role;
  insert into t403 (area, name, pass, detail) values ('الإرجاع', 'تكلفة الأمر بعد الإرجاع = 1500 − 900 (ملغاة) − 200 = 400', (x->>'total')::numeric = 400, x->>'total');
end $$;
do $$ declare j jsonb; r jsonb; begin
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000001', true); set local role authenticated;
  j := public.fm_erp_cost(current_date - 1, current_date + 1, null, false); reset role;
  select x into r from jsonb_array_elements(j->'rows') x where x->>'id' = current_setting('fm403.wo');
  insert into t403 (area, name, pass, detail) values ('الاتساق', 'تقرير تكلفة المشروعات يخصم الإرجاع (600 − 200 = 400)', (r->>'mat_store')::numeric = 400, r->>'mat_store');
end $$;
-- a second service (kept), and one on a contract whose bill already holds the order (left out of budget / journal)
insert into public.fm_contracts (id, name, contractor_name, region) values ('40300000-0000-4000-8000-0000000000d1', 'عقد اختبار', 'مقاول المستخلص', 'qassim') on conflict do nothing;
insert into public.fm_bills (id, contract_id, month) values ('40300000-0000-4000-8000-0000000000e1', '40300000-0000-4000-8000-0000000000d1', to_char(now(), 'YYYY-MM')) on conflict do nothing;
insert into public.fm_bill_wos (bill_id, wo_id) values ('40300000-0000-4000-8000-0000000000e1', current_setting('fm403.wo')::uuid) on conflict do nothing;
do $$ declare w uuid := current_setting('fm403.wo')::uuid; b jsonb; j jsonb; sub numeric; n1 int; n2 int; n3 int; n4 int; bal boolean; begin
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000005', true); set local role authenticated;
  perform public.fm_wo_service_add(w, '{"vendor":"مؤسسة كهرباء عنيزة","descr":"فحص لوحة كهرباء","qty":1,"unit_price":700}', gen_random_uuid());
  perform public.fm_wo_service_add(w, '{"contract_id":"40300000-0000-4000-8000-0000000000d1","descr":"زيارة ضمن المستخلص","qty":1,"unit_price":250}', gen_random_uuid());
  j := public.fm_acct_journal(current_date - 1, current_date + 1);
  perform set_config('request.jwt.claim.sub', '40300000-0000-4000-8000-000000000001', true);
  b := public.fm_erp_budget(extract(year from now())::int);
  reset role;
  select coalesce(sum((x->>'a')::numeric), 0) into sub from jsonb_array_elements(b->'actual') x where x->>'p' = '40300000-0000-4000-8000-0000000000c1' and x->>'c' = 'sub';
  insert into t403 (area, name, pass, detail) values ('الميزانية', 'فعلي «مقاولو باطن» للمشروع = الخدمة القائمة 700 (لا الملغاة ولا التي في المستخلص)', sub = 700, sub::text);
  select count(*) filter (where x->>'src' = 'wosvc'), count(*) filter (where x->>'src' = 'wosvc_v'), count(*) filter (where x->>'src' = 'woret'),
         count(*) filter (where x->>'src' = 'wosvc' and x->>'desc' like '%المستخلص%')
    into n1, n2, n3, n4 from jsonb_array_elements(j->'entries') x;
  select bool_and(abs((select sum((l->>'dr')::numeric) - sum((l->>'cr')::numeric) from jsonb_array_elements(x->'lines') l)) < 0.01) into bal
    from jsonb_array_elements(j->'entries') x where x->>'src' in ('wosvc','wosvc_v','woret');
  insert into t403 (area, name, pass, detail) values ('القيود', 'قيود الخدمات: خدمتان (900 الملغاة + 700) وعكس الملغاة، بلا خدمة المستخلص', n1 = 2 and n2 = 1 and n4 = 0, n1 || ' / ' || n2 || ' / ' || n4),
    ('القيود', 'قيد إرجاع القطعة (مخزون / تكلفة مواد) وكل القيود متوازنة', n3 = 1 and bal, n3 || ' متوازنة=' || bal);
end $$;
select n, area, name, case when pass then 'PASS' else 'FAIL' end res, left(detail, 160) detail from t403 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t403;
