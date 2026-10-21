-- =====================================================================
--  FM Platform — Supabase setup (V136, user management V141, profile V142, work orders V145–V149)
--  Paste this whole file in Supabase → SQL Editor → New query → Run.
--  Safe to run again: it only creates what is missing and refreshes policies.
-- =====================================================================

-- ---------- 1) users & roles ----------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  email        text,
  full_name    text,
  role         text not null default 'pending'
               check (role in ('pending','admin','engineer','supervisor','contractor','viewer')),
  person_names text[] not null default '{}',   -- names exactly as they appear in the tickets / school DB
  regions      text[] not null default '{}',   -- empty = all regions
  active       boolean not null default true,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
-- V145: the direct manager (work orders flow down this line)
alter table public.profiles add column if not exists reports_to uuid references public.profiles(id) on delete set null;
-- V157: the job title (المسمى الوظيفي). It decides the technical role (role follows it), the rank in the line and the scope.
--   sysadmin=مدير النظام, dept_manager=مدير الإدارة (read only), project_manager=مدير المشروع, ops_manager=مدير العمليات,
--   area_manager=مدير المنطقة (his regions), area_engineer=مهندس المنطقة, supervisor=المشرف, contractor=المقاول,
--   hse_manager=مدير الأمن والسلامة, qa_manager=مدير الجودة والتخطيط (both see everything, may open orders for anyone below the ops manager)
--   accountant=المحاسب (V171: support role like HSE / QA, sees his regions; building costs per the cost permissions)
alter table public.profiles add column if not exists job_title text;
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.profiles'::regclass and contype = 'c'
            and pg_get_constraintdef(oid) ilike '%role%' and pg_get_constraintdef(oid) not ilike '%job_title%' loop
    execute format('alter table public.profiles drop constraint %I', c); end loop;
  alter table public.profiles add constraint profiles_role_check
    check (role in ('pending','admin','manager','staff','engineer','supervisor','contractor','viewer'));
end $$;
alter table public.profiles drop constraint if exists profiles_position_check;
alter table public.profiles add constraint profiles_position_check check (job_title is null or job_title in
  ('sysadmin','dept_manager','project_manager','ops_manager','area_manager','area_engineer','supervisor','contractor','hse_manager','qa_manager','accountant'));
create or replace function public.fm_pos_role(p text) returns text language sql immutable as $$
  select case p when 'sysadmin' then 'admin' when 'dept_manager' then 'viewer'
    when 'project_manager' then 'manager' when 'ops_manager' then 'manager' when 'area_manager' then 'manager'
    when 'area_engineer' then 'engineer' when 'supervisor' then 'supervisor' when 'contractor' then 'contractor'
    when 'hse_manager' then 'staff' when 'qa_manager' then 'staff' when 'accountant' then 'staff' end $$;
create or replace function public.fm_profile_pos_trg() returns trigger language plpgsql as $$
begin
  if new.job_title is not null then new.role := public.fm_pos_role(new.job_title); end if;
  return new;
end $$;
drop trigger if exists fm_profile_pos on public.profiles;
create trigger fm_profile_pos before insert or update of job_title, role on public.profiles
  for each row execute function public.fm_profile_pos_trg();

-- the first account becomes admin, everyone after that waits for the admin to assign a role
create or replace function public.fm_handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id,email,full_name,role)
  values (new.id, new.email, coalesce(new.raw_user_meta_data->>'full_name', split_part(new.email,'@',1)),
          case when exists(select 1 from public.profiles where role='admin') then 'pending' else 'admin' end)
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists fm_on_auth_user_created on auth.users;
create trigger fm_on_auth_user_created after insert on auth.users
  for each row execute function public.fm_handle_new_user();

-- helpers used by the policies (security definer: read the caller's own profile)
create or replace function public.fm_role() returns text language sql stable security definer set search_path = public as $$
  select case when p.active then p.role else 'pending' end from public.profiles p where p.id = auth.uid() $$;
create or replace function public.fm_names() returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(p.person_names,'{}') from public.profiles p where p.id = auth.uid() $$;
create or replace function public.fm_regions() returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(p.regions,'{}') from public.profiles p where p.id = auth.uid() $$;
create or replace function public.fm_region_ok(r text) returns boolean language sql stable as $$
  select cardinality(public.fm_regions()) = 0 or r = any(public.fm_regions()) $$;
-- V157: the effective job title (older accounts get one from their role) and its rank in the line
create or replace function public.fm_posx(p_role text, p_pos text) returns text language sql immutable as $$
  select coalesce(p_pos, case p_role when 'admin' then 'sysadmin' when 'engineer' then 'area_engineer'
    when 'supervisor' then 'supervisor' when 'contractor' then 'contractor' when 'viewer' then 'viewer' end) $$;
create or replace function public.fm_prank(p_pos text) returns int language sql immutable as $$
  select case p_pos when 'sysadmin' then 9 when 'dept_manager' then 8 when 'project_manager' then 7 when 'ops_manager' then 6
    when 'area_manager' then 5 when 'area_engineer' then 4 when 'supervisor' then 3 when 'contractor' then 2 else 0 end $$;
create or replace function public.fm_my_pos() returns text language sql stable security definer set search_path = public as $$
  select case when p.active then public.fm_posx(p.role, p.job_title) end from public.profiles p where p.id = auth.uid() $$;
-- sees every region and every order (read): system admin, department / project / operations managers, safety, quality
create or replace function public.fm_scope_all() returns boolean language sql stable as $$
  select coalesce(public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager','hse_manager','qa_manager'), false) $$;
-- the area manager sees his regions (no region set = all)
create or replace function public.fm_scope_region(r text) returns boolean language sql stable as $$
  select public.fm_scope_all() or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(r,''))) $$;

-- ---------- 2) tickets (uploaded by the admin from the Excel file) ----------
create table if not exists public.tickets (
  region       text not null,
  ticket_id    text not null,
  school       text,
  building_id  text,
  supervisor   text,
  engineer     text,
  contractor   text,
  priority     text,
  sub_category text,
  status       text,
  created_at   timestamptz,
  raw          jsonb not null,
  uploaded_at  timestamptz not null default now(),
  uploaded_by  uuid default auth.uid(),
  primary key (region, ticket_id)
);
create index if not exists tickets_sup_idx on public.tickets (region, supervisor);
create index if not exists tickets_eng_idx on public.tickets (region, engineer);
create index if not exists tickets_con_idx on public.tickets (region, contractor);

-- can the caller see this ticket?
create or replace function public.fm_can_see(r text, t text) returns boolean
language sql stable security definer set search_path = public as $$
  select case public.fm_role()
    when 'admin'  then true
    when 'viewer' then public.fm_region_ok(r)
    when 'manager' then public.fm_region_ok(r)
    when 'staff'   then public.fm_region_ok(r)
    when 'engineer'   then exists(select 1 from public.tickets k where k.region=r and k.ticket_id=t and public.fm_region_ok(r) and (k.engineer   = any(public.fm_names()) or k.supervisor = any(public.fm_names())))
    when 'supervisor' then exists(select 1 from public.tickets k where k.region=r and k.ticket_id=t and public.fm_region_ok(r) and  k.supervisor = any(public.fm_names()))
    when 'contractor' then exists(select 1 from public.tickets k where k.region=r and k.ticket_id=t and public.fm_region_ok(r) and  k.contractor = any(public.fm_names()))
    else false end $$;
create or replace function public.fm_can_edit(r text, t text) returns boolean language sql stable as $$
  select public.fm_role() in ('admin','manager','engineer','supervisor','contractor') and public.fm_can_see(r,t) $$;

-- ---------- 3) shared settings (school DB, SLA hours, closing rules …) ----------
create table if not exists public.app_kv (
  key        text primary key,
  value      jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid default auth.uid()
);

-- ---------- 4) work on tickets ----------
create table if not exists public.ticket_work (
  region          text not null,
  ticket_id       text not null,
  stage           text not null,
  rec             jsonb not null,           -- resolution, parts, edits, assignee …
  resolved_at     timestamptz,
  updated_at      timestamptz not null default now(),
  updated_by      uuid default auth.uid(),
  updated_by_name text,
  primary key (region, ticket_id)
);
create table if not exists public.ticket_events (     -- append-only: history + notes + field arrivals
  id        uuid primary key default gen_random_uuid(),
  region    text not null,
  ticket_id text not null,
  at        timestamptz not null default now(),
  by_id     uuid default auth.uid(),
  by_name   text,
  type      text not null,                  -- stage | close | edit | note | photo | arrive | sys
  stage     text,
  text      text,
  geo       jsonb
);
create index if not exists ticket_events_t_idx on public.ticket_events (region, ticket_id, at);
create table if not exists public.ticket_photos (
  id        uuid primary key default gen_random_uuid(),
  region    text not null,
  ticket_id text not null,
  kind      text not null default 'after' check (kind in ('before','after')),
  path      text not null,
  at        timestamptz not null default now(),
  by_id     uuid default auth.uid(),
  by_name   text,
  geo       jsonb
);
create index if not exists ticket_photos_t_idx on public.ticket_photos (region, ticket_id);

-- ---------- 5) row level security ----------
alter table public.profiles      enable row level security;
alter table public.tickets       enable row level security;
alter table public.app_kv        enable row level security;
alter table public.ticket_work   enable row level security;
alter table public.ticket_events enable row level security;
alter table public.ticket_photos enable row level security;

drop policy if exists p_profiles_read  on public.profiles;
drop policy if exists p_profiles_admin on public.profiles;
drop policy if exists p_profiles_self  on public.profiles;
create policy p_profiles_read  on public.profiles for select using (id = auth.uid() or public.fm_role() = 'admin');
create policy p_profiles_admin on public.profiles for update using (public.fm_role() = 'admin') with check (public.fm_role() = 'admin');
-- a user may only change their own display name (role, names and regions stay as the admin set them)
create policy p_profiles_self  on public.profiles for update using (id = auth.uid())
  with check (id = auth.uid() and role = (select role from public.profiles where id = auth.uid())
              and job_title is not distinct from (select job_title from public.profiles where id = auth.uid())
              and person_names = (select person_names from public.profiles where id = auth.uid())
              and regions = (select regions from public.profiles where id = auth.uid())
              and active = (select active from public.profiles where id = auth.uid())
              and reports_to is not distinct from (select reports_to from public.profiles where id = auth.uid()));

drop policy if exists p_tickets_read  on public.tickets;
drop policy if exists p_tickets_write on public.tickets;
create policy p_tickets_read  on public.tickets for select using (public.fm_can_see(region, ticket_id));
create policy p_tickets_write on public.tickets for all using (public.fm_role() = 'admin') with check (public.fm_role() = 'admin');

drop policy if exists p_kv_read  on public.app_kv;
drop policy if exists p_kv_write on public.app_kv;
create policy p_kv_read  on public.app_kv for select using (public.fm_role() in ('admin','manager','staff','engineer','supervisor','contractor','viewer'));
create policy p_kv_write on public.app_kv for all using (public.fm_role() = 'admin') with check (public.fm_role() = 'admin');

-- only admin / engineer may verify-and-close or cancel
drop policy if exists p_work_read   on public.ticket_work;
drop policy if exists p_work_insert on public.ticket_work;
drop policy if exists p_work_update on public.ticket_work;
drop policy if exists p_work_delete on public.ticket_work;
create policy p_work_read   on public.ticket_work for select using (public.fm_can_see(region, ticket_id));
create policy p_work_insert on public.ticket_work for insert with check (public.fm_can_edit(region, ticket_id)
  and (public.fm_role() in ('admin','manager','engineer') or stage not in ('closed','cancelled')));
create policy p_work_update on public.ticket_work for update using (public.fm_can_edit(region, ticket_id))
  with check (public.fm_can_edit(region, ticket_id) and (public.fm_role() in ('admin','manager','engineer') or stage not in ('closed','cancelled')));
create policy p_work_delete on public.ticket_work for delete using (public.fm_role() = 'admin');

drop policy if exists p_ev_read   on public.ticket_events;
drop policy if exists p_ev_insert on public.ticket_events;
drop policy if exists p_ev_delete on public.ticket_events;
create policy p_ev_read   on public.ticket_events for select using (public.fm_can_see(region, ticket_id));
create policy p_ev_insert on public.ticket_events for insert with check (public.fm_can_edit(region, ticket_id) and by_id = auth.uid());
create policy p_ev_delete on public.ticket_events for delete using (public.fm_role() = 'admin');

drop policy if exists p_ph_read   on public.ticket_photos;
drop policy if exists p_ph_insert on public.ticket_photos;
drop policy if exists p_ph_delete on public.ticket_photos;
create policy p_ph_read   on public.ticket_photos for select using (public.fm_can_see(region, ticket_id));
create policy p_ph_insert on public.ticket_photos for insert with check (public.fm_can_edit(region, ticket_id) and by_id = auth.uid());
create policy p_ph_delete on public.ticket_photos for delete using (public.fm_role() in ('admin','manager','engineer') or by_id = auth.uid());

-- ---------- 6) photo storage (private bucket; path = region/ticket_id/file.jpg) ----------
insert into storage.buckets (id, name, public) values ('ticket-photos','ticket-photos', false)
  on conflict (id) do nothing;
-- storage policies: newer Supabase projects may refuse changes to storage.objects from the SQL editor
-- ("must be owner of relation objects"); then the existing policies stay and the rest of this file still runs
do $do$ begin
  execute $q$drop policy if exists p_obj_read   on storage.objects$q$;
  execute $q$drop policy if exists p_obj_insert on storage.objects$q$;
  execute $q$drop policy if exists p_obj_delete on storage.objects$q$;
  execute $q$create policy p_obj_read   on storage.objects for select using (bucket_id = 'ticket-photos'
  and public.fm_can_see(split_part(name,'/',1), split_part(name,'/',2)))$q$;
  execute $q$create policy p_obj_insert on storage.objects for insert with check (bucket_id = 'ticket-photos'
  and public.fm_can_edit(split_part(name,'/',1), split_part(name,'/',2)))$q$;
  execute $q$create policy p_obj_delete on storage.objects for delete using (bucket_id = 'ticket-photos'
  and (public.fm_role() in ('admin','engineer') or owner = auth.uid()))$q$;
exception when insufficient_privilege then
  raise notice 'ticket-photos: لم تُحدَّث سياسات التخزين (لا صلاحية على storage.objects) — أضفها من Storage ← Policies إن لزم';
end $do$;

-- ---------- 7) live updates ----------
do $$ begin
  begin alter publication supabase_realtime add table public.ticket_work;   exception when others then null; end;
  begin alter publication supabase_realtime add table public.ticket_events; exception when others then null; end;
end $$;

-- ---------- 8) user management by the admin (V141) ----------
-- The admin creates users, sets temporary passwords and resets them from the platform.
-- These functions run with the database owner's rights, so no service_role key is ever needed in the pages;
-- each one refuses to work unless the caller is an active admin.
alter table public.profiles add column if not exists must_change_pw boolean not null default false;

create or replace function public.fm_admin_create_user(p_email text, p_password text, p_full_name text, p_role text,
  p_regions text[] default '{}', p_names text[] default '{}', p_active boolean default true)
returns uuid language plpgsql security definer set search_path = public, extensions, auth as $$
declare v_id uuid := gen_random_uuid(); v_email text := lower(trim(p_email));
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed' using errcode = '42501'; end if;
  if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'invalid email'; end if;
  if length(coalesce(p_password,'')) < 8 then raise exception 'password too short'; end if;
  if p_role not in ('admin','manager','staff','engineer','supervisor','contractor','viewer','pending') then raise exception 'invalid role'; end if;
  if exists (select 1 from auth.users where lower(email) = v_email) then raise exception 'User already registered'; end if;
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
          extensions.crypt(p_password, extensions.gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}'::jsonb,
          jsonb_build_object('full_name', coalesce(nullif(trim(p_full_name),''), split_part(v_email,'@',1))),
          now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_id, v_id::text,
          jsonb_build_object('sub', v_id::text, 'email', v_email, 'email_verified', true, 'phone_verified', false),
          'email', now(), now(), now());
  -- the fm_on_auth_user_created trigger has just made the profile; apply what the admin chose
  update public.profiles set full_name = coalesce(nullif(trim(p_full_name),''), full_name), role = p_role,
         regions = coalesce(p_regions,'{}'), person_names = coalesce(p_names,'{}'), active = coalesce(p_active,true),
         must_change_pw = true, updated_at = now()
   where id = v_id;
  return v_id;
end $$;

create or replace function public.fm_admin_set_password(p_user uuid, p_password text) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed' using errcode = '42501'; end if;
  if length(coalesce(p_password,'')) < 8 then raise exception 'password too short'; end if;
  update auth.users set encrypted_password = extensions.crypt(p_password, extensions.gen_salt('bf')), updated_at = now()
   where id = p_user;
  if not found then raise exception 'user not found'; end if;
  update public.profiles set must_change_pw = true, updated_at = now() where id = p_user;
end $$;

-- called by the user right after choosing a new password
create or replace function public.fm_password_changed() returns void
language sql security definer set search_path = public as $$
  update public.profiles set must_change_pw = false, updated_at = now() where id = auth.uid() $$;

revoke all on function public.fm_admin_create_user(text,text,text,text,text[],text[],boolean) from public, anon;
revoke all on function public.fm_admin_set_password(uuid,text) from public, anon;
revoke all on function public.fm_password_changed() from public, anon;
grant execute on function public.fm_admin_create_user(text,text,text,text,text[],text[],boolean) to authenticated;
grant execute on function public.fm_admin_set_password(uuid,text) to authenticated;
grant execute on function public.fm_password_changed() to authenticated;

-- ---------- 9) personal profile: phone, photo, contact sync (V142) ----------
alter table public.profiles add column if not exists phone  text;
alter table public.profiles add column if not exists avatar text;   -- small JPEG data URL (about 20 KB)

-- copy a person's phone / e-mail into every school-DB row that carries one of his names,
-- so the platform, the field app and the school pages all show the new contact details
create or replace function public.fm_apply_contact(p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
declare p public.profiles; v jsonb; e jsonb; outv jsonb := '[]'::jsonb; f text[];
  fields text[][] := array[['supervisor','supervisorPhone','supervisorEmail'],
                           ['engineer','engineerPhone','engineerEmail'],
                           ['lightSupervisor','lightSupervisorPhone','lightSupervisorEmail'],
                           ['lightEngineer','lightEngineerPhone','lightEngineerEmail'],
                           ['contractor','contractorPhone','contractorEmail']];
begin
  select * into p from public.profiles where id = p_user;
  if not found or cardinality(p.person_names) = 0 then return; end if;
  select value into v from public.app_kv where key = 'fm_school_master_db_v1';
  if v is null then return; end if;
  if jsonb_typeof(v) = 'string' then v := (v #>> '{}')::jsonb; end if;
  if jsonb_typeof(v) <> 'array' then return; end if;
  for e in select * from jsonb_array_elements(v) loop
    foreach f slice 1 in array fields loop
      if coalesce(e->>f[1],'') <> '' and trim(e->>f[1]) = any(p.person_names) then
        if coalesce(p.phone,'') <> '' then e := e || jsonb_build_object(f[2], p.phone); end if;
        if coalesce(p.email,'') <> '' then e := e || jsonb_build_object(f[3], p.email); end if;
      end if;
    end loop;
    outv := outv || jsonb_build_array(e);
  end loop;
  update public.app_kv set value = outv, updated_at = now() where key = 'fm_school_master_db_v1';
end $$;
revoke all on function public.fm_apply_contact(uuid) from public, anon, authenticated;

-- the signed-in user saves his phone; it is copied to the school DB at once
create or replace function public.fm_update_my_contact(p_phone text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed' using errcode = '42501'; end if;
  update public.profiles set phone = nullif(trim(p_phone),''), updated_at = now() where id = auth.uid();
  perform public.fm_apply_contact(auth.uid());
end $$;
revoke all on function public.fm_update_my_contact(text) from public, anon;
grant execute on function public.fm_update_my_contact(text) to authenticated;

-- a confirmed e-mail change (Supabase sends the confirmation link) reaches the profile and the school DB
create or replace function public.fm_on_auth_email_change() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.email is distinct from old.email then
    begin
      update public.profiles set email = new.email, updated_at = now() where id = new.id;
      perform public.fm_apply_contact(new.id);
    exception when others then null;   -- never block the sign-in service
    end;
  end if;
  return new;
end $$;
drop trigger if exists fm_on_auth_user_email on auth.users;
create trigger fm_on_auth_user_email after update of email on auth.users
  for each row execute function public.fm_on_auth_email_change();

-- ---------- 10) work orders (V145) ----------
-- Hierarchy: admin > engineer > supervisor > contractor. An order goes from a person to someone below him
-- in his own line (profiles.reports_to); the admin may assign to anyone below him.
-- All writes go through the functions below, which check the hierarchy and the allowed status changes.
-- V158: system settings (escalation hours, spending limits, QA sample) — read by everyone signed in, written by the system admin
create table if not exists public.fm_settings (key text primary key, value jsonb not null, updated_at timestamptz not null default now(), updated_by uuid default auth.uid());
insert into public.fm_settings(key, value) values
  ('escalation', '{"enabled": true, "hours": [0, 24, 72]}'),
  ('spend_limits', '{"area_manager": 1000, "ops_manager": 5000}'),
  ('qa', '{"sample_pct": 5, "days": 30}')
on conflict (key) do nothing;
alter table public.fm_settings enable row level security;
drop policy if exists p_set_read on public.fm_settings;
drop policy if exists p_set_write on public.fm_settings;
create policy p_set_read  on public.fm_settings for select using (public.fm_role() <> 'pending');
create policy p_set_write on public.fm_settings for all using (public.fm_role() = 'admin') with check (public.fm_role() = 'admin');
grant select, insert, update on public.fm_settings to authenticated;
create or replace function public.fm_setting(k text) returns jsonb language sql stable security definer set search_path = public as $$
  select value from public.fm_settings where key = k $$;
-- V158: a deputy acts for a manager over his team while the period is running
create table if not exists public.fm_deputies (
  id uuid primary key default gen_random_uuid(),
  principal uuid not null references public.profiles(id) on delete cascade,
  deputy uuid not null references public.profiles(id) on delete cascade,
  from_at timestamptz not null, to_at timestamptz not null, note text,
  active boolean not null default true, created_by uuid default auth.uid(), created_at timestamptz not null default now(),
  check (principal <> deputy), check (to_at > from_at));
create index if not exists fm_deputies_dep_idx on public.fm_deputies (deputy, active);
create or replace function public.fm_rank(r text) returns int language sql immutable as $$
  select case r when 'admin' then 4 when 'engineer' then 3 when 'supervisor' then 2 when 'contractor' then 1 else 0 end $$;

-- true when p_user reports to p_boss, directly or through other managers
create or replace function public.fm_is_under_base(p_user uuid, p_boss uuid) returns boolean
language sql stable security definer set search_path = public as $$
  with recursive up(id, boss, depth) as (
    select id, reports_to, 1 from public.profiles where id = p_user
    union all
    select p.id, p.reports_to, u.depth + 1 from public.profiles p join up u on p.id = u.boss where u.depth < 8)
  select p_boss is not null and exists (select 1 from up where boss = p_boss) $$;
-- V158: an active deputy counts as the boss of his principal and of the principal's team
create or replace function public.fm_is_under(p_user uuid, p_boss uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.fm_is_under_base(p_user, p_boss) or exists (select 1 from public.fm_deputies d
    where d.deputy = p_boss and d.active and now() between d.from_at and d.to_at
      and (d.principal = p_user or public.fm_is_under_base(p_user, d.principal))) $$;

-- may p_me assign work to p_user? (V147: the scheduled campaigns check it for the schedule's owner)
create or replace function public.fm_can_assign_base(p_me uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles t, public.profiles me
    where t.id = p_user and me.id = p_me and me.active and t.active and t.id <> me.id
      -- V157: by job title. Orders go to people from the contractor up to the operations manager.
      and public.fm_prank(public.fm_posx(t.role, t.job_title)) between 2 and 6
      and (me.role = 'admin'
        or (public.fm_posx(me.role, me.job_title) in ('project_manager','ops_manager')
            and public.fm_prank(public.fm_posx(t.role, t.job_title)) < public.fm_prank(public.fm_posx(me.role, me.job_title)))
        or (public.fm_posx(me.role, me.job_title) = 'area_manager' and public.fm_prank(public.fm_posx(t.role, t.job_title)) < 5
            and (public.fm_is_under(t.id, me.id) or (cardinality(me.regions) = 0 or t.regions && me.regions)))
        or (public.fm_posx(me.role, me.job_title) in ('hse_manager','qa_manager') and public.fm_prank(public.fm_posx(t.role, t.job_title)) < 6)
        or (public.fm_posx(me.role, me.job_title) in ('area_engineer','supervisor')
            and public.fm_prank(public.fm_posx(t.role, t.job_title)) < public.fm_prank(public.fm_posx(me.role, me.job_title))
            and public.fm_is_under(t.id, me.id)))) $$;
-- V158: plus, while a deputy period runs, what the principal may
create or replace function public.fm_can_assign_as(p_me uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.fm_can_assign_base(p_me, p_user) or exists (select 1 from public.fm_deputies d
    where d.deputy = p_me and d.active and now() between d.from_at and d.to_at and d.principal <> p_user
      and public.fm_can_assign_base(d.principal, p_user)) $$;
-- may the signed-in user assign work to p_user?
create or replace function public.fm_can_assign_to(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.fm_can_assign_as(auth.uid(), p_user) $$;

-- the people the signed-in user may assign to (for the assignee list; V146 adds email and
-- person_names so a group of schools can be matched to each school's own supervisor)
drop function if exists public.fm_wo_assignable();
create or replace function public.fm_wo_assignable() returns table(id uuid, full_name text, role text, regions text[], phone text, email text, person_names text[], job_title text)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.full_name, p.email), p.role, p.regions, p.phone, p.email, p.person_names, public.fm_posx(p.role, p.job_title) from public.profiles p
   where public.fm_can_assign_to(p.id) order by public.fm_prank(public.fm_posx(p.role, p.job_title)) desc, p.full_name $$;

create sequence if not exists public.wo_seq;
create table if not exists public.work_orders (
  id              uuid primary key default gen_random_uuid(),
  code            text unique,
  title           text not null,
  description     text,
  type            text not null default 'task',      -- repair | preventive | inspection | visit | data | task
  region          text,
  school          text,
  priority        text not null default 'متوسط',
  due_at          timestamptz,
  status          text not null default 'assigned'
                  check (status in ('assigned','accepted','rejected','in_progress','done','returned','closed','cancelled')),
  checklist       jsonb not null default '[]',        -- [{t:'…', done:true|false}]
  ticket_refs     text[] not null default '{}',
  created_by      uuid not null default auth.uid() references public.profiles(id),
  created_by_name text,
  assignee        uuid references public.profiles(id),
  assignee_name   text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  accepted_at     timestamptz,
  done_at         timestamptz,
  closed_at       timestamptz
);
-- V146: orders created together for a group of schools share a batch («حملة»)
alter table public.work_orders add column if not exists batch_id    uuid;
alter table public.work_orders add column if not exists batch_title text;
alter table public.work_orders add column if not exists building_id text;
create index if not exists work_orders_batch_idx on public.work_orders (batch_id);
create index if not exists work_orders_assignee_idx on public.work_orders (assignee, status);
create index if not exists work_orders_creator_idx  on public.work_orders (created_by, status);
create table if not exists public.wo_events (
  id      uuid primary key default gen_random_uuid(),
  wo_id   uuid not null references public.work_orders(id) on delete cascade,
  at      timestamptz not null default now(),
  by_id   uuid default auth.uid(),
  by_name text,
  type    text not null,
  status  text,
  text    text,
  geo     jsonb
);
create index if not exists wo_events_wo_idx on public.wo_events (wo_id, at);
create table if not exists public.wo_photos (
  id      uuid primary key default gen_random_uuid(),
  wo_id   uuid not null references public.work_orders(id) on delete cascade,
  kind    text not null default 'after' check (kind in ('before','after','attach')),
  path    text not null,
  at      timestamptz not null default now(),
  by_id   uuid default auth.uid(),
  by_name text,
  geo     jsonb
);
create index if not exists wo_photos_wo_idx on public.wo_photos (wo_id);
-- V148: a photo may belong to one checklist item (its index) and arrival photos carry a tag
-- (sign = the school sign, entrance = the entrance, fence = the fence)
alter table public.wo_photos add column if not exists item int;
alter table public.wo_photos add column if not exists tag  text;
alter table public.wo_photos drop constraint if exists wo_photos_kind_check;
alter table public.wo_photos add constraint wo_photos_kind_check check (kind in ('before','after','attach','arrival','invoice'));

-- who sees an order: its creator, its assignee, the admin, and the managers above either of them
create or replace function public.fm_wo_can_see(p_wo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.fm_role() <> 'pending' and exists (select 1 from public.work_orders w where w.id = p_wo
    and (w.created_by = auth.uid() or w.assignee = auth.uid() or public.fm_role() = 'admin' or public.fm_scope_region(w.region)
         or public.fm_is_under(w.assignee, auth.uid()) or public.fm_is_under(w.created_by, auth.uid()))) $$;
-- who may add photos: its creator and its assignee (while the order is not finished)
create or replace function public.fm_wo_party(p_wo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.fm_role() <> 'pending' and exists (select 1 from public.work_orders w where w.id = p_wo
    and (w.created_by = auth.uid() or w.assignee = auth.uid()) and w.status not in ('closed','cancelled')) $$;
create or replace function public.fm_uuid_or_null(t text) returns uuid language sql immutable as $$
  select case when t ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then t::uuid end $$;

alter table public.work_orders enable row level security;
alter table public.wo_events   enable row level security;
alter table public.wo_photos   enable row level security;
drop policy if exists p_wo_read  on public.work_orders;
drop policy if exists p_woev_read on public.wo_events;
drop policy if exists p_woph_read on public.wo_photos;
drop policy if exists p_woph_insert on public.wo_photos;
create policy p_wo_read    on public.work_orders for select using (public.fm_wo_can_see(id));
create policy p_woev_read  on public.wo_events   for select using (public.fm_wo_can_see(wo_id));
create policy p_woph_read  on public.wo_photos   for select using (public.fm_wo_can_see(wo_id));
create policy p_woph_insert on public.wo_photos  for insert with check (by_id = auth.uid() and public.fm_wo_party(wo_id));

insert into storage.buckets (id, name, public) values ('wo-photos','wo-photos', false) on conflict (id) do nothing;
-- storage policies: newer Supabase projects may refuse changes to storage.objects from the SQL editor
-- ("must be owner of relation objects"); then the existing policies stay and the rest of this file still runs
do $do$ begin
  execute $q$drop policy if exists p_woobj_read   on storage.objects$q$;
  execute $q$drop policy if exists p_woobj_insert on storage.objects$q$;
  execute $q$create policy p_woobj_read   on storage.objects for select using (bucket_id = 'wo-photos'
  and (public.fm_wo_can_see(public.fm_uuid_or_null(split_part(name,'/',1)))
       -- V149: a repair order shows the photos it copied from the inspection order
       or exists (select 1 from public.wo_photos ph where ph.path = storage.objects.name and public.fm_wo_can_see(ph.wo_id))))$q$;
  execute $q$create policy p_woobj_insert on storage.objects for insert with check (bucket_id = 'wo-photos'
  and public.fm_wo_party(public.fm_uuid_or_null(split_part(name,'/',1))))$q$;
exception when insufficient_privilege then
  raise notice 'wo-photos: لم تُحدَّث سياسات التخزين (لا صلاحية على storage.objects) — أضفها من Storage ← Policies إن لزم';
end $do$;

-- create an order (admin / engineer / supervisor) for someone below in the line.
-- fm_wo_create_as is internal (also used by the scheduled campaigns for the schedule's owner).
create or replace function public.fm_wo_create_as(p_me uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles; t public.profiles; v_id uuid := gen_random_uuid(); v_code text;
begin
  select * into me from public.profiles where id = p_me;
  if me.id is null or not me.active or me.role not in ('admin','manager','staff','engineer','supervisor') then
    raise exception 'not allowed' using errcode = '42501'; end if;
  if coalesce(trim(p->>'title'),'') = '' then raise exception 'title required'; end if;
  select * into t from public.profiles where id = public.fm_uuid_or_null(p->>'assignee');
  if t.id is null or not public.fm_can_assign_as(me.id, t.id) then raise exception 'cannot assign to this user'; end if;
  v_code := 'WO-' || to_char(now(),'YYYY') || '-' || lpad(nextval('public.wo_seq')::text, 4, '0');
  insert into public.work_orders (id, code, title, description, type, region, school, priority, due_at, checklist, ticket_refs,
                                  created_by, created_by_name, assignee, assignee_name, batch_id, batch_title, building_id)
  values (v_id, v_code, trim(p->>'title'), nullif(trim(p->>'description'),''), coalesce(nullif(p->>'type',''),'task'),
          nullif(p->>'region',''), nullif(trim(p->>'school'),''), coalesce(nullif(p->>'priority',''),'متوسط'),
          nullif(p->>'due_at','')::timestamptz,
          case when jsonb_typeof(p->'checklist') = 'array' then p->'checklist' else '[]'::jsonb end,
          case when jsonb_typeof(p->'ticket_refs') = 'array' then array(select jsonb_array_elements_text(p->'ticket_refs')) else '{}' end,
          me.id, coalesce(me.full_name, me.email), t.id, coalesce(t.full_name, t.email),
          public.fm_uuid_or_null(p->>'batch_id'), nullif(trim(p->>'batch_title'),''), nullif(trim(p->>'building_id'),''));
  insert into public.wo_events (wo_id, by_id, by_name, type, status, text)
  values (v_id, me.id, coalesce(me.full_name, me.email), 'create', 'assigned',
          case when p->>'schedule' is not null then '🔁 أُنشئ تلقائياً (حملة متكررة) وأُسند إلى ' else '📝 أُنشئ الأمر وأُسند إلى ' end || coalesce(t.full_name, t.email));
  return v_id;
end $$;
create or replace function public.fm_wo_create(p jsonb) returns uuid
language sql security definer set search_path = public as $$ select public.fm_wo_create_as(auth.uid(), p - 'schedule') $$;

-- V146: one order per school for a group of schools, all in one batch, all or nothing.
-- p = {batch_id?, batch_title, items:[{title, assignee, school, …}]}; a large group is sent in
-- several calls with the same batch_id, which only the batch's own creator may add to.
create or replace function public.fm_wo_create_many(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_b uuid := coalesce(public.fm_uuid_or_null(p->>'batch_id'), gen_random_uuid()); it jsonb; n int := 0;
  bt text := nullif(trim(p->>'batch_title'),'');
begin
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'items required'; end if;
  if jsonb_array_length(p->'items') > 500 then raise exception 'too many items'; end if;
  if exists (select 1 from public.work_orders where batch_id = v_b and created_by <> auth.uid()) then
    raise exception 'not allowed' using errcode = '42501'; end if;
  for it in select * from jsonb_array_elements(p->'items') loop
    begin
      perform public.fm_wo_create(it || jsonb_build_object('batch_id', v_b, 'batch_title', coalesce(bt, it->>'title')));
    exception when others then
      raise exception '% — %', sqlerrm, coalesce(nullif(it->>'school',''), '#' || (n + 1)) using errcode = sqlstate;
    end;
    n := n + 1;
  end loop;
  return jsonb_build_object('batch_id', v_b, 'count', n);
end $$;

-- every step of the order; the allowed step depends on who you are (assignee / creator) and the current status
create or replace function public.fm_wo_act(p_id uuid, p_action text, p_note text default null, p_geo jsonb default null, p_data jsonb default null)
returns text language plpgsql security definer set search_path = public as $$
declare w public.work_orders; me public.profiles; t public.profiles; nm text; isA boolean; isC boolean; ns text; msg text; it jsonb; i int;
  note text := nullif(trim(coalesce(p_note,'')),'');
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into w from public.work_orders where id = p_id for update;
  if w.id is null or not public.fm_wo_can_see(w.id) then raise exception 'work order not found'; end if;
  nm := coalesce(me.full_name, me.email);
  isA := w.assignee = me.id;
  -- V157: also the project / operations managers, and the area manager in his regions
  isC := w.created_by = me.id or me.role = 'admin' or public.fm_posx(me.role, me.job_title) in ('project_manager','ops_manager')
         or (public.fm_posx(me.role, me.job_title) = 'area_manager' and public.fm_region_ok(coalesce(w.region,'')))
         -- V158: a deputy approves what his principal may
         or exists (select 1 from public.fm_deputies d join public.profiles pr on pr.id = d.principal
                     where d.deputy = me.id and d.active and now() between d.from_at and d.to_at
                       and (pr.id = w.created_by or public.fm_posx(pr.role, pr.job_title) in ('project_manager','ops_manager')
                            or (public.fm_posx(pr.role, pr.job_title) = 'area_manager'
                                and (cardinality(pr.regions) = 0 or coalesce(w.region,'') = any(pr.regions)))));
  ns := w.status;
  if p_action = 'accept' and isA and w.status = 'assigned' then ns := 'accepted'; msg := '✅ قبل الأمر';
  elsif p_action = 'reject' and isA and w.status = 'assigned' then
    if note is null then raise exception 'reason required'; end if; ns := 'rejected'; msg := '⛔ رفض الأمر';
  elsif p_action = 'start' and isA and w.status in ('accepted','returned') then ns := 'in_progress'; msg := '🛠️ بدأ التنفيذ';
  elsif p_action = 'arrive' and isA and w.status in ('accepted','in_progress','returned') then msg := '📍 وصل للموقع';
  elsif p_action = 'checklist' and isA and w.status in ('accepted','in_progress','returned') then
    update public.work_orders set checklist = coalesce(p_data,'[]'::jsonb), updated_at = now() where id = w.id;
    return w.status;
  elsif p_action = 'done' and isA and w.status in ('accepted','in_progress','returned') then
    if not exists (select 1 from public.wo_photos where wo_id = w.id and kind = 'after') then raise exception 'after photo required'; end if;
    -- V148: a school order needs the three arrival photos; a repaired item needs materials and before / after photos,
    -- an item that still needs repair needs a before photo
    if w.school is not null and (select count(distinct tag) from public.wo_photos
        where wo_id = w.id and kind = 'arrival' and tag in ('sign','entrance','fence')) < 3 then
      raise exception 'arrival photos required'; end if;
    for it, i in select e, (o - 1)::int from jsonb_array_elements(case when jsonb_typeof(p_data) = 'array' then p_data else w.checklist end) with ordinality as t(e, o) loop
      if it->>'res' = 'fixed' and (jsonb_typeof(it->'materials') is distinct from 'array' or jsonb_array_length(it->'materials') = 0
          or not exists (select 1 from public.wo_photos where wo_id = w.id and item = i and kind = 'before')
          or not exists (select 1 from public.wo_photos where wo_id = w.id and item = i and kind = 'after')) then
        raise exception 'item documentation required: %', i + 1; end if;
      -- V149: a purchased material needs its unit price and an invoice photo on the item
      if it->>'res' = 'fixed' and exists (select 1 from jsonb_array_elements(it->'materials') m where m->>'src' = 'buy') and (
          exists (select 1 from jsonb_array_elements(it->'materials') m where m->>'src' = 'buy'
                    and coalesce(nullif(regexp_replace(m->>'price', '[^0-9.]', '', 'g'), '')::numeric, 0) <= 0)
          or not exists (select 1 from public.wo_photos where wo_id = w.id and item = i and kind = 'invoice')) then
        raise exception 'invoice required: %', i + 1; end if;
      if it->>'res' = 'fix' and not exists (select 1 from public.wo_photos where wo_id = w.id and item = i and kind = 'before') then
        raise exception 'item documentation required: %', i + 1; end if;
    end loop;
    if jsonb_typeof(p_data) = 'array' then update public.work_orders set checklist = p_data where id = w.id; end if;
    ns := 'done'; msg := '📨 أبلغ: تم الإجراء — بانتظار الاعتماد';
  elsif p_action = 'close' and isC and w.status = 'done' then
    -- V158: purchases above the limits set in the system need the area / operations manager (or a higher title)
    if public.fm_wo_spend_rank(w.checklist) > greatest(public.fm_prank(public.fm_posx(me.role, me.job_title)),
         coalesce((select max(public.fm_prank(public.fm_posx(pr.role, pr.job_title))) from public.fm_deputies d join public.profiles pr on pr.id = d.principal
                    where d.deputy = me.id and d.active and now() between d.from_at and d.to_at), 0)) then
      raise exception 'spend approval required: %', case public.fm_wo_spend_rank(w.checklist) when 6 then 'ops_manager' else 'area_manager' end;
    end if;
    ns := 'closed'; msg := '🔒 اعتمد الإنجاز وأغلق الأمر';
  -- V158: the safety manager stops unsafe work (reason required) and lets it resume
  elsif p_action = 'stop' and public.fm_posx(me.role, me.job_title) in ('hse_manager','sysadmin') and w.status not in ('closed','cancelled','stopped') then
    if note is null then raise exception 'reason required'; end if;
    update public.work_orders set stop_prev = w.status where id = w.id;
    ns := 'stopped'; msg := '⛔ أوقف العمل لأسباب تتعلق بالسلامة';
  elsif p_action = 'resume' and public.fm_posx(me.role, me.job_title) in ('hse_manager','sysadmin') and w.status = 'stopped' then
    ns := coalesce(nullif(w.stop_prev,''), 'accepted'); msg := '▶️ سمح باستئناف العمل';
  elsif p_action = 'return' and isC and w.status = 'done' then
    if note is null then raise exception 'reason required'; end if; ns := 'returned'; msg := '↩️ أعاد الأمر للتصحيح';
  elsif p_action = 'cancel' and isC and w.status not in ('closed','cancelled','stopped') then ns := 'cancelled'; msg := '🚫 ألغى الأمر';
  elsif p_action = 'reassign' and isC and w.status in ('assigned','rejected','accepted','in_progress','returned') then
    select * into t from public.profiles where id = public.fm_uuid_or_null(p_data->>'assignee');
    if t.id is null or not public.fm_can_assign_to(t.id) then raise exception 'cannot assign to this user'; end if;
    update public.work_orders set assignee = t.id, assignee_name = coalesce(t.full_name, t.email), accepted_at = null where id = w.id;
    ns := 'assigned'; msg := '🔁 أعاد الإسناد إلى ' || coalesce(t.full_name, t.email);
  elsif p_action = 'note' and note is not null then
    insert into public.wo_events (wo_id, by_id, by_name, type, status, text, geo) values (w.id, me.id, nm, 'note', w.status, '✍️ ' || note, p_geo);
    update public.work_orders set updated_at = now() where id = w.id;
    return w.status;
  else raise exception 'action not allowed'; end if;
  update public.work_orders set status = ns, updated_at = now(),
         accepted_at = case when ns = 'accepted' then now() else accepted_at end,
         done_at     = case when ns = 'done' then now() else done_at end,
         closed_at   = case when ns in ('closed','cancelled') then now() else closed_at end
   where id = w.id;
  insert into public.wo_events (wo_id, by_id, by_name, type, status, text, geo)
  values (w.id, me.id, nm, p_action, ns, msg || coalesce(' — ' || note, ''), p_geo);
  return ns;
end $$;

revoke all on function public.fm_wo_create(jsonb) from public, anon;
revoke all on function public.fm_wo_create_as(uuid,jsonb) from public, anon, authenticated;
revoke all on function public.fm_can_assign_as(uuid,uuid) from public, anon, authenticated;
revoke all on function public.fm_wo_act(uuid,text,text,jsonb,jsonb) from public, anon;
revoke all on function public.fm_wo_assignable() from public, anon;
revoke all on function public.fm_wo_create_many(jsonb) from public, anon;
grant execute on function public.fm_wo_create_many(jsonb) to authenticated;
grant execute on function public.fm_wo_create(jsonb) to authenticated;
grant execute on function public.fm_wo_act(uuid,text,text,jsonb,jsonb) to authenticated;
grant execute on function public.fm_wo_assignable() to authenticated;
do $$ begin
  begin alter publication supabase_realtime add table public.work_orders; exception when others then null; end;
  begin alter publication supabase_realtime add table public.wo_events;   exception when others then null; end;
end $$;

-- ---------- 11) templates and recurring campaigns (V147) ----------
-- Templates: a saved title / type / priority / due days / instructions / checklist (and optionally schools).
-- Shared templates are seen by every admin / engineer / supervisor; private ones only by their owner.
create table if not exists public.wo_templates (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  data            jsonb not null default '{}',
  shared          boolean not null default true,
  created_by      uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_by_name text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
alter table public.wo_templates enable row level security;
drop policy if exists p_wot_read on public.wo_templates;
drop policy if exists p_wot_ins  on public.wo_templates;
drop policy if exists p_wot_upd  on public.wo_templates;
drop policy if exists p_wot_del  on public.wo_templates;
create policy p_wot_read on public.wo_templates for select using (public.fm_role() in ('admin','manager','staff','engineer','supervisor') and (shared or created_by = auth.uid()));
create policy p_wot_ins  on public.wo_templates for insert with check (created_by = auth.uid() and public.fm_role() in ('admin','manager','staff','engineer','supervisor'));
-- V157: the quality & planning manager also maintains the shared templates
create policy p_wot_upd  on public.wo_templates for update using (created_by = auth.uid() or public.fm_role() = 'admin' or (shared and public.fm_my_pos() = 'qa_manager'))
  with check (created_by = auth.uid() or public.fm_role() = 'admin' or (shared and public.fm_my_pos() = 'qa_manager'));
create policy p_wot_del  on public.wo_templates for delete using (created_by = auth.uid() or public.fm_role() = 'admin');

-- Recurring campaigns: the same group of schools gets a new batch of orders every week / month / quarter / N days.
-- The schools and their assignees are a snapshot taken when the schedule is saved. Each run creates the orders
-- in the owner's name and re-checks the hierarchy: a school whose assignee is no longer in the owner's line is skipped.
create table if not exists public.wo_schedules (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  active          boolean not null default true,
  freq            text not null check (freq in ('weekly','monthly','quarterly','days')),
  every_n         int  not null default 1 check (every_n between 1 and 365),
  start_at        timestamptz not null,           -- the first run; later runs keep its weekday / day of month and hour
  next_run_at     timestamptz not null,
  due_days        int  not null default 7 check (due_days between 1 and 365),
  data            jsonb not null default '{}',     -- {title, type, priority, description, checklist}
  items           jsonb not null default '[]',     -- [{school, building_id, region, assignee, priority?, description?}]
  created_by      uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_by_name text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  last_run_at     timestamptz,
  last_batch      uuid,
  last_result     jsonb,
  runs            int not null default 0
);
create index if not exists wo_schedules_due_idx on public.wo_schedules (active, next_run_at);
alter table public.wo_schedules enable row level security;
drop policy if exists p_wos_read on public.wo_schedules;
create policy p_wos_read on public.wo_schedules for select using (public.fm_role() <> 'pending'
  and (created_by = auth.uid() or public.fm_role() = 'admin' or public.fm_scope_all() or public.fm_is_under(created_by, auth.uid())));

-- the first run time after p_after: start_at + k × the interval (counted from the start, so the 31st stays the end of the month)
create or replace function public.fm_wo_next_run(s public.wo_schedules, p_after timestamptz) returns timestamptz
language plpgsql stable as $$
declare k int := 0; step interval; t timestamptz;
begin
  step := case s.freq when 'weekly' then make_interval(days => 7 * s.every_n) when 'days' then make_interval(days => s.every_n)
                      when 'monthly' then make_interval(months => s.every_n) else make_interval(months => 3 * s.every_n) end;
  if s.start_at > p_after then return s.start_at; end if;
  -- jump close to p_after first, then step
  if s.freq in ('weekly','days') then k := greatest(0, floor(extract(epoch from (p_after - s.start_at)) / extract(epoch from step))::int - 1);
  else k := greatest(0, ((extract(year from age(p_after, s.start_at)) * 12 + extract(month from age(p_after, s.start_at)))::int
                        / (case s.freq when 'monthly' then s.every_n else 3 * s.every_n end)) - 1); end if;
  loop
    t := (s.start_at at time zone 'Asia/Riyadh' + step * k) at time zone 'Asia/Riyadh';
    exit when t > p_after or k > 100000;
    k := k + 1;
  end loop;
  return t;
end $$;

-- one run of a schedule: a new batch for every school whose assignee is still in the owner's line
create or replace function public.fm_wo_run_schedule(p_id uuid, p_manual boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.wo_schedules; me public.profiles; it jsonb; v_b uuid := gen_random_uuid(); n int := 0;
  skipped jsonb := '[]'; res jsonb; bt text;
begin
  select * into s from public.wo_schedules where id = p_id for update skip locked;
  if s.id is null then return null; end if;
  select * into me from public.profiles where id = s.created_by;
  bt := s.name || ' — ' || to_char(now() at time zone 'Asia/Riyadh', 'YYYY-MM-DD');
  if me.id is null or not me.active or me.role not in ('admin','manager','staff','engineer','supervisor') then
    res := jsonb_build_object('count', 0, 'error', 'owner not active');
  else
    for it in select * from jsonb_array_elements(s.items) loop
      if public.fm_can_assign_as(me.id, public.fm_uuid_or_null(it->>'assignee')) then
        perform public.fm_wo_create_as(me.id, s.data || it || jsonb_build_object(
          'title', s.data->>'title', 'batch_id', v_b, 'batch_title', bt, 'schedule', s.id,
          'due_at', now() + make_interval(days => s.due_days),
          'description', concat_ws(E'\n\n', nullif(s.data->>'description',''), nullif(it->>'note',''))));
        n := n + 1;
      else
        skipped := skipped || to_jsonb(coalesce(it->>'school','?'));
      end if;
    end loop;
    res := jsonb_build_object('count', n, 'skipped', skipped, 'batch_id', case when n > 0 then v_b end);
  end if;
  update public.wo_schedules set last_run_at = now(), last_result = res, runs = runs + 1, updated_at = now(),
         last_batch = case when n > 0 then v_b else last_batch end,
         next_run_at = case when p_manual and next_run_at > now() then next_run_at else public.fm_wo_next_run(s, now()) end
   where id = s.id;
  return res;
end $$;

-- run every schedule that is due (pg_cron calls it every hour; the platform also calls it when it opens)
create or replace function public.fm_wo_run_due() returns int
language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  if auth.uid() is not null and public.fm_role() not in ('admin','manager','staff','engineer','supervisor') then return 0; end if;
  perform public.fm_wo_escalate();   -- V158
  for r in select id from public.wo_schedules where active and next_run_at <= now() order by next_run_at limit 25 loop
    perform public.fm_wo_run_schedule(r.id, false); n := n + 1;
  end loop;
  return n;
end $$;

-- save a schedule (new, or edit your own); every school's assignee must be in your line
create or replace function public.fm_wo_schedule_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles; s public.wo_schedules; it jsonb; v_id uuid := public.fm_uuid_or_null(p->>'id');
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active or me.role not in ('admin','manager','staff','engineer','supervisor') then
    raise exception 'not allowed' using errcode = '42501'; end if;
  if coalesce(trim(p->>'name'),'') = '' or coalesce(trim(p->'data'->>'title'),'') = '' then raise exception 'title required'; end if;
  if jsonb_typeof(p->'items') <> 'array' or jsonb_array_length(p->'items') = 0 then raise exception 'items required'; end if;
  if jsonb_array_length(p->'items') > 2000 then raise exception 'too many items'; end if;
  for it in select * from jsonb_array_elements(p->'items') loop
    if not public.fm_can_assign_as(me.id, public.fm_uuid_or_null(it->>'assignee')) then
      raise exception 'cannot assign to this user — %', coalesce(it->>'school','?'); end if;
  end loop;
  if v_id is not null then
    select * into s from public.wo_schedules where id = v_id;
    if s.id is null or (s.created_by <> me.id and me.role <> 'admin') then raise exception 'not allowed' using errcode = '42501'; end if;
  end if;
  s.id := coalesce(v_id, gen_random_uuid());
  s.name := trim(p->>'name'); s.freq := p->>'freq'; s.every_n := coalesce((p->>'every_n')::int, 1);
  s.start_at := (p->>'start_at')::timestamptz; s.due_days := coalesce((p->>'due_days')::int, 7);
  s.next_run_at := public.fm_wo_next_run(s, now() - interval '1 minute');
  insert into public.wo_schedules (id, name, active, freq, every_n, start_at, next_run_at, due_days, data, items, created_by, created_by_name)
  values (s.id, s.name, true, s.freq, s.every_n, s.start_at, s.next_run_at, s.due_days, p->'data', p->'items', me.id, coalesce(me.full_name, me.email))
  on conflict (id) do update set name = excluded.name, freq = excluded.freq, every_n = excluded.every_n, start_at = excluded.start_at,
     next_run_at = excluded.next_run_at, due_days = excluded.due_days, data = excluded.data, items = excluded.items, updated_at = now();
  return s.id;
end $$;

-- pause / resume / delete / run now (the owner or the admin)
create or replace function public.fm_wo_schedule_act(p_id uuid, p_action text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.wo_schedules;
begin
  select * into s from public.wo_schedules where id = p_id;
  if s.id is null or not (s.created_by = auth.uid() or public.fm_role() = 'admin') or public.fm_role() = 'pending' then
    raise exception 'not allowed' using errcode = '42501'; end if;
  if p_action = 'pause' then update public.wo_schedules set active = false, updated_at = now() where id = p_id;
  elsif p_action = 'resume' then update public.wo_schedules set active = true, updated_at = now(), next_run_at = public.fm_wo_next_run(s, now()) where id = p_id;
  elsif p_action = 'delete' then delete from public.wo_schedules where id = p_id;
  elsif p_action = 'run' then return public.fm_wo_run_schedule(p_id, true);
  else raise exception 'action not allowed'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- is the hourly automatic run (pg_cron) set up?
create or replace function public.fm_wo_cron_on() returns boolean
language plpgsql stable security definer set search_path = public as $$
declare ok boolean := false;
begin
  begin execute 'select exists (select 1 from cron.job where jobname = ''fm-wo-schedules'')' into ok;
  exception when others then ok := false; end;
  return ok;
end $$;

revoke all on function public.fm_wo_next_run(public.wo_schedules, timestamptz) from public, anon;
revoke all on function public.fm_wo_run_schedule(uuid, boolean) from public, anon, authenticated;
revoke all on function public.fm_wo_run_due() from public, anon;
revoke all on function public.fm_wo_schedule_save(jsonb) from public, anon;
revoke all on function public.fm_wo_schedule_act(uuid, text) from public, anon;
revoke all on function public.fm_wo_cron_on() from public, anon;
grant select, insert, update, delete on public.wo_templates to authenticated;
grant select on public.wo_schedules to authenticated;
grant execute on function public.fm_wo_run_due() to authenticated;
grant execute on function public.fm_wo_schedule_save(jsonb) to authenticated;
grant execute on function public.fm_wo_schedule_act(uuid, text) to authenticated;
grant execute on function public.fm_wo_cron_on() to authenticated;

-- hourly automatic run. Needs the pg_cron extension (Supabase → Database → Extensions → pg_cron);
-- without it the campaigns still run whenever an admin / engineer / supervisor opens the platform.
do $$ begin
  begin execute 'create extension if not exists pg_cron'; exception when others then null; end;
  begin
    execute 'select cron.unschedule(jobid) from cron.job where jobname = ''fm-wo-schedules''';
    execute 'select cron.schedule(''fm-wo-schedules'', ''7 * * * *'', ''select public.fm_wo_run_due()'')';
  exception when others then raise notice 'pg_cron is not available: recurring campaigns run when the platform is opened'; end;
end $$;

-- ---------- 12) repair orders and the materials list (V149) ----------
-- A repair order is created from the items of an inspection order marked «يحتاج إصلاح»; it carries their
-- description and before photos and points back to the inspection order (source_wo).
alter table public.work_orders add column if not exists source_wo uuid references public.work_orders(id) on delete set null;

-- the materials list (warehouse items) the field app picks from; the unit price is copied into each use
create table if not exists public.wo_materials (
  id         uuid primary key default gen_random_uuid(),
  code       text,
  name       text not null,
  unit       text,
  price      numeric(12,2),
  category   text,
  active     boolean not null default true,
  updated_at timestamptz not null default now()
);
create unique index if not exists wo_materials_name_uq on public.wo_materials (lower(name));
alter table public.wo_materials enable row level security;
drop policy if exists p_wom_read  on public.wo_materials;
drop policy if exists p_wom_write on public.wo_materials;
create policy p_wom_read  on public.wo_materials for select using (public.fm_role() in ('admin','manager','staff','engineer','supervisor','contractor'));
create policy p_wom_write on public.wo_materials for all using (public.fm_role() in ('admin','manager','engineer')) with check (public.fm_role() in ('admin','manager','engineer'));
grant select, insert, update, delete on public.wo_materials to authenticated;

-- create a repair order from the «يحتاج إصلاح» items of p_src (all of them, or the indexes in p->items)
create or replace function public.fm_wo_repair(p_src uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.work_orders; me public.profiles; it jsonb; i int; idx int[] := '{}'; items jsonb := '[]'; probs text := '';
  v_id uuid; v_code text;
begin
  select * into me from public.profiles where id = auth.uid();
  select * into s from public.work_orders where id = p_src for update;
  if s.id is null or not public.fm_wo_can_see(s.id) then raise exception 'work order not found'; end if;
  for it, i in select e, (o - 1)::int from jsonb_array_elements(s.checklist) with ordinality as t(e, o) loop
    if it->>'res' = 'fix' and it->>'rwo' is null
       and (jsonb_typeof(p->'items') is distinct from 'array' or (p->'items') @> to_jsonb(i)) then
      idx := idx || i;
      -- V151: a graded (FCI) element describes its defect in the chosen option («opt»)
      items := items || jsonb_strip_nulls(jsonb_build_object('t', (it->>'t') || coalesce(' — ' || nullif(it->>'opt',''), ''), 'tool', it->>'tool', 'src_item', coalesce(it->>'no', (i + 1)::text), 'done', false));
      probs := probs || E'\n• ' || coalesce((it->>'no') || ' ', '') || (it->>'t') || coalesce(' — ' || nullif(it->>'opt',''), '') || coalesce(' — ' || nullif(it->>'note',''), '');
    end if;
  end loop;
  if cardinality(idx) = 0 then raise exception 'nothing to repair'; end if;
  v_id := public.fm_wo_create_as(me.id, jsonb_build_object(
    'title', coalesce(nullif(trim(p->>'title'),''), 'إصلاح — ' || coalesce(s.school, s.title)),
    'type', 'repair', 'school', s.school, 'region', s.region, 'building_id', s.building_id,
    'priority', coalesce(nullif(p->>'priority',''), s.priority), 'due_at', p->>'due_at', 'assignee', p->>'assignee',
    'description', 'أمر إصلاح للبنود التي سُجّلت «يحتاج إصلاح» في ' || coalesce(s.code,'') || ' (' || s.title || '):' || probs
       || coalesce(E'\n\n' || nullif(trim(p->>'note'),''), ''),
    'checklist', items));
  update public.work_orders set source_wo = s.id where id = v_id returning code into v_code;
  -- the before photos of those items, attached to the matching item of the repair order
  insert into public.wo_photos (wo_id, kind, path, at, by_id, by_name, geo, item)
  select v_id, 'before', ph.path, ph.at, ph.by_id, ph.by_name, ph.geo, array_position(idx, ph.item) - 1
    from public.wo_photos ph where ph.wo_id = s.id and ph.kind = 'before' and ph.item = any(idx);
  update public.work_orders set updated_at = now(), checklist = (
    select jsonb_agg(case when (o - 1)::int = any(idx) then e || jsonb_build_object('rwo', v_code) else e end order by o)
      from jsonb_array_elements(s.checklist) with ordinality as t(e, o)) where id = s.id;
  insert into public.wo_events (wo_id, by_id, by_name, type, status, text)
  values (s.id, me.id, coalesce(me.full_name, me.email), 'note', s.status, '🔧 أُنشئ أمر الإصلاح ' || v_code || ' لـ ' || cardinality(idx) || ' بند');
  return jsonb_build_object('id', v_id, 'code', v_code, 'count', cardinality(idx));
end $$;
revoke all on function public.fm_wo_repair(uuid, jsonb) from public, anon;
grant execute on function public.fm_wo_repair(uuid, jsonb) to authenticated;

-- ---------- 13) proactive school engagement (V154, field F15) ----------
-- Each engineer / supervisor is assigned schools (fm_eng_assignments); every contact by phone, WhatsApp or visit is a log
-- (fm_eng_logs, append-only); a log with observations opens a follow-up (fm_eng_observations, due in 48 h / 24 h urgent)
-- whose every change is kept in fm_eng_audit. Logs are written only through fm_eng_submit (time and author set by the server).
create or replace function public.fm_eng_admin() returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.profiles where id=auth.uid() and role='admin' and coalesce(active,true)) $$;
-- V155: a manager (engineer / supervisor) sees and follows up the engagement of the people under him (profiles.reports_to line)
create or replace function public.fm_eng_lead(p_user uuid) returns boolean language sql stable security definer set search_path=public as $$
  select p_user is not null and exists(select 1 from public.profiles where id=auth.uid() and active and role in ('manager','engineer','supervisor'))
         and public.fm_is_under(p_user, auth.uid()) $$;
-- V157: who sees one person's engagement (assignment region known) / who may follow up his observations
create or replace function public.fm_eng_sees(p_user uuid, p_region text) returns boolean language sql stable security definer set search_path=public as $$
  select public.fm_eng_admin() or public.fm_scope_region(p_region) or public.fm_eng_lead(p_user) $$;
create or replace function public.fm_eng_manages(p_user uuid, p_region text) returns boolean language sql stable security definer set search_path=public as $$
  select public.fm_eng_admin() or public.fm_eng_lead(p_user) or coalesce(public.fm_my_pos() in ('project_manager','ops_manager'), false)
      or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(p_region,''))) $$;
-- evidence folders are named by the author's id (text): read through a definer, since profiles are private
create or replace function public.fm_eng_lead_folder(p_folder text) returns boolean language sql stable security definer set search_path=public as $$
  select public.fm_scope_all() or exists(select 1 from public.profiles t where t.id::text=p_folder
    and (public.fm_eng_lead(t.id) or (public.fm_my_pos() = 'area_manager' and (cardinality(public.fm_regions()) = 0 or t.regions && public.fm_regions())))) $$;
revoke all on function public.fm_eng_lead_folder(text) from public, anon;
grant execute on function public.fm_eng_lead_folder(text) to authenticated;
create table if not exists public.fm_eng_targets(role text primary key check(role in ('supervisor','engineer')), cycle text not null check(cycle in ('weekly','monthly')), visits integer not null default 8 check(visits>=0));
insert into public.fm_eng_targets values ('supervisor','weekly',8),('engineer','monthly',8) on conflict do nothing;
create table if not exists public.fm_eng_assignments(id uuid primary key default gen_random_uuid(), school_code text not null, school_name text not null, region text not null default '', user_id uuid not null references public.profiles(id), principal text not null default '', phone text not null default '', active boolean not null default true, unique(school_code,user_id));
create table if not exists public.fm_eng_logs(id uuid primary key default gen_random_uuid(), assignment_id uuid not null references public.fm_eng_assignments(id), user_id uuid not null default auth.uid() references public.profiles(id), at timestamptz not null default now(), channel text not null check(channel in ('phone','whatsapp','visit')), outcome text not null check(outcome in ('clear','observation','urgent','no_reply')), confirmed boolean not null default false, summary text not null check(length(trim(summary))>0), evidence_path text, geo jsonb, created_at timestamptz not null default now());
create table if not exists public.fm_eng_observations(id uuid primary key default gen_random_uuid(), log_id uuid not null unique references public.fm_eng_logs(id), owner_id uuid not null references public.profiles(id), due_at timestamptz not null, status text not null default 'open' check(status in ('open','in_progress','closed')), action text not null default '', ticket_ref text not null default '', wo_ref text not null default '', updated_at timestamptz not null default now());
create table if not exists public.fm_eng_audit(id bigint generated always as identity primary key, observation_id uuid not null references public.fm_eng_observations(id), actor uuid default auth.uid(), at timestamptz default now(), old_data jsonb, new_data jsonb);
create or replace function public.fm_eng_audit_update() returns trigger language plpgsql security definer set search_path=public as $$
begin new.updated_at=now(); insert into public.fm_eng_audit(observation_id,old_data,new_data) values(old.id,to_jsonb(old),to_jsonb(new)); return new; end $$;
drop trigger if exists eng_audit on public.fm_eng_observations;
create trigger eng_audit before update on public.fm_eng_observations for each row execute function public.fm_eng_audit_update();
-- the only way to write a log: the caller must own the active assignment; the server sets the author and the time
create or replace function public.fm_eng_submit(p jsonb) returns uuid language plpgsql security definer set search_path=public as $$
declare lid uuid; v_me uuid := auth.uid(); v_out text := p->>'outcome';
begin
  if not exists (select 1 from public.fm_eng_assignments a join public.profiles u on u.id=a.user_id
                 where a.id=(p->>'assignment_id')::uuid and a.user_id=v_me and a.active and u.active and u.role in ('supervisor','engineer')) then
    raise exception 'not allowed';
  end if;
  insert into public.fm_eng_logs(assignment_id,user_id,channel,outcome,confirmed,summary,evidence_path,geo)
  values((p->>'assignment_id')::uuid, v_me, p->>'channel', v_out, coalesce((p->>'confirmed')::boolean,false), p->>'summary', nullif(p->>'evidence_path',''),
         case when jsonb_typeof(p->'geo')='object' then p->'geo' end)
  returning id into lid;
  if v_out in ('observation','urgent') then
    insert into public.fm_eng_observations(log_id,owner_id,due_at)
    values(lid, v_me, now() + case when v_out='urgent' then interval '24 hours' else interval '48 hours' end);
  end if;
  return lid;
end $$;
-- completed-contact evidence rules, enforced on the server as well as in the UI
alter table public.fm_eng_logs drop constraint if exists eng_completed_evidence;
alter table public.fm_eng_logs add constraint eng_completed_evidence check (
  (outcome<>'no_reply' or not confirmed) and
  (not confirmed or channel<>'whatsapp' or evidence_path is not null) and
  (not confirmed or channel<>'visit' or evidence_path is not null or (geo->>'lat' is not null and geo->>'lng' is not null)) and
  (evidence_path is null or split_part(evidence_path,'/',1)=user_id::text));
alter table public.fm_eng_observations drop constraint if exists eng_closed_action;
alter table public.fm_eng_observations add constraint eng_closed_action check(status<>'closed' or length(trim(action))>0);
create index if not exists fm_eng_logs_assignment_at on public.fm_eng_logs(assignment_id,at);
create index if not exists fm_eng_assignments_user on public.fm_eng_assignments(user_id);
alter table public.fm_eng_targets enable row level security;
alter table public.fm_eng_assignments enable row level security;
alter table public.fm_eng_logs enable row level security;
alter table public.fm_eng_observations enable row level security;
alter table public.fm_eng_audit enable row level security;
-- the region of an observation (through its log and assignment)
create or replace function public.fm_eng_obs_region(p_log uuid) returns text language sql stable security definer set search_path=public as $$
  select a.region from public.fm_eng_logs l join public.fm_eng_assignments a on a.id = l.assignment_id where l.id = p_log $$;
-- V157: names and titles of the people whose engagement the caller may see (profiles themselves stay private)
create or replace function public.fm_eng_people() returns table(id uuid, full_name text, role text, job_title text, regions text[])
language sql stable security definer set search_path=public as $$
  select p.id, coalesce(p.full_name, p.email), p.role, public.fm_posx(p.role, p.job_title), p.regions from public.profiles p
   where exists(select 1 from public.fm_eng_assignments a where a.user_id = p.id and public.fm_eng_sees(a.user_id, a.region)) $$;
revoke all on function public.fm_eng_people() from public, anon;
grant execute on function public.fm_eng_people() to authenticated;
drop policy if exists eng_targets_read on public.fm_eng_targets;
create policy eng_targets_read on public.fm_eng_targets for select to authenticated using(exists(select 1 from public.profiles where id=auth.uid() and coalesce(active,true) and role in ('admin','manager','staff','supervisor','engineer','viewer')));
drop policy if exists eng_targets_admin on public.fm_eng_targets;
create policy eng_targets_admin on public.fm_eng_targets for all to authenticated using(public.fm_eng_admin()) with check(public.fm_eng_admin());
drop policy if exists eng_assign_read on public.fm_eng_assignments;
create policy eng_assign_read on public.fm_eng_assignments for select to authenticated using(public.fm_eng_admin() or (user_id=auth.uid() and exists(select 1 from public.profiles where id=auth.uid() and coalesce(active,true) and role in ('engineer','supervisor'))) or public.fm_eng_sees(user_id, region));
drop policy if exists eng_assign_admin on public.fm_eng_assignments;
create policy eng_assign_admin on public.fm_eng_assignments for all to authenticated using(public.fm_eng_admin()) with check(public.fm_eng_admin());
drop policy if exists eng_logs_read on public.fm_eng_logs;
create policy eng_logs_read on public.fm_eng_logs for select to authenticated using(public.fm_eng_admin() or exists(select 1 from public.fm_eng_assignments a where a.id=assignment_id and (a.user_id=auth.uid() or public.fm_eng_sees(a.user_id, a.region))));
drop policy if exists eng_logs_insert on public.fm_eng_logs;
drop policy if exists eng_obs_read on public.fm_eng_observations;
create policy eng_obs_read on public.fm_eng_observations for select to authenticated using(public.fm_eng_admin() or owner_id=auth.uid() or public.fm_eng_sees(owner_id, public.fm_eng_obs_region(log_id)));
drop policy if exists eng_obs_insert on public.fm_eng_observations;
drop policy if exists eng_obs_update on public.fm_eng_observations;
create policy eng_obs_update on public.fm_eng_observations for update to authenticated using(public.fm_eng_admin() or (owner_id=auth.uid() and exists(select 1 from public.profiles where id=auth.uid() and coalesce(active,true) and role in ('engineer','supervisor'))) or public.fm_eng_manages(owner_id, public.fm_eng_obs_region(log_id))) with check(public.fm_eng_admin() or owner_id=auth.uid() or public.fm_eng_manages(owner_id, public.fm_eng_obs_region(log_id)));
drop policy if exists eng_audit_read on public.fm_eng_audit;
create policy eng_audit_read on public.fm_eng_audit for select to authenticated using(public.fm_eng_admin() or exists(select 1 from public.fm_eng_observations o where o.id=observation_id and (o.owner_id=auth.uid() or public.fm_eng_sees(o.owner_id, public.fm_eng_obs_region(o.log_id)))));
-- logs and observations are created only by fm_eng_submit; a follow-up may change only its status, action and references
-- (not its owner, log or due time)
revoke all on public.fm_eng_targets, public.fm_eng_assignments, public.fm_eng_logs, public.fm_eng_observations, public.fm_eng_audit from anon, authenticated;
grant select, insert, update on public.fm_eng_targets, public.fm_eng_assignments to authenticated;
grant select on public.fm_eng_logs, public.fm_eng_observations, public.fm_eng_audit to authenticated;
grant update (status, action, ticket_ref, wo_ref) on public.fm_eng_observations to authenticated;
revoke all on function public.fm_eng_submit(jsonb) from public, anon;
grant execute on function public.fm_eng_submit(jsonb) to authenticated;
revoke all on function public.fm_eng_audit_update() from public, anon, authenticated;
-- evidence files: private bucket, one folder per user
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('school-engagement','school-engagement',false,5242880,array['image/jpeg','image/png','image/webp','application/pdf']) on conflict(id) do nothing;
-- storage policies: newer Supabase projects may refuse changes to storage.objects from the SQL editor
-- ("must be owner of relation objects"); then the existing policies stay and the rest of this file still runs
do $do$ begin
  execute $q$drop policy if exists eng_evidence_insert on storage.objects$q$;
  execute $q$create policy eng_evidence_insert on storage.objects for insert to authenticated with check(bucket_id='school-engagement' and (storage.foldername(name))[1]=auth.uid()::text and exists(select 1 from public.profiles where id=auth.uid() and coalesce(active,true) and role in ('supervisor','engineer')))$q$;
  execute $q$drop policy if exists eng_evidence_read on storage.objects$q$;
  execute $q$create policy eng_evidence_read on storage.objects for select to authenticated using(bucket_id='school-engagement' and (public.fm_eng_admin() or (storage.foldername(name))[1]=auth.uid()::text
  or public.fm_eng_lead_folder((storage.foldername(name))[1])))$q$;
exception when insufficient_privilege then
  raise notice 'school-engagement: لم تُحدَّث سياسات التخزين (لا صلاحية على storage.objects) — أضفها من Storage ← Policies إن لزم';
end $do$;
revoke all on function public.fm_eng_lead(uuid) from public, anon;
grant execute on function public.fm_eng_lead(uuid) to authenticated;

-- ---------- 14) escalation, spending limit, stop work, quality audits, deputies, audit log (V158) ----------
-- work orders: «stopped» (safety) and the escalation state
do $$ declare c text; begin
  for c in select conname from pg_constraint where conrelid = 'public.work_orders'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%status%' loop
    execute format('alter table public.work_orders drop constraint %I', c); end loop;
  alter table public.work_orders add constraint work_orders_status_check
    check (status in ('assigned','accepted','rejected','in_progress','done','returned','closed','cancelled','stopped'));
end $$;
alter table public.work_orders add column if not exists stop_prev text;
alter table public.work_orders add column if not exists esc_level int not null default 0;
alter table public.work_orders add column if not exists esc_to uuid references public.profiles(id) on delete set null;
alter table public.work_orders add column if not exists esc_at timestamptz;

-- the title needed to approve an order's purchases: 6 = operations manager, 5 = area manager, 0 = anyone allowed
create or replace function public.fm_wo_spend(cl jsonb) returns numeric language sql immutable as $$
  select coalesce(sum(coalesce(nullif(regexp_replace(m->>'q', '[^0-9.]', '', 'g'), '')::numeric, 0)
                    * coalesce(nullif(regexp_replace(m->>'price', '[^0-9.]', '', 'g'), '')::numeric, 0)), 0)
    from jsonb_array_elements(case when jsonb_typeof(cl) = 'array' then cl else '[]'::jsonb end) e,
         jsonb_array_elements(case when jsonb_typeof(e->'materials') = 'array' then e->'materials' else '[]'::jsonb end) m
   where m->>'src' = 'buy' $$;
create or replace function public.fm_wo_spend_rank(cl jsonb) returns int language sql stable security definer set search_path = public as $$
  select case when (public.fm_setting('spend_limits')->>'ops_manager') is not null and public.fm_wo_spend(cl) > (public.fm_setting('spend_limits')->>'ops_manager')::numeric then 6
              when (public.fm_setting('spend_limits')->>'area_manager') is not null and public.fm_wo_spend(cl) > (public.fm_setting('spend_limits')->>'area_manager')::numeric then 5
              else 0 end $$;

-- escalation: an open order past its due time climbs one manager up the assignee's line at each threshold (hours late)
create or replace function public.fm_wo_escalate() returns int
language plpgsql security definer set search_path = public as $$
declare cfg jsonb := public.fm_setting('escalation'); w record; lv int; tgt uuid; cur uuid; k int; n int := 0; h numeric; nm text;
begin
  if cfg is null or coalesce((cfg->>'enabled')::boolean, true) = false then return 0; end if;
  for w in select * from public.work_orders where due_at < now() and status in ('assigned','accepted','in_progress','returned') and assignee is not null loop
    h := extract(epoch from now() - w.due_at) / 3600;
    select count(*) into lv from jsonb_array_elements_text(cfg->'hours') x where x::numeric <= h;
    if lv <= w.esc_level then continue; end if;
    cur := w.assignee; tgt := null; k := 0;
    while k < lv loop
      select reports_to into cur from public.profiles where id = cur;
      exit when cur is null; tgt := cur; k := k + 1;
    end loop;
    if tgt is null then continue; end if;
    select coalesce(full_name, email) into nm from public.profiles where id = tgt;
    update public.work_orders set esc_level = lv, esc_to = tgt, esc_at = now() where id = w.id;
    insert into public.wo_events (wo_id, by_id, by_name, type, status, text)
    values (w.id, null, 'النظام', 'escalate', w.status, '⏫ تصعيد (المستوى ' || lv || ') إلى ' || coalesce(nm,'') || ' — متأخر ' || round(h) || ' ساعة');
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.fm_wo_escalate() from public, anon, authenticated;
-- the orders escalated to the signed-in user
create or replace function public.fm_wo_my_escalations() returns setof public.work_orders language sql stable security definer set search_path = public as $$
  select * from public.work_orders where esc_to = auth.uid() and status in ('assigned','accepted','in_progress','returned') order by esc_level desc, due_at $$;
revoke all on function public.fm_wo_my_escalations() from public, anon;
grant execute on function public.fm_wo_my_escalations() to authenticated;
revoke all on function public.fm_wo_spend_rank(jsonb) from public, anon;
grant execute on function public.fm_wo_spend_rank(jsonb) to authenticated;

-- quality audits: a random sample of closed orders; a failed audit opens a non-conformance report (NCR) and can open a corrective order
create sequence if not exists public.ncr_seq;
create table if not exists public.wo_audits (
  id uuid primary key default gen_random_uuid(),
  wo_id uuid not null unique references public.work_orders(id) on delete cascade,
  sampled_at timestamptz not null default now(), sampled_by uuid,
  status text not null default 'pending' check (status in ('pending','pass','fail')),
  score int check (score between 0 and 100), notes text, reviewed_by uuid, reviewed_at timestamptz,
  ncr_code text unique, ncr_status text check (ncr_status in ('open','closed')), ncr_action text, ncr_due timestamptz, ncr_wo uuid, ncr_closed_at timestamptz);
alter table public.wo_audits enable row level security;
drop policy if exists p_aud_read on public.wo_audits;
create policy p_aud_read on public.wo_audits for select using (public.fm_scope_all() or public.fm_wo_can_see(wo_id));
revoke all on public.wo_audits from anon, authenticated;
grant select on public.wo_audits to authenticated;
create or replace function public.fm_qa_ok() returns boolean language sql stable as $$
  select coalesce(public.fm_my_pos() in ('qa_manager','sysadmin'), false) $$;
create or replace function public.fm_qa_sample(p_pct numeric default null, p_days int default null) returns int
language plpgsql security definer set search_path = public as $$
declare cfg jsonb := public.fm_setting('qa'); pct numeric := coalesce(p_pct, (cfg->>'sample_pct')::numeric, 5); dd int := coalesce(p_days, (cfg->>'days')::int, 30); tot int; n int;
begin
  if not public.fm_qa_ok() then raise exception 'not allowed' using errcode = '42501'; end if;
  select count(*) into tot from public.work_orders w where w.status = 'closed' and w.closed_at > now() - make_interval(days => dd)
     and not exists (select 1 from public.wo_audits a where a.wo_id = w.id);
  n := ceil(tot * least(greatest(pct, 0), 100) / 100.0);
  insert into public.wo_audits (wo_id, sampled_by)
  select w.id, auth.uid() from public.work_orders w where w.status = 'closed' and w.closed_at > now() - make_interval(days => dd)
     and not exists (select 1 from public.wo_audits a where a.wo_id = w.id) order by random() limit n;
  return n;
end $$;
create or replace function public.fm_qa_review(p_id uuid, p_result text, p_score int default null, p_notes text default null, p_corrective boolean default false) returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.wo_audits; w public.work_orders; me public.profiles; v_ncr text; cw uuid;
begin
  if not public.fm_qa_ok() then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into me from public.profiles where id = auth.uid();
  select * into a from public.wo_audits where id = p_id for update;
  if a.id is null then raise exception 'audit not found'; end if;
  if p_result not in ('pass','fail') then raise exception 'invalid result'; end if;
  if p_result = 'fail' and nullif(trim(coalesce(p_notes,'')),'') is null then raise exception 'reason required'; end if;
  select * into w from public.work_orders where id = a.wo_id;
  if p_result = 'fail' and a.ncr_code is null then
    v_ncr := 'NCR-' || to_char(now(),'YYYY') || '-' || lpad(nextval('public.ncr_seq')::text, 4, '0');
    if p_corrective and w.assignee is not null and public.fm_can_assign_as(me.id, w.assignee) then
      cw := public.fm_wo_create_as(me.id, jsonb_build_object('title', 'تصحيح عدم مطابقة ' || v_ncr || ' — ' || w.title, 'type', 'repair',
              'assignee', w.assignee, 'school', w.school, 'region', w.region, 'building_id', w.building_id, 'priority', 'عالي',
              'due_at', now() + interval '7 days', 'description', 'تقرير عدم مطابقة على الأمر ' || w.code || E'\n' || p_notes));
      update public.work_orders set source_wo = w.id where id = cw;
    end if;
  end if;
  update public.wo_audits set status = p_result, score = p_score, notes = nullif(trim(coalesce(p_notes,'')),''), reviewed_by = me.id, reviewed_at = now(),
     ncr_code = coalesce(ncr_code, v_ncr), ncr_status = case when coalesce(ncr_code, v_ncr) is not null then coalesce(ncr_status,'open') end,
     ncr_due = coalesce(ncr_due, case when v_ncr is not null then now() + interval '7 days' end), ncr_wo = coalesce(ncr_wo, cw)
   where id = a.id;
  insert into public.wo_events (wo_id, by_id, by_name, type, status, text)
  values (w.id, me.id, coalesce(me.full_name, me.email), 'audit', w.status,
          case when p_result = 'pass' then '✅ تدقيق الجودة: مطابق' else '❌ تدقيق الجودة: غير مطابق — ' || coalesce(v_ncr, a.ncr_code, '') || ' — ' || p_notes end
          || coalesce(' (' || p_score || '%)', ''));
  return jsonb_build_object('ncr', coalesce(v_ncr, a.ncr_code), 'corrective', (select x.code from public.work_orders x where x.id = cw));
end $$;
create or replace function public.fm_qa_ncr_close(p_id uuid, p_action text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.fm_qa_ok() then raise exception 'not allowed' using errcode = '42501'; end if;
  if nullif(trim(coalesce(p_action,'')),'') is null then raise exception 'action required'; end if;
  update public.wo_audits set ncr_status = 'closed', ncr_action = trim(p_action), ncr_closed_at = now() where id = p_id and ncr_status = 'open';
  if not found then raise exception 'ncr not open'; end if;
end $$;
revoke all on function public.fm_qa_sample(numeric,int) from public, anon;
revoke all on function public.fm_qa_review(uuid,text,int,text,boolean) from public, anon;
revoke all on function public.fm_qa_ncr_close(uuid,text) from public, anon;
grant execute on function public.fm_qa_sample(numeric,int) to authenticated;
grant execute on function public.fm_qa_review(uuid,text,int,text,boolean) to authenticated;
grant execute on function public.fm_qa_ncr_close(uuid,text) to authenticated;

-- deputies: set by the principal himself (or the system admin for anyone), ended by either of them
alter table public.fm_deputies enable row level security;
drop policy if exists p_dep_read on public.fm_deputies;
create policy p_dep_read on public.fm_deputies for select using (principal = auth.uid() or deputy = auth.uid() or public.fm_scope_all());
revoke all on public.fm_deputies from anon, authenticated;
grant select on public.fm_deputies to authenticated;
create or replace function public.fm_deputy_set(p_deputy uuid, p_from timestamptz, p_to timestamptz, p_note text default null, p_principal uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles; pr uuid; dp public.profiles; v uuid;
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active then raise exception 'not allowed' using errcode = '42501'; end if;
  pr := coalesce(p_principal, me.id);
  if pr <> me.id and me.role <> 'admin' then raise exception 'not allowed' using errcode = '42501'; end if;
  if public.fm_prank(public.fm_posx((select role from public.profiles where id = pr), (select job_title from public.profiles where id = pr))) < 3
     and public.fm_posx((select role from public.profiles where id = pr), (select job_title from public.profiles where id = pr)) not in ('hse_manager','qa_manager') then
    raise exception 'not allowed' using errcode = '42501'; end if;
  select * into dp from public.profiles where id = p_deputy;
  if dp.id is null or not dp.active or dp.id = pr or dp.role in ('pending','contractor') then raise exception 'invalid deputy'; end if;
  if p_to <= p_from or p_to > p_from + interval '120 days' then raise exception 'invalid period'; end if;
  update public.fm_deputies set active = false where principal = pr and active and to_at > p_from;
  insert into public.fm_deputies (principal, deputy, from_at, to_at, note) values (pr, p_deputy, p_from, p_to, nullif(trim(coalesce(p_note,'')),'')) returning id into v;
  return v;
end $$;
create or replace function public.fm_deputy_end(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.fm_deputies set active = false where id = p_id and active
     and (principal = auth.uid() or deputy = auth.uid() or public.fm_role() = 'admin');
  if not found then raise exception 'not allowed' using errcode = '42501'; end if;
end $$;
-- who can be chosen as a deputy (names and titles only; profiles stay private)
create or replace function public.fm_deputy_candidates() returns table(id uuid, full_name text, job_title text, regions text[])
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.full_name, p.email), public.fm_posx(p.role, p.job_title), p.regions from public.profiles p
   where p.active and p.id <> auth.uid() and p.role not in ('pending','contractor') and public.fm_role() <> 'pending'
   order by public.fm_prank(public.fm_posx(p.role, p.job_title)) desc, p.full_name $$;
revoke all on function public.fm_deputy_set(uuid,timestamptz,timestamptz,text,uuid) from public, anon;
revoke all on function public.fm_deputy_end(uuid) from public, anon;
revoke all on function public.fm_deputy_candidates() from public, anon;
grant execute on function public.fm_deputy_set(uuid,timestamptz,timestamptz,text,uuid) to authenticated;
grant execute on function public.fm_deputy_end(uuid) to authenticated;
grant execute on function public.fm_deputy_candidates() to authenticated;

-- audit log of sensitive operations (written by triggers, read by the system admin only)
create table if not exists public.fm_audit_log (
  id bigint generated always as identity primary key, at timestamptz not null default now(),
  actor uuid default auth.uid(), actor_name text, action text not null, target text, details jsonb);
create index if not exists fm_audit_log_at_idx on public.fm_audit_log (at desc);
alter table public.fm_audit_log enable row level security;
drop policy if exists p_alog_read on public.fm_audit_log;
create policy p_alog_read on public.fm_audit_log for select using (public.fm_role() = 'admin');
revoke all on public.fm_audit_log from anon, authenticated;
grant select on public.fm_audit_log to authenticated;
create or replace function public.fm_audit(p_action text, p_target text, p_details jsonb) returns void
language sql security definer set search_path = public as $$
  insert into public.fm_audit_log (actor, actor_name, action, target, details)
  values (auth.uid(), (select coalesce(full_name, email) from public.profiles where id = auth.uid()), p_action, p_target, p_details) $$;
revoke all on function public.fm_audit(text,text,jsonb) from public, anon, authenticated;
create or replace function public.fm_audit_trg() returns trigger language plpgsql security definer set search_path = public as $$
declare o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end; n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end; d jsonb := '{}'; k text;
begin
  if tg_table_name = 'profiles' then
    foreach k in array array['role','job_title','active','regions','reports_to','person_names'] loop
      if o is null or n is null or (o->k) is distinct from (n->k) then d := d || jsonb_build_object(k, jsonb_build_object('from', o->k, 'to', n->k)); end if;
    end loop;
    if tg_op = 'UPDATE' and d = '{}' then return null; end if;
    perform public.fm_audit('profile.' || lower(tg_op), coalesce(n->>'email', o->>'email'), d);
  elsif tg_table_name = 'work_orders' then
    if tg_op = 'DELETE' then perform public.fm_audit('wo.delete', o->>'code', jsonb_build_object('title', o->>'title'));
    elsif (o->>'status') is distinct from (n->>'status') and (n->>'status' in ('closed','cancelled','stopped') or o->>'status' = 'stopped') then
      perform public.fm_audit('wo.' || case when o->>'status' = 'stopped' and n->>'status' <> 'cancelled' then 'resumed' else n->>'status' end, n->>'code', jsonb_build_object('from', o->>'status', 'title', n->>'title', 'spend', public.fm_wo_spend(new.checklist)));
    end if;
  elsif tg_table_name = 'fm_settings' then
    perform public.fm_audit('settings.' || lower(tg_op), n->>'key', jsonb_build_object('from', o->'value', 'to', n->'value'));
  elsif tg_table_name = 'fm_deputies' then
    perform public.fm_audit(case when tg_op = 'INSERT' then 'deputy.set' else 'deputy.update' end, n->>'principal',
      jsonb_build_object('deputy', n->>'deputy', 'from', n->>'from_at', 'to', n->>'to_at', 'active', n->'active'));
  elsif tg_table_name = 'wo_audits' then
    if (o->>'status') is distinct from (n->>'status') or (o->>'ncr_status') is distinct from (n->>'ncr_status') then
      perform public.fm_audit(case when (o->>'ncr_status') is distinct from (n->>'ncr_status') and n->>'ncr_status' = 'closed' then 'qa.ncr_closed' else 'qa.' || coalesce(n->>'status','') end, (select code from public.work_orders where id = new.wo_id),
        jsonb_build_object('score', n->'score', 'ncr', n->>'ncr_code', 'ncr_status', n->>'ncr_status'));
    end if;
  end if;
  return null;
end $$;
drop trigger if exists fm_audit_profiles on public.profiles;
create trigger fm_audit_profiles after insert or update or delete on public.profiles for each row execute function public.fm_audit_trg();
drop trigger if exists fm_audit_wo on public.work_orders;
create trigger fm_audit_wo after update of status or delete on public.work_orders for each row execute function public.fm_audit_trg();
drop trigger if exists fm_audit_settings on public.fm_settings;
create trigger fm_audit_settings after insert or update on public.fm_settings for each row execute function public.fm_audit_trg();
drop trigger if exists fm_audit_dep on public.fm_deputies;
create trigger fm_audit_dep after insert or update on public.fm_deputies for each row execute function public.fm_audit_trg();
drop trigger if exists fm_audit_qa on public.wo_audits;
create trigger fm_audit_qa after update on public.wo_audits for each row execute function public.fm_audit_trg();

-- ---------- 15) school satisfaction ratings (V160, field F20) ----------
-- After a completed contact the school rates the service, the supervisor and the engineer (1–5) plus overall and a comment.
-- Two sources: 'school' = the principal through a one-time public link (rate.html?t=…, no account, 7 days), and
-- 'staff' = the supervisor / engineer records what the principal said. One rating per contact and source.
-- A score of 2 or less opens a follow-up (fu_status) that the managers of that person close with an action.
create table if not exists public.fm_eng_rate_links(token text primary key, log_id uuid not null unique references public.fm_eng_logs(id) on delete cascade,
  school_code text not null, school_name text not null, region text not null default '', supervisor_id uuid references public.profiles(id), engineer_id uuid references public.profiles(id),
  created_by uuid not null references public.profiles(id), created_at timestamptz not null default now(), expires_at timestamptz not null, used_at timestamptz);
create table if not exists public.fm_eng_ratings(id uuid primary key default gen_random_uuid(), log_id uuid not null references public.fm_eng_logs(id) on delete cascade,
  source text not null check(source in ('school','staff')), school_code text not null, school_name text not null, region text not null default '',
  supervisor_id uuid references public.profiles(id), engineer_id uuid references public.profiles(id), entered_by uuid references public.profiles(id),
  rater_name text not null default '', rater_title text not null default '',
  q_service int not null check(q_service between 1 and 5), q_supervisor int check(q_supervisor between 1 and 5), q_engineer int check(q_engineer between 1 and 5),
  q_overall int not null check(q_overall between 1 and 5), comment text not null default '' check(length(comment)<=1000),
  fu_status text not null default 'none' check(fu_status in ('none','open','closed')), fu_action text not null default '', fu_by uuid references public.profiles(id), fu_at timestamptz,
  created_at timestamptz not null default now(), unique(log_id, source), constraint rate_closed_action check(fu_status<>'closed' or length(trim(fu_action))>0));
create index if not exists fm_eng_ratings_created on public.fm_eng_ratings(created_at);
alter table public.fm_eng_rate_links enable row level security;
alter table public.fm_eng_ratings enable row level security;
-- the supervisor and the engineer of one contact: its author, and the other role among the active assignments of that school
-- (an engineer prefers the supervisor who reports to him; a supervisor falls back to his own engineer)
create or replace function public.fm_eng_rate_people(p_log uuid, out o_sup uuid, out o_eng uuid, out o_code text, out o_name text, out o_region text)
language plpgsql stable security definer set search_path=public as $$
declare v_user uuid; v_role text; v_boss uuid;
begin
  select l.user_id, u.role, u.reports_to, a.school_code, a.school_name, a.region into v_user, v_role, v_boss, o_code, o_name, o_region
    from public.fm_eng_logs l join public.fm_eng_assignments a on a.id = l.assignment_id join public.profiles u on u.id = l.user_id where l.id = p_log;
  if v_user is null then return; end if;
  if v_role = 'engineer' then
    o_eng := v_user;
    select a.user_id into o_sup from public.fm_eng_assignments a join public.profiles p on p.id = a.user_id
     where a.school_code = o_code and a.active and p.active and p.role = 'supervisor' order by coalesce(p.reports_to = v_user, false) desc, a.id limit 1;
  else
    o_sup := v_user;
    select a.user_id into o_eng from public.fm_eng_assignments a join public.profiles p on p.id = a.user_id
     where a.school_code = o_code and a.active and p.active and p.role = 'engineer' order by coalesce(p.id = v_boss, false) desc, a.id limit 1;
    if o_eng is null and exists(select 1 from public.profiles where id = v_boss and role = 'engineer' and active) then o_eng := v_boss; end if;
  end if;
end $$;
revoke all on function public.fm_eng_rate_people(uuid) from public, anon, authenticated;
-- who may see one rating / link: the rated people, their managers and the scopes of fm_eng_sees
create or replace function public.fm_eng_rate_sees(p_sup uuid, p_eng uuid, p_region text) returns boolean language sql stable security definer set search_path=public as $$
  select public.fm_eng_admin() or auth.uid() in (p_sup, p_eng) or (p_sup is not null and public.fm_eng_sees(p_sup, p_region))
      or (p_eng is not null and public.fm_eng_sees(p_eng, p_region)) $$;
revoke all on function public.fm_eng_rate_sees(uuid,uuid,text) from public, anon;
grant execute on function public.fm_eng_rate_sees(uuid,uuid,text) to authenticated;
drop policy if exists eng_rate_links_read on public.fm_eng_rate_links;
create policy eng_rate_links_read on public.fm_eng_rate_links for select to authenticated using(created_by = auth.uid() or public.fm_eng_rate_sees(supervisor_id, engineer_id, region));
drop policy if exists eng_ratings_read on public.fm_eng_ratings;
create policy eng_ratings_read on public.fm_eng_ratings for select to authenticated using(public.fm_eng_rate_sees(supervisor_id, engineer_id, region));
revoke all on public.fm_eng_rate_links, public.fm_eng_ratings from anon, authenticated;
grant select on public.fm_eng_rate_links, public.fm_eng_ratings to authenticated;
-- names: fm_eng_people (section 13) also returns the people of the ratings the caller sees
create or replace function public.fm_eng_people() returns table(id uuid, full_name text, role text, job_title text, regions text[])
language sql stable security definer set search_path=public as $$
  select p.id, coalesce(p.full_name, p.email), p.role, public.fm_posx(p.role, p.job_title), p.regions from public.profiles p
   where exists(select 1 from public.fm_eng_assignments a where a.user_id = p.id and public.fm_eng_sees(a.user_id, a.region))
      or exists(select 1 from public.fm_eng_ratings r where p.id in (r.supervisor_id, r.engineer_id) and public.fm_eng_rate_sees(r.supervisor_id, r.engineer_id, r.region)) $$;
-- the author of a completed contact (not «no reply») asks for a rating: returns the link token (the same one while it is valid)
create or replace function public.fm_eng_rate_link(p_log uuid) returns text language plpgsql security definer set search_path=public as $$
declare l record; x record; v_tok text;
begin
  select * into l from public.fm_eng_logs where id = p_log;
  if l.id is null or l.user_id <> auth.uid() or not exists(select 1 from public.profiles where id = auth.uid() and active) then raise exception 'not allowed'; end if;
  if l.outcome = 'no_reply' then raise exception 'rating needs a completed contact'; end if;
  if exists(select 1 from public.fm_eng_ratings where log_id = p_log and source = 'school') then raise exception 'already rated'; end if;
  select token into v_tok from public.fm_eng_rate_links where log_id = p_log and used_at is null and expires_at > now();
  if v_tok is not null then return v_tok; end if;
  select * into x from public.fm_eng_rate_people(p_log);
  v_tok := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  delete from public.fm_eng_rate_links where log_id = p_log;
  insert into public.fm_eng_rate_links(token, log_id, school_code, school_name, region, supervisor_id, engineer_id, created_by, expires_at)
  values (v_tok, p_log, x.o_code, x.o_name, coalesce(x.o_region,''), x.o_sup, x.o_eng, auth.uid(), now() + interval '7 days');
  return v_tok;
end $$;
revoke all on function public.fm_eng_rate_link(uuid) from public, anon;
grant execute on function public.fm_eng_rate_link(uuid) to authenticated;
-- shared checks of one rating payload; returns the row values
create or replace function public.fm_eng_rate_vals(p jsonb, out s int, out sv int, out en int, out ov int, out cm text, out rn text, out rt text)
language plpgsql immutable as $$
begin
  s := nullif(p->>'q_service','')::int; sv := nullif(p->>'q_supervisor','')::int; en := nullif(p->>'q_engineer','')::int; ov := nullif(p->>'q_overall','')::int;
  if s is null or ov is null or s not between 1 and 5 or ov not between 1 and 5 or coalesce(sv,1) not between 1 and 5 or coalesce(en,1) not between 1 and 5 then
    raise exception 'invalid rating'; end if;
  cm := left(trim(coalesce(p->>'comment','')), 1000); rn := left(trim(coalesce(p->>'rater_name','')), 100); rt := left(trim(coalesce(p->>'rater_title','')), 100);
end $$;
revoke all on function public.fm_eng_rate_vals(jsonb) from public, anon, authenticated;
-- public (anon): what the rating page shows for one token. Only names, never ids or contact data.
create or replace function public.fm_eng_rate_info(p_token text) returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce((select jsonb_build_object('state', case when k.used_at is not null then 'used' when k.expires_at <= now() then 'expired' else 'ok' end,
      'school', k.school_name, 'at', l.at, 'channel', l.channel,
      'supervisor', (select full_name from public.profiles where id = k.supervisor_id), 'engineer', (select full_name from public.profiles where id = k.engineer_id))
    from public.fm_eng_rate_links k join public.fm_eng_logs l on l.id = k.log_id where k.token = p_token and length(p_token) = 64),
    jsonb_build_object('state', 'invalid')) $$;
-- public (anon): the principal submits once
create or replace function public.fm_eng_rate_submit(p_token text, p jsonb) returns text language plpgsql security definer set search_path=public as $$
declare k record; v record;
begin
  select * into k from public.fm_eng_rate_links where token = p_token and length(p_token) = 64 for update;
  if k.token is null then raise exception 'invalid link'; end if;
  if k.used_at is not null then raise exception 'already rated'; end if;
  if k.expires_at <= now() then raise exception 'link expired'; end if;
  select * into v from public.fm_eng_rate_vals(p);
  insert into public.fm_eng_ratings(log_id, source, school_code, school_name, region, supervisor_id, engineer_id, rater_name, rater_title,
    q_service, q_supervisor, q_engineer, q_overall, comment, fu_status)
  values (k.log_id, 'school', k.school_code, k.school_name, k.region, k.supervisor_id, k.engineer_id, v.rn, v.rt,
    v.s, case when k.supervisor_id is not null then v.sv end, case when k.engineer_id is not null then v.en end, v.ov, v.cm,
    case when least(v.s, coalesce(v.sv,5), coalesce(v.en,5), v.ov) <= 2 then 'open' else 'none' end);
  update public.fm_eng_rate_links set used_at = now() where token = p_token;
  return 'ok';
end $$;
revoke all on function public.fm_eng_rate_info(text), public.fm_eng_rate_submit(text,jsonb) from public;
grant execute on function public.fm_eng_rate_info(text), public.fm_eng_rate_submit(text,jsonb) to anon, authenticated;
-- the author of the contact records what the principal said (within 7 days of the contact)
create or replace function public.fm_eng_rate_staff(p_log uuid, p jsonb) returns uuid language plpgsql security definer set search_path=public as $$
declare l record; x record; v record; rid uuid;
begin
  select * into l from public.fm_eng_logs where id = p_log;
  if l.id is null or l.user_id <> auth.uid() or not exists(select 1 from public.profiles where id = auth.uid() and active) then raise exception 'not allowed'; end if;
  if l.outcome = 'no_reply' then raise exception 'rating needs a completed contact'; end if;
  if l.at < now() - interval '7 days' then raise exception 'rating period ended'; end if;
  select * into x from public.fm_eng_rate_people(p_log); select * into v from public.fm_eng_rate_vals(p);
  insert into public.fm_eng_ratings(log_id, source, school_code, school_name, region, supervisor_id, engineer_id, entered_by, rater_name, rater_title,
    q_service, q_supervisor, q_engineer, q_overall, comment, fu_status)
  values (p_log, 'staff', x.o_code, x.o_name, coalesce(x.o_region,''), x.o_sup, x.o_eng, auth.uid(), v.rn, v.rt,
    v.s, case when x.o_sup is not null then v.sv end, case when x.o_eng is not null then v.en end, v.ov, v.cm,
    case when least(v.s, coalesce(v.sv,5), coalesce(v.en,5), v.ov) <= 2 then 'open' else 'none' end)
  returning id into rid;
  return rid;
exception when unique_violation then raise exception 'already rated';
end $$;
revoke all on function public.fm_eng_rate_staff(uuid,jsonb) from public, anon;
grant execute on function public.fm_eng_rate_staff(uuid,jsonb) to authenticated;
-- follow-up of a low rating: the managers of the rated people (not the rated people themselves)
create or replace function public.fm_eng_rate_follow(p_id uuid, p_status text, p_action text) returns void language plpgsql security definer set search_path=public as $$
declare r record;
begin
  select * into r from public.fm_eng_ratings where id = p_id for update;
  if r.id is null or r.fu_status = 'none' or p_status not in ('open','closed') then raise exception 'not allowed'; end if;
  if not (public.fm_eng_admin() or (r.supervisor_id is not null and public.fm_eng_manages(r.supervisor_id, r.region))
          or (r.engineer_id is not null and public.fm_eng_manages(r.engineer_id, r.region))) then
    raise exception 'not allowed'; end if;
  -- a rated person never closes a follow-up of his own low score
  if (auth.uid() = r.supervisor_id and coalesce(r.q_supervisor,5) <= 2) or (auth.uid() = r.engineer_id and coalesce(r.q_engineer,5) <= 2) then
    raise exception 'not allowed'; end if;
  if p_status = 'closed' and length(trim(coalesce(p_action,''))) = 0 then raise exception 'action required'; end if;
  update public.fm_eng_ratings set fu_status = p_status, fu_action = trim(coalesce(p_action,'')), fu_by = auth.uid(), fu_at = now() where id = p_id;
end $$;
revoke all on function public.fm_eng_rate_follow(uuid,text,text) from public, anon;
grant execute on function public.fm_eng_rate_follow(uuid,text,text) to authenticated;

-- V160: contact with the schools counts in the supervisor / engineer score. fm_settings.score_weights = the share (%) of
-- contact coverage (cov) and school satisfaction (sat); the ticket score (35/35/15/15) keeps the rest. A part with no data
-- (no active assignment / no rating) gives its share back to the tickets.
insert into public.fm_settings(key, value) values ('score_weights', '{"cov": 10, "sat": 10}') on conflict (key) do nothing;
-- per active supervisor / engineer the caller may see: coverage of the last 4 weekly cycles (or the last 30 days for a
-- monthly cycle) = assignment-cycles with a completed contact ÷ assignment-cycles, and satisfaction = his own item
-- (q_supervisor / q_engineer) of the ratings of the last 90 days × 20 (0–100)
create or replace function public.fm_eng_scores() returns table(user_id uuid, full_name text, person_names text[], role text, cov numeric, cov_hit int, cov_total int, sat numeric, sat_n int)
language sql stable security definer set search_path=public as $$
  with ppl as (
    select p.id, coalesce(p.full_name, p.email) fname, coalesce(p.person_names, '{}') pn, p.role,
           coalesce((select t.cycle from public.fm_eng_targets t where t.role = p.role), case when p.role = 'engineer' then 'monthly' else 'weekly' end) cyc
      from public.profiles p
     where p.active and p.role in ('supervisor','engineer')
       and (public.fm_eng_admin() or p.id = auth.uid() or public.fm_scope_all()
            or exists(select 1 from public.fm_eng_assignments a where a.user_id = p.id and a.active and public.fm_eng_sees(a.user_id, a.region)))),
  blk as (
    select p.id uid, now() - case when p.cyc = 'weekly' then (b + 1) * interval '7 days' else interval '30 days' end f,
           now() - b * interval '7 days' t
      from ppl p cross join lateral generate_series(0, case when p.cyc = 'weekly' then 3 else 0 end) b),
  cv as (
    select b.uid, count(*)::int tot,
           count(*) filter (where exists(select 1 from public.fm_eng_logs l where l.assignment_id = a.id and l.outcome <> 'no_reply' and l.confirmed
                                         and l.at > b.f and l.at <= b.t))::int hit
      from blk b join public.fm_eng_assignments a on a.user_id = b.uid and a.active group by b.uid),
  st as (
    select x.uid, avg(x.v) av, count(*)::int n from (
      select r.supervisor_id uid, r.q_supervisor v from public.fm_eng_ratings r where r.q_supervisor is not null and r.created_at > now() - interval '90 days'
      union all
      select r.engineer_id, r.q_engineer from public.fm_eng_ratings r where r.q_engineer is not null and r.created_at > now() - interval '90 days') x
     group by x.uid)
  select p.id, p.fname, p.pn, p.role,
         case when coalesce(cv.tot,0) > 0 then round(cv.hit * 100.0 / cv.tot, 1) end, coalesce(cv.hit,0), coalesce(cv.tot,0),
         case when st.n > 0 then round(st.av * 20, 1) end, coalesce(st.n,0)
    from ppl p left join cv on cv.uid = p.id left join st on st.uid = p.id $$;
revoke all on function public.fm_eng_scores() from public, anon;
grant execute on function public.fm_eng_scores() to authenticated;

-- ---------- 16) usage: who opens the platform / field app and what he does (V164, field F21) ----------
-- Each app calls fm_touch once when it opens (and at most once every 10 minutes after): one row per user, day and app.
create table if not exists public.fm_activity(user_id uuid not null references public.profiles(id) on delete cascade, day date not null,
  app text not null check(app in ('platform','field')), first_at timestamptz not null default now(), last_at timestamptz not null default now(),
  hits int not null default 1, primary key(user_id, day, app));
alter table public.fm_activity enable row level security;
revoke all on public.fm_activity from anon, authenticated;
create or replace function public.fm_touch(p_app text) returns void language sql security definer set search_path=public as $$
  insert into public.fm_activity(user_id, day, app)
  select auth.uid(), (now() at time zone 'Asia/Riyadh')::date, p_app
   where auth.uid() is not null and p_app in ('platform','field') and exists(select 1 from public.profiles where id = auth.uid())
  on conflict (user_id, day, app) do update set last_at = now(), hits = public.fm_activity.hits + 1 $$;
revoke all on function public.fm_touch(text) from public, anon;
grant execute on function public.fm_touch(text) to authenticated;
-- the usage report: system admin and project manager. Days in Riyadh time, p_to inclusive.
create or replace function public.fm_usage_report(p_from date, p_to date)
returns table(user_id uuid, full_name text, email text, job_title text, regions text[], phone text, active boolean, created_at timestamptz,
  last_sign_in timestamptz, must_change_pw boolean, last_seen timestamptz, days int, platform_days int, field_days int,
  wo_created int, wo_actions int, wo_done int, eng_logs int, eng_done int, rate_requests int)
language plpgsql stable security definer set search_path=public as $$
declare f timestamptz := (p_from::timestamp at time zone 'Asia/Riyadh'); t timestamptz := ((p_to + 1)::timestamp at time zone 'Asia/Riyadh');
begin
  if not (public.fm_eng_admin() or coalesce(public.fm_my_pos() = 'project_manager', false)) then raise exception 'not allowed'; end if;
  return query
  select p.id, coalesce(p.full_name, p.email), p.email, public.fm_posx(p.role, p.job_title), p.regions, p.phone, p.active, p.created_at,
    u.last_sign_in_at, p.must_change_pw,
    (select max(a.last_at) from public.fm_activity a where a.user_id = p.id),
    (select count(distinct a.day)::int from public.fm_activity a where a.user_id = p.id and a.day between p_from and p_to),
    (select count(*)::int from public.fm_activity a where a.user_id = p.id and a.app = 'platform' and a.day between p_from and p_to),
    (select count(*)::int from public.fm_activity a where a.user_id = p.id and a.app = 'field' and a.day between p_from and p_to),
    (select count(*)::int from public.work_orders w where w.created_by = p.id and w.created_at >= f and w.created_at < t),
    (select count(*)::int from public.wo_events e where e.by_id = p.id and e.type <> 'create' and e.at >= f and e.at < t),
    (select count(*)::int from public.wo_events e where e.by_id = p.id and e.type = 'done' and e.at >= f and e.at < t),
    (select count(*)::int from public.fm_eng_logs l where l.user_id = p.id and l.at >= f and l.at < t),
    (select count(*)::int from public.fm_eng_logs l where l.user_id = p.id and l.outcome <> 'no_reply' and l.confirmed and l.at >= f and l.at < t),
    (select count(*)::int from public.fm_eng_rate_links k where k.created_by = p.id and k.created_at >= f and k.created_at < t)
  from public.profiles p left join auth.users u on u.id = p.id
  where p.role <> 'pending';
end $$;
revoke all on function public.fm_usage_report(date,date) from public, anon;
grant execute on function public.fm_usage_report(date,date) to authenticated;

-- ---------- 17) data scope per title (V165, field F22) ----------
-- Uploading the tickets file: the system admin, the project and operations managers (every region) and the area manager
-- (his regions). The same people write the region's reference date and ranking (app_kv fm_ref_date_<r> / fm_rank_<r>).
create or replace function public.fm_can_upload(r text) returns boolean language sql stable security definer set search_path = public as $$
  select public.fm_role() = 'admin' or coalesce(public.fm_my_pos() in ('project_manager','ops_manager'), false)
      or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(r,''))) $$;
revoke all on function public.fm_can_upload(text) from public, anon;
grant execute on function public.fm_can_upload(text) to authenticated;
drop policy if exists p_tickets_write on public.tickets;
create policy p_tickets_write on public.tickets for all using (public.fm_can_upload(region)) with check (public.fm_can_upload(region));
-- the school DB: engineers, supervisors and contractors never read the whole file; they get their schools from fm_my_school_db
drop policy if exists p_kv_read on public.app_kv;
create policy p_kv_read on public.app_kv for select using (
  public.fm_role() in ('admin','manager','staff','viewer')
  or (public.fm_role() in ('engineer','supervisor','contractor') and key <> 'fm_school_master_db_v1'));
drop policy if exists p_kv_write on public.app_kv;
create policy p_kv_write on public.app_kv for all
  using (public.fm_role() = 'admin' or ((key like 'fm\_ref\_date\_%' or key like 'fm\_rank\_%') and public.fm_can_upload(regexp_replace(key, '^fm_(ref_date|rank)_', ''))))
  with check (public.fm_role() = 'admin' or ((key like 'fm\_ref\_date\_%' or key like 'fm\_rank\_%') and public.fm_can_upload(regexp_replace(key, '^fm_(ref_date|rank)_', ''))));
-- the rows of the school DB that concern the caller: a staff name (maintenance / light services supervisor, engineer,
-- contractor) is his or one of the people under him (reports_to line, deputies included), or the school is assigned
-- to him or his team for engagement. Managers and read-only titles get the whole file.
create or replace function public.fm_my_school_db() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; me uuid := auth.uid();
begin
  if me is null or public.fm_role() not in ('admin','manager','staff','viewer','engineer','supervisor','contractor') then return '[]'::jsonb; end if;
  select value into v from public.app_kv where key = 'fm_school_master_db_v1';
  if v is null then return '[]'::jsonb; end if;
  if jsonb_typeof(v) = 'string' then v := (v #>> '{}')::jsonb; end if;
  if jsonb_typeof(v) <> 'array' then return '[]'::jsonb; end if;
  if public.fm_role() in ('admin','manager','staff','viewer') then return v; end if;
  return coalesce((
    with nm as (
      select distinct lower(btrim(n)) n from public.profiles p, unnest(coalesce(p.person_names,'{}') || coalesce(p.full_name,'')) n
       where (p.id = me or public.fm_is_under(p.id, me)) and btrim(n) <> ''),
    sc as (
      select distinct a.school_code c from public.fm_eng_assignments a where a.active and (a.user_id = me or public.fm_is_under(a.user_id, me)))
    select jsonb_agg(r) from jsonb_array_elements(v) r
     where exists(select 1 from nm where nm.n in (lower(btrim(r->>'supervisor')), lower(btrim(r->>'engineer')), lower(btrim(r->>'lightSupervisor')),
                                                 lower(btrim(r->>'lightEngineer')), lower(btrim(r->>'contractor'))))
        or exists(select 1 from sc where sc.c = regexp_replace(regexp_replace(upper(coalesce(r->>'buildingId','')), '^S[[:space:]-]*', ''), '[^A-Z0-9]', '', 'g'))
  ), '[]'::jsonb);
end $$;
revoke all on function public.fm_my_school_db() from public, anon;
grant execute on function public.fm_my_school_db() to authenticated;

-- ---------- 18) full deputy during leave (V166, field F23) ----------
-- Who may set a deputy: the person himself, his managers up the reports_to line, the project / operations manager,
-- the area manager of his region and the system admin. The person (principal) is a supervisor or above; the deputy is
-- anyone above a supervisor (engineer, managers, HSE, QA; not read-only). While the leave runs:
--   * the principal's open work orders move to the deputy (status «assigned», he must accept) with a note
--     «محوَّل من … بتاريخ …»; new orders addressed to the principal go to the deputy the same way;
--   * the deputy sees the principal's tickets, schools and regions (fm_names / fm_regions), his team and engagement,
--     assigns and approves as him (V158), and may log contacts for the principal's schools;
--   * the principal's engagement targets are paused (fm_eng_scores, the engagement page).
-- When the leave ends, the transferred orders the deputy has not started go back to the principal (also with a note).
alter table public.fm_deputies add column if not exists set_by uuid references public.profiles(id);
alter table public.fm_deputies add column if not exists reason text;
alter table public.fm_deputies add column if not exists applied_at timestamptz;
alter table public.fm_deputies add column if not exists ended_at timestamptz;
alter table public.fm_deputies add column if not exists returned_at timestamptz;
alter table public.fm_deputies add column if not exists transferred int not null default 0;
alter table public.work_orders add column if not exists transfer_note text;
alter table public.work_orders add column if not exists transfer_from uuid references public.profiles(id) on delete set null;
alter table public.work_orders add column if not exists deputy_id uuid references public.fm_deputies(id) on delete set null;
-- the deputyship running now for one principal
create or replace function public.fm_deputy_now(p_user uuid) returns public.fm_deputies language sql stable security definer set search_path = public as $$
  select d.* from public.fm_deputies d where d.principal = p_user and d.active and now() >= d.from_at and now() < d.to_at
   order by d.from_at desc limit 1 $$;
revoke all on function public.fm_deputy_now(uuid) from public, anon, authenticated;
-- the names / regions of the caller, plus those of the people he stands in for now
create or replace function public.fm_names() returns text[] language sql stable security definer set search_path = public as $$
  select coalesce(p.person_names,'{}') || coalesce((select array_agg(distinct n) from public.fm_deputies d join public.profiles pr on pr.id = d.principal,
           unnest(coalesce(pr.person_names,'{}')) n where d.deputy = p.id and d.active and now() >= d.from_at and now() < d.to_at), '{}')
    from public.profiles p where p.id = auth.uid() $$;
create or replace function public.fm_regions() returns text[] language sql stable security definer set search_path = public as $$
  select case when cardinality(coalesce(p.regions,'{}')) = 0 then '{}'::text[]
              when exists(select 1 from public.fm_deputies d join public.profiles pr on pr.id = d.principal
                           where d.deputy = p.id and d.active and now() >= d.from_at and now() < d.to_at and cardinality(coalesce(pr.regions,'{}')) = 0) then '{}'::text[]
              else coalesce((select array_agg(distinct r) from (select unnest(p.regions) r union select unnest(pr.regions) from public.fm_deputies d
                     join public.profiles pr on pr.id = d.principal where d.deputy = p.id and d.active and now() >= d.from_at and now() < d.to_at) x), p.regions) end
    from public.profiles p where p.id = auth.uid() $$;
-- may the caller set / end a deputy for this principal?
create or replace function public.fm_deputy_may(p_principal uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles me, public.profiles pr where me.id = auth.uid() and me.active and pr.id = p_principal and pr.active
    and (public.fm_prank(public.fm_posx(pr.role, pr.job_title)) >= 3 or public.fm_posx(pr.role, pr.job_title) in ('hse_manager','qa_manager'))
    and (pr.id = me.id or me.role = 'admin' or public.fm_is_under_base(pr.id, me.id)
         or public.fm_posx(me.role, me.job_title) in ('project_manager','ops_manager')
         or (public.fm_posx(me.role, me.job_title) = 'area_manager' and (cardinality(coalesce(me.regions,'{}')) = 0 or coalesce(pr.regions,'{}') && me.regions
             or cardinality(coalesce(pr.regions,'{}')) = 0)))) $$;
revoke all on function public.fm_deputy_may(uuid) from public, anon;
grant execute on function public.fm_deputy_may(uuid) to authenticated;
-- move the open orders when a leave starts, and give back the unstarted ones when it ends
create or replace function public.fm_deputy_apply() returns int language plpgsql security definer set search_path = public as $$
declare d record; n int; tot int := 0; dn text; pn text;
begin
  for d in select * from public.fm_deputies where active and applied_at is null and now() >= from_at and now() < to_at for update skip locked loop
    select coalesce(full_name, email) into dn from public.profiles where id = d.deputy;
    select coalesce(full_name, email) into pn from public.profiles where id = d.principal;
    with t as (
      update public.work_orders w set assignee = d.deputy, assignee_name = dn, status = 'assigned', accepted_at = null, transfer_from = d.principal, deputy_id = d.id,
             transfer_note = '↪️ محوَّل من ' || pn || ' بتاريخ ' || to_char(now() at time zone 'Asia/Riyadh', 'YYYY-MM-DD') || ' (نيابة حتى ' || to_char(d.to_at at time zone 'Asia/Riyadh', 'YYYY-MM-DD') || ')',
             updated_at = now()
       where w.assignee = d.principal and w.status in ('assigned','accepted','in_progress','returned') returning w.id, w.transfer_note)
    insert into public.wo_events(wo_id, by_id, by_name, type, status, text) select t.id, d.set_by, 'النظام', 'deputy', 'assigned', t.transfer_note || ' — بانتظار قبول ' || dn from t;
    get diagnostics n = row_count;
    update public.fm_deputies set applied_at = now(), transferred = n where id = d.id;
    tot := tot + n;
  end loop;
  for d in select * from public.fm_deputies where applied_at is not null and returned_at is null and (not active or now() >= to_at) for update skip locked loop
    select coalesce(full_name, email) into pn from public.profiles where id = d.principal;
    with t as (
      update public.work_orders w set assignee = d.principal, assignee_name = pn, status = 'assigned', accepted_at = null,
             transfer_note = '↩️ أُعيد إلى ' || pn || ' بعد انتهاء النيابة بتاريخ ' || to_char(now() at time zone 'Asia/Riyadh', 'YYYY-MM-DD'), transfer_from = d.deputy, updated_at = now()
       where w.deputy_id = d.id and w.assignee = d.deputy and w.status in ('assigned','accepted') returning w.id, w.transfer_note)
    insert into public.wo_events(wo_id, by_id, by_name, type, status, text) select t.id, d.principal, 'النظام', 'deputy', 'assigned', t.transfer_note from t;
    update public.fm_deputies set returned_at = now(), ended_at = coalesce(ended_at, least(now(), to_at)) where id = d.id;
  end loop;
  return tot;
end $$;
revoke all on function public.fm_deputy_apply() from public, anon;
grant execute on function public.fm_deputy_apply() to authenticated;
-- a new order (or a reassignment) to someone on leave goes to his deputy, with the same note
create or replace function public.fm_wo_deputy_trg() returns trigger language plpgsql security definer set search_path = public as $$
declare d public.fm_deputies; dn text; pn text;
begin
  if new.assignee is null or (tg_op = 'UPDATE' and new.assignee is not distinct from old.assignee) then return new; end if;
  d := public.fm_deputy_now(new.assignee);
  if d.id is null or d.deputy = new.assignee then return new; end if;
  select coalesce(full_name, email) into dn from public.profiles where id = d.deputy;
  select coalesce(full_name, email) into pn from public.profiles where id = d.principal;
  new.assignee := d.deputy; new.assignee_name := dn; new.transfer_from := d.principal; new.deputy_id := d.id;
  new.transfer_note := '↪️ محوَّل من ' || pn || ' بتاريخ ' || to_char(now() at time zone 'Asia/Riyadh', 'YYYY-MM-DD') || ' (نيابة حتى ' || to_char(d.to_at at time zone 'Asia/Riyadh', 'YYYY-MM-DD') || ')';
  if tg_op = 'UPDATE' then new.status := 'assigned'; new.accepted_at := null; end if;
  return new;
end $$;
drop trigger if exists fm_wo_deputy on public.work_orders;
create trigger fm_wo_deputy before insert or update of assignee on public.work_orders for each row execute function public.fm_wo_deputy_trg();
-- set a deputy (returns the id and how many open orders moved now)
create or replace function public.fm_deputy_assign(p_principal uuid, p_deputy uuid, p_from timestamptz, p_to timestamptz, p_reason text default null, p_note text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare dp public.profiles; v uuid; n int := 0;
begin
  if not public.fm_deputy_may(p_principal) then raise exception 'not allowed' using errcode = '42501'; end if;
  select * into dp from public.profiles where id = p_deputy;
  if dp.id is null or not dp.active or dp.id = p_principal or dp.role in ('pending','contractor','supervisor','viewer')
     or not (public.fm_prank(public.fm_posx(dp.role, dp.job_title)) >= 4 or public.fm_posx(dp.role, dp.job_title) in ('hse_manager','qa_manager')) then
    raise exception 'invalid deputy'; end if;
  if p_to <= p_from or p_to > p_from + interval '120 days' or p_to <= now() then raise exception 'invalid period'; end if;
  update public.fm_deputies set active = false, ended_at = coalesce(ended_at, now()) where principal = p_principal and active and to_at > p_from;
  insert into public.fm_deputies (principal, deputy, from_at, to_at, note, set_by, reason)
  values (p_principal, p_deputy, p_from, p_to, nullif(trim(coalesce(p_note,'')),''), auth.uid(), nullif(trim(coalesce(p_reason,'')),'')) returning id into v;
  perform public.fm_deputy_apply();
  select transferred into n from public.fm_deputies where id = v;
  return jsonb_build_object('id', v, 'transferred', coalesce(n,0), 'started', p_from <= now());
end $$;
revoke all on function public.fm_deputy_assign(uuid,uuid,timestamptz,timestamptz,text,text) from public, anon;
grant execute on function public.fm_deputy_assign(uuid,uuid,timestamptz,timestamptz,text,text) to authenticated;
-- the V158 entry points keep working with the new rules
create or replace function public.fm_deputy_set(p_deputy uuid, p_from timestamptz, p_to timestamptz, p_note text default null, p_principal uuid default null) returns uuid
language plpgsql security definer set search_path = public as $$
begin return (public.fm_deputy_assign(coalesce(p_principal, auth.uid()), p_deputy, p_from, p_to, null, p_note)->>'id')::uuid; end $$;
create or replace function public.fm_deputy_end(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.fm_deputies set active = false, ended_at = now() where id = p_id and active
     and (principal = auth.uid() or deputy = auth.uid() or public.fm_deputy_may(principal));
  if not found then raise exception 'not allowed' using errcode = '42501'; end if;
  perform public.fm_deputy_apply();
end $$;
-- who can be a deputy (anyone above a supervisor), and for whom the caller may set one
create or replace function public.fm_deputy_candidates() returns table(id uuid, full_name text, job_title text, regions text[])
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.full_name, p.email), public.fm_posx(p.role, p.job_title), p.regions from public.profiles p
   where p.active and p.role not in ('pending','contractor','supervisor','viewer') and public.fm_role() <> 'pending'
     and (public.fm_prank(public.fm_posx(p.role, p.job_title)) >= 4 or public.fm_posx(p.role, p.job_title) in ('hse_manager','qa_manager'))
   order by public.fm_prank(public.fm_posx(p.role, p.job_title)) desc, p.full_name $$;
create or replace function public.fm_deputy_principals() returns table(id uuid, full_name text, job_title text, regions text[])
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.full_name, p.email), public.fm_posx(p.role, p.job_title), p.regions from public.profiles p
   where public.fm_deputy_may(p.id) order by (p.id = auth.uid()) desc, public.fm_prank(public.fm_posx(p.role, p.job_title)) desc, p.full_name $$;
-- leaves the caller may see (for the engagement page and the field app): who, when, and the deputy's name
create or replace function public.fm_leaves() returns table(id uuid, principal uuid, principal_name text, deputy uuid, deputy_name text, from_at timestamptz, to_at timestamptz, reason text, transferred int, running boolean)
language sql stable security definer set search_path = public as $$
  select d.id, d.principal, coalesce(pr.full_name, pr.email), d.deputy, coalesce(dp.full_name, dp.email), d.from_at, coalesce(d.ended_at, d.to_at), d.reason, d.transferred,
         d.active and now() >= d.from_at and now() < d.to_at
    from public.fm_deputies d join public.profiles pr on pr.id = d.principal join public.profiles dp on dp.id = d.deputy
   where public.fm_role() <> 'pending' and coalesce(d.ended_at, d.to_at) > now() - interval '120 days'
     and (d.principal = auth.uid() or d.deputy = auth.uid() or public.fm_scope_all() or public.fm_is_under_base(d.principal, auth.uid())
          or public.fm_is_under_base(auth.uid(), d.principal) or public.fm_deputy_may(d.principal))
   order by d.from_at desc $$;
revoke all on function public.fm_deputy_candidates() from public, anon;
revoke all on function public.fm_deputy_principals() from public, anon;
revoke all on function public.fm_leaves() from public, anon;
grant execute on function public.fm_deputy_candidates() to authenticated;
grant execute on function public.fm_deputy_principals() to authenticated;
grant execute on function public.fm_leaves() to authenticated;
-- the deputy may log contacts for the principal's schools during the leave
create or replace function public.fm_eng_submit(p jsonb) returns uuid language plpgsql security definer set search_path=public as $$
declare lid uuid; v_me uuid := auth.uid(); v_out text := p->>'outcome';
begin
  if not exists (select 1 from public.fm_eng_assignments a join public.profiles u on u.id=a.user_id
                 where a.id=(p->>'assignment_id')::uuid and a.active and u.active and u.role in ('supervisor','engineer')
                   and (a.user_id=v_me or (public.fm_deputy_now(a.user_id)).deputy = v_me)) then
    raise exception 'not allowed';
  end if;
  insert into public.fm_eng_logs(assignment_id,user_id,channel,outcome,confirmed,summary,evidence_path,geo)
  values((p->>'assignment_id')::uuid, v_me, p->>'channel', v_out, coalesce((p->>'confirmed')::boolean,false), p->>'summary', nullif(p->>'evidence_path',''),
         case when jsonb_typeof(p->'geo')='object' then p->'geo' end)
  returning id into lid;
  if v_out in ('observation','urgent') then
    insert into public.fm_eng_observations(log_id,owner_id,due_at)
    values(lid, v_me, now() + case when v_out='urgent' then interval '24 hours' else interval '48 hours' end);
  end if;
  return lid;
end $$;
-- coverage: cycles during a leave do not count against the principal
create or replace function public.fm_eng_scores() returns table(user_id uuid, full_name text, person_names text[], role text, cov numeric, cov_hit int, cov_total int, sat numeric, sat_n int)
language sql stable security definer set search_path=public as $$
  with ppl as (
    select p.id, coalesce(p.full_name, p.email) fname, coalesce(p.person_names, '{}') pn, p.role,
           coalesce((select t.cycle from public.fm_eng_targets t where t.role = p.role), case when p.role = 'engineer' then 'monthly' else 'weekly' end) cyc
      from public.profiles p
     where p.active and p.role in ('supervisor','engineer')
       and (public.fm_eng_admin() or p.id = auth.uid() or public.fm_scope_all()
            or exists(select 1 from public.fm_eng_assignments a where a.user_id = p.id and a.active and public.fm_eng_sees(a.user_id, a.region)))),
  blk as (
    select p.id uid, now() - case when p.cyc = 'weekly' then (b + 1) * interval '7 days' else interval '30 days' end f,
           now() - b * interval '7 days' t
      from ppl p cross join lateral generate_series(0, case when p.cyc = 'weekly' then 3 else 0 end) b),
  cv as (
    select b.uid, count(*)::int tot,
           count(*) filter (where exists(select 1 from public.fm_eng_logs l where l.assignment_id = a.id and l.outcome <> 'no_reply' and l.confirmed
                                         and l.at > b.f and l.at <= b.t))::int hit
      from blk b join public.fm_eng_assignments a on a.user_id = b.uid and a.active
     -- V166: cycles that overlap a leave (the person had a deputy) are not counted
     where not exists(select 1 from public.fm_deputies d where d.principal = b.uid and d.applied_at is not null
                        and d.from_at < b.t and coalesce(d.ended_at, d.to_at) > b.f)
     group by b.uid),
  st as (
    select x.uid, avg(x.v) av, count(*)::int n from (
      select r.supervisor_id uid, r.q_supervisor v from public.fm_eng_ratings r where r.q_supervisor is not null and r.created_at > now() - interval '90 days'
      union all
      select r.engineer_id, r.q_engineer from public.fm_eng_ratings r where r.q_engineer is not null and r.created_at > now() - interval '90 days') x
     group by x.uid)
  select p.id, p.fname, p.pn, p.role,
         case when coalesce(cv.tot,0) > 0 then round(cv.hit * 100.0 / cv.tot, 1) end, coalesce(cv.hit,0), coalesce(cv.tot,0),
         case when st.n > 0 then round(st.av * 20, 1) end, coalesce(st.n,0)
    from ppl p left join cv on cv.uid = p.id left join st on st.uid = p.id $$;
-- the apps call fm_touch when they open: it also starts / ends the leaves that are due (no pg_cron needed)
create or replace function public.fm_touch(p_app text) returns void language plpgsql security definer set search_path=public as $$
begin
  insert into public.fm_activity(user_id, day, app)
  select auth.uid(), (now() at time zone 'Asia/Riyadh')::date, p_app
   where auth.uid() is not null and p_app in ('platform','field') and exists(select 1 from public.profiles where id = auth.uid())
  on conflict (user_id, day, app) do update set last_at = now(), hits = public.fm_activity.hits + 1;
  if exists(select 1 from public.fm_deputies where (active and applied_at is null and now() >= from_at and now() < to_at)
                                            or (applied_at is not null and returned_at is null and (not active or now() >= to_at))) then
    perform public.fm_deputy_apply();
  end if;
end $$;

-- ---------- 19) news ticker (V167, field F24) ----------
-- Short news shown in a moving bar at the top of the platform and the field app. Publishers: the system admin, project /
-- operations / HSE / QA managers (everyone), the area manager (his regions) and the area engineer (his team). Each item
-- may target job titles and regions; «urgent» ones also open a window once on each device.
create table if not exists public.fm_news(id uuid primary key default gen_random_uuid(),
  text text not null check(length(btrim(text)) between 1 and 300), body text not null default '' check(length(body) <= 3000),
  priority text not null default 'normal' check(priority in ('normal','important','urgent')),
  titles text[] not null default '{}', regions text[] not null default '{}', scope text not null default 'all' check(scope in ('all','region','team')),
  author uuid not null references public.profiles(id) on delete cascade, author_name text,
  start_at timestamptz not null default now(), end_at timestamptz, pinned boolean not null default false, active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now());
create index if not exists fm_news_live on public.fm_news(active, start_at);
alter table public.fm_news enable row level security;
-- what the caller may publish: 'all', 'region' (area manager), 'team' (area engineer) or null
create or replace function public.fm_news_scope() returns text language sql stable security definer set search_path = public as $$
  select case when public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager','hse_manager','qa_manager') then 'all'
              when public.fm_my_pos() = 'area_manager' then 'region' when public.fm_my_pos() = 'area_engineer' then 'team' end $$;
-- is this item for the caller now?
create or replace function public.fm_news_for_me(n public.fm_news) returns boolean language sql stable security definer set search_path = public as $$
  select n.active and now() >= n.start_at and (n.end_at is null or now() < n.end_at) and public.fm_role() <> 'pending'
     and (n.author = auth.uid() or (
          (cardinality(n.titles) = 0 or coalesce(public.fm_my_pos() = any(n.titles), false))
      and (cardinality(n.regions) = 0 or cardinality(public.fm_regions()) = 0 or public.fm_regions() && n.regions)
      and (n.scope <> 'team' or public.fm_is_under(auth.uid(), n.author)))) $$;
drop policy if exists p_news_read on public.fm_news;
create policy p_news_read on public.fm_news for select using (author = auth.uid() or public.fm_role() = 'admin' or public.fm_news_for_me(fm_news));
revoke all on public.fm_news from anon, authenticated;
grant select on public.fm_news to authenticated;
-- the ticker: items for the caller now (pinned first, then urgent, important, newest)
create or replace function public.fm_news_feed() returns setof public.fm_news language sql stable security definer set search_path = public as $$
  select n.* from public.fm_news n where public.fm_news_for_me(n)
   order by n.pinned desc, case n.priority when 'urgent' then 0 when 'important' then 1 else 2 end, n.start_at desc limit 30 $$;
-- publish / edit (author or system admin); the audience is kept inside the publisher's scope
create or replace function public.fm_news_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare sc text := public.fm_news_scope(); me public.profiles; v uuid := nullif(p->>'id','')::uuid; r text[]; t text[];
begin
  select * into me from public.profiles where id = auth.uid();
  if sc is null or me.id is null or not me.active then raise exception 'not allowed' using errcode = '42501'; end if;
  if v is not null and not exists(select 1 from public.fm_news where id = v and (author = me.id or public.fm_role() = 'admin')) then raise exception 'not allowed' using errcode = '42501'; end if;
  t := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'titles','[]')) x), '{}');
  r := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'regions','[]')) x), '{}');
  if sc = 'region' and cardinality(coalesce(me.regions,'{}')) > 0 then
    r := case when cardinality(r) = 0 then me.regions else coalesce((select array_agg(x) from unnest(r) x where x = any(me.regions)), '{}') end;
    if cardinality(r) = 0 then raise exception 'invalid region'; end if;
  end if;
  if v is null then
    insert into public.fm_news(text, body, priority, titles, regions, scope, author, author_name, start_at, end_at, pinned)
    values (btrim(p->>'text'), coalesce(p->>'body',''), coalesce(nullif(p->>'priority',''),'normal'), t, r, sc, me.id, coalesce(me.full_name, me.email),
            coalesce(nullif(p->>'start_at','')::timestamptz, now()), nullif(p->>'end_at','')::timestamptz, coalesce((p->>'pinned')::boolean, false))
    returning id into v;
  else
    update public.fm_news set text = btrim(p->>'text'), body = coalesce(p->>'body',''), priority = coalesce(nullif(p->>'priority',''),'normal'), titles = t, regions = r,
           start_at = coalesce(nullif(p->>'start_at','')::timestamptz, start_at), end_at = nullif(p->>'end_at','')::timestamptz,
           pinned = coalesce((p->>'pinned')::boolean, false), active = true, updated_at = now() where id = v;
  end if;
  return v;
end $$;
create or replace function public.fm_news_end(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
begin
  update public.fm_news set active = false, updated_at = now() where id = p_id and (author = auth.uid() or public.fm_role() = 'admin');
  if not found then raise exception 'not allowed' using errcode = '42501'; end if;
end $$;
revoke all on function public.fm_news_scope(), public.fm_news_for_me(public.fm_news), public.fm_news_feed(), public.fm_news_save(jsonb), public.fm_news_end(uuid) from public, anon;
grant execute on function public.fm_news_scope(), public.fm_news_for_me(public.fm_news), public.fm_news_feed(), public.fm_news_save(jsonb), public.fm_news_end(uuid) to authenticated;

-- ---------- 20) building costs: expenses, budgets and cost permissions (V171) ----------
-- Each building («ملف المدرسة») shows what was spent on it in a period: the materials of its finished work orders
-- (done / closed; q × the unit price kept on the item, store or purchase) and the expenses entered by hand:
-- an invoice, or a known monthly cost (a monthly expense counts once per calendar month it runs in the period).
-- One expense may cover one building, a group of buildings or a whole region; its amount is split equally between
-- them or charged in full to each. A yearly budget per building (fm_budgets) is compared with the year's spending.
-- Who may see costs, enter expenses and set budgets is set per job title by the system admin (fm_settings.cost_perms);
-- the system admin always may. Scope: managers who see everything → all buildings; area manager and accountant →
-- their regions; anyone else (area engineer) → his schools (fm_my_school_db). Tables are read and written only
-- through the functions below.
insert into public.fm_settings(key, value) values ('cost_perms',
  '{"view":["dept_manager","project_manager","ops_manager","area_manager","area_engineer","accountant"],"entry":["project_manager","area_manager","area_engineer","accountant"],"budget":["dept_manager","project_manager"]}')
on conflict (key) do nothing;
-- the building key: the ministry / building number (S prefix and separators dropped), else the school name
create or replace function public.fm_bkey(p_id text, p_name text) returns text language sql immutable as $$
  select case when regexp_replace(regexp_replace(upper(coalesce(p_id,'')), '^S[[:space:]-]*', ''), '[^A-Z0-9]', '', 'g') <> ''
    then regexp_replace(regexp_replace(upper(coalesce(p_id,'')), '^S[[:space:]-]*', ''), '[^A-Z0-9]', '', 'g')
    else 'N:' || lower(regexp_replace(coalesce(p_name,''), '[[:space:]]+', '', 'g')) end $$;
-- may the caller view / enter / budget? (view also follows from entry or budget)
create or replace function public.fm_cost_can(p_what text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin'
    or public.fm_my_pos() in (select jsonb_array_elements_text(case when p_what = 'view'
         then coalesce(s.value->'view','[]') || coalesce(s.value->'entry','[]') || coalesce(s.value->'budget','[]')
         else coalesce(s.value->p_what,'[]') end)
       from public.fm_settings s where s.key = 'cost_perms'), false) $$;
create or replace function public.fm_cost_scope() returns text language sql stable security definer set search_path = public as $$
  select case when not public.fm_cost_can('view') then null
    when public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager','hse_manager','qa_manager') then 'all'
    when public.fm_my_pos() in ('area_manager','accountant') then 'region'
    else 'mine' end $$;
-- the buildings the caller may see costs of (from the school DB)
create or replace function public.fm_cost_schools() returns table(bkey text, name text, region text)
language plpgsql stable security definer set search_path = public as $$
declare sc text := public.fm_cost_scope(); v jsonb;
begin
  if sc is null then return; end if;
  if sc = 'mine' then v := public.fm_my_school_db();
  else select value into v from public.app_kv where key = 'fm_school_master_db_v1';
       if jsonb_typeof(v) = 'string' then v := (v #>> '{}')::jsonb; end if; end if;
  if v is null or jsonb_typeof(v) <> 'array' then return; end if;
  return query select distinct on (x.k) x.k, x.n, x.r from (
      select public.fm_bkey(e->>'buildingId', e->>'school') k, nullif(btrim(coalesce(e->>'school','')),'') n, nullif(btrim(coalesce(e->>'region','')),'') r
        from jsonb_array_elements(v) e
       where jsonb_typeof(e) = 'object' and (btrim(coalesce(e->>'school','')) <> '' or btrim(coalesce(e->>'buildingId','')) <> '')) x
    where sc <> 'region' or public.fm_region_ok(coalesce(x.r,''))
    order by x.k, x.n nulls last;
end $$;

create table if not exists public.fm_expenses (
  id              uuid primary key default gen_random_uuid(),
  title           text not null,
  category        text not null default 'أخرى',
  vendor          text,
  invoice_no      text,
  amount          numeric(14,2) not null check (amount > 0),
  kind            text not null default 'once' check (kind in ('once','monthly')),
  start_on        date not null,
  end_on          date,
  split           text not null default 'equal' check (split in ('equal','each')),
  scope           text not null default 'school' check (scope in ('school','group','region')),
  region          text,
  schools         text[] not null default '{}',
  school_names    text[] not null default '{}',
  note            text,
  active          boolean not null default true,
  created_by      uuid default auth.uid() references public.profiles(id) on delete set null,
  created_by_name text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  cancelled_by    uuid references public.profiles(id) on delete set null,
  cancel_reason   text
);
create index if not exists fm_expenses_dates_idx on public.fm_expenses (start_on, end_on) where active;
create index if not exists fm_expenses_schools_idx on public.fm_expenses using gin (schools);
alter table public.fm_expenses enable row level security;
create table if not exists public.fm_budgets (
  bkey       text not null,
  year       int  not null check (year between 2000 and 2100),
  amount     numeric(14,2) not null check (amount > 0),
  name       text,
  region     text,
  updated_by uuid default auth.uid() references public.profiles(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (bkey, year)
);
alter table public.fm_budgets enable row level security;
revoke all on public.fm_expenses, public.fm_budgets from anon;

-- what the caller may do and the buildings he may see
create or replace function public.fm_cost_me() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('scope', public.fm_cost_scope(), 'view', public.fm_cost_can('view'), 'entry', public.fm_cost_can('entry'),
    'budget', public.fm_cost_can('budget'), 'edit_all', public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager'),
    'schools', coalesce((select jsonb_agg(jsonb_build_object('k', s.bkey, 'n', s.name, 'r', s.region)) from public.fm_cost_schools() s), '[]'::jsonb)) $$;

-- add or change an expense. p: {id?, title, category, vendor, invoice_no, amount, kind, start_on, end_on, split, scope,
-- region (scope region), schools: [keys] (scope school / group), note}
create or replace function public.fm_expense_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); v_id uuid := nullif(p->>'id','')::uuid; e public.fm_expenses; sc text := public.fm_cost_scope();
  v_keys text[]; v_names text[]; v_scope text := coalesce(nullif(p->>'scope',''),'school'); v_kind text := coalesce(nullif(p->>'kind',''),'once');
  v_amt numeric := nullif(p->>'amount','')::numeric; v_start date := nullif(p->>'start_on','')::date; v_end date := nullif(p->>'end_on','')::date;
  v_region text := nullif(btrim(coalesce(p->>'region','')),'');
begin
  if me is null or not public.fm_cost_can('entry') then raise exception 'not allowed'; end if;
  if btrim(coalesce(p->>'title','')) = '' then raise exception 'title required'; end if;
  if v_amt is null or v_amt <= 0 or v_amt > 100000000 then raise exception 'invalid amount'; end if;
  if v_kind not in ('once','monthly') or v_scope not in ('school','group','region') or coalesce(p->>'split','equal') not in ('equal','each') then raise exception 'invalid kind'; end if;
  if v_start is null then raise exception 'date required'; end if;
  if v_kind = 'once' then v_end := null; elsif v_end is not null and v_end < v_start then raise exception 'end before start'; end if;
  if v_scope = 'region' then
    if v_region is null or sc not in ('all','region') or not (sc = 'all' or public.fm_region_ok(v_region)) then raise exception 'region not allowed'; end if;
    select array_agg(s.bkey order by s.name), array_agg(coalesce(s.name, s.bkey) order by s.name) into v_keys, v_names from public.fm_cost_schools() s where s.region = v_region;
  else
    select array_agg(s.bkey order by s.name), array_agg(coalesce(s.name, s.bkey) order by s.name) into v_keys, v_names
      from public.fm_cost_schools() s where s.bkey in (select distinct jsonb_array_elements_text(coalesce(p->'schools','[]')));
    if coalesce(cardinality(v_keys),0) <> (select count(distinct x) from jsonb_array_elements_text(coalesce(p->'schools','[]')) x) then raise exception 'building not allowed'; end if;
    v_region := null;
  end if;
  if coalesce(cardinality(v_keys),0) = 0 then raise exception 'no buildings'; end if;
  if cardinality(v_keys) > 5000 then raise exception 'too many buildings'; end if;
  if v_scope = 'school' and cardinality(v_keys) > 1 then v_scope := 'group'; end if;
  if v_id is null then
    insert into public.fm_expenses(title, category, vendor, invoice_no, amount, kind, start_on, end_on, split, scope, region, schools, school_names, note, created_by, created_by_name)
    values (left(btrim(p->>'title'),200), left(coalesce(nullif(btrim(p->>'category'),''),'أخرى'),60), left(nullif(btrim(p->>'vendor'),''),200),
            left(nullif(btrim(p->>'invoice_no'),''),80), v_amt, v_kind, v_start, v_end, coalesce(p->>'split','equal'), v_scope, v_region, v_keys, v_names,
            left(nullif(btrim(p->>'note'),''),1000), me, (select full_name from public.profiles where id = me))
    returning id into v_id;
  else
    select * into e from public.fm_expenses where id = v_id for update;
    if not found or not e.active then raise exception 'not found'; end if;
    if e.created_by is distinct from me and not (public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager')) then raise exception 'not allowed'; end if;
    update public.fm_expenses set title = left(btrim(p->>'title'),200), category = left(coalesce(nullif(btrim(p->>'category'),''),'أخرى'),60),
      vendor = left(nullif(btrim(p->>'vendor'),''),200), invoice_no = left(nullif(btrim(p->>'invoice_no'),''),80), amount = v_amt, kind = v_kind,
      start_on = v_start, end_on = v_end, split = coalesce(p->>'split','equal'), scope = v_scope, region = v_region, schools = v_keys,
      school_names = v_names, note = left(nullif(btrim(p->>'note'),''),1000), updated_at = now() where id = v_id;
  end if;
  return v_id;
end $$;
create or replace function public.fm_expense_cancel(p_id uuid, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare e public.fm_expenses; me uuid := auth.uid();
begin
  if me is null or not public.fm_cost_can('entry') then raise exception 'not allowed'; end if;
  select * into e from public.fm_expenses where id = p_id for update;
  if not found or not e.active then raise exception 'not found'; end if;
  if e.created_by is distinct from me and not (public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager')) then raise exception 'not allowed'; end if;
  update public.fm_expenses set active = false, cancelled_by = me, cancel_reason = left(nullif(btrim(coalesce(p_reason,'')),''),300), updated_at = now() where id = p_id;
end $$;

-- set the yearly budgets: p_rows [{k, amount}] (amount empty or 0 removes it)
create or replace function public.fm_budget_set(p_year int, p_rows jsonb) returns int language plpgsql security definer set search_path = public as $$
declare n int := 0; x jsonb; s record; v numeric;
begin
  if auth.uid() is null or not public.fm_cost_can('budget') then raise exception 'not allowed'; end if;
  if p_year is null or p_year < 2000 or p_year > 2100 then raise exception 'invalid year'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_rows,'[]')) loop
    select * into s from public.fm_cost_schools() c where c.bkey = x->>'k';
    if not found then raise exception 'building not allowed: %', x->>'k'; end if;
    v := nullif(x->>'amount','')::numeric;
    if v is null or v <= 0 then delete from public.fm_budgets where bkey = s.bkey and year = p_year;
    elsif v > 100000000 then raise exception 'invalid amount';
    else insert into public.fm_budgets(bkey, year, amount, name, region) values (s.bkey, p_year, v, s.name, s.region)
         on conflict (bkey, year) do update set amount = excluded.amount, name = excluded.name, region = excluded.region, updated_by = auth.uid(), updated_at = now();
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;

-- the finished orders (done / closed) in a period with their building key (internal, used by fm_bld_costs)
create or replace function public.fm_cost_orders(ks text[], ns text[], wide boolean, p_from date, p_to date)
returns table(id uuid, code text, title text, type text, status text, school text, k text, at timestamptz, checklist jsonb)
language sql stable security definer set search_path = public as $$
  with s as (select * from unnest(ks, ns) as t(bkey, name))
  select w.id, w.code, w.title, w.type, w.status, w.school,
         coalesce(sb.bkey, sn.bkey, case when wide then public.fm_bkey(w.building_id, w.school) end),
         coalesce(w.done_at, w.closed_at, w.updated_at), case when jsonb_typeof(w.checklist) = 'array' then w.checklist else '[]' end
    from public.work_orders w
    left join s sb on not public.fm_bkey(w.building_id, null) like 'N:%' and sb.bkey = public.fm_bkey(w.building_id, null)
    left join lateral (select s2.bkey from s s2 where sb.bkey is null and s2.name = btrim(w.school) limit 1) sn on true
   where w.status in ('done','closed') and coalesce(w.done_at, w.closed_at, w.updated_at)::date between p_from and p_to
     and (sb.bkey is not null or sn.bkey is not null or wide) $$;
revoke all on function public.fm_cost_orders(text[], text[], boolean, date, date) from public, anon, authenticated;
-- the costs of the caller's buildings between two dates (one building with p_key):
-- {materials: [...], repairs: [...], expenses: [...], budgets: [...]}; the platform sums them per period
create or replace function public.fm_bld_costs(p_from date, p_to date, p_key text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare sc text := public.fm_cost_scope(); me uuid := auth.uid(); v_mat jsonb; v_rep jsonb; v_exp jsonb; v_bud jsonb; ks text[]; ns text[]; rs text[];
  ed boolean := public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager');
  wide boolean := sc = 'all' and p_key is null;
begin
  if me is null or sc is null then raise exception 'not allowed'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 3700 then raise exception 'invalid period'; end if;
  select coalesce(array_agg(c.bkey),'{}'), coalesce(array_agg(c.name),'{}'), coalesce(array_agg(c.region),'{}') into ks, ns, rs
    from public.fm_cost_schools() c where p_key is null or c.bkey = p_key;
  -- the materials of the finished orders (fm_cost_orders: building by building_id, else the school name; whoever sees
  -- all buildings also gets the orders that match no building, keyed by their own number / name)
  select coalesce(jsonb_agg(m order by m->>'at'), '[]'::jsonb) into v_mat from (
    select jsonb_build_object('wo', w.id, 'code', w.code, 'title', w.title, 'type', w.type, 'status', w.status, 'school', w.school, 'k', w.k,
        'at', w.at, 'item', it.e->>'t', 'g', it.e->>'g', 'n', mt.m->>'n', 'mid', mt.m->>'id',
        'q', coalesce(nullif(mt.m->>'q','')::numeric, 0), 'u', mt.m->>'u', 'src', coalesce(mt.m->>'src','store'),
        'price', nullif(mt.m->>'price','')::numeric) m
      from public.fm_cost_orders(ks, ns, wide, p_from, p_to) w
      cross join lateral jsonb_array_elements(w.checklist) it(e)
      cross join lateral jsonb_array_elements(case when jsonb_typeof(it.e->'materials') = 'array' then it.e->'materials' else '[]' end) mt(m)
     where jsonb_typeof(mt.m) = 'object') z;
  -- the repairs: items marked «fixed» in any order, the done items of repair orders (a repair order without items counts
  -- once by its title); cost = the item's materials (q × price)
  select coalesce(jsonb_agg(r order by r->>'at'), '[]'::jsonb) into v_rep from (
    select jsonb_build_object('wo', w.id, 'code', w.code, 'title', w.title, 'type', w.type, 'status', w.status, 'school', w.school, 'k', w.k, 'at', w.at,
        't', it.e->>'t', 'g', it.e->>'g', 'res', it.e->>'res', 'note', it.e->>'note', 'opt', it.e->>'opt',
        'cost', (select coalesce(sum(coalesce(nullif(m->>'q','')::numeric, 0) * coalesce(nullif(m->>'price','')::numeric, 0)), 0)
                   from jsonb_array_elements(case when jsonb_typeof(it.e->'materials') = 'array' then it.e->'materials' else '[]' end) m
                  where jsonb_typeof(m) = 'object')) r
      from public.fm_cost_orders(ks, ns, wide, p_from, p_to) w cross join lateral jsonb_array_elements(w.checklist) it(e)
     where jsonb_typeof(it.e) = 'object' and (it.e->>'res' = 'fixed'
        or (w.type = 'repair' and coalesce(it.e->>'res','') not in ('na','fix') and (it.e->>'res' is not null or coalesce(it.e->>'done','') = 'true')))
    union all
    select jsonb_build_object('wo', w.id, 'code', w.code, 'title', w.title, 'type', w.type, 'status', w.status, 'school', w.school, 'k', w.k, 'at', w.at,
        't', w.title, 'g', null, 'res', null, 'note', null, 'opt', null, 'cost', 0)
      from public.fm_cost_orders(ks, ns, wide, p_from, p_to) w where w.type = 'repair' and jsonb_array_length(w.checklist) = 0) z;
  -- expenses that run in the period (only the caller's buildings are listed; n = all buildings it covers)
  select coalesce(jsonb_agg(jsonb_build_object('id', e.id, 'title', e.title, 'category', e.category, 'vendor', e.vendor, 'invoice_no', e.invoice_no,
      'amount', e.amount, 'kind', e.kind, 'start_on', e.start_on, 'end_on', e.end_on, 'split', e.split, 'scope', e.scope, 'region', e.region,
      'n', cardinality(e.schools), 'note', e.note, 'by', e.created_by_name, 'created_at', e.created_at, 'mine', e.created_by = me,
      'can_edit', public.fm_cost_can('entry') and (e.created_by = me or ed),
      'schools', (select jsonb_agg(jsonb_build_object('k', x, 'n', e.school_names[i])) from unnest(e.schools) with ordinality u(x, i) where x = any(ks)))
      order by e.start_on desc), '[]'::jsonb) into v_exp
    from public.fm_expenses e
   where e.active and e.start_on <= p_to and (case when e.kind = 'once' then e.start_on >= p_from else coalesce(e.end_on, p_to) >= p_from end)
     and e.schools && ks;
  select coalesce(jsonb_agg(jsonb_build_object('k', b.bkey, 'year', b.year, 'amount', b.amount)), '[]'::jsonb) into v_bud
    from public.fm_budgets b where b.bkey = any(ks) and b.year between extract(year from p_from)::int and extract(year from p_to)::int;
  return jsonb_build_object('scope', sc, 'materials', v_mat, 'repairs', v_rep, 'expenses', v_exp, 'budgets', v_bud);
end $$;
revoke all on function public.fm_cost_can(text), public.fm_cost_scope(), public.fm_cost_schools(), public.fm_cost_me(), public.fm_expense_save(jsonb),
  public.fm_expense_cancel(uuid, text), public.fm_budget_set(int, jsonb), public.fm_bld_costs(date, date, text) from public, anon;
grant execute on function public.fm_cost_can(text), public.fm_cost_scope(), public.fm_cost_schools(), public.fm_cost_me(), public.fm_expense_save(jsonb),
  public.fm_expense_cancel(uuid, text), public.fm_budget_set(int, jsonb), public.fm_bld_costs(date, date, text) to authenticated;

-- ---------- 21) spare-parts inventory (V173, field F26) ----------
-- Stores (مستودعات) per region hold a balance of each warehouse material (wo_materials). Every change is a move:
-- in (receipt from a supplier), adjust (stock count), transfer (between stores) and out (an approved work order).
-- When a work order is closed (approved), its store materials (src store with a material id) are taken out of the
-- region's default store once (fm_wo_stock_out); a balance may go below zero, it is shown as a shortage.
-- Managers of the stock: system admin, project / operations managers (all stores), area manager and area engineer
-- (stores of their regions). Everyone signed in reads the stores and balances (the field app shows what is available);
-- the moves are read by the managers and the support titles. Writes only through the functions below.
create table if not exists public.wo_stores (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  region     text,
  is_default boolean not null default false,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create table if not exists public.wo_stock (
  store_id    uuid not null references public.wo_stores(id) on delete cascade,
  material_id uuid not null references public.wo_materials(id) on delete cascade,
  qty         numeric(14,3) not null default 0,
  min_qty     numeric(14,3) not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (store_id, material_id)
);
create table if not exists public.wo_stock_moves (
  id          uuid primary key default gen_random_uuid(),
  at          timestamptz not null default now(),
  store_id    uuid not null references public.wo_stores(id) on delete cascade,
  material_id uuid not null references public.wo_materials(id) on delete cascade,
  qty         numeric(14,3) not null,               -- + in, - out
  kind        text not null check (kind in ('in','out','adjust','transfer')),
  unit_price  numeric(12,2),
  wo_id       uuid references public.work_orders(id) on delete set null,
  wo_code     text,
  school      text,
  item        text,
  supplier    text,
  invoice_no  text,
  note        text,
  by_id       uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name     text
);
create index if not exists wo_stock_moves_at_idx on public.wo_stock_moves (store_id, at desc);
create index if not exists wo_stock_moves_wo_idx on public.wo_stock_moves (wo_id);
create index if not exists wo_stock_moves_mat_idx on public.wo_stock_moves (material_id, at desc);
alter table public.wo_stores enable row level security;
alter table public.wo_stock enable row level security;
alter table public.wo_stock_moves enable row level security;
-- may the caller manage this store (region)?
create or replace function public.fm_stock_can(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager')
    or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_region_ok(coalesce(p_region,''))), false) $$;
drop policy if exists p_store_read on public.wo_stores;
create policy p_store_read on public.wo_stores for select using (public.fm_role() in ('admin','manager','staff','engineer','supervisor','contractor','viewer'));
drop policy if exists p_stock_read on public.wo_stock;
create policy p_stock_read on public.wo_stock for select using (public.fm_role() in ('admin','manager','staff','engineer','supervisor','contractor','viewer'));
drop policy if exists p_move_read on public.wo_stock_moves;
create policy p_move_read on public.wo_stock_moves for select using (public.fm_role() in ('admin','manager','staff','engineer','viewer'));
revoke insert, update, delete on public.wo_stores, public.wo_stock, public.wo_stock_moves from anon, authenticated;

-- the default store of a region: the one marked default, else the oldest active store of the region, else a store without a region
create or replace function public.fm_stock_store_for(p_region text) returns uuid language sql stable security definer set search_path = public as $$
  select id from public.wo_stores where active and (coalesce(region,'') = coalesce(p_region,'') or coalesce(region,'') = '')
   order by (coalesce(region,'') = coalesce(p_region,'')) desc, is_default desc, created_at limit 1 $$;
revoke all on function public.fm_stock_store_for(text) from public, anon, authenticated;

-- add or change a store: p {id?, name, region, is_default, active}
create or replace function public.fm_stock_store_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id','')::uuid; v_reg text := nullif(btrim(coalesce(p->>'region','')),''); s public.wo_stores;
begin
  if auth.uid() is null or not public.fm_stock_can(v_reg) then raise exception 'not allowed'; end if;
  if btrim(coalesce(p->>'name','')) = '' then raise exception 'name required'; end if;
  if v_id is null then
    insert into public.wo_stores(name, region, is_default, active) values (left(btrim(p->>'name'),120), v_reg, coalesce((p->>'is_default')::boolean,false), coalesce((p->>'active')::boolean,true)) returning id into v_id;
  else
    select * into s from public.wo_stores where id = v_id;
    if not found or not public.fm_stock_can(s.region) then raise exception 'not allowed'; end if;
    update public.wo_stores set name = left(btrim(p->>'name'),120), region = v_reg, is_default = coalesce((p->>'is_default')::boolean,false),
      active = coalesce((p->>'active')::boolean,true) where id = v_id;
  end if;
  if coalesce((p->>'is_default')::boolean,false) then update public.wo_stores set is_default = false where id <> v_id and coalesce(region,'') = coalesce(v_reg,''); end if;
  return v_id;
end $$;

-- one stock change: p {kind: in | adjust | transfer, store_id, to_store (transfer), supplier, invoice_no, note, update_price,
--   lines: [{material_id, qty (in / transfer), count (adjust = the counted balance), price (in)}]}; returns the number of moves
create or replace function public.fm_stock_move(p jsonb) returns int language plpgsql security definer set search_path = public as $$
declare k text := p->>'kind'; st public.wo_stores; st2 public.wo_stores; x jsonb; q numeric; cur numeric; n int := 0; m uuid; pr numeric;
  me uuid := auth.uid(); nm text := (select coalesce(full_name, email) from public.profiles where id = auth.uid());
begin
  if me is null or k not in ('in','adjust','transfer') then raise exception 'invalid kind'; end if;
  select * into st from public.wo_stores where id = nullif(p->>'store_id','')::uuid and active;
  if not found or not public.fm_stock_can(st.region) then raise exception 'not allowed'; end if;
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
    else q := nullif(x->>'qty','')::numeric; if q is null or q <= 0 or q > 1000000 then raise exception 'invalid qty'; end if; end if;
    if q = 0 then continue; end if;
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
  return n;
end $$;
-- the minimum (reorder level) of materials in a store: p_rows [{material_id, min}]
create or replace function public.fm_stock_min(p_store uuid, p_rows jsonb) returns int language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; x jsonb; n int := 0;
begin
  select * into st from public.wo_stores where id = p_store;
  if auth.uid() is null or not found or not public.fm_stock_can(st.region) then raise exception 'not allowed'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_rows,'[]')) loop
    if coalesce(nullif(x->>'min','')::numeric,0) < 0 then raise exception 'invalid min'; end if;
    insert into public.wo_stock(store_id, material_id, min_qty) values (st.id, (x->>'material_id')::uuid, coalesce(nullif(x->>'min','')::numeric,0))
      on conflict (store_id, material_id) do update set min_qty = excluded.min_qty, updated_at = now();
    n := n + 1;
  end loop;
  return n;
end $$;
-- an approved work order takes its store materials out of the region's default store (once per order)
create or replace function public.fm_wo_stock_out() returns trigger language plpgsql security definer set search_path = public as $$
declare st uuid; x record;
begin
  if new.status <> 'closed' or old.status = 'closed' then return new; end if;
  if exists(select 1 from public.wo_stock_moves where wo_id = new.id and kind = 'out') then return new; end if;
  st := public.fm_stock_store_for(new.region);
  if st is null then return new; end if;
  for x in
    select (mt.m->>'id')::uuid mid, sum(coalesce(nullif(mt.m->>'q','')::numeric,0)) q, max(nullif(mt.m->>'price','')::numeric) pr, string_agg(distinct it.e->>'t', ' • ') items
      from jsonb_array_elements(case when jsonb_typeof(new.checklist) = 'array' then new.checklist else '[]' end) it(e)
      cross join lateral jsonb_array_elements(case when jsonb_typeof(it.e->'materials') = 'array' then it.e->'materials' else '[]' end) mt(m)
     where jsonb_typeof(mt.m) = 'object' and coalesce(mt.m->>'src','store') = 'store'
       and coalesce(mt.m->>'id','') ~ '^[0-9a-fA-F-]{36}$' and exists(select 1 from public.wo_materials w where w.id = (mt.m->>'id')::uuid)
     group by 1 having sum(coalesce(nullif(mt.m->>'q','')::numeric,0)) > 0
  loop
    insert into public.wo_stock(store_id, material_id, qty) values (st, x.mid, -x.q)
      on conflict (store_id, material_id) do update set qty = public.wo_stock.qty - x.q, updated_at = now();
    insert into public.wo_stock_moves(store_id, material_id, qty, kind, unit_price, wo_id, wo_code, school, item, by_id, by_name)
    values (st, x.mid, -x.q, 'out', x.pr, new.id, new.code, new.school, left(x.items,300), auth.uid(), (select coalesce(full_name, email) from public.profiles where id = auth.uid()));
  end loop;
  return new;
end $$;
drop trigger if exists fm_wo_stock_out on public.work_orders;
create trigger fm_wo_stock_out after update of status on public.work_orders for each row execute function public.fm_wo_stock_out();
revoke all on function public.fm_stock_can(text), public.fm_stock_store_save(jsonb), public.fm_stock_move(jsonb), public.fm_stock_min(uuid, jsonb) from public, anon;
grant execute on function public.fm_stock_can(text), public.fm_stock_store_save(jsonb), public.fm_stock_move(jsonb), public.fm_stock_min(uuid, jsonb) to authenticated;
revoke all on function public.fm_wo_stock_out() from public, anon, authenticated;

-- ---------- 22) school principal portal (V175, school S1) ----------
-- Every school can get a permanent private link school.html?k=<64 hex> (no account). Its principal sees the school's
-- open tickets and open work orders (no staff contact data), raises requests (category, description, urgency, up to 3
-- small photos) and follows / rates them. Staff see the requests of their schools in «🏫 طلبات المدارس», accept,
-- reject, link a work order (closing that order marks the request done) or close it with a reply.
-- The schools of the caller: whole DB for the system admin and the titles that see everything, his regions for the area
-- manager, else his own rows (fm_my_school_db).
create or replace function public.fm_my_schools() returns table(bkey text, name text, region text, principal text, principal_phone text)
language plpgsql stable security definer set search_path = public as $$
declare v jsonb; sc text;
begin
  if auth.uid() is null or public.fm_role() not in ('admin','manager','staff','viewer','engineer','supervisor','contractor') then return; end if;
  sc := case when public.fm_role() = 'admin' or public.fm_scope_all() then 'all' when public.fm_my_pos() = 'area_manager' then 'region' else 'mine' end;
  if sc = 'mine' then v := public.fm_my_school_db();
  else select value into v from public.app_kv where key = 'fm_school_master_db_v1'; if jsonb_typeof(v) = 'string' then v := (v #>> '{}')::jsonb; end if; end if;
  if v is null or jsonb_typeof(v) <> 'array' then return; end if;
  return query select distinct on (x.k) x.k, x.n, x.r, x.p, x.ph from (
      select public.fm_bkey(e->>'buildingId', e->>'school') k, nullif(btrim(coalesce(e->>'school','')),'') n, nullif(btrim(coalesce(e->>'region','')),'') r,
             nullif(btrim(coalesce(e->>'principal','')),'') p, nullif(btrim(coalesce(e->>'principalPhone','')),'') ph
        from jsonb_array_elements(v) e where jsonb_typeof(e) = 'object' and btrim(coalesce(e->>'school','')) <> '') x
   where sc <> 'region' or public.fm_region_ok(coalesce(x.r,''))
   order by x.k, x.n;
end $$;

create table if not exists public.fm_school_links (
  token        text primary key check (token ~ '^[0-9a-f]{64}$'),
  bkey         text not null,
  school_name  text not null,
  region       text,
  active       boolean not null default true,
  created_by   uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);
create unique index if not exists fm_school_links_one on public.fm_school_links (bkey) where active;
create sequence if not exists public.fm_school_req_seq;
create table if not exists public.fm_school_requests (
  id              uuid primary key default gen_random_uuid(),
  code            text unique,
  token           text references public.fm_school_links(token) on delete set null,
  bkey            text not null,
  school_name     text not null,
  region          text,
  category        text not null,
  description     text not null,
  urgency         text not null default 'normal' check (urgency in ('normal','urgent')),
  contact_name    text,
  contact_phone   text,
  photos          jsonb not null default '[]',
  status          text not null default 'new' check (status in ('new','accepted','in_progress','done','rejected')),
  response        text,
  wo_id           uuid references public.work_orders(id) on delete set null,
  wo_code         text,
  handled_by      uuid references public.profiles(id) on delete set null,
  handled_by_name text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  rating          int check (rating between 1 and 5),
  rating_comment  text,
  rated_at        timestamptz
);
create index if not exists fm_school_requests_bkey_idx on public.fm_school_requests (bkey, created_at desc);
alter table public.fm_school_links enable row level security;
alter table public.fm_school_requests enable row level security;
revoke all on public.fm_school_links, public.fm_school_requests from anon, authenticated;

-- public (anon): what the portal shows for a link
create or replace function public.fm_school_portal(p_token text) returns jsonb language plpgsql security definer set search_path = public as $$
declare k public.fm_school_links;
begin
  select * into k from public.fm_school_links where token = p_token and length(p_token) = 64 and active;
  if not found then return jsonb_build_object('state','invalid'); end if;
  update public.fm_school_links set last_used_at = now() where token = p_token and (last_used_at is null or last_used_at < now() - interval '10 minutes');
  return jsonb_build_object('state','ok','school', k.school_name, 'region', k.region,
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'code', r.code, 'category', r.category, 'description', r.description, 'urgency', r.urgency,
        'status', r.status, 'response', r.response, 'wo_code', r.wo_code, 'created_at', r.created_at, 'updated_at', r.updated_at, 'rating', r.rating, 'photos', jsonb_array_length(r.photos))
        order by r.created_at desc) from (select * from public.fm_school_requests where bkey = k.bkey order by created_at desc limit 30) r), '[]'::jsonb),
    'tickets', coalesce((select jsonb_agg(jsonb_build_object('id', t.ticket_id, 'cat', t.sub_category, 'status', t.status, 'priority', t.priority, 'at', t.created_at) order by t.created_at desc)
        from (select * from public.tickets t where (public.fm_bkey(t.building_id, null) = k.bkey or btrim(t.school) = k.school_name)
                and coalesce(t.status,'') !~* '(مغلق|تم الحل|تم حل|محلول|ملغ|مكتمل|closed|resolved|cancel)' order by t.created_at desc limit 50) t), '[]'::jsonb),
    'orders', coalesce((select jsonb_agg(jsonb_build_object('code', w.code, 'title', w.title, 'type', w.type, 'status', w.status, 'at', w.created_at) order by w.created_at desc)
        from (select * from public.work_orders w where (public.fm_bkey(w.building_id, null) = k.bkey or btrim(w.school) = k.school_name)
                and w.status not in ('closed','cancelled','rejected') order by w.created_at desc limit 50) w), '[]'::jsonb));
end $$;
-- public (anon): a new request (at most 10 per link a day; photos: up to 3 data URLs of an image, ≤ 600 000 characters each)
create or replace function public.fm_school_request_new(p_token text, p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare k public.fm_school_links; v_code text; ph jsonb := coalesce(p->'photos','[]'); x jsonb;
begin
  select * into k from public.fm_school_links where token = p_token and length(p_token) = 64 and active;
  if not found then raise exception 'invalid link'; end if;
  if (select count(*) from public.fm_school_requests where token = p_token and created_at > now() - interval '1 day') >= 10 then raise exception 'too many requests'; end if;
  if btrim(coalesce(p->>'category','')) = '' or length(btrim(coalesce(p->>'description',''))) < 5 then raise exception 'description required'; end if;
  if jsonb_typeof(ph) <> 'array' or jsonb_array_length(ph) > 3 then raise exception 'invalid photos'; end if;
  for x in select * from jsonb_array_elements(ph) loop
    if jsonb_typeof(x) <> 'string' or (x #>> '{}') !~ '^data:image/(jpeg|png|webp);base64,[A-Za-z0-9+/=]+$' or length(x #>> '{}') > 600000 then raise exception 'invalid photos'; end if;
  end loop;
  v_code := 'SR-' || to_char(now() at time zone 'Asia/Riyadh', 'YYYY') || '-' || lpad(nextval('public.fm_school_req_seq')::text, 4, '0');
  insert into public.fm_school_requests(code, token, bkey, school_name, region, category, description, urgency, contact_name, contact_phone, photos)
  values (v_code, p_token, k.bkey, k.school_name, k.region, left(btrim(p->>'category'),60), left(btrim(p->>'description'),1000),
          case when p->>'urgency' = 'urgent' then 'urgent' else 'normal' end, left(nullif(btrim(coalesce(p->>'contact_name','')),''),100),
          left(nullif(btrim(coalesce(p->>'contact_phone','')),''),30), ph);
  return v_code;
end $$;
-- public (anon): rate a finished request once
create or replace function public.fm_school_request_rate(p_token text, p_id uuid, p_score int, p_comment text) returns void language plpgsql security definer set search_path = public as $$
declare r public.fm_school_requests;
begin
  select * into r from public.fm_school_requests where id = p_id and token = p_token for update;
  if not found or not exists(select 1 from public.fm_school_links where token = p_token and active) then raise exception 'invalid link'; end if;
  if r.status <> 'done' then raise exception 'not finished'; end if;
  if r.rating is not null then raise exception 'already rated'; end if;
  if p_score is null or p_score not between 1 and 5 then raise exception 'invalid rating'; end if;
  update public.fm_school_requests set rating = p_score, rating_comment = left(nullif(btrim(coalesce(p_comment,'')),''),500), rated_at = now() where id = p_id;
end $$;

-- staff: the links of my schools / make (or renew) links
create or replace function public.fm_school_links_list() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('k', s.bkey, 'name', s.name, 'region', s.region, 'principal', s.principal, 'phone', s.principal_phone,
      'token', l.token, 'created_at', l.created_at, 'last_used_at', l.last_used_at) order by s.name), '[]'::jsonb)
    from public.fm_my_schools() s left join public.fm_school_links l on l.bkey = s.bkey and l.active
   where public.fm_role() in ('admin','manager','engineer','supervisor') $$;
create or replace function public.fm_school_link_make(p_keys text[], p_renew boolean default false) returns int language plpgsql security definer set search_path = public as $$
declare s record; n int := 0;
begin
  if auth.uid() is null or public.fm_role() not in ('admin','manager','engineer','supervisor') then raise exception 'not allowed'; end if;
  for s in select * from public.fm_my_schools() m where m.bkey = any(p_keys) loop
    if p_renew then update public.fm_school_links set active = false, revoked_at = now() where bkey = s.bkey and active; end if;
    if not exists(select 1 from public.fm_school_links where bkey = s.bkey and active) then
      insert into public.fm_school_links(token, bkey, school_name, region) values (replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', ''), s.bkey, s.name, s.region);
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;
create or replace function public.fm_school_link_revoke(p_key text) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or public.fm_role() not in ('admin','manager','engineer','supervisor') or not exists(select 1 from public.fm_my_schools() m where m.bkey = p_key) then raise exception 'not allowed'; end if;
  update public.fm_school_links set active = false, revoked_at = now() where bkey = p_key and active;
end $$;
-- staff: the requests of my schools (last p_days days, open ones always)
create or replace function public.fm_school_req_list(p_days int default 90) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(r) - 'token' order by r.created_at desc), '[]'::jsonb)
    from public.fm_school_requests r
   where public.fm_role() in ('admin','manager','staff','viewer','engineer','supervisor')
     and r.bkey in (select bkey from public.fm_my_schools())
     and (r.status in ('new','accepted','in_progress') or r.created_at > now() - make_interval(days => greatest(1, least(coalesce(p_days,90), 730)))) $$;
-- staff: accept | reject (reply required) | done (reply required) | link {wo_id, wo_code} (→ in progress)
create or replace function public.fm_school_req_act(p_id uuid, p_action text, p_note text default null, p_wo jsonb default null) returns text language plpgsql security definer set search_path = public as $$
declare r public.fm_school_requests; me uuid := auth.uid(); nm text := (select coalesce(full_name, email) from public.profiles where id = auth.uid()); ns text; note text := nullif(btrim(coalesce(p_note,'')),'');
begin
  select * into r from public.fm_school_requests where id = p_id for update;
  if not found or me is null or public.fm_role() not in ('admin','manager','engineer','supervisor') or r.bkey not in (select bkey from public.fm_my_schools()) then raise exception 'not allowed'; end if;
  if p_action = 'accept' and r.status = 'new' then ns := 'accepted';
  elsif p_action = 'reject' and r.status in ('new','accepted') then if note is null then raise exception 'reason required'; end if; ns := 'rejected';
  elsif p_action = 'done' and r.status in ('new','accepted','in_progress') then if note is null then raise exception 'reason required'; end if; ns := 'done';
  elsif p_action = 'link' and r.status in ('new','accepted','in_progress') then
    if not exists(select 1 from public.work_orders where id = nullif(p_wo->>'wo_id','')::uuid) then raise exception 'work order not found'; end if;
    ns := 'in_progress';
    update public.fm_school_requests set wo_id = (p_wo->>'wo_id')::uuid, wo_code = (select code from public.work_orders where id = (p_wo->>'wo_id')::uuid) where id = p_id;
  else raise exception 'action not allowed'; end if;
  update public.fm_school_requests set status = ns, response = coalesce(left(note,1000), response), handled_by = me, handled_by_name = nm, updated_at = now() where id = p_id;
  return ns;
end $$;
-- a closed work order finishes the requests linked to it
create or replace function public.fm_school_req_wo_trg() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'closed' and old.status <> 'closed' then
    update public.fm_school_requests set status = 'done', response = coalesce(response, 'تم تنفيذ أمر العمل ' || coalesce(new.code,'') || ' واعتماده'), updated_at = now()
     where wo_id = new.id and status in ('accepted','in_progress','new');
  end if;
  return new;
end $$;
drop trigger if exists fm_school_req_wo on public.work_orders;
create trigger fm_school_req_wo after update of status on public.work_orders for each row execute function public.fm_school_req_wo_trg();
revoke all on function public.fm_my_schools(), public.fm_school_req_wo_trg() from public, anon, authenticated;
revoke all on function public.fm_school_portal(text), public.fm_school_request_new(text, jsonb), public.fm_school_request_rate(text, uuid, int, text) from public;
grant execute on function public.fm_school_portal(text), public.fm_school_request_new(text, jsonb), public.fm_school_request_rate(text, uuid, int, text) to anon, authenticated;
revoke all on function public.fm_school_links_list(), public.fm_school_link_make(text[], boolean), public.fm_school_link_revoke(text), public.fm_school_req_list(int), public.fm_school_req_act(uuid, text, text, jsonb) from public, anon;
grant execute on function public.fm_school_links_list(), public.fm_school_link_make(text[], boolean), public.fm_school_link_revoke(text), public.fm_school_req_list(int), public.fm_school_req_act(uuid, text, text, jsonb) to authenticated;

-- done. Next: in the platform → الإعدادات → «السحابة والمستخدمين», paste the Project URL and the anon key.
