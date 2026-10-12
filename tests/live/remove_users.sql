-- RakizoraFM live tests — remove the test data AND the test accounts (run reset.sql first, then this).
-- Pass an email to remove one account only, e.g. the test admin: change the like-pattern to 'fm.test.admin@rakizora.test'.
do $$
declare t uuid[];
begin
  select array_agg(id) into t from auth.users where email like 'fm.test.%@rakizora.test';
  if t is null then raise notice 'لا يوجد مستخدمو اختبار'; return; end if;
  delete from public.fm_eng_assignments a where a.user_id=any(t) and not exists (select 1 from public.fm_eng_logs l where l.assignment_id=a.id);
  update public.profiles set reports_to=null where reports_to=any(t) and not (id=any(t));
  delete from auth.users where id=any(t);
  raise notice 'حُذف % مستخدم اختبار', array_length(t,1);
end $$;
