-- V408 — decisions on returned faults / failed audits in contractor bills (section 138), LOCAL database only.
-- runner: bash tests/integration/onaizah402.sh <db> tests/integration/repded408.sql
\set ON_ERROR_STOP 1
create temp table t408 (n serial, name text, pass boolean, detail text);
grant all on t408 to authenticated; grant usage on sequence t408_n_seq to authenticated;
insert into auth.users (id, email, raw_user_meta_data) values
 ('40800000-0000-4000-8000-000000000001','d.am@rakizora.test','{"full_name":"مدير منطقة الخصم"}'),
 ('40800000-0000-4000-8000-000000000002','d.sup@rakizora.test','{"full_name":"مشرف الخصم"}'),
 ('40800000-0000-4000-8000-000000000003','d.oam@rakizora.test','{"full_name":"مدير منطقة أخرى"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '40800000-%' on conflict (id) do nothing;
update public.profiles p set job_title = x.t, regions = x.r, active = true from (values ('40800000-0000-4000-8000-000000000001'::uuid,'area_manager','{qassim}'::text[]),
 ('40800000-0000-4000-8000-000000000002','supervisor','{qassim}'),('40800000-0000-4000-8000-000000000003','area_manager','{riyadh}')) x(id,t,r) where p.id = x.id;
insert into public.fm_contracts (id, name, contractor_name, region) values ('40800000-0000-4000-8000-0000000000c1','عقد الخصم','مقاول الخصم','qassim') on conflict (id) do nothing;
insert into public.fm_bills (id, contract_id, month, status) values ('40800000-0000-4000-8000-0000000000b1','40800000-0000-4000-8000-0000000000c1','2026-10','draft'),
 ('40800000-0000-4000-8000-0000000000b2','40800000-0000-4000-8000-0000000000c1','2026-11','draft') on conflict (id) do nothing;
do $$ declare e text; n int; j jsonb; begin
  perform set_config('request.jwt.claim.sub', '40800000-0000-4000-8000-000000000001', true); set local role authenticated;
  n := public.fm_bill_rep_set('qassim', '[{"ticket":"T1","kind":"repeat","decision":"ded","amount":100,"bill_id":"40800000-0000-4000-8000-0000000000b1"}]');
  begin perform public.fm_bill_rep_set('qassim', '[{"ticket":"T1","kind":"repeat","decision":"ded","amount":100,"bill_id":"40800000-0000-4000-8000-0000000000b2"}]'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t408 (name, pass, detail) values ('لا يُخصم البلاغ نفسه في مستخلصين حيين', e like 'already deducted%', e);
  begin perform public.fm_bill_rep_set('qassim', '[{"ticket":"T2","kind":"audit","decision":"excl","reason":"x"}]'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t408 (name, pass, detail) values ('الاستبعاد يحتاج سبباً', e like 'reason required%', e);
  perform public.fm_bill_rep_set('qassim', '[{"ticket":"T2","kind":"audit","decision":"excl","reason":"العطل بسبب سوء الاستخدام"}]');
  j := public.fm_bill_rep_list('qassim');
  insert into t408 (name, pass, detail) values ('القائمة تعرض القرارين ورقم المستخلص', jsonb_array_length(j) = 2 and exists (select 1 from jsonb_array_elements(j) x where x->>'bill_code' like 'BL-%'), j::text);
  reset role;
  update public.fm_bills set status = 'cancelled' where id = '40800000-0000-4000-8000-0000000000b1';
  set local role authenticated;
  perform public.fm_bill_rep_set('qassim', '[{"ticket":"T1","kind":"repeat","decision":"ded","amount":150,"bill_id":"40800000-0000-4000-8000-0000000000b2"}]');
  reset role;
  select count(*) into n from public.fm_bill_rep_dec where ticket_id = 'T1' and bill_id = '40800000-0000-4000-8000-0000000000b2' and amount = 150;
  insert into t408 (name, pass, detail) values ('بعد إلغاء المستخلص يُخصم في مستخلص آخر', n = 1, n::text);
  set local role authenticated;
  perform public.fm_bill_rep_set('qassim', '[{"ticket":"T2","kind":"audit","decision":null}]');
  reset role;
  select count(*) into n from public.fm_bill_rep_dec where ticket_id = 'T2';
  insert into t408 (name, pass, detail) values ('التراجع يحذف القرار', n = 0, n::text);
  set local role authenticated;
  perform set_config('request.jwt.claim.sub', '40800000-0000-4000-8000-000000000002', true);
  begin perform public.fm_bill_rep_set('qassim', '[{"ticket":"T3","kind":"audit","decision":"excl","reason":"سبب طويل"}]'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t408 (name, pass, detail) values ('المشرف لا يقرر', e = 'not allowed', e);
  perform set_config('request.jwt.claim.sub', '40800000-0000-4000-8000-000000000003', true);
  begin perform public.fm_bill_rep_list('qassim'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t408 (name, pass, detail) values ('مدير منطقة أخرى لا يقرأ', e = 'not allowed', e);
  reset role;
end $$;
select n, name, case when pass then 'PASS' else 'FAIL' end res, left(detail, 120) detail from t408 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t408;
