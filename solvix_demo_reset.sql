-- Solvix — remove the demo data created by solvix_demo.sql (schools «DEMO-…», employees «D9…», accounts «…@solvix-demo.test», records «demo-c-…»).
-- Real data is not touched. Demo photos (if a demo supervisor uploaded any) stay in the bucket nv-photos; delete them from Storage if you wish.
delete from public.nv_log where coll in (select id from public.nv_collections where school_id like 'demo-s%' or employee_id like 'demo-e%') or school like 'demo-s%' or emp like 'demo-e%';
delete from public.nv_collections where id like 'demo-c-%' or school_id like 'demo-s%' or employee_id like 'demo-e%';
delete from public.nv_schools where id like 'demo-s%';
delete from public.nv_employees where id like 'demo-e%';
delete from public.nv_staff where email like '%@solvix-demo.test';
delete from auth.identities where user_id in (select id from auth.users where email like '%@solvix-demo.test');
delete from auth.users where email like '%@solvix-demo.test';
select 'تم حذف البيانات التجريبية' as "النتيجة";
