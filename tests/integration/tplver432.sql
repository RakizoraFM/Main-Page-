-- V432 — template versions and approval (section 149), LOCAL database only.
\set ON_ERROR_STOP 1
create temp table t422 (n serial, name text, pass boolean, detail text);
grant all on t422 to authenticated; grant usage on sequence t422_n_seq to authenticated;
insert into auth.users (id, email, raw_user_meta_data) values ('42200000-0000-4000-8000-000000000001','v.eng@rakizora.test','{"full_name":"مهندس القوالب"}'),('42200000-0000-4000-8000-000000000002','v.pm@rakizora.test','{"full_name":"مدير المشروع"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '42200000-%' on conflict (id) do nothing;
update public.profiles p set job_title = x.t, active = true, regions = '{qassim}' from (values ('42200000-0000-4000-8000-000000000001'::uuid,'area_engineer'),('42200000-0000-4000-8000-000000000002','project_manager')) x(id,t) where p.id = x.id;
insert into public.fm_settings (key, value) values ('tpl_appr','{"enabled":true}') on conflict (key) do update set value = excluded.value;
do $$ declare id_ uuid; e text; r public.wo_templates; begin
  perform set_config('request.jwt.claim.sub', '42200000-0000-4000-8000-000000000001', true); set local role authenticated;
  insert into public.wo_templates (name, data, shared) values ('فحص طفايات', '{"checklist":["أ"]}', true) returning id into id_;
  update public.wo_templates set data = '{"checklist":["أ","ب"]}' where id = id_;
  begin perform public.fm_tpl_approve(id_, true, null); e := 'none'; exception when others then e := sqlerrm; end;
  reset role;
  select * into r from public.wo_templates where id = id_;
  insert into t422 (name, pass, detail) values ('التعديل يرفع الإصدار ويحفظ السابق', r.ver = 2 and jsonb_array_length(r.hist) = 1 and r.status = 'pending', r.ver || ' ' || r.status),
    ('المهندس لا يعتمد قالبه', e = 'not allowed', e);
  perform set_config('request.jwt.claim.sub', '42200000-0000-4000-8000-000000000002', true); set local role authenticated;
  perform public.fm_tpl_approve(id_, true, null);
  reset role;
  select * into r from public.wo_templates where id = id_;
  insert into t422 (name, pass, detail) values ('مدير المشروع يعتمد دون رفع الإصدار', r.status = 'approved' and r.ver = 2 and r.appr_name = 'مدير المشروع', r.status || r.ver);
  perform set_config('request.jwt.claim.sub', '42200000-0000-4000-8000-000000000001', true); set local role authenticated;
  update public.wo_templates set shared = false where id = id_;
  reset role;
  select * into r from public.wo_templates where id = id_;
  insert into t422 (name, pass, detail) values ('تغيير غير البيانات لا يلغي الاعتماد', r.status = 'approved' and r.ver = 2, r.status || r.ver);
end $$;
select n, name, case when pass then 'PASS' else 'FAIL' end res, detail from t422 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t422;
