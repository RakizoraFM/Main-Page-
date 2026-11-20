-- V417 — item units (section 143), LOCAL database only.
\set ON_ERROR_STOP 1
create temp table t417 (n serial, name text, pass boolean, detail text);
grant all on t417 to authenticated; grant usage on sequence t417_n_seq to authenticated;
insert into auth.users (id, email, raw_user_meta_data) values ('41700000-0000-4000-8000-000000000001','u.adm@rakizora.test','{"full_name":"أدمن"}'),('41700000-0000-4000-8000-000000000002','u.sup@rakizora.test','{"full_name":"مشرف"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '41700000-%' on conflict (id) do nothing;
update public.profiles set role = 'admin', job_title = 'sysadmin', active = true where id = '41700000-0000-4000-8000-000000000001';
update public.profiles set job_title = 'supervisor', active = true, regions = '{qassim}' where id = '41700000-0000-4000-8000-000000000002';
insert into public.wo_materials (id, code, name, unit, price, active, approval, approved_at) values ('41700000-0000-4000-8000-0000000000b1','SP-41701','لمبة','حبة',5,true,'approved',now()) on conflict (id) do nothing;
do $$ declare j jsonb; e text; begin
  perform set_config('request.jwt.claim.sub', '41700000-0000-4000-8000-000000000001', true); set local role authenticated;
  j := public.fm_mat_units_set('41700000-0000-4000-8000-0000000000b1', '[{"u":"كرتون","f":24},{"u":"علبة","f":6}]');
  insert into t417 (name, pass, detail) values ('حفظ وحدتين', jsonb_array_length(j) = 2, j::text);
  begin perform public.fm_mat_units_set('41700000-0000-4000-8000-0000000000b1', '[{"u":"كرتون","f":1}]'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t417 (name, pass, detail) values ('المعامل يجب أن يكون أكبر من 1', e = 'invalid units', e);
  perform set_config('request.jwt.claim.sub', '41700000-0000-4000-8000-000000000002', true);
  begin perform public.fm_mat_units_set('41700000-0000-4000-8000-0000000000b1', '[]'); e := 'none'; exception when others then e := sqlerrm; end;
  insert into t417 (name, pass, detail) values ('المشرف لا يعدّل', e = 'not allowed', e);
  reset role;
end $$;
select n, name, case when pass then 'PASS' else 'FAIL' end res, detail from t417 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t417;
