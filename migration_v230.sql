-- V230 / F52 — data integrity fixes after V229. No historical records rewritten.
begin;

create or replace function public.fm_lines230(p jsonb) returns void language plpgsql immutable set search_path=public as $$
declare x jsonb;mid uuid;seen uuid[]:='{}';n numeric;
begin
 if jsonb_typeof(p->'lines') is distinct from 'array' then raise exception 'invalid lines';end if;
 if jsonb_array_length(p->'lines')>3000 then raise exception 'too many lines';end if;
 for x in select value from jsonb_array_elements(p->'lines') loop
  mid:=nullif(x->>'material_id','')::uuid;
  if mid is null then raise exception 'unknown material';end if;
  if mid=any(seen) then raise exception 'duplicate material';end if;seen:=array_append(seen,mid);
  if nullif(x->>'price','') is not null then n:=(x->>'price')::numeric;
   if n<0 or n::text in('NaN','Infinity','-Infinity') then raise exception 'invalid price';end if;
  end if;
  if x?'qty' then n:=nullif(x->>'qty','')::numeric;
   if n is null or n<=0 or n>1000000 or n::text in('NaN','Infinity','-Infinity') then raise exception 'invalid qty';end if;
  end if;
  if x?'count' then n:=nullif(x->>'count','')::numeric;
   if n is null or n<0 or n>100000000 or n::text in('NaN','Infinity','-Infinity') then raise exception 'invalid count';end if;
  end if;
 end loop;
end $$;
revoke all on function public.fm_lines230(jsonb) from public,anon;
grant execute on function public.fm_lines230(jsonb) to authenticated;

create or replace function public.fm_stock_move(p jsonb) returns int language plpgsql security definer set search_path = public as $$
declare k text := p->>'kind'; st public.wo_stores; st2 public.wo_stores; x jsonb; q numeric; cur numeric; n int := 0; m uuid; pr numeric;
  me uuid := auth.uid(); nm text := (select coalesce(full_name, email) from public.profiles where id = auth.uid());
  hold jsonb := '[]'; hv numeric := 0; mp numeric; ap boolean; a public.wo_stock_adj; u uuid;
begin
  perform public.fm_lines230(p);
  if p->>'kind'='transfer' then perform public.fm_transfer_send(p);return jsonb_array_length(p->'lines');end if;
  if me is null or k not in ('in','adjust','transfer') then raise exception 'invalid kind'; end if;
  select * into st from public.wo_stores where id = nullif(p->>'store_id','')::uuid and active;
  if not found or not public.fm_stock_can(st.region) then raise exception 'not allowed'; end if;
  ap := public.fm_adj_approver(st.region) or coalesce(current_setting('fm.adj_ok', true), '') = '1';
  if k = 'transfer' then
    select * into st2 from public.wo_stores where id = nullif(p->>'to_store','')::uuid and active;
    if not found or st2.id = st.id or not public.fm_stock_can(st2.region) then raise exception 'invalid store'; end if;
  end if;
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    m := nullif(x->>'material_id','')::uuid;
    if m is null or not exists(select 1 from public.wo_materials where id = m) then raise exception 'unknown material'; end if;
    pr := nullif(x->>'price','')::numeric;
    insert into public.wo_stock(store_id, material_id) values (st.id, m) on conflict do nothing;
    select qty into cur from public.wo_stock where store_id = st.id and material_id = m for update;
    if k = 'adjust' then q := nullif(x->>'count','')::numeric; if q is null or q < 0 then raise exception 'invalid count'; end if; q := q - cur;
      insert into public.wo_stock_counts(store_id, material_id, book, counted, diff, price, by_id, by_name, held)
      values (st.id, m, cur, cur + q, q, (select price from public.wo_materials where id = m), me, nm,
              q <> 0 and not ap and public.fm_adj_needs(cur, q, (select price from public.wo_materials where id = m)));
    else q := nullif(x->>'qty','')::numeric; if q is null or q <= 0 or q > 1000000 then raise exception 'invalid qty'; end if; end if;
    if q = 0 then continue; end if;
    if k = 'adjust' and not ap then
      select price into mp from public.wo_materials where id = m;
      if public.fm_adj_needs(cur, q, mp) then
        hold := hold || jsonb_build_object('material_id', m, 'book', cur, 'counted', cur + q, 'diff', q, 'price', mp, 'value', round(abs(q) * coalesce(mp,0), 2));
        hv := hv + abs(q) * coalesce(mp,0);
        continue;
      end if;
    end if;
    if k = 'transfer' then
      update public.wo_stock set qty = qty - q, updated_at = now() where store_id = st.id and material_id = m;
      insert into public.wo_stock(store_id, material_id, qty) values (st2.id, m, q)
        on conflict (store_id, material_id) do update set qty = public.wo_stock.qty + q, updated_at = now();
      insert into public.wo_stock_moves(store_id, material_id, qty, kind, note, by_id, by_name) values
        (st.id, m, -q, 'transfer', left(concat_ws(' — ', '← إلى ' || st2.name, nullif(btrim(coalesce(p->>'note','')),'')),300), me, nm),
        (st2.id, m, q, 'transfer', left(concat_ws(' — ', '→ من ' || st.name, nullif(btrim(coalesce(p->>'note','')),'')),300), me, nm);
    else
      update public.wo_stock set qty = qty + q, updated_at = now() where store_id = st.id and material_id = m;
      insert into public.wo_stock_moves(store_id, material_id, qty, kind, unit_price, supplier, invoice_no, note, by_id, by_name)
      values (st.id, m, q, k, case when k = 'in' then pr end, left(nullif(btrim(coalesce(p->>'supplier','')),''),200),
              left(nullif(btrim(coalesce(p->>'invoice_no','')),''),80), left(nullif(btrim(coalesce(p->>'note','')),''),300), me, nm);
      if k = 'in' and pr is not null and pr >= 0 and coalesce((p->>'update_price')::boolean,false) then
        update public.wo_materials set price = pr, updated_at = now() where id = m; end if;
    end if;
    n := n + 1;
  end loop;
  if jsonb_array_length(hold) > 0 then
    insert into public.wo_stock_adj(store_id, region, lines, value, note, by_name)
    values (st.id, st.region, hold, round(hv, 2), left(nullif(btrim(coalesce(p->>'note','')),''),300), nm) returning * into a;
    begin
      for u in select * from public.fm_adj_approvers(st.region) loop
        perform public.fm_push_add(u, 'wh_adj', '⚖️ فرق جرد بانتظار اعتمادك — ' || a.code, st.name || ' • ' || jsonb_array_length(hold) || ' صنف • ' || round(hv) || ' ر.س • ' || coalesce(nm,''), 'wh=adj', 'adj');
      end loop;
    exception when others then null; end;
  end if;
  return n;
end $$;

create or replace function public.fm_po_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; s uuid := nullif(p->>'supplier_id','')::uuid; x jsonb; L jsonb := '[]'; t numeric := 0; q numeric; pr numeric; r public.wo_purchase_requests;
begin
  perform public.fm_lines230(p);
  select * into st from public.wo_stores where id = nullif(p->>'store_id','')::uuid and active;
  if auth.uid() is null or not found or not (public.fm_wh_keeper(st.id) or public.fm_stock_can(st.region)) then raise exception 'not allowed'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    if not exists(select 1 from public.wo_materials where id = nullif(x->>'material_id','')::uuid and active) then raise exception 'unknown material'; end if;
    q := nullif(x->>'qty','')::numeric; if q is null or q <= 0 or q > 1000000 then raise exception 'invalid qty'; end if;
    pr := coalesce(nullif(x->>'price','')::numeric, public.fm_wh_agreed((x->>'material_id')::uuid, s), 0);
    if pr < 0 then raise exception 'invalid price'; end if;
    L := L || jsonb_build_object('material_id', x->>'material_id', 'qty', q, 'price', pr, 'recv', 0); t := t + q * pr;
  end loop;
  if jsonb_array_length(L) = 0 then raise exception 'no lines'; end if;
  insert into public.wo_purchase_requests(store_id, supplier_id, supplier_name, lines, total, note, requested_by_name)
  values (st.id, s, (select name from public.wo_suppliers where id = s), L, round(t,2), left(nullif(btrim(coalesce(p->>'note','')),''),500), public.fm_me_name()) returning * into r;
  return jsonb_build_object('id', r.id, 'code', r.code);
end $$;

create or replace function public.fm_po_act(p_id uuid, p_action text, p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare r public.wo_purchase_requests; st public.wo_stores; pos text := public.fm_my_pos(); lim jsonb := coalesce(public.fm_setting('spend_limits'),'{}'); ok boolean;
  x jsonb; g jsonb; L jsonb := '[]'; q numeric; pr numeric; v numeric; all_done boolean := true; n int := 0; sr text; wm int; at_ timestamptz;
begin
  select * into r from public.wo_purchase_requests where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  select * into st from public.wo_stores where id = r.store_id;
  if p_action in ('approve','reject') then
    if r.status <> 'requested' then raise exception 'invalid status'; end if;
    ok := public.fm_role() = 'admin' or pos in ('sysadmin','dept_manager','project_manager')
      or (pos = 'ops_manager' and (coalesce(nullif(lim->>'ops_manager','')::numeric,0) = 0 or r.total <= (lim->>'ops_manager')::numeric))
      or (pos = 'area_manager' and public.fm_region_ok(coalesce(st.region,'')) and (coalesce(nullif(lim->>'area_manager','')::numeric,0) = 0 or r.total <= (lim->>'area_manager')::numeric));
    if not ok then raise exception 'spend approval required'; end if;
    if p_action = 'reject' and btrim(coalesce(p->>'note','')) = '' then raise exception 'note required'; end if;
    update public.wo_purchase_requests set status = case when p_action = 'approve' then 'approved' else 'rejected' end, approved_by_name = public.fm_me_name(), approved_at = now(),
      response = left(nullif(btrim(coalesce(p->>'note','')),''),500) where id = p_id;
    return p_action;
  elsif p_action = 'cancel' then
    if r.requested_by <> auth.uid() or r.status not in ('requested','approved') then raise exception 'not allowed'; end if;
    update public.wo_purchase_requests set status = 'cancelled' where id = p_id; return 'cancelled';
  elsif p_action = 'receive' then
    perform public.fm_lines230(p);
    if not (public.fm_wh_keeper(st.id) or public.fm_stock_can(st.region)) then raise exception 'not allowed'; end if;
    if r.status not in ('approved','partial') then raise exception 'invalid status'; end if;
    at_ := least(now(), coalesce(nullif(p->>'at','')::date + time '12:00', now()));
    for x in select * from jsonb_array_elements(r.lines) loop
      g := (select e from jsonb_array_elements(coalesce(p->'lines','[]')) t(e) where e->>'material_id' = x->>'material_id' limit 1);
      q := coalesce(nullif(g->>'qty','')::numeric, 0);
      if q < 0 then raise exception 'invalid qty'; end if;
      if q > 0 then
        pr := coalesce(nullif(g->>'price','')::numeric, (x->>'price')::numeric);
        if pr<0 or pr::text in ('NaN','Infinity','-Infinity') then raise exception 'invalid price';end if;
        v := public.fm_wh_receive_line(st.id, (x->>'material_id')::uuid, q, pr, r.supplier_id, r.supplier_name, p->>'invoice_no', at_, r.code, null);
        x := x || jsonb_build_object('recv', coalesce((x->>'recv')::numeric,0) + q, 'paid', pr, 'variance', v);
        select warranty_months into wm from public.wo_materials where id = (x->>'material_id')::uuid;
        for sr in select btrim(e #>> '{}') from jsonb_array_elements(case when jsonb_typeof(g->'serials') = 'array' then g->'serials' else '[]' end) t(e) loop
          if sr <> '' then
            insert into public.wo_serials(material_id, serial, supplier_id, supplier_name, po_code, invoice_no, received_at, warranty_until)
            values ((x->>'material_id')::uuid, left(sr,80), r.supplier_id, r.supplier_name, r.code, left(nullif(btrim(coalesce(p->>'invoice_no','')),''),80), at_::date,
                    case when wm > 0 then (at_::date + make_interval(months => wm))::date end)
            on conflict (material_id, serial) do nothing;
          end if;
        end loop;
        n := n + 1;
      end if;
      if coalesce((x->>'recv')::numeric,0) < (x->>'qty')::numeric then all_done := false; end if;
      L := L || x;
    end loop;
    if n = 0 then raise exception 'nothing received'; end if;
    update public.wo_purchase_requests set lines = L, status = case when all_done then 'received' else 'partial' end, received_at = now() where id = p_id;
    return case when all_done then 'received' else 'partial' end;
  end if;
  raise exception 'invalid action';
end $$;

create or replace function public.fm_po_receive(p_id uuid, p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.wo_purchase_requests; st public.wo_stores; s text; g public.wo_grn; before uuid[]; L jsonb := '[]'; x jsonb; ln jsonb; m public.wo_materials;
  q numeric; pr numeric; tot numeric := 0;
begin
  perform public.fm_lines230(p);
  if length(coalesce(p->>'photo','')) > 560000 then raise exception 'photo too large'; end if;
  select * into r from public.wo_purchase_requests where id = p_id for update;
  if not found then raise exception 'not found'; end if;
  select coalesce(array_agg(id), '{}') into before from public.wo_stock_moves where ref = r.code;
  s := public.fm_po_act(p_id, 'receive', p - 'photo' - 'invoice_date');
  select * into st from public.wo_stores where id = r.store_id;
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    q := coalesce(nullif(x->>'qty','')::numeric, 0);
    if q <= 0 then continue; end if;
    ln := (select e from jsonb_array_elements(r.lines) t(e) where e->>'material_id' = x->>'material_id' limit 1);
    if ln is null then continue; end if;
    select * into m from public.wo_materials where id = (x->>'material_id')::uuid;
    pr := coalesce(nullif(x->>'price','')::numeric, (ln->>'price')::numeric);
    L := L || jsonb_build_object('material_id', m.id, 'name', m.name, 'unit', m.unit, 'code', m.code, 'qty', q, 'price', pr);
    tot := tot + q * coalesce(pr, 0);
  end loop;
  insert into public.wo_grn(store_id, region, supplier, invoice_no, invoice_date, photo, lines, total, note, by_name, po_code)
  values (st.id, st.region, r.supplier_name, left(nullif(btrim(coalesce(p->>'invoice_no','')),''),80),
          coalesce(nullif(p->>'invoice_date','')::date, nullif(p->>'at','')::date), nullif(p->>'photo',''), L, round(tot, 2),
          'استلام طلب الشراء ' || r.code, public.fm_me_name(), r.code)
  returning * into g;
  update public.wo_stock_moves set note = left(concat_ws(' — ', g.code, note), 300) where ref = r.code and not (id = any(before));
  return jsonb_build_object('status', s, 'id', g.id, 'code', g.code);
end $$;

create or replace function public.fm_grn_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; g public.wo_grn; n int; L jsonb := '[]'; x jsonb; m public.wo_materials; tot numeric := 0;
begin
  perform public.fm_lines230(p);
  select * into st from public.wo_stores where id = nullif(p->>'store_id','')::uuid and active;
  if auth.uid() is null or not found or not public.fm_stock_can(st.region) then raise exception 'not allowed'; end if;
  if length(coalesce(p->>'photo','')) > 560000 then raise exception 'photo too large'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    select * into m from public.wo_materials where id = nullif(x->>'material_id','')::uuid;
    if not found then raise exception 'unknown material'; end if;
    L := L || jsonb_build_object('material_id', m.id, 'name', m.name, 'unit', m.unit, 'code', m.code, 'qty', (x->>'qty')::numeric, 'price', nullif(x->>'price','')::numeric);
    tot := tot + coalesce((x->>'qty')::numeric,0) * coalesce(nullif(x->>'price','')::numeric,0);
  end loop;
  if jsonb_array_length(L) = 0 then raise exception 'invalid qty'; end if;
  insert into public.wo_grn(store_id, region, supplier, invoice_no, invoice_date, photo, lines, total, note, by_name)
  values (st.id, st.region, left(nullif(btrim(coalesce(p->>'supplier','')),''),200), left(nullif(btrim(coalesce(p->>'invoice_no','')),''),80),
          nullif(p->>'invoice_date','')::date, nullif(p->>'photo',''), L, round(tot,2), left(nullif(btrim(coalesce(p->>'note','')),''),300), public.fm_me_name())
  returning * into g;
  n := public.fm_stock_move(jsonb_set(p - 'photo' - 'invoice_date', '{note}', to_jsonb(left(concat_ws(' — ', g.code, nullif(btrim(coalesce(p->>'note','')),'')),300))) || '{"kind":"in"}');
  return jsonb_build_object('id', g.id, 'code', g.code, 'moves', n);
end $$;

create or replace function public.fm_issue_req_new(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); h uuid := coalesce(nullif(p->>'holder','')::uuid, auth.uid()); src text := coalesce(nullif(p->>'source',''),'direct');
  w public.work_orders; pos text := public.fm_my_pos(); st uuid := nullif(p->>'store_id','')::uuid; x jsonb; L jsonb := '[]'; m public.wo_materials; q numeric;
  hr text; r public.wo_issue_requests;
begin
  perform public.fm_lines230(p);
  if me is null or src not in ('wo','ticket','direct') then raise exception 'invalid'; end if;
  if h = me then
    if pos not in ('supervisor','contractor','area_engineer') then raise exception 'not allowed'; end if;
    if src = 'direct' and pos in ('supervisor','contractor') then raise exception 'source required'; end if;
  elsif not public.fm_wh_may_direct(h) then raise exception 'not allowed'; end if;
  if src = 'wo' then
    select * into w from public.work_orders where id = nullif(p->>'wo_id','')::uuid;
    if not found or w.status in ('closed','cancelled','rejected') then raise exception 'invalid order'; end if;
    if w.assignee is distinct from h and w.created_by <> me and not public.fm_is_under(w.assignee, me) then raise exception 'invalid order'; end if;
  elsif src = 'ticket' and btrim(coalesce(p->>'ticket_ref','')) = '' then raise exception 'ticket required'; end if;
  select (regions)[1] into hr from public.profiles where id = h;
  st := coalesce(st, public.fm_stock_store_for(coalesce(w.region, hr)));
  if st is null then raise exception 'no store'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    select * into m from public.wo_materials where id = nullif(x->>'material_id','')::uuid;
    if not found or not m.active or m.approved_at is null then raise exception 'item not approved: %', coalesce(m.name, x->>'material_id'); end if;
    q := nullif(x->>'qty','')::numeric;
    if q is null or q <= 0 or q > 100000 then raise exception 'invalid qty'; end if;
    L := L || jsonb_build_object('material_id', m.id, 'qty', q, 'issued', 0);
  end loop;
  if jsonb_array_length(L) = 0 then raise exception 'no lines'; end if;
  if jsonb_array_length(L) > 60 then raise exception 'too many lines'; end if;
  insert into public.wo_issue_requests(holder, holder_name, requested_by, requested_by_name, source, wo_id, wo_code, ticket_ref, school, store_id, lines, note)
  values (h, (select coalesce(full_name, email) from public.profiles where id = h), me, public.fm_me_name(), src, w.id, w.code,
          left(nullif(btrim(coalesce(p->>'ticket_ref','')),''),60), left(coalesce(w.school, nullif(btrim(coalesce(p->>'school','')),'')),200), st, L,
          left(nullif(btrim(coalesce(p->>'note','')),''),500))
  returning * into r;
  return jsonb_build_object('id', r.id, 'code', r.code);
end $$;

create or replace function public.fm_issue_req_act(p_id uuid, p_action text, p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare r public.wo_issue_requests; st uuid; x jsonb; giv jsonb; L jsonb := '[]'; q numeric; rem numeric; cur numeric; m public.wo_materials;
  rules jsonb := coalesce(public.fm_setting('stock_rules'),'{}'); cap numeric; hp text; nm text := public.fm_me_name(); any_issued boolean := false; all_done boolean := true; n int := 0;
begin
  select * into r from public.wo_issue_requests where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if p_action = 'issue' then
    st := coalesce(nullif(p->>'store_id','')::uuid, r.store_id);
    if not public.fm_wh_keeper(st) then raise exception 'storekeeper only'; end if;
    if r.status not in ('requested','partial') then raise exception 'invalid status'; end if;
    for x in select * from jsonb_array_elements(r.lines) loop
      rem := (x->>'qty')::numeric - coalesce((x->>'issued')::numeric,0);
      giv := (select e from jsonb_array_elements(coalesce(p->'lines','[]')) t(e) where e->>'material_id' = x->>'material_id' limit 1);
      q := case when jsonb_array_length(coalesce(p->'lines','[]')) = 0 then rem else least(rem, coalesce(nullif(giv->>'qty','')::numeric,0)) end;
      if q < 0 then raise exception 'invalid qty'; end if;
      if q > 0 then
        select * into m from public.wo_materials where id = (x->>'material_id')::uuid;
        if coalesce((rules->>'block_overdue')::boolean, true) and exists(select 1 from public.wo_custody_moves u where u.holder = r.holder and u.material_id = m.id
             and u.kind = 'use' and u.scrap_open > 0 and u.scrap_due < current_date) then raise exception 'overdue scrap: %', m.name; end if;
        select qty into cur from public.wo_stock where store_id = st and material_id = m.id for update;
        if coalesce(cur,0) < q then raise exception 'insufficient: % (%)', m.name, coalesce(cur,0); end if;
        update public.wo_stock set qty = qty - q, updated_at = now() where store_id = st and material_id = m.id;
        insert into public.wo_stock_moves(store_id, material_id, qty, kind, unit_price, wo_id, wo_code, school, holder, holder_name, ref, note, by_id, by_name)
        values (st, m.id, -q, 'issue', m.price, r.wo_id, r.wo_code, r.school, r.holder, r.holder_name, r.code, r.ticket_ref, auth.uid(), nm);
        insert into public.wo_custody(holder, material_id, qty) values (r.holder, m.id, q)
          on conflict (holder, material_id) do update set qty = public.wo_custody.qty + q, updated_at = now();
        insert into public.wo_custody_moves(holder, holder_name, material_id, kind, qty, unit_price, store_id, wo_id, wo_code, school, ticket_ref, req_id, ref, by_name)
        values (r.holder, r.holder_name, m.id, 'issue', q, m.price, st, r.wo_id, r.wo_code, r.school, r.ticket_ref, r.id, r.code, nm);
        n := n + 1;
      end if;
      x := jsonb_set(x, '{issued}', to_jsonb(coalesce((x->>'issued')::numeric,0) + q));
      if (x->>'issued')::numeric > 0 then any_issued := true; end if;
      if (x->>'issued')::numeric < (x->>'qty')::numeric then all_done := false; end if;
      L := L || x;
    end loop;
    if n = 0 then raise exception 'nothing to issue'; end if;
    hp := (select public.fm_posx(role, job_title) from public.profiles where id = r.holder);
    cap := nullif(rules->'cap'->>hp,'')::numeric;
    if coalesce(cap,0) > 0 and public.fm_custody_value(r.holder) > cap then raise exception 'custody cap: %', cap; end if;
    update public.wo_issue_requests set lines = L, status = case when all_done then 'issued' else 'partial' end, store_id = st, issued_by_name = nm, issued_at = now() where id = p_id;
    return case when all_done then 'issued' else 'partial' end;
  elsif p_action = 'reject' then
    if not public.fm_wh_keeper(r.store_id) then raise exception 'storekeeper only'; end if;
    if r.status not in ('requested','partial') then raise exception 'invalid status'; end if;
    if btrim(coalesce(p->>'note','')) = '' then raise exception 'note required'; end if;
    update public.wo_issue_requests set status = case when r.status = 'partial' then 'issued' else 'rejected' end, response = left(btrim(p->>'note'),500), issued_by_name = coalesce(issued_by_name, nm) where id = p_id;
    return 'rejected';
  elsif p_action = 'cancel' then
    if auth.uid() not in (r.holder, coalesce(r.requested_by, r.holder)) or r.status <> 'requested' then raise exception 'not allowed'; end if;
    update public.wo_issue_requests set status = 'cancelled', response = left(nullif(btrim(coalesce(p->>'note','')),''),500) where id = p_id;
    return 'cancelled';
  elsif p_action = 'receive' then
    raise exception 'signature required: update app and use fm_issue_req_sign_once';
  end if;
  raise exception 'invalid action';
end $$;

alter table public.wo_issue_requests add column if not exists client_payload230 jsonb;
create or replace function public.fm_issue_req_new_once(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare cid text:=nullif(btrim(p->>'client_id'),'');r public.wo_issue_requests;x jsonb;body jsonb:=p-'client_id';
begin
 if auth.uid() is null or public.fm_role()='pending' or not public.fm_mod('wh') then raise exception 'not allowed';end if;
 if cid is null or length(cid)>80 then raise exception 'client_id required';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||cid,230));
 select * into r from public.wo_issue_requests where requested_by=auth.uid() and client_id=cid;
 if found then
  if r.client_payload230 is null then raise exception 'legacy operation requires review';end if;
  if r.client_payload230<>body then raise exception 'operation conflict';end if;
  return jsonb_build_object('id',r.id,'code',r.code,'dup',true);
 end if;
 x:=public.fm_issue_req_new(body);
 update public.wo_issue_requests set client_id=cid,client_payload230=body where id=(x->>'id')::uuid;
 return x;
end $$;

create or replace function public.fm_issue_req_sign_legacy230(p_id uuid, p_sign text, p_inperson boolean default false) returns text language plpgsql security definer set search_path = public as $$
declare r public.wo_issue_requests; md text;
begin
  select * into r from public.wo_issue_requests where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if coalesce(p_sign,'') !~ '^data:image/(png|jpeg);base64,' or length(p_sign) > 120000 then raise exception 'invalid signature'; end if;
  if r.status not in ('issued','partial','received') then raise exception 'invalid status'; end if;
  if r.signed_at is not null and r.signed_at >= coalesce(r.issued_at, r.at) then raise exception 'already signed'; end if;
  if auth.uid() = r.holder then md := 'self';
  elsif coalesce(p_inperson,false) and public.fm_wh_keeper(r.store_id) then md := 'inperson';
  else raise exception 'not allowed'; end if;
  insert into public.wo_issue_signs(req_id, holder, sign, mode, lines, by_name)
  values (r.id, r.holder, p_sign, md, coalesce((select jsonb_agg(jsonb_build_object('material_id', l->>'material_id', 'issued', coalesce((l->>'issued')::numeric,0)))
    from jsonb_array_elements(r.lines) l where coalesce((l->>'issued')::numeric,0) > 0), '[]'), public.fm_me_name());
  update public.wo_issue_requests set signed_at = now(), sign_mode = md, received_at = now(),
    status = case when r.status = 'issued' then 'received' else r.status end where id = p_id;
  return md;
end $$;
revoke all on function public.fm_issue_req_sign_legacy230(uuid,text,boolean) from public,anon,authenticated;

create table if not exists public.fm_receipt_ops230(actor uuid not null references public.profiles(id),op_id text not null,payload jsonb not null,result text not null,at timestamptz not null default now(),primary key(actor,op_id));
alter table public.fm_receipt_ops230 enable row level security;
revoke all on public.fm_receipt_ops230 from anon,authenticated;
create or replace function public.fm_issue_req_sign_once(p jsonb) returns text language plpgsql security definer set search_path=public as $$
declare r public.wo_issue_requests;old public.fm_receipt_ops230;oid text:=nullif(p->>'op_id','');img bytea;result text;
begin
 if auth.uid() is null or public.fm_role()='pending' or not public.fm_mod('wh') then raise exception 'not allowed';end if;
 if oid is null or length(oid)>100 then raise exception 'operation id required';end if;
 perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text||oid,230));
 select * into old from public.fm_receipt_ops230 where actor=auth.uid() and op_id=oid;
 if found then if old.payload<>p then raise exception 'operation conflict';end if;return old.result;end if;
 select * into r from public.wo_issue_requests where id=(p->>'id')::uuid for update;
 if not found then raise exception 'not found';end if;
 if (p->>'expected_issued_at')::timestamptz is distinct from r.issued_at or p->'expected_lines' is distinct from r.lines or r.issued_at is null then raise exception 'receipt changed: reload and sign again';end if;
 if coalesce(p->>'sign','') !~ '^data:image/(png|jpeg);base64,[A-Za-z0-9+/]+={0,2}$' or length(p->>'sign')>120000 then raise exception 'invalid signature';end if;
 img:=decode(split_part(p->>'sign',',',2),'base64');
 if octet_length(img)<20 or not((substring(img from 1 for 8)=decode('89504e470d0a1a0a','hex')) or substring(img from 1 for 3)=decode('ffd8ff','hex')) then raise exception 'invalid signature';end if;
 result:=public.fm_issue_req_sign_legacy230(r.id,p->>'sign',coalesce((p->>'inperson')::boolean,false));
 insert into public.fm_receipt_ops230(actor,op_id,payload,result) values(auth.uid(),oid,p,result);
 return result;
end $$;
create or replace function public.fm_issue_req_sign(p_id uuid,p_sign text,p_inperson boolean default false) returns text language plpgsql security definer set search_path=public as $$
begin raise exception 'receipt snapshot required: update app';end $$;
revoke all on function public.fm_issue_req_sign_once(jsonb) from public,anon;
grant execute on function public.fm_issue_req_sign_once(jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
