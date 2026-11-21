-- V421 — conditional fields in fm_wo_form_check (section 145), LOCAL database only.
\set ON_ERROR_STOP 1
create temp table t421 (n serial, name text, pass boolean, detail text);
select public.fm_form_show('{"sf":"leak","sv":"نعم"}', '{"leak":"لا"}', 'ok') = false as a, public.fm_form_show('{"sf":"leak","sv":"نعم|ربما"}', '{"leak":" ربما "}', 'ok') as b,
       public.fm_form_show('{}', '{}', null) as c, public.fm_form_show('{"sf":"__res","sv":"fix|fixed"}', '{}', 'fix') as d \gset
insert into t421 (name, pass, detail) values ('الحقل المشروط يختفي عند «لا»', :'a', ''), ('عدة قيم بفاصل |', :'b', ''), ('بلا شرط يظهر دائماً', :'c', ''), ('شرط على نتيجة البند', :'d', '');
insert into auth.users (id, email) values ('42100000-0000-4000-8000-000000000001','c.adm@rakizora.test') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role, active) values ('42100000-0000-4000-8000-000000000001','c.adm@rakizora.test','أدمن','admin',true) on conflict (id) do update set role='admin', active=true;
insert into public.work_orders (id, code, title, type, status, created_by, assignee, form, checklist) values
 ('42100000-0000-4000-8000-0000000000a1','WO-C1','x','inspection','in_progress','42100000-0000-4000-8000-000000000001','42100000-0000-4000-8000-000000000001',
  '{"res":true,"rules":{"after":"none","before":"none"},"fields":[{"id":"leak","l":"يوجد تسريب؟","t":"yesno"},{"id":"where","l":"مكان التسريب","t":"text","req":true,"sf":"leak","sv":"نعم"}]}',
  '[{"t":"خزان","res":"ok","fv":{"leak":"لا"}}]');
do $$ declare e text; begin
  begin update public.work_orders set status = 'done' where id = '42100000-0000-4000-8000-0000000000a1'; e := 'none'; exception when others then e := sqlerrm; end;
  insert into t421 (name, pass, detail) values ('الحقل الإلزامي المخفي لا يمنع الإنجاز', e not like 'form field required%', e);
  update public.work_orders set status = 'in_progress', checklist = '[{"t":"خزان","res":"ok","fv":{"leak":"نعم"}}]' where id = '42100000-0000-4000-8000-0000000000a1';
  begin update public.work_orders set status = 'done' where id = '42100000-0000-4000-8000-0000000000a1'; e := 'none'; exception when others then e := sqlerrm; end;
  insert into t421 (name, pass, detail) values ('عند «نعم» يصبح الحقل إلزامياً', e like 'form field required%', e);
end $$;
select n, name, case when pass then 'PASS' else 'FAIL' end res, detail from t421 order by n;
select count(*) filter (where pass) passed, count(*) filter (where not pass) failed from t421;
