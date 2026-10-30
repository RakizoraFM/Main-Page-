-- =====================================================================
-- Section 53 (V247): weekly summary for managers «📬 الملخص الأسبوعي»
-- Every Sunday morning each manager gets one push notification (and optionally one WhatsApp message) with
-- last week's numbers for his regions: tickets (sent by the platform from the uploaded file, so the SLA
-- logic is the platform's own), work orders, stock under the minimum and school requests.
-- Same content as section 53 of supabase_setup.sql. Idempotent.
-- =====================================================================

-- ticket numbers per week (Sunday, Riyadh) and region, sent by an uploader; ops = snapshot taken when the summary is sent
create table if not exists public.fm_weekly (
  week     date not null,
  region   text not null,
  tickets  jsonb,
  t_at     timestamptz,
  t_by     text,
  ops      jsonb,
  o_at     timestamptz,
  primary key (week, region)
);
create table if not exists public.fm_weekly_sent (
  week    date not null,
  user_id uuid not null references public.profiles(id) on delete cascade,
  at      timestamptz not null default now(),
  push    boolean not null default false,
  wa      boolean not null default false,
  primary key (week, user_id)
);
alter table public.fm_weekly enable row level security;
alter table public.fm_weekly_sent enable row level security;
revoke all on public.fm_weekly, public.fm_weekly_sent from public, anon, authenticated;

-- the Sunday that starts the week of a moment (Riyadh)
create or replace function public.fm_week_start(t timestamptz) returns date language sql stable as $$
  select ((t at time zone 'Asia/Riyadh')::date - extract(dow from (t at time zone 'Asia/Riyadh'))::int) $$;

-- settings: {enabled (true), titles [...], wa (false)}
create or replace function public.fm_weekly_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'enabled', coalesce((s->>'enabled')::boolean, true),
    'wa', coalesce((s->>'wa')::boolean, false),
    'titles', case when jsonb_typeof(s->'titles') = 'array' then s->'titles'
                   else '["sysadmin","dept_manager","project_manager","ops_manager","area_manager"]'::jsonb end)
  from (select coalesce(public.fm_setting('weekly'), '{}') s) x $$;

-- who may open the page / see the numbers of a region
create or replace function public.fm_weekly_can() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_scope_all() or public.fm_my_pos() in ('area_manager','area_engineer','owner_rep','accountant'), false) $$;
create or replace function public.fm_weekly_all() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_scope_all() or public.fm_my_pos() = 'owner_rep', false) $$;

-- the known regions
create or replace function public.fm_weekly_regions() returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct r order by r), '{}') from (
    select region r from public.tickets union select region from public.work_orders union select region from public.wo_stores
    union select region from public.fm_weekly) x where coalesce(btrim(r),'') <> '' $$;

-- live operational numbers of one region for one week (internal)
create or replace function public.fm_weekly_ops(p_week date, p_region text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a timestamptz := (p_week::timestamp at time zone 'Asia/Riyadh'); b timestamptz := ((p_week + 7)::timestamp at time zone 'Asia/Riyadh');
        o jsonb := '{}'::jsonb;
begin
  if public.fm_mod('wo') then
    select o || jsonb_build_object(
      'wo_new',    count(*) filter (where created_at >= a and created_at < b),
      'wo_closed', count(*) filter (where status = 'closed' and closed_at >= a and closed_at < b),
      'wo_late',   count(*) filter (where status in ('assigned','accepted','in_progress','returned') and due_at < now()),
      'wo_wait',   count(*) filter (where status = 'done'),
      'wo_esc',    count(*) filter (where status in ('assigned','accepted','in_progress','returned') and esc_level > 0),
      'wo_open',   count(*) filter (where status in ('assigned','accepted','in_progress','returned','done')))
      into o from public.work_orders where coalesce(region,'') = p_region;
  end if;
  if public.fm_mod('wh') then
    select o || jsonb_build_object(
      'low', count(*) filter (where k.min_qty > 0 and k.qty < k.min_qty),
      'neg', count(*) filter (where k.qty < 0))
      into o from public.wo_stock k join public.wo_stores s on s.id = k.store_id where s.active and coalesce(s.region,'') = p_region;
  end if;
  if public.fm_mod('portal') then
    select o || jsonb_build_object(
      'req_new',  count(*) filter (where created_at >= a and created_at < b),
      'req_wait', count(*) filter (where status = 'new'))
      into o from public.fm_school_requests where coalesce(region,'') = p_region;
  end if;
  if public.fm_mod('eng') then
    select o || jsonb_build_object('rate_n', count(*), 'rate', round(avg(q_overall)::numeric, 2))
      into o from public.fm_eng_ratings where coalesce(region,'') = p_region and created_at >= a and created_at < b;
  end if;
  return o;
end $$;

-- the platform sends the ticket numbers of a week: {rec, closed, br, sla, open, open_br, avg_h}
create or replace function public.fm_weekly_submit(p_week date, p_region text, p_stats jsonb) returns boolean
language plpgsql security definer set search_path = public as $$
declare k text; v jsonb; clean jsonb := '{}'::jsonb; nm text;
begin
  if auth.uid() is null or not (public.fm_role() = 'admin' or public.fm_can_upload(p_region)) then raise exception 'not allowed'; end if;
  if not public.fm_mod('tickets') then raise exception 'module disabled'; end if;
  if p_week is null or extract(dow from p_week) <> 0 or p_week > public.fm_week_start(now()) or p_week < public.fm_week_start(now()) - 371 then raise exception 'invalid week'; end if;
  if coalesce(btrim(p_region),'') = '' or length(p_region) > 40 then raise exception 'invalid region'; end if;
  if jsonb_typeof(p_stats) <> 'object' then raise exception 'invalid stats'; end if;
  for k, v in select * from jsonb_each(p_stats) loop
    if k in ('rec','closed','br','sla','open','open_br','avg_h','file_date') then
      if k = 'file_date' then clean := clean || jsonb_build_object(k, left(v #>> '{}', 10));
      elsif jsonb_typeof(v) = 'number' and (v::text)::numeric between 0 and 10000000 then clean := clean || jsonb_build_object(k, round((v::text)::numeric, 1));
      elsif jsonb_typeof(v) = 'null' then clean := clean || jsonb_build_object(k, null); end if;
    end if;
  end loop;
  select coalesce(nullif(full_name,''), email) into nm from public.profiles where id = auth.uid();
  insert into public.fm_weekly(week, region, tickets, t_at, t_by) values (p_week, p_region, clean, now(), nm)
  on conflict (week, region) do update set tickets = excluded.tickets, t_at = now(), t_by = excluded.t_by;
  return true;
end $$;

-- the numbers the caller may see for a week (default: last complete week) and the week before
create or replace function public.fm_weekly_data(p_week date default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare w date := coalesce(p_week, public.fm_week_start(now()) - 7); regs text[]; mine text[] := public.fm_regions(); r text; out jsonb := '[]'::jsonb;
        cur public.fm_weekly; prv public.fm_weekly;
begin
  if auth.uid() is null or not public.fm_weekly_can() then raise exception 'not allowed'; end if;
  if extract(dow from w) <> 0 then raise exception 'invalid week'; end if;
  regs := public.fm_weekly_regions();
  foreach r in array regs loop
    if not (public.fm_weekly_all() or cardinality(mine) = 0 or r = any(mine)) then continue; end if;
    select * into cur from public.fm_weekly where week = w and region = r;
    select * into prv from public.fm_weekly where week = w - 7 and region = r;
    out := out || jsonb_build_array(jsonb_build_object('region', r,
      'tickets', cur.tickets, 't_at', cur.t_at, 't_by', cur.t_by,
      'ops', coalesce(cur.ops, public.fm_weekly_ops(w, r)), 'ops_live', cur.ops is null, 'o_at', cur.o_at,
      'prev_tickets', prv.tickets, 'prev_ops', coalesce(prv.ops, public.fm_weekly_ops(w - 7, r))));
  end loop;
  return jsonb_build_object('week', w, 'now_week', public.fm_week_start(now()), 'regions', out, 'cfg', public.fm_weekly_cfg(),
    'can_send', coalesce(public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin', false),
    'sent', (select max(at) from public.fm_weekly_sent where week = w),
    'sent_n', (select count(*) from public.fm_weekly_sent where week = w));
end $$;

-- sum the numbers of several regions (internal)
create or replace function public.fm_weekly_sum(p_rows jsonb, p_key text) returns jsonb language plpgsql immutable as $$
declare x jsonb; k text; v jsonb; o jsonb := '{}'::jsonb; n int := 0; hn numeric := 0; hs numeric := 0;
begin
  for x in select e->p_key from jsonb_array_elements(p_rows) e loop
    if x is null or jsonb_typeof(x) <> 'object' then continue; end if;
    n := n + 1;
    for k, v in select * from jsonb_each(x) loop
      if k in ('sla','rate','avg_h','file_date') or jsonb_typeof(v) <> 'number' then continue; end if;
      o := o || jsonb_build_object(k, coalesce((o->>k)::numeric, 0) + (v::text)::numeric);
    end loop;
    if (x->>'avg_h') is not null and coalesce((x->>'closed')::numeric, 0) > 0 then hs := hs + (x->>'avg_h')::numeric * (x->>'closed')::numeric; hn := hn + (x->>'closed')::numeric; end if;
  end loop;
  if n = 0 then return null; end if;
  if p_key = 'tickets' then
    o := o || jsonb_build_object('sla', case when coalesce((o->>'rec')::numeric,0) > 0 then round(100 - (o->>'br')::numeric * 100 / (o->>'rec')::numeric, 1) end,
                                 'avg_h', case when hn > 0 then round(hs / hn, 1) end);
  end if;
  return o;
end $$;

-- the text of one summary (internal): [title, body, tickets line, orders line, stock / schools line]
create or replace function public.fm_weekly_text(p_week date, t jsonb, o jsonb) returns text[] language plpgsql immutable as $$
declare l1 text; l2 text; l3 text := ''; ttl text;
begin
  ttl := '📬 ملخص الأسبوع ' || to_char(p_week, 'DD/MM') || ' – ' || to_char(p_week + 6, 'DD/MM');
  l1 := case when t is null then '📋 البلاغات: لم تُرفع بيانات هذا الأسبوع'
    else '📋 البلاغات: ' || coalesce((t->>'rec')::numeric::int, 0) || ' جديد • ' || coalesce((t->>'closed')::numeric::int, 0) || ' أُغلق • '
         || coalesce((t->>'br')::numeric::int, 0) || ' تجاوز' || coalesce(' (SLA ' || round((t->>'sla')::numeric) || '%)', '')
         || coalesce(' • مفتوح ' || (t->>'open')::numeric::int, '') || coalesce(' منها ' || nullif((t->>'open_br')::numeric::int, 0) || ' متأخر', '') end;
  l2 := case when o ? 'wo_new' then '🛠️ الأوامر: ' || coalesce((o->>'wo_new')::numeric::int, 0) || ' جديد • ' || coalesce((o->>'wo_closed')::numeric::int, 0) || ' اعتُمد • '
         || coalesce((o->>'wo_late')::numeric::int, 0) || ' متأخر • ' || coalesce((o->>'wo_wait')::numeric::int, 0) || ' بانتظار الاعتماد' else '' end;
  if coalesce((o->>'low')::numeric,0) + coalesce((o->>'neg')::numeric,0) > 0 then l3 := '📦 تحت الحد الأدنى: ' || coalesce((o->>'low')::numeric::int, 0) || ' صنف' || coalesce(' • سالب ' || nullif((o->>'neg')::numeric::int, 0), ''); end if;
  if coalesce((o->>'req_new')::numeric,0) + coalesce((o->>'req_wait')::numeric,0) > 0 then l3 := l3 || case when l3 <> '' then ' • ' else '' end || '🏫 طلبات المدارس: ' || coalesce((o->>'req_new')::numeric::int, 0)
         || coalesce(' (' || nullif((o->>'req_wait')::numeric::int, 0) || ' بانتظار الرد)', ''); end if;
  return array[ttl, left(concat_ws(E'\n', l1, nullif(l2,''), nullif(l3,'')), 300), l1, coalesce(nullif(l2,''), '—'), coalesce(nullif(l3,''), '—')];
end $$;

-- send the summary of a week (default: last complete week). Cron (no caller) or the system admin.
-- p_test = only to the caller (even when already sent or the summary is off).
create or replace function public.fm_weekly_run(p_week date default null, p_test boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare w date := coalesce(p_week, public.fm_week_start(now()) - 7); cfg jsonb := public.fm_weekly_cfg(); regs text[]; r text;
        rows jsonb := '[]'::jsonb; p record; mine jsonb; t jsonb; o jsonb; tx text[]; np int := 0; nw int := 0; nn int := 0; pu boolean; wa boolean;
        base text := nullif(rtrim(coalesce(public.fm_setting('wa')->>'base_url',''), '/'), '');
begin
  if auth.uid() is not null and not (public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin') then raise exception 'not allowed'; end if;
  if extract(dow from w) <> 0 or w > public.fm_week_start(now()) then raise exception 'invalid week'; end if;
  if not p_test and not coalesce((cfg->>'enabled')::boolean, true) then return jsonb_build_object('off', true); end if;
  regs := public.fm_weekly_regions();
  -- snapshot of the operational numbers (kept with the week for the history)
  foreach r in array regs loop
    o := public.fm_weekly_ops(w, r);
    if not p_test then
      insert into public.fm_weekly(week, region, ops, o_at) values (w, r, o, now())
      on conflict (week, region) do update set ops = coalesce(public.fm_weekly.ops, excluded.ops), o_at = coalesce(public.fm_weekly.o_at, now());
    end if;
    rows := rows || jsonb_build_array(jsonb_build_object('region', r, 'tickets', (select tickets from public.fm_weekly where week = w and region = r),
                                                         'ops', coalesce((select ops from public.fm_weekly where week = w and region = r), o)));
  end loop;
  for p in select pr.id, coalesce(nullif(pr.full_name,''), pr.email) nm, pr.phone, pr.regions, public.fm_posx(pr.role, pr.job_title) pos
             from public.profiles pr
            where pr.active and pr.role <> 'pending'
              and (case when p_test then pr.id = auth.uid()
                        else public.fm_posx(pr.role, pr.job_title) in (select jsonb_array_elements_text(cfg->'titles'))
                             and not exists (select 1 from public.fm_weekly_sent s where s.week = w and s.user_id = pr.id) end) loop
    -- his regions: everything for the titles that see all, else his own regions (none set = all)
    select coalesce(jsonb_agg(e), '[]'::jsonb) into mine from jsonb_array_elements(rows) e
     where p.pos in ('sysadmin','dept_manager','project_manager','ops_manager','hse_manager','qa_manager','owner_rep')
        or cardinality(coalesce(p.regions,'{}')) = 0 or (e->>'region') = any(p.regions);
    if jsonb_array_length(mine) = 0 then continue; end if;
    t := public.fm_weekly_sum(mine, 'tickets'); o := coalesce(public.fm_weekly_sum(mine, 'ops'), '{}'::jsonb);
    tx := public.fm_weekly_text(w, t, o);
    pu := public.fm_push_add(p.id, 'weekly', tx[1], tx[2], 'weekly', 'weekly-' || w, p.id = auth.uid());
    wa := false;
    if coalesce((cfg->>'wa')::boolean, false) and p.phone is not null then
      wa := public.fm_wa_add(p.phone, 'weekly', array[p.nm, to_char(w, 'DD/MM') || ' – ' || to_char(w + 6, 'DD/MM'), tx[3], tx[4], tx[5],
              coalesce(base || '/index.html#weekly', '—')], 'weekly', w || ':' || p.id);
    end if;
    if pu then np := np + 1; end if; if wa then nw := nw + 1; end if; nn := nn + 1;
    if not p_test then insert into public.fm_weekly_sent(week, user_id, push, wa) values (w, p.id, pu, wa) on conflict do nothing; end if;
  end loop;
  return jsonb_build_object('week', w, 'people', nn, 'push', np, 'wa', nw);
end $$;

revoke all on function public.fm_weekly_ops(date,text), public.fm_weekly_sum(jsonb,text), public.fm_weekly_text(date,jsonb,jsonb) from public, anon, authenticated;
revoke all on function public.fm_week_start(timestamptz), public.fm_weekly_cfg(), public.fm_weekly_can(), public.fm_weekly_all(), public.fm_weekly_regions(),
  public.fm_weekly_submit(date,text,jsonb), public.fm_weekly_data(date), public.fm_weekly_run(date,boolean) from public, anon;
grant execute on function public.fm_week_start(timestamptz), public.fm_weekly_cfg(), public.fm_weekly_can(), public.fm_weekly_all(), public.fm_weekly_regions(),
  public.fm_weekly_submit(date,text,jsonb), public.fm_weekly_data(date), public.fm_weekly_run(date,boolean) to authenticated;

-- every Sunday 07:30 Riyadh (04:30 UTC): last week's summary
do $do$ begin
  begin execute 'select cron.unschedule(''fm-weekly'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-weekly'', ''30 4 * * 0'', ''select public.fm_weekly_run(null, false)'')';
  exception when others then raise notice 'pg_cron is not available: send the summary from «📬 الملخص الأسبوعي»'; end;
end $do$;
notify pgrst, 'reload schema';
