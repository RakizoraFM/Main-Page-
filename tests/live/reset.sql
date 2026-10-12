-- RakizoraFM live tests — remove what the tests created, KEEP the test accounts and their school assignment.
-- Run in Supabase → SQL Editor after a test run. Touches only data of the accounts fm.test.*@rakizora.test.
do $$
declare t uuid[]; n int;
begin
  select array_agg(id) into t from auth.users where email like 'fm.test.%@rakizora.test';
  if t is null then raise notice 'لا يوجد مستخدمو اختبار'; return; end if;
  delete from public.fm_eng_audit where observation_id in (select o.id from public.fm_eng_observations o join public.fm_eng_logs l on l.id=o.log_id
     join public.fm_eng_assignments a on a.id=l.assignment_id where a.user_id=any(t) or l.user_id=any(t) or o.owner_id=any(t));
  delete from public.fm_eng_observations o using public.fm_eng_logs l, public.fm_eng_assignments a
     where l.id=o.log_id and a.id=l.assignment_id and (a.user_id=any(t) or l.user_id=any(t) or o.owner_id=any(t));
  delete from public.fm_eng_logs l using public.fm_eng_assignments a where a.id=l.assignment_id and (a.user_id=any(t) or l.user_id=any(t));
  begin
    delete from storage.objects where bucket_id='school-engagement' and split_part(name,'/',1) in (select x::text from unnest(t) x);
    delete from storage.objects where bucket_id='wo-photos' and split_part(name,'/',1) in (select id::text from public.work_orders where created_by=any(t) or assignee=any(t));
  exception when others then raise notice 'الملفات لم تُحذف من التخزين (صور اختبار صغيرة جداً تبقى): %', sqlerrm;
  end;
  update public.work_orders set source_wo=null where source_wo in (select id from public.work_orders where created_by=any(t) or assignee=any(t));
  delete from public.work_orders where created_by=any(t) or assignee=any(t);
  get diagnostics n = row_count; raise notice 'أوامر اختبار محذوفة: %', n;
end $$;
select (select count(*) from public.work_orders w join auth.users u on u.id in (w.created_by, w.assignee) where u.email like 'fm.test.%') as test_orders_left,
       (select count(*) from auth.users where email like 'fm.test.%@rakizora.test') as test_users_kept;
