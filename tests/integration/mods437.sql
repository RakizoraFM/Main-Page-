-- V437 — section 151: the eight parts added after V181 (erp, hr, assets, energy, ai, reports, cpen, integ), LOCAL database only.
\set ON_ERROR_STOP 1
create temp table t437 (n serial, name text, pass boolean, detail text);
insert into auth.users (id, email, raw_user_meta_data) values ('43700000-0000-4000-8000-000000000001','m.adm@rakizora.test','{"full_name":"أدمن"}') on conflict (id) do nothing;
insert into public.profiles (id, email, full_name, role) select id, email, raw_user_meta_data->>'full_name', 'pending' from auth.users where id::text like '43700000-%' on conflict (id) do nothing;
update public.profiles set job_title = 'sysadmin', active = true where id = '43700000-0000-4000-8000-000000000001';
create or replace function pg_temp.try(q text) returns text language plpgsql as $$ begin execute q; return 'ok'; exception when others then return sqlerrm; end $$;
create or replace function pg_temp.ins_all() returns jsonb language plpgsql as $$ declare r jsonb := '{}'; begin
  r := r || jsonb_build_object('erp', pg_temp.try($q$insert into public.fm_periods(month) values ('2099-0'||(1+floor(random()*8))::int) on conflict do nothing$q$));
  r := r || jsonb_build_object('hr', pg_temp.try($q$insert into public.fm_att(user_id, kind) values ('43700000-0000-4000-8000-000000000001','in')$q$));
  r := r || jsonb_build_object('energy', pg_temp.try($q$insert into public.fm_meters(bkey, school_name, kind) values ('K1','مدرسة','elec')$q$));
  r := r || jsonb_build_object('integ', pg_temp.try($q$insert into public.fm_sources(name, url) values ('s','https://x')$q$));
  r := r || jsonb_build_object('wo_ok', pg_temp.try($q$select 1$q$));
  return r; end $$;
-- A) single-company site: no fm_plan row → every part
delete from public.fm_plan;
insert into t437(name, pass, detail) select 'بدون اشتراك: كل الأجزاء مفعّلة', (select bool_and(public.fm_mod(k)) from unnest(public.fm_mods_new()) k), public.fm_mods_on()::text;
-- B) company with every part (list signed by SA11, marker _v)
insert into public.fm_plan(id, company, secret, active_until, modules) values (1, 'co437', repeat('a',64), current_date + 90,
  '{"tickets":null,"wo":null,"wh":null,"eng":null,"portal":null,"costs":null,"bill":null,"cc":null,"erp":null,"hr":null,"assets":null,"energy":null,"ai":null,"reports":null,"cpen":null,"integ":null,"_v":437}');
insert into t437(name, pass, detail) select 'شركة بكل الأجزاء: fm_mods_on يضم الأجزاء الثمانية الجديدة',
  (select bool_and(public.fm_mods_on() ? k) from unnest(public.fm_mods_new()) k), public.fm_mods_on()::text;
insert into t437(name, pass, detail) select 'شركة بكل الأجزاء: الكتابة مسموحة', (j->>'erp') = 'ok' and (j->>'hr') = 'ok' and (j->>'energy') = 'ok' and (j->>'integ') = 'ok', j::text from (select pg_temp.ins_all() j) x;
-- C) company without erp and hr
update public.fm_plan set modules = '{"tickets":null,"wo":null,"wh":null,"eng":null,"portal":null,"costs":null,"bill":null,"cc":null,"assets":null,"energy":null,"ai":null,"reports":null,"cpen":null,"integ":null,"_v":437}';
insert into t437(name, pass, detail) select 'بدون erp وhr: الجزءان مغلقان والباقي مفتوح',
  not public.fm_mod('erp') and not public.fm_mod('hr') and public.fm_mod('energy') and public.fm_mod('wo') and not (public.fm_mods_on() ? 'erp') and not (public.fm_mods_on() ? 'hr'), public.fm_mods_on()::text;
insert into t437(name, pass, detail) select 'بدون erp وhr: الكتابة في جداولهما مرفوضة وفي غيرهما مسموحة',
  (j->>'erp') like 'module disabled: erp%' and (j->>'hr') like 'module disabled: hr%' and (j->>'energy') = 'ok' and (j->>'integ') = 'ok', j::text from (select pg_temp.ins_all() j) x;
-- D) old company: list saved before V437 (no _v) → the new parts stay open, the old rule for the old parts is unchanged
update public.fm_plan set modules = '{"tickets":null,"wo":null}';
insert into t437(name, pass, detail) select 'شركة قديمة بلا المفاتيح الجديدة: الأجزاء الجديدة تبقى مفتوحة',
  (select bool_and(public.fm_mod(k)) from unnest(public.fm_mods_new()) k), public.fm_mods_on()::text;
insert into t437(name, pass, detail) select 'شركة قديمة: الأجزاء القديمة غير المشتراة تبقى مغلقة كما كانت', not public.fm_mod('wh') and not public.fm_mod('bill') and public.fm_mod('wo'), '';
insert into t437(name, pass, detail) select 'شركة قديمة: الكتابة في جداول الأجزاء الجديدة مسموحة', (j->>'erp') = 'ok' and (j->>'hr') = 'ok', j::text from (select pg_temp.ins_all() j) x;
-- E) a new part on trial with an end date that passed → off; still running → on
update public.fm_plan set modules = jsonb_build_object('tickets', null, 'ai', (current_date - 1)::text, 'hr', (current_date + 5)::text, '_v', 437);
insert into t437(name, pass, detail) select 'تجربة جزء جديد: تنتهي بتاريخها', not public.fm_mod('ai') and public.fm_mod('hr') and not public.fm_mod('erp'), public.fm_mods_on()::text;
-- F) the backup e-mail schedule is core: reports off does not refuse it
update public.fm_plan set modules = '{"tickets":null,"_v":437}';
insert into t437(name, pass, detail) select 'جدولة النسخ الاحتياطي ليست ضمن «التقارير»',
  e not like 'module disabled%' and e2 like 'module disabled: reports%', e || ' | ' || e2 from (select pg_temp.try($q$insert into public.fm_report_schedules(name, kind) values ('b','p:backup')$q$) e,
    pg_temp.try($q$insert into public.fm_report_schedules(name, kind) values ('w','wo_open')$q$) e2) x;
insert into t437(name, pass, detail) select 'core دائماً مفعّل', public.fm_mod('core'), '';
delete from public.fm_plan;
select n, case when pass then '✅' else '❌' end r, name, left(detail, 160) from t437 order by n;
select count(*) filter (where pass) || ' / ' || count(*) as passed from t437;
