-- =====================================================================
-- Section 52 (V246) — badges («🏅 لوحة الشرف»)
-- Monthly automatic badges (work orders, school ratings, warehouse) computed on the server, ticket badges
-- (zero SLA breaches, star of the month) computed by the platform from the uploaded tickets and sent by an
-- uploader, and manual appreciation badges given by managers with a reason. Everyone signed in sees the
-- honour board; a new badge sends a push notification and a news-ticker item.
-- Same content as section 52 of supabase_setup.sql. Idempotent.
-- =====================================================================
begin;

create table if not exists public.fm_badges (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references public.profiles(id) on delete cascade,
  user_name  text not null default '',
  job_title  text,
  region     text not null default '',
  kind       text not null,
  period     text,                         -- 'YYYY-MM' for monthly badges, null for manual ones
  auto       boolean not null default false,
  value      numeric,                      -- the number behind an automatic badge (e.g. 12 orders, 4.8 rating)
  reason     text not null default '' check (length(reason) <= 500),
  by_id      uuid references public.profiles(id) on delete set null,
  by_name    text,
  at         timestamptz not null default now(),
  revoked    boolean not null default false,
  revoked_by text,
  revoked_at timestamptz,
  revoke_reason text
);
create unique index if not exists fm_badges_auto_uq on public.fm_badges (user_id, kind, period) where auto and not revoked;
create index if not exists fm_badges_at_idx on public.fm_badges (at desc);
create index if not exists fm_badges_user_idx on public.fm_badges (user_id, at desc);
-- which month / region the platform already sent its ticket badges for
create table if not exists public.fm_badge_runs (
  period text not null, src text not null, region text not null default '',
  at timestamptz not null default now(), by_name text, n int not null default 0,
  primary key (period, src, region));
alter table public.fm_badges enable row level security;
alter table public.fm_badge_runs enable row level security;
revoke all on public.fm_badges, public.fm_badge_runs from anon, authenticated;

-- the badge kinds (icon, title, auto?)
create or replace function public.fm_badge_kinds() returns jsonb language sql immutable as $$
  select '{
    "wo_ontime":{"i":"⏱️","t":"إنجاز في الموعد","a":true},
    "wo_top":{"i":"🏆","t":"الأعلى إنجازاً","a":true},
    "school_love":{"i":"💚","t":"محبوب المدارس","a":true},
    "wh_fast":{"i":"📦","t":"أسرع صرف","a":true},
    "wh_exact":{"i":"🎯","t":"دقة الجرد","a":true},
    "sla_zero":{"i":"✅","t":"صفر تجاوز للمهلة","a":true},
    "star_month":{"i":"⭐","t":"نجم الشهر","a":true},
    "thanks":{"i":"🙏","t":"شكر وتقدير","a":false},
    "hero":{"i":"🦸","t":"موقف مميز","a":false},
    "safety":{"i":"🦺","t":"بطل السلامة","a":false},
    "initiative":{"i":"💡","t":"مبادرة متميزة","a":false},
    "praise":{"i":"🏫","t":"إشادة من مدرسة","a":false}
  }'::jsonb $$;

-- the titles that can earn badges
create or replace function public.fm_badge_titles() returns text[] language sql immutable as $$
  select array['supervisor','area_engineer','contractor','storekeeper'] $$;

-- may the caller give a manual badge to p_user?
create or replace function public.fm_badge_can_award(p_user uuid) returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and p_user is not null and p_user <> auth.uid() and public.fm_role() <> 'pending'
    and exists (select 1 from public.profiles t where t.id = p_user and t.active
                and public.fm_posx(t.role, t.job_title) = any(public.fm_badge_titles()))
    and (public.fm_role() = 'admin'
         or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager','hse_manager','qa_manager')
         or (public.fm_my_pos() = 'area_manager' and (public.fm_is_under(p_user, auth.uid())
              or exists (select 1 from public.profiles t, unnest(case when cardinality(t.regions) = 0 then array['']::text[] else t.regions end) r(x)
                         where t.id = p_user and (r.x = '' or public.fm_region_ok(r.x)))))
         or (public.fm_my_pos() in ('area_engineer','supervisor') and public.fm_is_under(p_user, auth.uid()))) $$;

-- people the caller may give a badge to
create or replace function public.fm_badge_people() returns table(id uuid, full_name text, job_title text, region text)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(nullif(p.full_name,''), p.email), public.fm_posx(p.role, p.job_title), coalesce(p.regions[1], '')
    from public.profiles p
   where p.active and public.fm_posx(p.role, p.job_title) = any(public.fm_badge_titles()) and public.fm_badge_can_award(p.id)
   order by 2 $$;

-- internal: insert one badge, notify the person, return true when new
create or replace function public.fm_badge_put(p_user uuid, p_kind text, p_period text, p_auto boolean, p_value numeric, p_reason text, p_by uuid, p_by_name text)
returns boolean language plpgsql security definer set search_path = public as $$
declare pr record; k jsonb := public.fm_badge_kinds()->p_kind; rc int := 0;
begin
  if k is null then raise exception 'unknown badge'; end if;
  select id, coalesce(nullif(full_name,''), email) nm, public.fm_posx(role, job_title) pos, coalesce(regions[1],'') rg into pr
    from public.profiles where id = p_user and active;
  if not found then return false; end if;
  insert into public.fm_badges(user_id, user_name, job_title, region, kind, period, auto, value, reason, by_id, by_name)
  values (p_user, pr.nm, pr.pos, pr.rg, p_kind, p_period, p_auto, p_value, left(coalesce(p_reason,''),500), p_by, p_by_name)
  on conflict do nothing;
  get diagnostics rc = row_count;
  if rc > 0 then
    begin
      perform public.fm_push_add(p_user, 'badge', (k->>'i') || ' حصلت على شارة «' || (k->>'t') || '»',
        case when p_auto then 'مبروك! شارة شهر ' || coalesce(p_period,'') else coalesce(nullif(p_reason,''),'تقديراً لعملك') || ' — ' || coalesce(p_by_name,'') end,
        '#badges', 'badge', false);
    exception when others then null; end;
  end if;
  return rc > 0;
end $$;

-- news ticker item (author = the caller, else the first active system admin)
create or replace function public.fm_badge_news(p_text text, p_body text) returns void language plpgsql security definer set search_path = public as $$
declare a uuid := auth.uid(); an text;
begin
  if not coalesce((public.fm_setting('badges')->>'news')::boolean, true) then return; end if;
  if a is null then select id into a from public.profiles where active and (role = 'admin' or job_title = 'sysadmin') order by created_at limit 1; end if;
  if a is null then return; end if;
  select coalesce(nullif(full_name,''), email) into an from public.profiles where id = a;
  begin
    insert into public.fm_news(text, body, priority, author, author_name, start_at, end_at)
    values (left(p_text,300), left(coalesce(p_body,''),3000), 'important', a, an, now(), now() + interval '7 days');
  exception when others then null; end;
end $$;

-- manual badge
create or replace function public.fm_badge_award(p_user uuid, p_kind text, p_reason text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare k jsonb := public.fm_badge_kinds()->p_kind; nm text; un text; ok boolean;
begin
  if k is null or coalesce((k->>'a')::boolean, true) then raise exception 'unknown badge'; end if;
  if not public.fm_badge_can_award(p_user) then raise exception 'not allowed'; end if;
  if length(btrim(coalesce(p_reason,''))) < 5 then raise exception 'reason required'; end if;
  if (select count(*) from public.fm_badges where by_id = auth.uid() and not auto and at > now() - interval '1 day') >= 20 then raise exception 'too many today'; end if;
  select coalesce(nullif(full_name,''), email) into nm from public.profiles where id = auth.uid();
  select coalesce(nullif(full_name,''), email) into un from public.profiles where id = p_user;
  ok := public.fm_badge_put(p_user, p_kind, null, false, null, btrim(p_reason), auth.uid(), nm);
  if ok then perform public.fm_badge_news((k->>'i') || ' ' || un || ' حصل على شارة «' || (k->>'t') || '»', btrim(p_reason) || ' — ' || nm); end if;
  return jsonb_build_object('ok', ok);
end $$;

-- revoke (system admin, project manager, or the one who gave a manual badge)
create or replace function public.fm_badge_revoke(p_id uuid, p_reason text) returns boolean
language plpgsql security definer set search_path = public as $$
declare b record; nm text;
begin
  select * into b from public.fm_badges where id = p_id and not revoked for update;
  if not found then raise exception 'not found'; end if;
  if not (public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager') or (not b.auto and b.by_id = auth.uid())) then raise exception 'not allowed'; end if;
  if length(btrim(coalesce(p_reason,''))) < 3 then raise exception 'reason required'; end if;
  select coalesce(nullif(full_name,''), email) into nm from public.profiles where id = auth.uid();
  update public.fm_badges set revoked = true, revoked_by = nm, revoked_at = now(), revoke_reason = left(btrim(p_reason),300) where id = p_id;
  return true;
end $$;

-- the honour board: every badge of a year (everyone signed in sees it)
create or replace function public.fm_badge_list(p_year int default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare y int := coalesce(p_year, extract(year from now() at time zone 'Asia/Riyadh')::int); admin boolean;
begin
  if auth.uid() is null or public.fm_role() = 'pending' then raise exception 'not allowed'; end if;
  admin := public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager');
  return jsonb_build_object('kinds', public.fm_badge_kinds(), 'me', auth.uid(),
    'can_run', public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager'),
    'can_award', exists (select 1 from public.fm_badge_people() limit 1),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'user', b.user_id, 'name', b.user_name, 'title', b.job_title, 'region', b.region,
        'kind', b.kind, 'period', b.period, 'auto', b.auto, 'value', b.value, 'reason', b.reason, 'by', b.by_name, 'at', b.at,
        'can_revoke', admin or (not b.auto and b.by_id = auth.uid())) order by b.at desc)
      from public.fm_badges b where not b.revoked
       and (coalesce(b.period, to_char(b.at at time zone 'Asia/Riyadh','YYYY-MM')) like y::text || '-%')), '[]'::jsonb),
    'runs', coalesce((select jsonb_agg(jsonb_build_object('period', period, 'src', src, 'region', region, 'at', at, 'by', by_name, 'n', n))
      from public.fm_badge_runs where period like y::text || '-%'), '[]'::jsonb));
end $$;

-- monthly server badges for p_month ('YYYY-MM'; default = last month in Riyadh)
create or replace function public.fm_badge_run(p_month text default null) returns int
language plpgsql security definer set search_path = public as $$
declare m text := coalesce(nullif(btrim(p_month),''), to_char((now() at time zone 'Asia/Riyadh') - interval '1 month','YYYY-MM'));
  d0 timestamptz; d1 timestamptz; n int := 0; r record; nm text; cfg jsonb := coalesce(public.fm_setting('badges'), '{}');
begin
  if auth.uid() is not null and not (public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager')) then
    raise exception 'not allowed'; end if;
  if not coalesce((cfg->>'enabled')::boolean, true) then return 0; end if;
  if m !~ '^\d{4}-\d{2}$' or m >= to_char(now() at time zone 'Asia/Riyadh','YYYY-MM') then raise exception 'month must be a past month'; end if;
  d0 := (m || '-01')::timestamp at time zone 'Asia/Riyadh'; d1 := ((m || '-01')::date + interval '1 month')::timestamp at time zone 'Asia/Riyadh';
  select coalesce(nullif(full_name,''), email) into nm from public.profiles where id = auth.uid();
  -- ⏱️ on time: ≥ 5 orders with a due date done in the month, all on time, no return in the month
  for r in select w.assignee u, count(*) c from public.work_orders w join public.profiles p on p.id = w.assignee
            where w.done_at >= d0 and w.done_at < d1 and w.due_at is not null and w.status in ('done','closed')
              and public.fm_posx(p.role, p.job_title) in ('supervisor','contractor','area_engineer')
            group by w.assignee
           having count(*) >= 5 and bool_and(w.done_at <= w.due_at)
              and not exists (select 1 from public.wo_events e join public.work_orders w2 on w2.id = e.wo_id
                               where w2.assignee = w.assignee and e.type = 'return' and e.at >= d0 and e.at < d1) loop
    if public.fm_badge_put(r.u, 'wo_ontime', m, true, r.c, r.c || ' أمر عمل في موعدها دون إرجاع', null, 'تلقائي') then n := n + 1; end if;
  end loop;
  -- 🏆 most orders done in the month per region (≥ 5; ties share it)
  for r in with c as (select coalesce(nullif(w.region,''),'—') rg, w.assignee u, count(*) c from public.work_orders w join public.profiles p on p.id = w.assignee
                        where w.done_at >= d0 and w.done_at < d1 and w.status in ('done','closed')
                          and public.fm_posx(p.role, p.job_title) in ('supervisor','contractor') group by 1, 2 having count(*) >= 5)
           select u, c, rg from (select c.*, rank() over (partition by rg order by c desc) rk from c) x where rk = 1 loop
    if public.fm_badge_put(r.u, 'wo_top', m, true, r.c, r.c || ' أمر عمل منجز — الأعلى في ' || case r.rg when 'riyadh' then 'الرياض' when 'qassim' then 'القصيم' else r.rg end, null, 'تلقائي') then n := n + 1; end if;
  end loop;
  -- 💚 school ratings ≥ 4.5 from ≥ 3 ratings in the month (supervisor / engineer score)
  for r in select u, avg(s)::numeric(4,2) a, count(*) c from (
             select supervisor_id u, q_supervisor s from public.fm_eng_ratings where created_at >= d0 and created_at < d1 and supervisor_id is not null and q_supervisor is not null
             union all
             select engineer_id, q_engineer from public.fm_eng_ratings where created_at >= d0 and created_at < d1 and engineer_id is not null and q_engineer is not null) x
            group by u having count(*) >= 3 and avg(s) >= 4.5 loop
    if public.fm_badge_put(r.u, 'school_love', m, true, r.a, 'متوسط تقييم المدارس ' || r.a || ' من 5 (' || r.c || ' تقييم)', null, 'تلقائي') then n := n + 1; end if;
  end loop;
  -- 📦 storekeeper: ≥ 10 requests issued in the month, median request → issue ≤ 24 h
  for r in select p.id u, count(*) c, percentile_cont(0.5) within group (order by extract(epoch from (q.issued_at - q.at))/3600.0) h
             from public.wo_issue_requests q join public.profiles p on p.active and public.fm_posx(p.role, p.job_title) = 'storekeeper'
                  and btrim(coalesce(p.full_name,'')) <> '' and btrim(q.issued_by_name) = btrim(p.full_name)
            where q.issued_at >= d0 and q.issued_at < d1 group by p.id having count(*) >= 10 loop
    if r.h <= 24 and public.fm_badge_put(r.u, 'wh_fast', m, true, round(r.h::numeric,1), r.c || ' طلب صرف — الوسيط ' || round(r.h::numeric,1) || ' ساعة', null, 'تلقائي') then n := n + 1; end if;
  end loop;
  -- 🎯 storekeeper: ≥ 20 counted lines in the month, ≥ 98 % without difference
  for r in select c.by_id u, count(*) c, (100.0 * count(*) filter (where coalesce(c.diff,0) = 0) / count(*))::numeric(5,1) pc
             from public.wo_stock_counts c join public.profiles p on p.id = c.by_id
            where c.at >= d0 and c.at < d1 and public.fm_posx(p.role, p.job_title) = 'storekeeper' group by c.by_id having count(*) >= 20 loop
    if r.pc >= 98 and public.fm_badge_put(r.u, 'wh_exact', m, true, r.pc, r.c || ' سطر جرد — مطابقة ' || r.pc || '%', null, 'تلقائي') then n := n + 1; end if;
  end loop;
  insert into public.fm_badge_runs(period, src, region, by_name, n) values (m, 'server', '', coalesce(nm,'تلقائي'), n)
  on conflict (period, src, region) do update set at = now(), by_name = excluded.by_name, n = public.fm_badge_runs.n + excluded.n;
  if n > 0 then perform public.fm_badge_news('🏅 شارات شهر ' || m || ': ' || n || ' شارة جديدة', 'افتح «🏅 لوحة الشرف» لمعرفة المتميزين.'); end if;
  return n;
end $$;

-- ticket badges computed by the platform: p_rows [{name, kind: sla_zero | star_month, value, note}]
create or replace function public.fm_badge_submit(p_month text, p_region text, p_rows jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int := 0; x jsonb; u uuid; nm text; k text;
begin
  if auth.uid() is null or not (public.fm_role() = 'admin' or public.fm_can_upload(p_region)) then raise exception 'not allowed'; end if;
  if p_month !~ '^\d{4}-\d{2}$' or p_month >= to_char(now() at time zone 'Asia/Riyadh','YYYY-MM') then raise exception 'month must be a past month'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 300 then raise exception 'invalid rows'; end if;
  if not coalesce((public.fm_setting('badges')->>'enabled')::boolean, true) then return 0; end if;
  select coalesce(nullif(full_name,''), email) into nm from public.profiles where id = auth.uid();
  for x in select * from jsonb_array_elements(p_rows) loop
    k := x->>'kind';
    if k not in ('sla_zero','star_month') then continue; end if;
    select p.id into u from public.profiles p
     where p.active and public.fm_posx(p.role, p.job_title) in ('supervisor','area_engineer')
       and (btrim(x->>'name') = any(coalesce(p.person_names,'{}')) or btrim(coalesce(p.full_name,'')) = btrim(x->>'name'))
     order by p.created_at limit 1;
    if u is null then continue; end if;
    if public.fm_badge_put(u, k, p_month, true, nullif(x->>'value','')::numeric, left(coalesce(x->>'note',''),300), auth.uid(), 'تلقائي — ' || coalesce(nm,'')) then n := n + 1; end if;
  end loop;
  insert into public.fm_badge_runs(period, src, region, by_name, n) values (p_month, 'tickets', coalesce(p_region,''), nm, n)
  on conflict (period, src, region) do update set at = now(), by_name = excluded.by_name, n = public.fm_badge_runs.n + excluded.n;
  if n > 0 then perform public.fm_badge_news('🏅 شارات البلاغات لشهر ' || p_month || ': ' || n || ' شارة', 'افتح «🏅 لوحة الشرف» لمعرفة المتميزين.'); end if;
  return n;
end $$;

revoke all on function public.fm_badge_put(uuid,text,text,boolean,numeric,text,uuid,text), public.fm_badge_news(text,text) from public, anon, authenticated;
revoke all on function public.fm_badge_kinds(), public.fm_badge_titles(), public.fm_badge_can_award(uuid), public.fm_badge_people(), public.fm_badge_award(uuid,text,text),
  public.fm_badge_revoke(uuid,text), public.fm_badge_list(int), public.fm_badge_run(text), public.fm_badge_submit(text,text,jsonb) from public, anon;
grant execute on function public.fm_badge_kinds(), public.fm_badge_titles(), public.fm_badge_can_award(uuid), public.fm_badge_people(), public.fm_badge_award(uuid,text,text),
  public.fm_badge_revoke(uuid,text), public.fm_badge_list(int), public.fm_badge_run(text), public.fm_badge_submit(text,text,jsonb) to authenticated;

-- the 1st of every month, 06:10 Riyadh (03:10 UTC): last month's server badges
do $do$ begin
  begin execute 'select cron.unschedule(''fm-badges'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-badges'', ''10 3 1 * *'', ''select public.fm_badge_run(null)'')';
  exception when others then raise notice 'pg_cron is not available: run «احتساب شارات الشهر» from «🏅 لوحة الشرف»'; end;
end $do$;
notify pgrst, 'reload schema';
commit;
