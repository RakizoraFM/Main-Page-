-- Solvix — DEMO data to try the platform (run in the Supabase SQL Editor AFTER solvix_setup.sql and after «تحميل القوائم الجاهزة»).
-- Creates: 3 management accounts (owner / manager / coordinator), 3 field supervisors with e-mail sign-in, 6 demo schools
-- (3 completed, 1 in progress, 1 not started, 1 inactive) and ~45 asset records from the approved catalog, plus one change-log entry.
-- Everything is marked DEMO (schools «DEMO-…», employees «D9…», e-mails «…@solvix-demo.test», records «demo-c-…»).
-- Remove it all with solvix_demo_reset.sql. Running this file again first removes the previous demo data.
-- Password of every demo account: Solvix@2026  (demo only — delete the accounts when you finish testing).
do $demo$
declare
  pw constant text := 'Solvix@2026';
  u record; v_id uuid; t record; r record; i int; n int; k int := 0;
  types text[]; rooms text[]; conds text[]; floors text[] := array['الأرضي','الأول','الثاني','الثالث'];
  sch text; emp text; sub timestamptz;
begin
  if not exists(select 1 from public.nv_types where code is not null) then
    raise exception 'شغّل solvix_setup.sql أولاً، ثم من Solvix: «تحميل القوائم الجاهزة» أو «اعتماد الدليل المدمج» — دليل الأصول فارغ.';
  end if;
  if not exists(select 1 from public.nv_rooms) or not exists(select 1 from public.nv_conditions) then
    raise exception 'أسماء الغرف أو حالات الأصول فارغة — حمّل القوائم الجاهزة من Solvix أولاً.';
  end if;

  -- 0) remove an earlier demo run
  delete from public.nv_log where coll like 'demo-c-%' or school like 'demo-s%';
  delete from public.nv_collections where id like 'demo-c-%';
  delete from public.nv_schools where id like 'demo-s%';
  delete from public.nv_employees where id like 'demo-e%';
  delete from public.nv_staff where email like '%@solvix-demo.test';
  delete from auth.identities where user_id in (select id from auth.users where email like '%@solvix-demo.test');
  delete from auth.users where email like '%@solvix-demo.test';

  -- 1) sign-in accounts (same columns as nv_staff_create / nv_emp_set_login)
  for u in select * from (values
      ('owner@solvix-demo.test','مالك تجريبي','owner'),
      ('manager@solvix-demo.test','مدير مشروع تجريبي','manager'),
      ('coordinator@solvix-demo.test','منسق تجريبي','coordinator'),
      ('field1@solvix-demo.test','أحمد الميداني (تجريبي)','field:demo-e1:D901'),
      ('field2@solvix-demo.test','خالد الحربي (تجريبي)','field:demo-e2:D902'),
      ('field3@solvix-demo.test','سعد العتيبي (تجريبي)','field:demo-e3:D903')) x(email,name,role)
  loop
    v_id := gen_random_uuid();
    insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                            created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
    values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', u.email, extensions.crypt(pw, extensions.gen_salt('bf')), now(),
            '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', u.name), now(), now(), '', '', '', '');
    insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
    values (gen_random_uuid(), v_id, v_id::text, jsonb_build_object('sub', v_id::text, 'email', u.email, 'email_verified', true, 'phone_verified', false), 'email', now(), now(), now());
    if u.role like 'field:%' then
      insert into public.nv_employees(id, number, name, email, user_id, created_at)
      values (split_part(u.role,':',2), split_part(u.role,':',3), u.name, u.email, v_id, now() - interval '20 days');
    else
      insert into public.nv_staff(user_id, email, name, role) values (v_id, u.email, u.name, u.role)
      on conflict (user_id) do update set role = excluded.role, name = excluded.name, active = true;
    end if;
  end loop;

  -- 2) demo schools
  insert into public.nv_schools(id, moe, ident, site, name, district, city, description, status, completed_at, completed_by, created_at) values
    ('demo-s1','990001','DEMO-SCH-01','DEMO','مدرسة تجريبية ١ — ابتدائية','الريان','بريده','بيانات تجريبية','inactive', now() - interval '6 days','demo-e1', now() - interval '30 days'),
    ('demo-s2','990002','DEMO-SCH-02','DEMO','مدرسة تجريبية ٢ — متوسطة','الصفراء','بريده','بيانات تجريبية','inactive', now() - interval '3 days','demo-e2', now() - interval '30 days'),
    ('demo-s3','990003','DEMO-SCH-03','DEMO','مدرسة تجريبية ٣ — ثانوية','الخبيب','عنيزه','بيانات تجريبية','inactive', now() - interval '1 day','demo-e1', now() - interval '30 days'),
    ('demo-s4','990004','DEMO-SCH-04','DEMO','مدرسة تجريبية ٤ — قيد الجرد','الفايزية','بريده','بيانات تجريبية','active', null, null, now() - interval '30 days'),
    ('demo-s5','990005','DEMO-SCH-05','DEMO','مدرسة تجريبية ٥ — لم تبدأ','النخيل','الرس','بيانات تجريبية','active', null, null, now() - interval '30 days'),
    ('demo-s6','990006','DEMO-SCH-06','DEMO','مدرسة تجريبية ٦ — غير نشطة','الشفاء','المذنب','بيانات تجريبية','inactive', null, null, now() - interval '30 days');

  -- 3) asset records from the approved catalog (a spread of levels, some critical)
  select array_agg(id order by code) into types from (select id, code, row_number() over (partition by cat order by code) rn from public.nv_types where code is not null) q where rn <= 4;
  select array_agg(id order by id) into rooms from (select id from public.nv_rooms order by id limit 12) q;
  select array_agg(id order by id) into conds from public.nv_conditions;
  for r in select * from (values ('demo-s1','demo-e1',12,6),('demo-s2','demo-e2',10,3),('demo-s3','demo-e1',9,1),('demo-s4','demo-e3',8,0)) x(s,e,cnt,days) loop
    for i in 1..r.cnt loop
      k := k + 1;
      select * into t from public.nv_types where id = types[1 + (k * 7) % array_length(types,1)];
      sub := now() - make_interval(days => r.days + (i % 3), hours => i);
      insert into public.nv_collections(id, employee_id, school_id, floor, room_number, room_name_id, notes, category_id, type_id, condition_id,
        quantity, price, status, manufacturer, brand, model, serial, parent_child, tag, lat, lng, submitted_at, created_at)
      values ('demo-c-' || lpad(k::text, 3, '0'), r.e, r.s, floors[1 + i % 4], (1 + i % 9)::text, rooms[1 + (i * 5) % array_length(rooms,1)],
        case when i % 5 = 0 then 'ملاحظة تجريبية: يحتاج صيانة' else '' end, t.cat, t.id, conds[1 + i % array_length(conds,1)],
        1 + (i * 3) % 6, (array[150, 450, 1200, 2800, 650, 90])[1 + i % 6], case when i % 4 = 0 then 'Does not work' else 'Works' end,
        (array['LG','Samsung','Carrier','Gree','HP','Dell'])[1 + i % 6], (array['LG','Samsung','Carrier','Gree','HP','Dell'])[1 + i % 6], 'DM-' || (100 + i),
        'SN-DEMO-' || lpad(k::text, 4, '0'), case when i % 3 = 0 then 'Child' else 'Parent' end, 'ASAD-' || (5000 + k),
        26.33 + (k % 9) * 0.004, 43.97 + (k % 7) * 0.004,
        case when r.s = 'demo-s4' and i > 5 then null else sub end, sub - interval '20 minutes');
    end loop;
  end loop;

  -- 4) one edit of a submitted asset (shows in «سجل التعديلات» and the notifications bell)
  insert into public.nv_log(by, coll, school, emp, changes, at)
  values ('emp:demo-e1', 'demo-c-002', 'demo-s1', 'demo-e1', jsonb_build_object('quantity', jsonb_build_object('old', 2, 'new', 3)), now() - interval '5 days');

  raise notice 'Solvix demo ready: % asset records, 6 schools, 6 accounts (password %).', k, pw;
end $demo$;

-- what was created
select 'حساب' as "النوع", email as "البريد", role as "الدور" from public.nv_staff where email like '%@solvix-demo.test'
union all select 'مشرف ميدان', email, number from public.nv_employees where id like 'demo-e%'
union all select 'مدرسة', ident, name from public.nv_schools where id like 'demo-s%'
union all select 'سجلات الجرد', count(*)::text, '' from public.nv_collections where id like 'demo-c-%';
