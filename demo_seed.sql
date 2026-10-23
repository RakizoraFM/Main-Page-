-- RakizoraFM — demo company (V182). Run ONLY in the Supabase project of the demo company, after supabase_setup.sql.
-- Every name, school, ticket and order here is invented. Nothing of a real client goes into the demo.
--
-- 1) Run this whole file once (it defines the functions; it is idempotent).
-- 2) Create the demo accounts with a password you choose (the same one for all; it is shown on the start page of the demo
--    company, so never reuse a real password):
--      select public.fm_demo_users('اكتب-كلمة-مرور-العرض');
-- 3) Fill the demo data (and refill it any time; pg_cron does it every night at 02:00 Riyadh time when it is enabled):
--      select public.fm_demo_reset();
-- In saas.html mark the company «شركة عرض» and type the same password, so start.html?c=<code> lists the accounts.

insert into public.fm_settings(key, value) values ('demo', 'true') on conflict (key) do update set value = 'true';

-- the demo accounts (fixed ids; the last part of the id says who it is)
create or replace function public.fm_demo_people() returns table(id uuid, email text, name text, title text, regions text[], boss uuid)
language sql immutable as $$
  values
  ('d0000000-0000-0000-0000-000000000001'::uuid, 'demo.admin@rakizora.demo',   'خالد العتيبي (مدير النظام)',     'sysadmin',        '{}'::text[],          null::uuid),
  ('d0000000-0000-0000-0000-000000000002', 'demo.pm@rakizora.demo',      'سعد القحطاني (مدير المشروع)',    'project_manager', '{}',                  null),
  ('d0000000-0000-0000-0000-000000000003', 'demo.area@rakizora.demo',    'فهد الدوسري (مدير منطقة الرياض)', 'area_manager',    '{riyadh}',            'd0000000-0000-0000-0000-000000000002'),
  ('d0000000-0000-0000-0000-000000000004', 'demo.eng1@rakizora.demo',    'م. ناصر الشهري',                'area_engineer',   '{riyadh}',            'd0000000-0000-0000-0000-000000000003'),
  ('d0000000-0000-0000-0000-000000000005', 'demo.eng2@rakizora.demo',    'م. عبدالله الحربي',             'area_engineer',   '{qassim}',            'd0000000-0000-0000-0000-000000000002'),
  ('d0000000-0000-0000-0000-000000000006', 'demo.sup1@rakizora.demo',    'ماجد السبيعي',                  'supervisor',      '{riyadh}',            'd0000000-0000-0000-0000-000000000004'),
  ('d0000000-0000-0000-0000-000000000007', 'demo.sup2@rakizora.demo',    'تركي المطيري',                  'supervisor',      '{riyadh}',            'd0000000-0000-0000-0000-000000000004'),
  ('d0000000-0000-0000-0000-000000000008', 'demo.sup3@rakizora.demo',    'بندر الرشيدي',                  'supervisor',      '{qassim}',            'd0000000-0000-0000-0000-000000000005'),
  ('d0000000-0000-0000-0000-000000000009', 'demo.contractor@rakizora.demo', 'مؤسسة الإتقان للصيانة',        'contractor',      '{riyadh}',            'd0000000-0000-0000-0000-000000000004'),
  ('d0000000-0000-0000-0000-00000000000a', 'demo.store@rakizora.demo',   'يوسف الزهراني (أمين المستودع)',  'storekeeper',     '{riyadh}',            null),
  ('d0000000-0000-0000-0000-00000000000b', 'demo.owner@rakizora.demo',   'م. ريم السالم (ممثل الجهة المالكة)', 'owner_rep',     '{}',                  null),
  ('d0000000-0000-0000-0000-00000000000c', 'demo.acc@rakizora.demo',     'هند العمري (المحاسبة)',           'accountant',      '{}',                  null) $$;

-- create (or reset the password of) the demo accounts — SQL editor only
create or replace function public.fm_demo_users(p_password text) returns int language plpgsql security definer set search_path = public as $$
declare x record; n int := 0;
begin
  if auth.uid() is not null then raise exception 'run it from the SQL editor'; end if;
  if coalesce(public.fm_setting('demo')::text,'') <> 'true' then raise exception 'not a demo project'; end if;
  if length(coalesce(p_password,'')) < 8 then raise exception 'password: at least 8 characters'; end if;
  for x in select * from public.fm_demo_people() loop
    if not exists(select 1 from auth.users where id = x.id) then
      insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at, raw_app_meta_data, raw_user_meta_data,
                              created_at, updated_at, confirmation_token, recovery_token, email_change_token_new, email_change)
      values ('00000000-0000-0000-0000-000000000000', x.id, 'authenticated', 'authenticated', x.email, extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
              '{"provider":"email","providers":["email"]}'::jsonb, jsonb_build_object('full_name', x.name), now(), now(), '', '', '', '');
      insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
      values (gen_random_uuid(), x.id, x.id::text, jsonb_build_object('sub', x.id::text, 'email', x.email, 'email_verified', true, 'phone_verified', false), 'email', now(), now(), now());
    else
      update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now() where id = x.id;
    end if;
    n := n + 1;
  end loop;
  perform public.fm_demo_profiles();
  return n;
end $$;
create or replace function public.fm_demo_profiles() returns void language plpgsql security definer set search_path = public as $$
declare x record;
begin
  for x in select * from public.fm_demo_people() loop
    insert into public.profiles(id, email, full_name, role) values (x.id, x.email, x.name, 'pending') on conflict (id) do nothing;
    update public.profiles set full_name = x.name, job_title = x.title, regions = x.regions, active = true,
      person_names = array[regexp_replace(x.name, '\s*\(.*\)$', '')] where id = x.id;
  end loop;
  for x in select * from public.fm_demo_people() loop update public.profiles set reports_to = x.boss where id = x.id; end loop;
end $$;

-- the demo data: 60 schools, about 900 tickets over 120 days, work orders, warehouse and custody
create or replace function public.fm_demo_seed() returns jsonb language plpgsql security definer set search_path = public as $$
declare
  A_NM text[] := array['النور','الأمل','الفجر','الرواد','الإبداع','المستقبل','الريادة','التميز','الفلاح','الهدى','البيان','الأندلس','قرطبة','اليرموك','حطين',
                     'الفاروق','الصديق','المعرفة','الحكمة','السلام','الخليل','الواحة','النخيل','الربيع','الصفا','المروة','الشروق','العلياء','الياسمين','الندى'];
  A_ST text[] := array['الابتدائية','المتوسطة','الثانوية'];
  A_OF text[] := array['مكتب تعليم الشمال','مكتب تعليم الوسط','مكتب تعليم الشرق','مكتب تعليم بريدة'];
  A_CAT text[][] := array[['تكييف','المكيف لا يبرد في الفصل'],['تكييف','تسريب مياه من وحدة التكييف'],['كهرباء','انقطاع الكهرباء عن جناح الفصول'],['كهرباء','إنارة الممر معطلة'],
                        ['كهرباء','فيش كهرباء محترق'],['سباكة','تسريب مياه في دورات المياه'],['سباكة','انسداد صرف المغاسل'],['سباكة','خلاط مياه تالف'],
                        ['مدني','كسر في بلاط الساحة'],['مدني','باب فصل لا يغلق'],['مدني','زجاج نافذة مكسور'],['حريق','طفاية حريق منتهية الصلاحية'],['حريق','جرس إنذار الحريق معطل'],['مصاعد','المصعد متوقف']];
  A_PR text[] := array['متوسط','متوسط','متوسط','عالي','عالي','طارئ'];
  sch jsonb := '[]'; s jsonb; i int; k int; reg text; sup text; eng text; con text; bid text; nm text; c int; cr timestamptz; pr text; st text; rs timestamptz; hrs numeric;
  lim int; mx timestamptz; st1 uuid; st2 uuid; m uuid; mats uuid[] := '{}'; sp1 uuid; sp2 uuid; w uuid; n_t int := 0; n_w int := 0;
  P_ADM uuid := 'd0000000-0000-0000-0000-000000000001'; P_ENG1 uuid := 'd0000000-0000-0000-0000-000000000004'; P_ENG2 uuid := 'd0000000-0000-0000-0000-000000000005';
  P_S1 uuid := 'd0000000-0000-0000-0000-000000000006'; P_S2 uuid := 'd0000000-0000-0000-0000-000000000007'; P_S3 uuid := 'd0000000-0000-0000-0000-000000000008';
  P_C1 uuid := 'd0000000-0000-0000-0000-000000000009'; P_K uuid := 'd0000000-0000-0000-0000-00000000000a';
begin
  if coalesce(public.fm_setting('demo')::text,'') <> 'true' then raise exception 'not a demo project'; end if;
  perform setseed(0.42);
  if exists(select 1 from public.profiles where id = P_ADM) then perform public.fm_demo_profiles(); end if;
  -- schools (the school DB the platform reads from app_kv)
  for i in 1..60 loop
    reg := case when i <= 40 then 'riyadh' else 'qassim' end;
    sup := case when reg = 'qassim' then 'بندر الرشيدي' when i % 2 = 0 then 'ماجد السبيعي' else 'تركي المطيري' end;
    eng := case when reg = 'qassim' then 'م. عبدالله الحربي' else 'م. ناصر الشهري' end;
    con := case when reg = 'qassim' then 'مؤسسة القصيم الحديثة' else 'مؤسسة الإتقان للصيانة' end;
    nm := 'مدرسة ' || A_NM[1 + (i - 1) % 30] || ' ' || A_ST[1 + (i - 1) % 3] || case when i > 30 then ' ' || (i / 30 + 1)::text else '' end;
    sch := sch || jsonb_build_object('school', nm, 'buildingId', 'D' || (1000 + i), 'region', reg,
      'office', case when reg = 'qassim' then A_OF[4] else A_OF[1 + i % 3] end, 'gender', case when i % 2 = 0 then 'بنين' else 'بنات' end,
      'size', (array['كبير','وسط','وسط','صغير'])[1 + i % 4], 'operation', 'تشغيل كامل',
      'lat', round((case when reg = 'qassim' then 26.30 + random() * 0.12 else 24.62 + random() * 0.22 end)::numeric, 5),
      'lng', round((case when reg = 'qassim' then 43.92 + random() * 0.12 else 46.60 + random() * 0.24 end)::numeric, 5),
      'supervisor', sup, 'supervisorPhone', '0500000' || lpad((100 + i)::text, 3, '0'), 'engineer', eng, 'engineerPhone', '0550000' || lpad((10 + i % 2)::text, 3, '0'),
      'contractor', con, 'principal', 'أ. ' || (array['محمد','عبدالرحمن','نورة','سارة','أحمد','منيرة'])[1 + i % 6] || ' (تجريبي)', 'principalPhone', '0530000' || lpad(i::text, 3, '0'),
      'guard', 'حارس ' || i, 'guardPhone', '0540000' || lpad(i::text, 3, '0'));
  end loop;
  insert into public.app_kv(key, value) values ('fm_school_master_db_v1', sch) on conflict (key) do update set value = excluded.value, updated_at = now();
  -- tickets: about 15 per school over 120 days; 80 % closed, some after their SLA
  for i in 1..60 loop
    s := sch -> (i - 1); c := 8 + floor(random() * 14)::int;
    for k in 1..c loop
      n_t := n_t + 1; pr := A_PR[1 + floor(random() * 6)::int]; lim := case pr when 'طارئ' then 24 when 'عالي' then 48 else 72 end;
      cr := date_trunc('hour', now() - (random() * 120) * interval '1 day');
      hrs := case when random() < 0.82 then lim * (0.15 + random() * 0.9) else lim * (1.05 + random() * 1.5) end;
      rs := cr + hrs * interval '1 hour';
      st := case when rs < now() and random() < 0.92 then (array['مغلق','تم حله'])[1 + floor(random() * 2)::int] when random() < 0.5 then 'قيد التنفيذ' else 'جديد' end;
      if st in ('قيد التنفيذ','جديد') then rs := null; end if;
      bid := s->>'buildingId';
      insert into public.tickets(region, ticket_id, school, building_id, supervisor, engineer, contractor, priority, sub_category, status, created_at, raw)
      values (s->>'region', 'DM-' || lpad(n_t::text, 5, '0'), s->>'school', bid, s->>'supervisor', s->>'engineer', s->>'contractor', pr,
              A_CAT[1 + (n_t * 7 + i) % 14][1], st, cr,
              jsonb_build_object('رقم البلاغ', 'DM-' || lpad(n_t::text, 5, '0'), 'اسم المدرسة', s->>'school', 'الرقم الوزاري / رقم المبنى', bid,
                'الحالة', st, 'الأولوية', pr, 'تاريخ البلاغ', to_char(cr at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"'),
                'تاريخ الإغلاق', coalesce(to_char(rs at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"'), ''),
                'التصنيف الرئيسي', A_CAT[1 + (n_t * 7 + i) % 14][1], 'التصنيف الفرعي', A_CAT[1 + (n_t * 7 + i) % 14][2], 'وصف البلاغ', A_CAT[1 + (n_t * 7 + i) % 14][2],
                'المشرف', s->>'supervisor', 'المهندس', s->>'engineer', 'المقاول', s->>'contractor'))
      on conflict (region, ticket_id) do nothing;
    end loop;
  end loop;
  for reg in select unnest(array['riyadh','qassim']) loop
    select max(created_at) into mx from public.tickets where region = reg;
    insert into public.app_kv(key, value) values ('fm_ref_date_' || reg, to_jsonb(to_char(mx at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS".000Z"')))
      on conflict (key) do update set value = excluded.value, updated_at = now();
  end loop;
  -- warehouse: two stores, approved items, two suppliers, balances
  insert into public.wo_stores(name, region, is_default, active, keeper) values ('مستودع الرياض الرئيسي', 'riyadh', true, true, case when exists(select 1 from public.profiles where id = P_K) then P_K end) returning id into st1;
  insert into public.wo_stores(name, region, is_default, active) values ('مستودع بريدة', 'qassim', true, true) returning id into st2;
  insert into public.wo_suppliers(name, phone, contact, vat_no) values ('مؤسسة التبريد المتقدم (تجريبي)', '0511111111', 'أ. سامي', '300000000000003') returning id into sp1;
  insert into public.wo_suppliers(name, phone, contact) values ('شركة الكهرباء والإنارة (تجريبي)', '0522222222', 'أ. وليد') returning id into sp2;
  for s in select * from jsonb_array_elements('[
      {"n":"فلتر مكيف سبليت","u":"حبة","p":35,"c":"تكييف","sc":false},{"n":"غاز فريون R410 (أسطوانة)","u":"أسطوانة","p":420,"c":"تكييف","sc":true},
      {"n":"كمبروسر مكيف 2 طن","u":"حبة","p":1650,"c":"تكييف","sc":true,"w":12,"sr":true},{"n":"مكثف تشغيل 45 مايكرو","u":"حبة","p":55,"c":"تكييف","sc":true},
      {"n":"قاطع كهرباء 20 أمبير","u":"حبة","p":28,"c":"كهرباء","sc":true},{"n":"لمبة LED 18 واط","u":"حبة","p":22,"c":"كهرباء","sc":false},
      {"n":"فيش كهرباء دبل","u":"حبة","p":9,"c":"كهرباء","sc":false},{"n":"كشاف طوارئ","u":"حبة","p":95,"c":"كهرباء","sc":true,"w":6},
      {"n":"خلاط مغسلة","u":"حبة","p":120,"c":"سباكة","sc":true},{"n":"سيفون كرسي","u":"حبة","p":75,"c":"سباكة","sc":false},
      {"n":"محبس زاوية","u":"حبة","p":18,"c":"سباكة","sc":false},{"n":"طفاية حريق 6 كجم","u":"حبة","p":140,"c":"حريق","sc":true,"w":12},
      {"n":"مقبض باب","u":"حبة","p":45,"c":"مدني","sc":false},{"n":"بلاط أرضيات","u":"م2","p":60,"c":"مدني","sc":false},{"n":"شريط عازل","u":"لفة","p":4,"c":"عام","sc":false}]'::jsonb) loop
    insert into public.wo_materials(code, name, unit, price, category, active, approval, approved_at, approved_by_name, scrap_return, warranty_months, serial_tracked)
    values (public.fm_mat_code(), s->>'n', s->>'u', (s->>'p')::numeric, s->>'c', true, 'approved', now() - interval '30 days', 'م. ريم السالم (ممثل الجهة المالكة)',
            (s->>'sc')::boolean, nullif(s->>'w','')::int, coalesce((s->>'sr')::boolean, false)) returning id into m;
    mats := mats || m;
    insert into public.wo_stock(store_id, material_id, qty, min_qty) values (st1, m, 10 + floor(random() * 60), 10), (st2, m, 5 + floor(random() * 25), 5);
    insert into public.wo_stock_moves(at, store_id, material_id, qty, kind, unit_price, supplier, supplier_id, invoice_no, by_name)
    values (now() - interval '25 days', st1, m, 60, 'in', (s->>'p')::numeric, 'مؤسسة التبريد المتقدم (تجريبي)', sp1, 'INV-D-1001', 'يوسف الزهراني (أمين المستودع)');
    insert into public.wo_supplier_prices(supplier_id, material_id, price, approval, approved_at) values (case when s->>'c' = 'تكييف' then sp1 else sp2 end, m, (s->>'p')::numeric, 'approved', now() - interval '30 days');
  end loop;
  update public.wo_stock set qty = 3 where store_id = st1 and material_id = mats[2];        -- one item below its minimum
  insert into public.wo_materials(code, name, unit, price_new, category, active, approval, nominated_by_name, nominated_at)
  values (public.fm_mat_code(), 'مضخة مياه 1 حصان', 'حبة', 980, 'سباكة', true, 'nominated', 'سعد القحطاني (مدير المشروع)', now() - interval '1 day');
  -- work orders: preventive, repair and handover in every state
  for i in 1..36 loop
    s := sch -> ((i * 7) % 60); reg := s->>'region';
    insert into public.work_orders(code, title, description, type, region, school, building_id, priority, due_at, status, checklist, created_by, created_by_name, assignee, assignee_name,
                                   created_at, updated_at, accepted_at, done_at, closed_at)
    values ('WO-DEMO-' || lpad(i::text, 3, '0'),
      (array['صيانة وقائية — التكييف','صيانة وقائية — الكهرباء','إصلاح تسريب دورات المياه','فحص أنظمة الحريق','استلام موقع (FCI)','إصلاح إنارة الممرات'])[1 + i % 6] || ' — ' || (s->>'school'),
      'أمر عمل تجريبي', (array['preventive','preventive','repair','inspection','handover','repair'])[1 + i % 6], reg, s->>'school', s->>'buildingId',
      (array['متوسط','عالي','متوسط','طارئ'])[1 + i % 4], now() + ((i % 9) - 4) * interval '1 day',
      (array['closed','closed','done','in_progress','accepted','assigned','returned','closed','closed'])[1 + i % 9],
      jsonb_build_array(jsonb_build_object('t','فحص الوحدة وتنظيف الفلاتر','done', i % 9 < 3, 'res','ok'),
                        jsonb_build_object('t','استبدال القطع التالفة','done', i % 9 < 3, 'res', case when i % 9 < 3 then 'fixed' end,
                          'materials', case when i % 9 < 3 then jsonb_build_array(jsonb_build_object('id', mats[1 + i % 15], 'n', (select name from public.wo_materials where id = mats[1 + i % 15]), 'q', 1 + i % 3, 'src', 'store',
                            'price', (select price from public.wo_materials where id = mats[1 + i % 15]))) else '[]'::jsonb end)),
      case when reg = 'qassim' then P_ENG2 else P_ENG1 end, case when reg = 'qassim' then 'م. عبدالله الحربي' else 'م. ناصر الشهري' end,
      case when reg = 'qassim' then P_S3 when i % 3 = 0 then P_C1 when i % 2 = 0 then P_S1 else P_S2 end,
      case when reg = 'qassim' then 'بندر الرشيدي' when i % 3 = 0 then 'مؤسسة الإتقان للصيانة' when i % 2 = 0 then 'ماجد السبيعي' else 'تركي المطيري' end,
      now() - (40 - i) * interval '1 day', now() - (40 - i) * interval '1 day' + interval '2 days', now() - (40 - i) * interval '1 day' + interval '3 hours',
      case when i % 9 in (0,1,2,7,8) then now() - (40 - i) * interval '1 day' + interval '1 day' end,
      case when i % 9 in (0,1,7,8) then now() - (40 - i) * interval '1 day' + interval '2 days' end)
    returning id into w;
    n_w := n_w + 1;
  end loop;
  -- custody: the supervisor holds parts, owes scrap (one overdue), one request waits for the storekeeper, one purchase request
  insert into public.wo_custody(holder, material_id, qty, scrap) values (P_S1, mats[5], 6, 2), (P_S1, mats[2], 1, 1), (P_S2, mats[9], 2, 0);
  insert into public.wo_custody_moves(at, holder, holder_name, material_id, kind, qty, unit_price, store_id, ref, by_name)
  values (now() - interval '12 days', P_S1, 'ماجد السبيعي', mats[5], 'issue', 8, 28, st1, 'IR-DEMO-1', 'يوسف الزهراني (أمين المستودع)');
  insert into public.wo_custody_moves(at, holder, holder_name, material_id, kind, qty, scrap, used, scrap_open, scrap_due, unit_price, wo_code, school, by_name)
  values (now() - interval '11 days', P_S1, 'ماجد السبيعي', mats[5], 'use', -2, 2, 2, 2, current_date - 4, 28, 'WO-DEMO-002', sch->1->>'school', 'م. ناصر الشهري'),
         (now() - interval '2 days', P_S1, 'ماجد السبيعي', mats[2], 'use', 0, 1, 1, 1, current_date + 5, 420, 'WO-DEMO-009', sch->9->>'school', 'م. ناصر الشهري');
  insert into public.wo_issue_requests(holder, holder_name, requested_by, requested_by_name, source, ticket_ref, school, store_id, lines, status)
  values (P_S2, 'تركي المطيري', P_S2, 'تركي المطيري', 'ticket', 'DM-00012', sch->2->>'school', st1, jsonb_build_array(jsonb_build_object('material_id', mats[6], 'qty', 6, 'issued', 0)), 'requested');
  insert into public.wo_purchase_requests(store_id, supplier_id, supplier_name, lines, total, status, requested_by_name)
  values (st1, sp1, 'مؤسسة التبريد المتقدم (تجريبي)', jsonb_build_array(jsonb_build_object('material_id', mats[2], 'qty', 10, 'price', 420, 'recv', 0)), 4200, 'requested', 'يوسف الزهراني (أمين المستودع)');
  -- engagement: the supervisors' schools
  insert into public.fm_eng_assignments(school_code, school_name, region, user_id, principal, phone, active)
  select x->>'buildingId', x->>'school', x->>'region', case when x->>'region' = 'qassim' then P_S3 when (x->>'supervisor') = 'ماجد السبيعي' then P_S1 else P_S2 end, x->>'principal', x->>'principalPhone', true
    from jsonb_array_elements(sch) x where exists(select 1 from public.profiles where id = P_S1);
  return jsonb_build_object('schools', 60, 'tickets', n_t, 'work_orders', n_w);
end $$;

-- wipe the demo data and fill it again
create or replace function public.fm_demo_reset() returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if coalesce(public.fm_setting('demo')::text,'') <> 'true' then raise exception 'not a demo project'; end if;
  if auth.uid() is not null and public.fm_role() <> 'admin' then raise exception 'not allowed'; end if;
  delete from public.wo_custody_moves where true; delete from public.wo_custody where true; delete from public.wo_custody_counts where true;
  delete from public.wo_issue_requests where true; delete from public.wo_purchase_requests where true; delete from public.wo_serials where true;
  delete from public.wo_stock_moves where true; delete from public.wo_stock where true; delete from public.wo_supplier_prices where true;
  delete from public.wo_material_photos where true; delete from public.wo_suppliers where true; delete from public.wo_materials where true; delete from public.wo_stores where true;
  delete from public.work_orders where true; delete from public.tickets where true; delete from public.fm_eng_assignments where true;
  return public.fm_demo_seed();
end $$;
revoke all on function public.fm_demo_users(text), public.fm_demo_profiles(), public.fm_demo_seed(), public.fm_demo_people() from public, anon, authenticated;
revoke all on function public.fm_demo_reset() from public, anon;
grant execute on function public.fm_demo_reset() to authenticated;
do $$ begin
  execute 'select cron.unschedule(''fm-demo-reset'')';
exception when others then null; end $$;
do $$ begin
  execute 'select cron.schedule(''fm-demo-reset'', ''0 23 * * *'', ''select public.fm_demo_reset()'')';
exception when others then null; end $$;
