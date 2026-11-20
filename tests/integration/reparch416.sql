-- V416 — report archive (section 142), LOCAL database only.
\set ON_ERROR_STOP 1
create temp table t416 (n serial, name text, pass boolean, detail text);
grant all on t416 to authenticated; grant usage on sequence t416_n_seq to authenticated;
insert into auth.users (id, email, raw_user_meta_data) values
 ('41600000-0000-4000-8000-000000000001','r.am@rakizora.test','{"full_name":"مدير القصيم"}'),
 ('41600000-0000-4000-8000-000000000002','r.am2@rakizora.test','{"full_name":"مدير الرياض"}'),
 ('41600000-0000-4000-8000-000000000003','r.sup@rakizora.test','{"full_name":"مشرف"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '41600000-%' on conflict (id) do nothing;
update public.profiles p set job_title = x.t, regions = x.r, active = true from (values ('41600000-0000-4000-8000-000000000001'::uuid,'area_manager','{qassim}'::text[]),('41600000-0000-4000-8000-000000000002','area_manager','{riyadh}'),('41600000-0000-4000-8000-000000000003','supervisor','{qassim}')) x(id,t,r) where p.id = x.id;
do $$ declare j jsonb; e text; h text := '<div class="pg">التقرير الشهري — القصيم — نوفمبر <script>alert(1)</script> ' || repeat('x', 60) || '</div>'; begin
  perform set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000001', true); set local role authenticated;
  j := public.fm_rep_arch_save('2026-10', 'qassim', 'monthly', 'تقرير أكتوبر', h, 'أُرسل للعميل');
  j := public.fm_rep_arch_save('2026-10', 'qassim', 'monthly', 'تقرير أكتوبر', h || ' معدّل', null);
  insert into t416 (name, pass, detail) values ('الحفظ الثاني نسخة 2 ولا يُستبدل الأول', (j->>'version')::int = 2, j::text);
  j := public.fm_rep_arch_list(24);
  insert into t416 (name, pass, detail) values ('القائمة نسختان', jsonb_array_length(j->'rows') = 2, jsonb_array_length(j->'rows')::text);
  insert into t416 (name, pass, detail) select 'السكربت يُزال من النسخة', public.fm_rep_arch_get((j->'rows'->1->>'id')::uuid)->>'html' not like '%<script%', 'ok';
  begin perform public.fm_rep_arch_save('2026-10', 'riyadh', 'monthly', 'x', h, null); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t416 (name, pass, detail) values ('مدير القصيم لا يحفظ للرياض', e = 'not allowed', e);
  perform set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000002', true);
  j := public.fm_rep_arch_list(24);
  insert into t416 (name, pass, detail) values ('مدير الرياض لا يرى أرشيف القصيم', jsonb_array_length(j->'rows') = 0, jsonb_array_length(j->'rows')::text);
  perform set_config('request.jwt.claim.sub', '41600000-0000-4000-8000-000000000003', true);
  j := public.fm_rep_arch_list(24);
  begin perform public.fm_rep_arch_save('2026-10', 'qassim', 'client', 'x', h, null); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t416 (name, pass, detail) values ('مشرف القصيم يقرأ ولا يحفظ', jsonb_array_length(j->'rows') = 2 and e = 'not allowed', jsonb_array_length(j->'rows') || ' ' || e);
  reset role;
end $$;
select n, name, case when pass then 'PASS' else 'FAIL' end res, detail from t416 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t416;
