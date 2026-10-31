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
--   storekeeper=أمين المستودع (V180: issues parts to custody and alone confirms returns and scrap; reports of his stores)
--   owner_rep=ممثل الجهة المالكة (V180: read only; gives the final approval of items and supplier prices)
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
  ('sysadmin','dept_manager','project_manager','ops_manager','area_manager','area_engineer','supervisor','contractor','hse_manager','qa_manager','accountant','storekeeper','owner_rep'));
create or replace function public.fm_pos_role(p text) returns text language sql immutable as $$
  select case p when 'sysadmin' then 'admin' when 'dept_manager' then 'viewer'
    when 'project_manager' then 'manager' when 'ops_manager' then 'manager' when 'area_manager' then 'manager'
    when 'area_engineer' then 'engineer' when 'supervisor' then 'supervisor' when 'contractor' then 'contractor'
    when 'hse_manager' then 'staff' when 'qa_manager' then 'staff' when 'accountant' then 'staff'
    when 'storekeeper' then 'staff' when 'owner_rep' then 'viewer' end $$;
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
  if not public.fm_mod('wo') then return 0; end if;     -- V181: the work-orders part is off
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

-- ---------- 23) SaaS subscription of this company (V179) ----------
-- Every company has its own Supabase project (this file). The platform owner keeps the companies, invoices and their
-- secrets in the control project (saas_control.sql). In each company project one row of fm_plan holds the subscription:
-- plan, school limit and the date it runs until. It is created once by the owner from the SQL editor (fm_plan_init) and
-- renewed by the company's system admin with an activation code the owner sends with the paid invoice (fm_plan_activate:
-- HMAC-SHA256 of the code with the secret only the owner and this database know). After active_until + grace_days every
-- role becomes «pending» (fm_role), so the data stays but nobody can work until the next code. No row = no subscription
-- control (the original single-company installation keeps working as before).
do $$ begin execute 'create extension if not exists pgcrypto with schema extensions'; exception when others then null; end $$;
create table if not exists public.fm_plan (
  id            int primary key default 1 check (id = 1),
  company       text not null,
  plan          text not null default 'basic',
  schools_limit int  not null default 0,          -- 0 = unlimited
  active_until  date,
  grace_days    int  not null default 7,
  secret        text not null,
  nonces        text[] not null default '{}',
  activated_at  timestamptz,
  updated_at    timestamptz not null default now()
);
alter table public.fm_plan enable row level security;
revoke all on public.fm_plan from anon, authenticated;
create or replace function public.fm_plan_ok() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce((select p.active_until is null or current_date <= p.active_until + p.grace_days from public.fm_plan p where p.id = 1), true) $$;
-- every policy goes through fm_role: an expired subscription turns everyone into «pending»
create or replace function public.fm_role() returns text language sql stable security definer set search_path = public as $$
  select case when p.active and public.fm_plan_ok() then p.role else 'pending' end from public.profiles p where p.id = auth.uid() $$;
-- what the platform shows (no secret)
create or replace function public.fm_plan_info() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('company', p.company, 'plan', p.plan, 'schools_limit', p.schools_limit, 'active_until', p.active_until,
      'grace_days', p.grace_days, 'days_left', p.active_until - current_date, 'activated_at', p.activated_at,
      'state', case when p.active_until is null then 'unlimited' when current_date <= p.active_until - 15 then 'ok'
                    when current_date <= p.active_until then 'warn' when current_date <= p.active_until + p.grace_days then 'grace' else 'expired' end,
      'schools', (select case when jsonb_typeof(v) = 'array' then jsonb_array_length(v) when jsonb_typeof(v) = 'string' and left(v #>> '{}',1) = '['
                  then jsonb_array_length((v #>> '{}')::jsonb) else 0 end from (select value v from public.app_kv where key = 'fm_school_master_db_v1') x))
    from public.fm_plan p where p.id = 1), jsonb_build_object('state','none')) $$;
-- created once by the owner in the SQL editor of the new company project (the console prints this line)
create or replace function public.fm_plan_init(p_company text, p_secret text, p_plan text, p_limit int, p_until date) returns void
language plpgsql security definer set search_path = public as $$
begin
  if exists(select 1 from public.fm_plan) then raise exception 'plan already initialised'; end if;
  if length(coalesce(p_secret,'')) < 32 then raise exception 'weak secret'; end if;
  insert into public.fm_plan(company, secret, plan, schools_limit, active_until) values (p_company, p_secret, coalesce(p_plan,'basic'), coalesce(p_limit,0), p_until);
end $$;
-- HMAC-SHA256 (pgcrypto lives in the extensions schema on Supabase)
create or replace function public.fm_plan_hmac(p_data text, p_key text) returns text language plpgsql immutable set search_path = public as $$
begin
  begin return encode(extensions.hmac(convert_to(p_data,'utf8'), convert_to(p_key,'utf8'), 'sha256'), 'hex');
  exception when undefined_function or invalid_schema_name then return encode(public.hmac(convert_to(p_data,'utf8'), convert_to(p_key,'utf8'), 'sha256'), 'hex'); end;
end $$;
-- the company's system admin enters the activation code: <base64url payload>.<hex hmac>, payload {c, p, l, u, n}
create or replace function public.fm_plan_activate(p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare pl public.fm_plan; parts text[]; b64 text; j jsonb;
begin
  if not exists(select 1 from public.profiles where id = auth.uid() and active and role = 'admin') then raise exception 'not allowed'; end if;
  select * into pl from public.fm_plan where id = 1 for update;
  if not found then raise exception 'no subscription'; end if;
  parts := regexp_split_to_array(btrim(coalesce(p_code,'')), '\.');
  if array_length(parts,1) <> 2 or parts[2] !~ '^[0-9a-f]{64}$' then raise exception 'invalid code'; end if;
  if public.fm_plan_hmac(parts[1], pl.secret) <> parts[2] then raise exception 'invalid code'; end if;
  b64 := translate(parts[1], '-_', '+/'); b64 := b64 || repeat('=', (4 - length(b64) % 4) % 4);
  j := convert_from(decode(b64, 'base64'), 'utf8')::jsonb;
  if j->>'c' is distinct from pl.company then raise exception 'code for another company'; end if;
  if coalesce(j->>'n','') = '' or (j->>'n') = any(pl.nonces) then raise exception 'code already used'; end if;
  update public.fm_plan set plan = coalesce(j->>'p', plan), schools_limit = coalesce((j->>'l')::int, schools_limit), active_until = (j->>'u')::date,
    nonces = (array[j->>'n'] || nonces)[1:100], activated_at = now(), updated_at = now() where id = 1;
  return public.fm_plan_info();
end $$;
-- the school limit of the plan (the shared school DB in app_kv)
create or replace function public.fm_plan_limit_trg() returns trigger language plpgsql security definer set search_path = public as $$
declare lim int; v jsonb := new.value; n int;
begin
  if new.key <> 'fm_school_master_db_v1' then return new; end if;
  select schools_limit into lim from public.fm_plan where id = 1;
  if coalesce(lim,0) <= 0 then return new; end if;
  if jsonb_typeof(v) = 'string' then begin v := (v #>> '{}')::jsonb; exception when others then return new; end; end if;
  n := case when jsonb_typeof(v) = 'array' then jsonb_array_length(v) else 0 end;
  if n > lim then raise exception 'plan school limit: % of %', n, lim; end if;
  return new;
end $$;
drop trigger if exists fm_plan_limit on public.app_kv;
create trigger fm_plan_limit before insert or update on public.app_kv for each row execute function public.fm_plan_limit_trg();
revoke all on function public.fm_plan_init(text, text, text, int, date), public.fm_plan_hmac(text, text), public.fm_plan_limit_trg() from public, anon, authenticated;
revoke all on function public.fm_plan_info(), public.fm_plan_activate(text) from public, anon;
grant execute on function public.fm_plan_info(), public.fm_plan_activate(text) to authenticated;

-- ---------- 24) warehouse, spare parts and custody (V180, field F29) ----------
-- Builds on section 21. Items (wo_materials) get a code, specifications, notes, up to 3 photos, a «scrap must be returned»
-- flag, warranty and serial tracking, and a two-step approval: the project manager (or above) nominates a new item or a new
-- price, then the owner's representative (job title owner_rep) approves it; while no active owner_rep account exists the
-- nomination is final. Only approved items can be issued. Suppliers and their prices follow the same approval.
-- The storekeeper (job title storekeeper, the keeper of a store or of the stores of his regions) is the only one who issues
-- parts to a person's custody (عهدة) and confirms what comes back: unused parts (return) and the scrap of used parts (scrap).
-- A supervisor / contractor asks for parts for a work order or a ticket; an engineer / area manager / project manager may
-- ask for someone of his team («direct»). When a work order is closed its store materials are taken first from the
-- assignee's custody, the rest from the region's store (as before). An item that needs its scrap returned stays owed by
-- the assignee (wo_custody.scrap) until the storekeeper confirms the scrap; after stock_rules.scrap_days it is overdue and
-- climbs to his manager / the project (esc_days), and new issues of that item to him are refused (block_overdue).
-- Custody value cap per job title (stock_rules.cap, 0 = none), monthly custody counts signed by the holder, purchase
-- requests (approved within spend_limits), receipts with the price difference against the approved price, and serial
-- numbers with their warranty.
insert into public.fm_settings(key, value) values
  ('stock_rules', '{"scrap_days":7,"esc_days":[7,14],"block_overdue":true,"variance_pct":5,"cap":{"supervisor":0,"contractor":0,"area_engineer":0}}')
on conflict (key) do nothing;

create or replace function public.fm_me_name() returns text language sql stable security definer set search_path = public as $$
  select coalesce(full_name, email) from public.profiles where id = auth.uid() $$;
-- full warehouse management (all stores, all reports, write-offs)
create or replace function public.fm_wh_admin() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager'), false) $$;
-- may add / edit items and suppliers (approval decides what becomes usable)
create or replace function public.fm_wh_edit() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_wh_admin() or public.fm_my_pos() in ('area_manager','area_engineer','storekeeper'), false) $$;
-- first approval step: project manager and above
create or replace function public.fm_wh_nominator() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager'), false) $$;
create or replace function public.fm_wh_has_owner() returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles where job_title = 'owner_rep' and active) $$;
-- the storekeeper may manage the stores of his regions too (receipts, counts, transfers)
create or replace function public.fm_stock_can(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager')
    or (public.fm_my_pos() in ('area_manager','area_engineer','storekeeper') and public.fm_region_ok(coalesce(p_region,''))), false) $$;
alter table public.wo_stores add column if not exists keeper uuid references public.profiles(id) on delete set null;
-- the caller is the storekeeper of this store (the named keeper, or any storekeeper of its region when none is named)
create or replace function public.fm_wh_keeper(p_store uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_my_pos() = 'storekeeper' and exists(select 1 from public.wo_stores s where s.id = p_store and s.active
    and (s.keeper = auth.uid() or (s.keeper is null and public.fm_region_ok(coalesce(s.region,''))))), false) $$;
-- may the caller see this person's custody? himself, his managers, the warehouse and control titles, the area manager of his regions
create or replace function public.fm_wh_sees_holder(h uuid) returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and public.fm_role() <> 'pending' and (h = auth.uid() or public.fm_role() = 'admin'
    or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager','storekeeper','owner_rep','accountant','qa_manager')
    or public.fm_is_under(h, auth.uid())
    or (public.fm_my_pos() = 'area_manager' and exists(select 1 from public.profiles p where p.id = h
          and (cardinality(public.fm_regions()) = 0 or p.regions && public.fm_regions())))) $$;
-- may the caller ask for parts on behalf of this person («direct»)?
create or replace function public.fm_wh_may_direct(h uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_my_pos() in ('sysadmin','project_manager','ops_manager','area_manager','area_engineer') or public.fm_role() = 'admin', false)
    and exists(select 1 from public.profiles p where p.id = h and p.active and public.fm_posx(p.role, p.job_title) in ('supervisor','contractor','area_engineer'))
    and (public.fm_is_under(h, auth.uid()) or public.fm_wh_admin()
      or (public.fm_my_pos() = 'area_manager' and exists(select 1 from public.profiles p where p.id = h
            and (cardinality(public.fm_regions()) = 0 or p.regions && public.fm_regions())))) $$;

-- ---- items: code, details, photos, approval ----
alter table public.wo_materials add column if not exists approval text not null default 'approved';
alter table public.wo_materials alter column approval set default 'pending';
alter table public.wo_materials drop constraint if exists wo_materials_approval_check;
alter table public.wo_materials add constraint wo_materials_approval_check check (approval in ('pending','nominated','approved','rejected'));
alter table public.wo_materials
  add column if not exists specs             text,
  add column if not exists notes             text,
  add column if not exists scrap_return      boolean not null default false,
  add column if not exists warranty_months   int,
  add column if not exists serial_tracked    boolean not null default false,
  add column if not exists price_new         numeric(12,2),
  add column if not exists appr_note         text,
  add column if not exists nominated_by_name text,
  add column if not exists nominated_at      timestamptz,
  add column if not exists approved_by_name  text,
  add column if not exists approved_at       timestamptz,
  add column if not exists created_by        uuid,
  add column if not exists created_at        timestamptz default now();
-- items that existed before V180 were already in use: they count as approved
update public.wo_materials set approved_at = coalesce(updated_at, now()) where approval = 'approved' and approved_at is null;
drop policy if exists p_wom_read  on public.wo_materials;
drop policy if exists p_wom_write on public.wo_materials;
create policy p_wom_read on public.wo_materials for select using (public.fm_role() in ('admin','manager','staff','engineer','supervisor','contractor','viewer'));
revoke insert, update, delete on public.wo_materials from anon, authenticated;
create sequence if not exists public.wo_material_code_seq;
create or replace function public.fm_mat_code() returns text language plpgsql security definer set search_path = public as $$
declare c text;
begin
  loop
    c := 'SP-' || lpad(nextval('public.wo_material_code_seq')::text, 5, '0');
    exit when not exists(select 1 from public.wo_materials where lower(code) = lower(c));
  end loop;
  return c;
end $$;

create table if not exists public.wo_material_photos (
  id          uuid primary key default gen_random_uuid(),
  material_id uuid not null references public.wo_materials(id) on delete cascade,
  data        text not null check (data ~ '^data:image/(jpeg|png|webp);base64,' and length(data) <= 420000),
  at          timestamptz not null default now(),
  by_id       uuid default auth.uid()
);
create index if not exists wo_material_photos_idx on public.wo_material_photos (material_id, at);
alter table public.wo_material_photos enable row level security;
drop policy if exists p_womp_read on public.wo_material_photos;
create policy p_womp_read on public.wo_material_photos for select using (public.fm_role() in ('admin','manager','staff','engineer','supervisor','contractor','viewer'));
revoke insert, update, delete on public.wo_material_photos from anon, authenticated;

-- ---- suppliers and their prices ----
create table if not exists public.wo_suppliers (
  id         uuid primary key default gen_random_uuid(),
  name       text not null,
  vat_no     text,
  cr_no      text,
  phone      text,
  email      text,
  contact    text,
  address    text,
  notes      text,
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists wo_suppliers_name_uq on public.wo_suppliers (lower(name));
create table if not exists public.wo_supplier_prices (
  supplier_id       uuid not null references public.wo_suppliers(id) on delete cascade,
  material_id       uuid not null references public.wo_materials(id) on delete cascade,
  price             numeric(12,2),                 -- the approved price
  price_new         numeric(12,2),                 -- waiting for approval
  lead_days         int,
  notes             text,
  approval          text not null default 'pending' check (approval in ('pending','nominated','approved','rejected')),
  appr_note         text,
  nominated_by_name text,
  nominated_at      timestamptz,
  approved_by_name  text,
  approved_at       timestamptz,
  updated_at        timestamptz not null default now(),
  primary key (supplier_id, material_id)
);
alter table public.wo_suppliers enable row level security;
alter table public.wo_supplier_prices enable row level security;
drop policy if exists p_wos_read on public.wo_suppliers;
create policy p_wos_read on public.wo_suppliers for select using (public.fm_role() in ('admin','manager','staff','engineer','viewer'));
drop policy if exists p_wosp_read on public.wo_supplier_prices;
create policy p_wosp_read on public.wo_supplier_prices for select using (public.fm_role() in ('admin','manager','staff','engineer','viewer'));
revoke insert, update, delete on public.wo_suppliers, public.wo_supplier_prices from anon, authenticated;

-- one approval step on an item (p_sup null) or a supplier price; returns true when something changed
create or replace function public.fm_appr_step(p_mat uuid, p_sup uuid, p_action text, p_note text) returns boolean
language plpgsql security definer set search_path = public as $$
declare st text; aat timestamptz; nm text := public.fm_me_name(); lead boolean := public.fm_wh_nominator();
  own boolean := public.fm_my_pos() = 'owner_rep'; fin boolean := false; nx text;
begin
  if p_sup is null then select approval, approved_at into st, aat from public.wo_materials where id = p_mat for update;
  else select approval, approved_at into st, aat from public.wo_supplier_prices where supplier_id = p_sup and material_id = p_mat for update; end if;
  if not found then raise exception 'not found'; end if;
  if p_action = 'nominate' then
    if not lead or st <> 'pending' then return false; end if;
    if public.fm_wh_has_owner() then nx := 'nominated'; else fin := true; end if;
  elsif p_action = 'approve' then
    if not own or st <> 'nominated' then return false; end if;
    fin := true;
  elsif p_action = 'reject' then
    if not ((lead and st in ('pending','nominated')) or (own and st = 'nominated')) then return false; end if;
    if btrim(coalesce(p_note,'')) = '' then raise exception 'note required'; end if;
    if p_sup is null then
      update public.wo_materials set approval = case when aat is not null then 'approved' else 'rejected' end, price_new = null,
        appr_note = left('❌ ' || nm || ': ' || btrim(p_note), 400), updated_at = now() where id = p_mat;
    else
      update public.wo_supplier_prices set approval = case when aat is not null then 'approved' else 'rejected' end, price_new = null,
        appr_note = left('❌ ' || nm || ': ' || btrim(p_note), 400), updated_at = now() where supplier_id = p_sup and material_id = p_mat;
    end if;
    return true;
  else raise exception 'invalid action'; end if;
  if fin then
    if p_sup is null then
      update public.wo_materials set approval = 'approved', price = coalesce(price_new, price), price_new = null, approved_by_name = nm, approved_at = now(),
        nominated_by_name = case when p_action = 'nominate' then nm else nominated_by_name end, nominated_at = case when p_action = 'nominate' then now() else nominated_at end,
        appr_note = nullif(btrim(coalesce(p_note,'')),''), updated_at = now() where id = p_mat;
    else
      update public.wo_supplier_prices set approval = 'approved', price = coalesce(price_new, price), price_new = null, approved_by_name = nm, approved_at = now(),
        nominated_by_name = case when p_action = 'nominate' then nm else nominated_by_name end, nominated_at = case when p_action = 'nominate' then now() else nominated_at end,
        appr_note = nullif(btrim(coalesce(p_note,'')),''), updated_at = now() where supplier_id = p_sup and material_id = p_mat;
    end if;
  else
    if p_sup is null then update public.wo_materials set approval = nx, nominated_by_name = nm, nominated_at = now(), appr_note = nullif(btrim(coalesce(p_note,'')),''), updated_at = now() where id = p_mat;
    else update public.wo_supplier_prices set approval = nx, nominated_by_name = nm, nominated_at = now(), appr_note = nullif(btrim(coalesce(p_note,'')),''), updated_at = now() where supplier_id = p_sup and material_id = p_mat; end if;
  end if;
  return true;
end $$;
-- approve / nominate / reject several: p_kind item (p_ids = [uuid]) or price (p_ids = [{s: supplier, m: material}])
create or replace function public.fm_mat_approve(p_kind text, p_ids jsonb, p_action text, p_note text) returns int
language plpgsql security definer set search_path = public as $$
declare x jsonb; n int := 0;
begin
  if auth.uid() is null or not (public.fm_wh_nominator() or public.fm_my_pos() = 'owner_rep') then raise exception 'not allowed'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_ids,'[]')) loop
    if p_kind = 'item' then if public.fm_appr_step((x #>> '{}')::uuid, null, p_action, p_note) then n := n + 1; end if;
    elsif p_kind = 'price' then if public.fm_appr_step((x->>'m')::uuid, (x->>'s')::uuid, p_action, p_note) then n := n + 1; end if;
    else raise exception 'invalid kind'; end if;
  end loop;
  return n;
end $$;

-- add or change an item: p {id?, code, name, unit, price, category, specs, notes, scrap_return, warranty_months, serial_tracked, active}
-- a new item or a new price waits for approval (the old approved price stays in use meanwhile)
create or replace function public.fm_mat_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id','')::uuid; m public.wo_materials; v_code text := nullif(btrim(coalesce(p->>'code','')),'');
  v_name text := btrim(coalesce(p->>'name','')); v_price numeric := nullif(p->>'price','')::numeric; chg boolean := false;
begin
  if auth.uid() is null or not public.fm_wh_edit() then raise exception 'not allowed'; end if;
  if v_name = '' then raise exception 'name required'; end if;
  if v_price is not null and (v_price < 0 or v_price > 100000000) then raise exception 'invalid price'; end if;
  if v_code is not null and exists(select 1 from public.wo_materials where lower(code) = lower(v_code) and id is distinct from v_id) then raise exception 'duplicate code'; end if;
  if exists(select 1 from public.wo_materials where lower(name) = lower(v_name) and id is distinct from v_id) then raise exception 'duplicate name'; end if;
  if v_id is null or not exists(select 1 from public.wo_materials where id = v_id) then
    insert into public.wo_materials(id, code, name, unit, category, specs, notes, scrap_return, warranty_months, serial_tracked, active, approval, price_new, created_by, created_at, updated_at)
    values (coalesce(v_id, gen_random_uuid()), coalesce(v_code, public.fm_mat_code()), left(v_name,200), left(nullif(btrim(coalesce(p->>'unit','')),''),40), left(nullif(btrim(coalesce(p->>'category','')),''),80),
            left(nullif(btrim(coalesce(p->>'specs','')),''),1000), left(nullif(btrim(coalesce(p->>'notes','')),''),1000), coalesce((p->>'scrap_return')::boolean,false),
            nullif(p->>'warranty_months','')::int, coalesce((p->>'serial_tracked')::boolean,false), coalesce((p->>'active')::boolean,true), 'pending', v_price, auth.uid(), now(), now())
    returning id into v_id;
    chg := true;
  else
    select * into m from public.wo_materials where id = v_id for update;
    if not found then raise exception 'not found'; end if;
    update public.wo_materials set code = coalesce(v_code, code, public.fm_mat_code()), name = left(v_name,200),
      unit = case when p ? 'unit' then left(nullif(btrim(coalesce(p->>'unit','')),''),40) else unit end,
      category = case when p ? 'category' then left(nullif(btrim(coalesce(p->>'category','')),''),80) else category end,
      specs = case when p ? 'specs' then left(nullif(btrim(coalesce(p->>'specs','')),''),1000) else specs end,
      notes = case when p ? 'notes' then left(nullif(btrim(coalesce(p->>'notes','')),''),1000) else notes end,
      scrap_return = coalesce((p->>'scrap_return')::boolean, scrap_return), warranty_months = case when p ? 'warranty_months' then nullif(p->>'warranty_months','')::int else warranty_months end,
      serial_tracked = coalesce((p->>'serial_tracked')::boolean, serial_tracked), active = coalesce((p->>'active')::boolean, active), updated_at = now()
     where id = v_id;
    if p ? 'price' and v_price is distinct from coalesce(m.price_new, m.price) and v_price is not null then
      update public.wo_materials set price_new = v_price, approval = 'pending', appr_note = null where id = v_id; chg := true;
    elsif m.approval = 'rejected' then
      update public.wo_materials set approval = 'pending', appr_note = null where id = v_id; chg := true;
    end if;
  end if;
  if chg and public.fm_wh_nominator() then perform public.fm_appr_step(v_id, null, 'nominate', null); end if;
  return v_id;
end $$;
-- remove an item: deleted when it was never used, else made inactive
create or replace function public.fm_mat_delete(p_id uuid) returns text language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.fm_wh_edit() then raise exception 'not allowed'; end if;
  if exists(select 1 from public.wo_stock_moves where material_id = p_id) or exists(select 1 from public.wo_stock where material_id = p_id and qty <> 0)
     or exists(select 1 from public.wo_custody where material_id = p_id) then
    update public.wo_materials set active = false, updated_at = now() where id = p_id; return 'inactive';
  end if;
  delete from public.wo_materials where id = p_id; return 'deleted';
end $$;
create or replace function public.fm_mat_photo(p_mat uuid, p_data text, p_del uuid) returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid;
begin
  if auth.uid() is null or not public.fm_wh_edit() then raise exception 'not allowed'; end if;
  if p_del is not null then delete from public.wo_material_photos where id = p_del; return p_del; end if;
  if (select count(*) from public.wo_material_photos where material_id = p_mat) >= 3 then raise exception 'max 3 photos'; end if;
  insert into public.wo_material_photos(material_id, data) values (p_mat, p_data) returning id into v;
  return v;
end $$;
-- add or change a supplier: p {id?, name, vat_no, cr_no, phone, email, contact, address, notes, active}
create or replace function public.fm_supplier_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id','')::uuid; v_name text := btrim(coalesce(p->>'name',''));
begin
  if auth.uid() is null or not public.fm_wh_edit() then raise exception 'not allowed'; end if;
  if v_name = '' then raise exception 'name required'; end if;
  if exists(select 1 from public.wo_suppliers where lower(name) = lower(v_name) and id is distinct from v_id) then raise exception 'duplicate name'; end if;
  if v_id is null then
    insert into public.wo_suppliers(name) values (left(v_name,200)) returning id into v_id;
  end if;
  update public.wo_suppliers set name = left(v_name,200), vat_no = left(nullif(btrim(coalesce(p->>'vat_no','')),''),40), cr_no = left(nullif(btrim(coalesce(p->>'cr_no','')),''),40),
    phone = left(nullif(btrim(coalesce(p->>'phone','')),''),40), email = left(nullif(btrim(coalesce(p->>'email','')),''),120), contact = left(nullif(btrim(coalesce(p->>'contact','')),''),120),
    address = left(nullif(btrim(coalesce(p->>'address','')),''),300), notes = left(nullif(btrim(coalesce(p->>'notes','')),''),1000), active = coalesce((p->>'active')::boolean, true)
   where id = v_id;
  return v_id;
end $$;
-- a supplier's price of an item: p {supplier_id, material_id, price, lead_days, notes, delete}
create or replace function public.fm_supplier_price_save(p jsonb) returns boolean language plpgsql security definer set search_path = public as $$
declare s uuid := (p->>'supplier_id')::uuid; m uuid := (p->>'material_id')::uuid; v numeric := nullif(p->>'price','')::numeric; r public.wo_supplier_prices; chg boolean := false;
begin
  if auth.uid() is null or not public.fm_wh_edit() then raise exception 'not allowed'; end if;
  if coalesce((p->>'delete')::boolean,false) then delete from public.wo_supplier_prices where supplier_id = s and material_id = m; return true; end if;
  if v is null or v < 0 or v > 100000000 then raise exception 'invalid price'; end if;
  select * into r from public.wo_supplier_prices where supplier_id = s and material_id = m for update;
  if not found then
    insert into public.wo_supplier_prices(supplier_id, material_id, price_new, lead_days, notes) values (s, m, v, nullif(p->>'lead_days','')::int, left(nullif(btrim(coalesce(p->>'notes','')),''),300));
    chg := true;
  else
    update public.wo_supplier_prices set lead_days = case when p ? 'lead_days' then nullif(p->>'lead_days','')::int else lead_days end,
      notes = case when p ? 'notes' then left(nullif(btrim(coalesce(p->>'notes','')),''),300) else notes end, updated_at = now() where supplier_id = s and material_id = m;
    if v is distinct from coalesce(r.price_new, r.price) or r.approval = 'rejected' then
      update public.wo_supplier_prices set price_new = v, approval = 'pending', appr_note = null where supplier_id = s and material_id = m; chg := true;
    end if;
  end if;
  if chg and public.fm_wh_nominator() then perform public.fm_appr_step(m, s, 'nominate', null); end if;
  return chg;
end $$;
-- the keeper of a store (an active storekeeper; null = every storekeeper of its region)
create or replace function public.fm_stock_store_keeper(p_store uuid, p_keeper uuid) returns boolean language plpgsql security definer set search_path = public as $$
declare st public.wo_stores;
begin
  select * into st from public.wo_stores where id = p_store;
  if auth.uid() is null or not found or not (public.fm_wh_admin() or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(st.region,'')))) then raise exception 'not allowed'; end if;
  if p_keeper is not null and not exists(select 1 from public.profiles where id = p_keeper and active and job_title = 'storekeeper') then raise exception 'not a storekeeper'; end if;
  update public.wo_stores set keeper = p_keeper where id = p_store;
  return true;
end $$;

-- ---- moves: new kinds ----
alter table public.wo_stock add column if not exists scrap_qty numeric(14,3) not null default 0;
alter table public.wo_stock_moves drop constraint if exists wo_stock_moves_kind_check;
alter table public.wo_stock_moves add constraint wo_stock_moves_kind_check check (kind in ('in','out','adjust','transfer','issue','return','scrap'));
alter table public.wo_stock_moves
  add column if not exists holder      uuid references public.profiles(id) on delete set null,
  add column if not exists holder_name text,
  add column if not exists ref         text,
  add column if not exists supplier_id uuid references public.wo_suppliers(id) on delete set null,
  add column if not exists variance    numeric(8,1);

-- ---- custody ----
create table if not exists public.wo_custody (
  holder      uuid not null references public.profiles(id) on delete cascade,
  material_id uuid not null references public.wo_materials(id) on delete cascade,
  qty         numeric(14,3) not null default 0,    -- in his hands
  scrap       numeric(14,3) not null default 0,    -- used, scrap still to be returned
  updated_at  timestamptz not null default now(),
  primary key (holder, material_id)
);
create table if not exists public.wo_custody_moves (
  id          uuid primary key default gen_random_uuid(),
  at          timestamptz not null default now(),
  holder      uuid not null references public.profiles(id) on delete cascade,
  holder_name text,
  material_id uuid not null references public.wo_materials(id) on delete cascade,
  kind        text not null check (kind in ('issue','use','scrap','return','writeoff')),
  qty         numeric(14,3) not null default 0,    -- change of what he holds
  scrap       numeric(14,3) not null default 0,    -- change of the scrap he owes
  used        numeric(14,3),                       -- use: the whole quantity used on the order (custody + store)
  scrap_open  numeric(14,3) not null default 0,    -- use: scrap still owed for this use
  scrap_due   date,
  unit_price  numeric(12,2),
  store_id    uuid references public.wo_stores(id) on delete set null,
  wo_id       uuid references public.work_orders(id) on delete set null,
  wo_code     text,
  school      text,
  building_id text,
  ticket_ref  text,
  req_id      uuid,
  ref         text,
  note        text,
  by_id       uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name     text
);
create index if not exists wo_custody_moves_h_idx on public.wo_custody_moves (holder, at desc);
create index if not exists wo_custody_moves_m_idx on public.wo_custody_moves (material_id, at desc);
create index if not exists wo_custody_moves_wo_idx on public.wo_custody_moves (wo_id);
create sequence if not exists public.wo_issue_req_seq;
create table if not exists public.wo_issue_requests (
  id                uuid primary key default gen_random_uuid(),
  code              text unique not null default ('IR-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_issue_req_seq')::text, 4, '0')),
  at                timestamptz not null default now(),
  holder            uuid not null references public.profiles(id) on delete cascade,
  holder_name       text,
  requested_by      uuid default auth.uid() references public.profiles(id) on delete set null,
  requested_by_name text,
  source            text not null check (source in ('wo','ticket','direct')),
  wo_id             uuid references public.work_orders(id) on delete set null,
  wo_code           text,
  ticket_ref        text,
  school            text,
  store_id          uuid references public.wo_stores(id) on delete set null,
  lines             jsonb not null default '[]',      -- [{material_id, qty, issued}]
  status            text not null default 'requested' check (status in ('requested','partial','issued','received','rejected','cancelled')),
  note              text,
  response          text,
  issued_by_name    text,
  issued_at         timestamptz,
  received_at       timestamptz
);
create index if not exists wo_issue_requests_h_idx on public.wo_issue_requests (holder, at desc);
create index if not exists wo_issue_requests_s_idx on public.wo_issue_requests (status, at desc);
create table if not exists public.wo_custody_counts (
  id          uuid primary key default gen_random_uuid(),
  at          timestamptz not null default now(),
  month       text not null,
  holder      uuid not null references public.profiles(id) on delete cascade,
  holder_name text,
  lines       jsonb not null default '[]',            -- [{material_id, book, counted, scrap_book}]
  diff_value  numeric(14,2) not null default 0,
  by_name     text,
  status      text not null default 'open' check (status in ('open','signed','disputed')),
  signed_at   timestamptz,
  sign_note   text
);
create index if not exists wo_custody_counts_h_idx on public.wo_custody_counts (holder, at desc);
alter table public.wo_custody enable row level security;
alter table public.wo_custody_moves enable row level security;
alter table public.wo_issue_requests enable row level security;
alter table public.wo_custody_counts enable row level security;
drop policy if exists p_cus_read on public.wo_custody;
create policy p_cus_read on public.wo_custody for select using (public.fm_wh_sees_holder(holder));
drop policy if exists p_cusm_read on public.wo_custody_moves;
create policy p_cusm_read on public.wo_custody_moves for select using (public.fm_wh_sees_holder(holder));
drop policy if exists p_ireq_read on public.wo_issue_requests;
create policy p_ireq_read on public.wo_issue_requests for select using (requested_by = auth.uid() or public.fm_wh_sees_holder(holder));
drop policy if exists p_ccnt_read on public.wo_custody_counts;
create policy p_ccnt_read on public.wo_custody_counts for select using (public.fm_wh_sees_holder(holder));
revoke insert, update, delete on public.wo_custody, public.wo_custody_moves, public.wo_issue_requests, public.wo_custody_counts from anon, authenticated;

-- people the caller may see or ask parts for (names come from here: profiles are private)
create or replace function public.fm_wh_people() returns table(id uuid, name text, title text, regions text[], direct boolean, boss uuid)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.full_name, p.email), public.fm_posx(p.role, p.job_title), p.regions, public.fm_wh_may_direct(p.id), p.reports_to from public.profiles p
   where p.active and public.fm_posx(p.role, p.job_title) in ('supervisor','contractor','area_engineer','storekeeper') and public.fm_wh_sees_holder(p.id)
   order by public.fm_prank(public.fm_posx(p.role, p.job_title)) desc, p.full_name $$;

-- custody value of a person (what he holds + the scrap he owes, at the item price)
create or replace function public.fm_custody_value(h uuid) returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum((greatest(c.qty,0) + c.scrap) * coalesce(m.price,0)),0) from public.wo_custody c join public.wo_materials m on m.id = c.material_id where c.holder = h $$;

-- ask for parts: p {holder?, source wo | ticket | direct, wo_id, ticket_ref, school, store_id, note, lines:[{material_id, qty}]}
create or replace function public.fm_issue_req_new(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); h uuid := coalesce(nullif(p->>'holder','')::uuid, auth.uid()); src text := coalesce(nullif(p->>'source',''),'direct');
  w public.work_orders; pos text := public.fm_my_pos(); st uuid := nullif(p->>'store_id','')::uuid; x jsonb; L jsonb := '[]'; m public.wo_materials; q numeric;
  hr text; r public.wo_issue_requests;
begin
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

-- act on a request: issue (storekeeper: p {store_id?, lines:[{material_id, qty}]} — empty = all that remains), reject (storekeeper,
-- p {note}), cancel (who asked / the holder, while nothing was issued), receive (the holder confirms he got it)
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
    if auth.uid() <> r.holder or r.status not in ('issued','partial') or r.received_at is not null then raise exception 'not allowed'; end if;
    update public.wo_issue_requests set received_at = now(), status = case when r.status = 'issued' then 'received' else r.status end where id = p_id;
    return 'received';
  end if;
  raise exception 'invalid action';
end $$;

-- the storekeeper receives back from a person: p {store_id, holder, note, lines:[{material_id, kind: return | scrap, qty}]}
-- return = unused parts back to the store; scrap = the scrap of used parts (clears what he owes, oldest use first)
create or replace function public.fm_custody_return(p jsonb) returns int language plpgsql security definer set search_path = public as $$
declare st uuid := nullif(p->>'store_id','')::uuid; h uuid := nullif(p->>'holder','')::uuid; x jsonb; q numeric; c public.wo_custody; m uuid; k text;
  hn text := (select coalesce(full_name, email) from public.profiles where id = nullif(p->>'holder','')::uuid); nm text := public.fm_me_name(); n int := 0; u record; t numeric; lft numeric;
begin
  if auth.uid() is null or not public.fm_wh_keeper(st) then raise exception 'storekeeper only'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    m := nullif(x->>'material_id','')::uuid; k := x->>'kind'; q := nullif(x->>'qty','')::numeric;
    if q is null or q <= 0 or k not in ('return','scrap') then raise exception 'invalid line'; end if;
    select * into c from public.wo_custody where holder = h and material_id = m for update;
    if not found then raise exception 'not in custody'; end if;
    if k = 'return' then
      if q > c.qty then raise exception 'more than held'; end if;
      update public.wo_custody set qty = qty - q, updated_at = now() where holder = h and material_id = m;
      insert into public.wo_stock(store_id, material_id, qty) values (st, m, q) on conflict (store_id, material_id) do update set qty = public.wo_stock.qty + q, updated_at = now();
      insert into public.wo_stock_moves(store_id, material_id, qty, kind, unit_price, holder, holder_name, note, by_id, by_name)
      values (st, m, q, 'return', (select price from public.wo_materials where id = m), h, hn, left(nullif(btrim(coalesce(p->>'note','')),''),300), auth.uid(), nm);
      insert into public.wo_custody_moves(holder, holder_name, material_id, kind, qty, unit_price, store_id, note, by_name)
      values (h, hn, m, 'return', -q, (select price from public.wo_materials where id = m), st, left(nullif(btrim(coalesce(p->>'note','')),''),300), nm);
    else
      if q > c.scrap then raise exception 'more than owed'; end if;
      update public.wo_custody set scrap = scrap - q, updated_at = now() where holder = h and material_id = m;
      lft := q;
      for u in select id, scrap_open from public.wo_custody_moves where holder = h and material_id = m and kind = 'use' and scrap_open > 0 order by at, id for update loop
        t := least(lft, u.scrap_open); update public.wo_custody_moves set scrap_open = scrap_open - t where id = u.id; lft := lft - t; exit when lft <= 0;
      end loop;
      insert into public.wo_stock(store_id, material_id) values (st, m) on conflict do nothing;
      update public.wo_stock set scrap_qty = scrap_qty + q, updated_at = now() where store_id = st and material_id = m;
      insert into public.wo_stock_moves(store_id, material_id, qty, kind, holder, holder_name, note, by_id, by_name)
      values (st, m, q, 'scrap', h, hn, left(nullif(btrim(coalesce(p->>'note','')),''),300), auth.uid(), nm);
      insert into public.wo_custody_moves(holder, holder_name, material_id, kind, scrap, store_id, note, by_name)
      values (h, hn, m, 'scrap', -q, st, left(nullif(btrim(coalesce(p->>'note','')),''),300), nm);
    end if;
    n := n + 1;
  end loop;
  return n;
end $$;
-- settle a custody difference (lost / damaged without scrap): system admin, project / operations manager, with a reason.
-- p {holder, reason, lines:[{material_id, qty, scrap}]}
create or replace function public.fm_custody_writeoff(p jsonb) returns int language plpgsql security definer set search_path = public as $$
declare h uuid := nullif(p->>'holder','')::uuid; x jsonb; q numeric; s numeric; m uuid; n int := 0; u record; t numeric; lft numeric;
  hn text := (select coalesce(full_name, email) from public.profiles where id = nullif(p->>'holder','')::uuid);
begin
  if auth.uid() is null or not public.fm_wh_admin() then raise exception 'not allowed'; end if;
  if btrim(coalesce(p->>'reason','')) = '' then raise exception 'reason required'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    m := nullif(x->>'material_id','')::uuid; q := coalesce(nullif(x->>'qty','')::numeric,0); s := coalesce(nullif(x->>'scrap','')::numeric,0);
    if q = 0 and s = 0 then continue; end if;
    if s < 0 then raise exception 'invalid line'; end if;
    insert into public.wo_custody(holder, material_id) values (h, m) on conflict do nothing;
    update public.wo_custody set qty = qty - q, scrap = greatest(0, scrap - s), updated_at = now() where holder = h and material_id = m;
    lft := s;
    if lft > 0 then
      for u in select id, scrap_open from public.wo_custody_moves where holder = h and material_id = m and kind = 'use' and scrap_open > 0 order by at, id for update loop
        t := least(lft, u.scrap_open); update public.wo_custody_moves set scrap_open = scrap_open - t where id = u.id; lft := lft - t; exit when lft <= 0;
      end loop;
    end if;
    insert into public.wo_custody_moves(holder, holder_name, material_id, kind, qty, scrap, unit_price, note, by_name)
    values (h, hn, m, 'writeoff', -q, -s, (select price from public.wo_materials where id = m), left(btrim(p->>'reason'),300), public.fm_me_name());
    n := n + 1;
  end loop;
  return n;
end $$;
-- monthly custody count: the storekeeper (or the person's manager) records what was counted, the holder signs it.
-- p {holder, month 'YYYY-MM', lines:[{material_id, counted}]}
create or replace function public.fm_custody_count_new(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare h uuid := nullif(p->>'holder','')::uuid; x jsonb; L jsonb := '[]'; c public.wo_custody; v numeric := 0; v_id uuid; cn numeric;
begin
  if auth.uid() is null or h is null or h = auth.uid() or not (public.fm_my_pos() = 'storekeeper' or public.fm_wh_admin() or public.fm_is_under(h, auth.uid())) then raise exception 'not allowed'; end if;
  if coalesce(p->>'month','') !~ '^\d{4}-\d{2}$' then raise exception 'invalid month'; end if;
  for c in select * from public.wo_custody where holder = h and (qty <> 0 or scrap <> 0) loop
    x := (select e from jsonb_array_elements(coalesce(p->'lines','[]')) t(e) where e->>'material_id' = c.material_id::text limit 1);
    cn := coalesce(nullif(x->>'counted','')::numeric, c.qty);
    if cn < 0 then raise exception 'invalid count'; end if;
    L := L || jsonb_build_object('material_id', c.material_id, 'book', c.qty, 'counted', cn, 'scrap_book', c.scrap);
    v := v + (cn - c.qty) * coalesce((select price from public.wo_materials where id = c.material_id),0);
  end loop;
  insert into public.wo_custody_counts(month, holder, holder_name, lines, diff_value, by_name)
  values (p->>'month', h, (select coalesce(full_name, email) from public.profiles where id = h), L, round(v,2), public.fm_me_name()) returning wo_custody_counts.id into v_id;
  return v_id;
end $$;
create or replace function public.fm_custody_count_sign(p_id uuid, p_agree boolean, p_note text) returns text language plpgsql security definer set search_path = public as $$
begin
  update public.wo_custody_counts set status = case when p_agree then 'signed' else 'disputed' end, signed_at = now(), sign_note = left(nullif(btrim(coalesce(p_note,'')),''),500)
   where id = p_id and holder = auth.uid() and status = 'open';
  if not found then raise exception 'not allowed'; end if;
  return case when p_agree then 'signed' else 'disputed' end;
end $$;
-- scrap not returned in time, for the people the caller sees. level 1 = late (the holder), 2 = his manager, 3 = the project
create or replace function public.fm_custody_overdue() returns table(holder uuid, holder_name text, material_id uuid, material text, open numeric, due date, days int, level int, wo_code text, school text)
language sql stable security definer set search_path = public as $$
  select u.holder, u.holder_name, u.material_id, m.name, u.scrap_open, u.scrap_due, (current_date - u.scrap_due)::int,
    case when (current_date - u.scrap_due) >= coalesce((public.fm_setting('stock_rules')->'esc_days'->>1)::int, 14) then 3
         when (current_date - u.scrap_due) >= coalesce((public.fm_setting('stock_rules')->'esc_days'->>0)::int, 7) then 2 else 1 end,
    u.wo_code, u.school
  from public.wo_custody_moves u join public.wo_materials m on m.id = u.material_id
  where u.kind = 'use' and u.scrap_open > 0 and u.scrap_due < current_date and public.fm_wh_sees_holder(u.holder)
  order by u.scrap_due $$;

-- a closed (approved) work order: its store materials come first from the assignee's custody, the rest from the region's
-- default store (as in V173). Items that need their scrap returned are owed by the assignee until the storekeeper gets it.
create or replace function public.fm_wo_stock_out() returns trigger language plpgsql security definer set search_path = public as $$
declare st uuid; x record; c numeric; sc boolean; days int := coalesce((public.fm_setting('stock_rules')->>'scrap_days')::int, 7);
  hn text := (select coalesce(full_name, email) from public.profiles where id = new.assignee); nm text := (select coalesce(full_name, email) from public.profiles where id = auth.uid());
begin
  if new.status <> 'closed' or old.status = 'closed' then return new; end if;
  if not public.fm_mod('wh') then return new; end if;     -- V181: the warehouse part is off
  if exists(select 1 from public.wo_stock_moves where wo_id = new.id and kind = 'out') or exists(select 1 from public.wo_custody_moves where wo_id = new.id and kind = 'use') then return new; end if;
  st := public.fm_stock_store_for(new.region);
  for x in
    select (mt.m->>'id')::uuid mid, sum(coalesce(nullif(mt.m->>'q','')::numeric,0)) q, max(nullif(mt.m->>'price','')::numeric) pr, string_agg(distinct it.e->>'t', ' • ') items
      from jsonb_array_elements(case when jsonb_typeof(new.checklist) = 'array' then new.checklist else '[]' end) it(e)
      cross join lateral jsonb_array_elements(case when jsonb_typeof(it.e->'materials') = 'array' then it.e->'materials' else '[]' end) mt(m)
     where jsonb_typeof(mt.m) = 'object' and coalesce(mt.m->>'src','store') = 'store'
       and coalesce(mt.m->>'id','') ~ '^[0-9a-fA-F-]{36}$' and exists(select 1 from public.wo_materials w where w.id = (mt.m->>'id')::uuid)
     group by 1 having sum(coalesce(nullif(mt.m->>'q','')::numeric,0)) > 0
  loop
    c := 0;
    sc := coalesce((select scrap_return from public.wo_materials where id = x.mid), false);
    if new.assignee is not null then
      select greatest(0, least(qty, x.q)) into c from public.wo_custody where holder = new.assignee and material_id = x.mid for update;
      c := coalesce(c, 0);
      if c > 0 or sc then
        insert into public.wo_custody(holder, material_id) values (new.assignee, x.mid) on conflict do nothing;
        update public.wo_custody set qty = qty - c, scrap = scrap + case when sc then x.q else 0 end, updated_at = now() where holder = new.assignee and material_id = x.mid;
        insert into public.wo_custody_moves(holder, holder_name, material_id, kind, qty, scrap, used, scrap_open, scrap_due, unit_price, store_id, wo_id, wo_code, school, building_id, ref, by_id, by_name)
        values (new.assignee, hn, x.mid, 'use', -c, case when sc then x.q else 0 end, x.q, case when sc then x.q else 0 end, case when sc then current_date + days end,
                x.pr, case when x.q > c then st end, new.id, new.code, new.school, new.building_id, left(x.items,300), auth.uid(), nm);
      end if;
    end if;
    if x.q > c and st is not null then
      insert into public.wo_stock(store_id, material_id, qty) values (st, x.mid, -(x.q - c))
        on conflict (store_id, material_id) do update set qty = public.wo_stock.qty - (x.q - c), updated_at = now();
      insert into public.wo_stock_moves(store_id, material_id, qty, kind, unit_price, wo_id, wo_code, school, item, holder, holder_name, by_id, by_name)
      values (st, x.mid, -(x.q - c), 'out', x.pr, new.id, new.code, new.school, left(x.items,300), new.assignee, hn, auth.uid(), nm);
    end if;
  end loop;
  return new;
end $$;

-- ---- purchase requests, receipts with the price difference, serial numbers and warranty ----
create sequence if not exists public.wo_po_seq;
create table if not exists public.wo_purchase_requests (
  id                uuid primary key default gen_random_uuid(),
  code              text unique not null default ('PR-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_po_seq')::text, 4, '0')),
  at                timestamptz not null default now(),
  store_id          uuid not null references public.wo_stores(id) on delete cascade,
  supplier_id       uuid references public.wo_suppliers(id) on delete set null,
  supplier_name     text,
  lines             jsonb not null default '[]',      -- [{material_id, qty, price, recv}]
  total             numeric(14,2) not null default 0,
  status            text not null default 'requested' check (status in ('requested','approved','rejected','cancelled','partial','received')),
  note              text,
  response          text,
  requested_by      uuid default auth.uid() references public.profiles(id) on delete set null,
  requested_by_name text,
  approved_by_name  text,
  approved_at       timestamptz,
  received_at       timestamptz
);
create index if not exists wo_purchase_requests_idx on public.wo_purchase_requests (status, at desc);
create table if not exists public.wo_serials (
  id             uuid primary key default gen_random_uuid(),
  material_id    uuid not null references public.wo_materials(id) on delete cascade,
  serial         text not null,
  supplier_id    uuid references public.wo_suppliers(id) on delete set null,
  supplier_name  text,
  po_code        text,
  invoice_no     text,
  received_at    date,
  warranty_until date,
  status         text not null default 'store' check (status in ('store','custody','installed','claim','returned','scrapped')),
  holder_name    text,
  school         text,
  building_id    text,
  wo_code        text,
  note           text,
  updated_at     timestamptz not null default now(),
  unique (material_id, serial)
);
alter table public.wo_purchase_requests enable row level security;
alter table public.wo_serials enable row level security;
drop policy if exists p_po_read on public.wo_purchase_requests;
create policy p_po_read on public.wo_purchase_requests for select using (public.fm_role() in ('admin','manager','staff','engineer','viewer'));
drop policy if exists p_ser_read on public.wo_serials;
create policy p_ser_read on public.wo_serials for select using (public.fm_role() in ('admin','manager','staff','engineer','viewer'));
revoke insert, update, delete on public.wo_purchase_requests, public.wo_serials from anon, authenticated;

-- the agreed price of an item from a supplier: his approved price, else the item's approved price
create or replace function public.fm_wh_agreed(p_mat uuid, p_sup uuid) returns numeric language sql stable security definer set search_path = public as $$
  select coalesce((select price from public.wo_supplier_prices where material_id = p_mat and supplier_id = p_sup and price is not null),
                  (select price from public.wo_materials where id = p_mat)) $$;
-- one receipt line into a store (used by the purchase receipt and the Excel import); returns the price difference in %
create or replace function public.fm_wh_receive_line(p_store uuid, p_mat uuid, p_qty numeric, p_price numeric, p_sup uuid, p_sup_name text, p_inv text, p_at timestamptz, p_ref text, p_note text) returns numeric
language plpgsql security definer set search_path = public as $$
declare ag numeric := public.fm_wh_agreed(p_mat, p_sup); v numeric;
begin
  if p_qty is null or p_qty <= 0 or p_qty > 1000000 then raise exception 'invalid qty'; end if;
  v := case when ag > 0 and p_price is not null then round((p_price - ag) / ag * 100, 1) end;
  insert into public.wo_stock(store_id, material_id, qty) values (p_store, p_mat, p_qty)
    on conflict (store_id, material_id) do update set qty = public.wo_stock.qty + p_qty, updated_at = now();
  insert into public.wo_stock_moves(at, store_id, material_id, qty, kind, unit_price, supplier, supplier_id, invoice_no, ref, variance, note, by_id, by_name)
  values (coalesce(p_at, now()), p_store, p_mat, p_qty, 'in', p_price, left(p_sup_name,200), p_sup, left(nullif(btrim(coalesce(p_inv,'')),''),80), p_ref, v, left(p_note,300), auth.uid(), public.fm_me_name());
  return v;
end $$;
revoke all on function public.fm_wh_receive_line(uuid, uuid, numeric, numeric, uuid, text, text, timestamptz, text, text) from public, anon, authenticated;
revoke all on function public.fm_appr_step(uuid, uuid, text, text) from public, anon, authenticated;

-- a purchase request: p {store_id, supplier_id, note, lines:[{material_id, qty, price}]} (price empty = the agreed price)
create or replace function public.fm_po_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; s uuid := nullif(p->>'supplier_id','')::uuid; x jsonb; L jsonb := '[]'; t numeric := 0; q numeric; pr numeric; r public.wo_purchase_requests;
begin
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
-- approve / reject (managers within the spend limits: area manager up to spend_limits.area_manager in his regions, operations
-- manager up to spend_limits.ops_manager, project manager / system admin any amount), cancel (who asked), receive
-- (storekeeper / store manager: p {invoice_no, at, lines:[{material_id, qty, price, serials:[…]}]})
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
    if not (public.fm_wh_keeper(st.id) or public.fm_stock_can(st.region)) then raise exception 'not allowed'; end if;
    if r.status not in ('approved','partial') then raise exception 'invalid status'; end if;
    at_ := least(now(), coalesce(nullif(p->>'at','')::date + time '12:00', now()));
    for x in select * from jsonb_array_elements(r.lines) loop
      g := (select e from jsonb_array_elements(coalesce(p->'lines','[]')) t(e) where e->>'material_id' = x->>'material_id' limit 1);
      q := coalesce(nullif(g->>'qty','')::numeric, 0);
      if q < 0 then raise exception 'invalid qty'; end if;
      if q > 0 then
        pr := coalesce(nullif(g->>'price','')::numeric, (x->>'price')::numeric);
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
-- a serial number: p {id?, material_id, serial, supplier_id, received_at, warranty_until, status, holder_name, school, building_id, wo_code, note}
create or replace function public.fm_serial_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare v uuid := nullif(p->>'id','')::uuid;
begin
  if auth.uid() is null or not public.fm_wh_edit() then raise exception 'not allowed'; end if;
  if v is null then
    if btrim(coalesce(p->>'serial','')) = '' then raise exception 'serial required'; end if;
    insert into public.wo_serials(material_id, serial) values ((p->>'material_id')::uuid, left(btrim(p->>'serial'),80)) returning id into v;
  end if;
  update public.wo_serials set
    supplier_id = case when p ? 'supplier_id' then nullif(p->>'supplier_id','')::uuid else supplier_id end,
    supplier_name = case when p ? 'supplier_id' then (select name from public.wo_suppliers where id = nullif(p->>'supplier_id','')::uuid) else supplier_name end,
    received_at = case when p ? 'received_at' then nullif(p->>'received_at','')::date else received_at end,
    warranty_until = case when p ? 'warranty_until' then nullif(p->>'warranty_until','')::date else warranty_until end,
    status = coalesce(nullif(p->>'status',''), status), holder_name = case when p ? 'holder_name' then left(nullif(btrim(coalesce(p->>'holder_name','')),''),120) else holder_name end,
    school = case when p ? 'school' then left(nullif(btrim(coalesce(p->>'school','')),''),200) else school end,
    building_id = case when p ? 'building_id' then left(nullif(btrim(coalesce(p->>'building_id','')),''),40) else building_id end,
    wo_code = case when p ? 'wo_code' then left(nullif(btrim(coalesce(p->>'wo_code','')),''),40) else wo_code end,
    note = case when p ? 'note' then left(nullif(btrim(coalesce(p->>'note','')),''),500) else note end, updated_at = now()
   where id = v;
  return v;
end $$;

-- the full materials list from Excel: p {store_id?, supplier?, invoice_no?, at?, rows:[{code, name, category, unit, price, specs, notes,
-- scrap_return, warranty_months, supplier, sup_price, qty}]}. New items and new prices wait for approval; a quantity is a receipt
-- into the store on that date with that supplier (a later file adds a new receipt, nothing is wiped).
create or replace function public.fm_wh_import(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; x jsonb; m public.wo_materials; mid uuid; sid uuid; sn text; q numeric; pr numeric; sp numeric; at_ timestamptz;
  n_new int := 0; n_upd int := 0; n_pr int := 0; n_in int := 0; n_var int := 0; v numeric; tol numeric := coalesce((public.fm_setting('stock_rules')->>'variance_pct')::numeric, 5);
begin
  if auth.uid() is null or not public.fm_wh_edit() then raise exception 'not allowed'; end if;
  if nullif(p->>'store_id','') is not null then
    select * into st from public.wo_stores where id = (p->>'store_id')::uuid and active;
    if not found or not (public.fm_wh_keeper(st.id) or public.fm_stock_can(st.region)) then raise exception 'not allowed'; end if;
  end if;
  at_ := least(now(), coalesce(nullif(p->>'at','')::date + time '12:00', now()));
  if jsonb_array_length(coalesce(p->'rows','[]')) > 3000 then raise exception 'too many rows'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'rows','[]')) loop
    if btrim(coalesce(x->>'name','')) = '' and btrim(coalesce(x->>'code','')) = '' then continue; end if;
    mid := null;
    if btrim(coalesce(x->>'code','')) <> '' then select id into mid from public.wo_materials where lower(code) = lower(btrim(x->>'code')) limit 1; end if;
    if mid is null and btrim(coalesce(x->>'name','')) <> '' then select id into mid from public.wo_materials where lower(name) = lower(btrim(x->>'name')) limit 1; end if;
    pr := nullif(x->>'price','')::numeric;
    if mid is null then
      if btrim(coalesce(x->>'name','')) = '' then continue; end if;
      mid := public.fm_mat_save(jsonb_strip_nulls(jsonb_build_object('code', nullif(btrim(coalesce(x->>'code','')),''), 'name', x->>'name', 'unit', x->>'unit', 'category', x->>'category',
        'price', pr, 'specs', x->>'specs', 'notes', x->>'notes', 'scrap_return', (x->>'scrap_return')::boolean, 'warranty_months', nullif(x->>'warranty_months','')::int)));
      n_new := n_new + 1;
    else
      select * into m from public.wo_materials where id = mid;
      perform public.fm_mat_save(jsonb_strip_nulls(jsonb_build_object('id', m.id, 'name', m.name,
        'unit', nullif(btrim(coalesce(x->>'unit','')),''), 'category', nullif(btrim(coalesce(x->>'category','')),''), 'specs', nullif(btrim(coalesce(x->>'specs','')),''),
        'notes', nullif(btrim(coalesce(x->>'notes','')),''), 'scrap_return', (x->>'scrap_return')::boolean, 'warranty_months', nullif(x->>'warranty_months','')::int, 'price', pr)));
      n_upd := n_upd + 1;
      if pr is not null and pr is distinct from coalesce(m.price_new, m.price) then n_pr := n_pr + 1; end if;
    end if;
    sn := nullif(btrim(coalesce(x->>'supplier', p->>'supplier', '')),''); sid := null;
    if sn is not null then
      select id into sid from public.wo_suppliers where lower(name) = lower(sn);
      if sid is null then sid := public.fm_supplier_save(jsonb_build_object('name', sn)); end if;
      sp := coalesce(nullif(x->>'sup_price','')::numeric, pr);
      if sp is not null then perform public.fm_supplier_price_save(jsonb_build_object('supplier_id', sid, 'material_id', mid, 'price', sp)); end if;
    end if;
    q := nullif(x->>'qty','')::numeric;
    if q is not null and q > 0 then
      if st.id is null then raise exception 'store required'; end if;
      v := public.fm_wh_receive_line(st.id, mid, q, coalesce(nullif(x->>'sup_price','')::numeric, pr), sid, sn, coalesce(x->>'invoice_no', p->>'invoice_no'), at_, 'Excel', null);
      n_in := n_in + 1; if abs(coalesce(v,0)) > tol then n_var := n_var + 1; end if;
    end if;
  end loop;
  return jsonb_build_object('new', n_new, 'updated', n_upd, 'prices', n_pr, 'received', n_in, 'variance', n_var);
end $$;

revoke all on function public.fm_mat_save(jsonb), public.fm_mat_delete(uuid), public.fm_mat_photo(uuid, text, uuid), public.fm_mat_approve(text, jsonb, text, text),
  public.fm_supplier_save(jsonb), public.fm_supplier_price_save(jsonb), public.fm_stock_store_keeper(uuid, uuid), public.fm_wh_people(),
  public.fm_issue_req_new(jsonb), public.fm_issue_req_act(uuid, text, jsonb), public.fm_custody_return(jsonb), public.fm_custody_writeoff(jsonb),
  public.fm_custody_count_new(jsonb), public.fm_custody_count_sign(uuid, boolean, text), public.fm_custody_overdue(), public.fm_custody_value(uuid),
  public.fm_po_save(jsonb), public.fm_po_act(uuid, text, jsonb), public.fm_serial_save(jsonb), public.fm_wh_import(jsonb), public.fm_mat_code() from public, anon;
grant execute on function public.fm_mat_save(jsonb), public.fm_mat_delete(uuid), public.fm_mat_photo(uuid, text, uuid), public.fm_mat_approve(text, jsonb, text, text),
  public.fm_supplier_save(jsonb), public.fm_supplier_price_save(jsonb), public.fm_stock_store_keeper(uuid, uuid), public.fm_wh_people(),
  public.fm_issue_req_new(jsonb), public.fm_issue_req_act(uuid, text, jsonb), public.fm_custody_return(jsonb), public.fm_custody_writeoff(jsonb),
  public.fm_custody_count_new(jsonb), public.fm_custody_count_sign(uuid, boolean, text), public.fm_custody_overdue(), public.fm_custody_value(uuid),
  public.fm_po_save(jsonb), public.fm_po_act(uuid, text, jsonb), public.fm_serial_save(jsonb), public.fm_wh_import(jsonb) to authenticated;
revoke all on function public.fm_mat_code() from authenticated;

-- ---------- 25) parts of the platform sold separately (V181) ----------
-- fm_plan.modules = the parts this company bought: {"tickets": null, "wo": null, "wh": "2026-11-30", …} (a date = until then,
-- e.g. a trial; null = for the whole subscription). The column empty (null) = every part, as before V181 — so a company
-- without a modules list and the single-company installation keep everything. Keys: tickets (البلاغات والـ SLA), wo (أوامر
-- العمل), wh (المستودعات وقطع الغيار), eng (التواصل مع المدارس والرضا), portal (بوابة مدير المدرسة), costs (تكاليف المباني), bill (V184 مستخلصات المقاولين);
-- «core» (users, school DB, settings) is always on. The activation code carries the list (key m); a code without it keeps
-- the current list. A part that is off: its pages disappear and the database refuses new rows in its tables (the data stays
-- and comes back when the part is bought again).
alter table public.fm_plan add column if not exists modules jsonb;
create or replace function public.fm_mod(k text) returns boolean language sql stable security definer set search_path = public as $$
  select k = 'core' or coalesce((select p.modules is null or jsonb_typeof(p.modules) <> 'object'
      or (p.modules ? k and (jsonb_typeof(p.modules->k) = 'null' or current_date <= (p.modules->>k)::date))
    from public.fm_plan p where p.id = 1), true) $$;
create or replace function public.fm_mods_on() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(k), '[]') from unnest(array['tickets','wo','wh','eng','portal','costs']) k where public.fm_mod(k) $$;
create or replace function public.fm_plan_info() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('company', p.company, 'plan', p.plan, 'schools_limit', p.schools_limit, 'active_until', p.active_until,
      'grace_days', p.grace_days, 'days_left', p.active_until - current_date, 'activated_at', p.activated_at, 'modules', p.modules, 'on', public.fm_mods_on(),
      'state', case when p.active_until is null then 'unlimited' when current_date <= p.active_until - 15 then 'ok'
                    when current_date <= p.active_until then 'warn' when current_date <= p.active_until + p.grace_days then 'grace' else 'expired' end,
      'schools', (select case when jsonb_typeof(v) = 'array' then jsonb_array_length(v) when jsonb_typeof(v) = 'string' and left(v #>> '{}',1) = '['
                  then jsonb_array_length((v #>> '{}')::jsonb) else 0 end from (select value v from public.app_kv where key = 'fm_school_master_db_v1') x))
    from public.fm_plan p where p.id = 1), jsonb_build_object('state','none','on',public.fm_mods_on())) $$;
create or replace function public.fm_plan_activate(p_code text) returns jsonb language plpgsql security definer set search_path = public as $$
declare pl public.fm_plan; parts text[]; b64 text; j jsonb;
begin
  if not exists(select 1 from public.profiles where id = auth.uid() and active and role = 'admin') then raise exception 'not allowed'; end if;
  select * into pl from public.fm_plan where id = 1 for update;
  if not found then raise exception 'no subscription'; end if;
  parts := regexp_split_to_array(btrim(coalesce(p_code,'')), '\.');
  if array_length(parts,1) <> 2 or parts[2] !~ '^[0-9a-f]{64}$' then raise exception 'invalid code'; end if;
  if public.fm_plan_hmac(parts[1], pl.secret) <> parts[2] then raise exception 'invalid code'; end if;
  b64 := translate(parts[1], '-_', '+/'); b64 := b64 || repeat('=', (4 - length(b64) % 4) % 4);
  j := convert_from(decode(b64, 'base64'), 'utf8')::jsonb;
  if j->>'c' is distinct from pl.company then raise exception 'code for another company'; end if;
  if coalesce(j->>'n','') = '' or (j->>'n') = any(pl.nonces) then raise exception 'code already used'; end if;
  if j ? 'm' and jsonb_typeof(j->'m') <> 'object' then raise exception 'invalid code'; end if;
  update public.fm_plan set plan = coalesce(j->>'p', plan), schools_limit = coalesce((j->>'l')::int, schools_limit), active_until = (j->>'u')::date,
    modules = case when j ? 'm' then j->'m' else modules end,
    nonces = (array[j->>'n'] || nonces)[1:100], activated_at = now(), updated_at = now() where id = 1;
  return public.fm_plan_info();
end $$;
-- new rows in the tables of a part that is off are refused
create or replace function public.fm_mod_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if not public.fm_mod(tg_argv[0]) then raise exception 'module disabled: %', tg_argv[0]; end if;
  return new;
end $$;
do $$ declare x text[]; begin
  foreach x slice 1 in array array[['tickets','tickets'],['work_orders','wo'],['wo_schedules','wo'],['wo_issue_requests','wh'],['wo_purchase_requests','wh'],
      ['wo_stock_moves','wh'],['wo_custody_moves','wh'],['fm_eng_logs','eng'],['fm_school_links','portal'],['fm_school_requests','portal'],['fm_expenses','costs'],['fm_budgets','costs']] loop
    if to_regclass('public.' || x[1]) is not null then
      execute format('drop trigger if exists fm_mod_guard on public.%I', x[1]);
      execute format('create trigger fm_mod_guard before insert on public.%I for each row execute function public.fm_mod_guard(%L)', x[1], x[2]);
    end if;
  end loop;
end $$;
revoke all on function public.fm_mod_guard() from public, anon, authenticated;
revoke all on function public.fm_mod(text), public.fm_mods_on() from public, anon;
grant execute on function public.fm_mod(text), public.fm_mods_on() to authenticated;

-- ---------- 26) contractor bills — المستخلصات (V184) ----------
-- A contract (fm_contracts) holds the contractor (an account or just a name), its region, a fixed monthly amount, a price per
-- closed work order by type (rates), which materials are billed (none / purchases / all, with a markup), the retention and
-- VAT rates and the penalty cap. A bill (fm_bills, BL-YYYY-####) is one month of one contract: fm_bill_build proposes its
-- lines (fixed amount, the contractor's work orders closed in that month that no other bill holds, their materials), the
-- preparer edits them (additions, deductions, penalties), and it moves draft → submitted → reviewed → approved → paid
-- (returned with a note goes back to the preparer). A work order is billed once (fm_bill_wos). The server always
-- recomputes the totals: gross − deductions (penalties capped at penalty_cap_pct of gross) = net; VAT on net;
-- retention on net; total = net + VAT − retention.
-- Preparers: system admin, project / operations managers, accountant, area manager (his regions). Reviewers: area engineer /
-- area manager of the region, operations manager. Approvers: project / operations managers, system admin. Payment: accountant,
-- system admin. Readers: those plus the department manager, QA and the contractor himself (his own bills).
create sequence if not exists public.fm_contract_seq;
create table if not exists public.fm_contracts (
  id              uuid primary key default gen_random_uuid(),
  code            text unique not null default ('CT-' || lpad(nextval('public.fm_contract_seq')::text, 3, '0')),
  name            text not null,
  contractor_id   uuid references public.profiles(id) on delete set null,
  contractor_name text not null,
  region          text,
  start_date      date,
  end_date        date,
  monthly_fixed   numeric(14,2) not null default 0,
  rates           jsonb not null default '{}',          -- {preventive: 150, repair: 250, inspection: 100, handover: 300, visit: 0, task: 0, data: 0}
  mat_mode        text not null default 'buy' check (mat_mode in ('none','buy','all')),
  mat_markup      numeric(6,2) not null default 0,
  retention_pct   numeric(5,2) not null default 0,
  vat_pct         numeric(5,2) not null default 15,
  penalty_cap_pct numeric(5,2) not null default 10,
  notes           text,
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);
create sequence if not exists public.fm_bill_seq;
create table if not exists public.fm_bills (
  id              uuid primary key default gen_random_uuid(),
  code            text unique not null default ('BL-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.fm_bill_seq')::text, 4, '0')),
  contract_id     uuid not null references public.fm_contracts(id) on delete restrict,
  month           text not null check (month ~ '^\d{4}-\d{2}$'),
  lines           jsonb not null default '[]',          -- [{k: fixed | wo | mat | add | ded | pen, t, q, p, a, wo_id?, ref?}]
  gross           numeric(14,2) not null default 0,
  deductions      numeric(14,2) not null default 0,
  net             numeric(14,2) not null default 0,
  vat             numeric(14,2) not null default 0,
  retention       numeric(14,2) not null default 0,
  total           numeric(14,2) not null default 0,
  status          text not null default 'draft' check (status in ('draft','submitted','reviewed','approved','paid','returned','cancelled')),
  history         jsonb not null default '[]',
  note            text,
  pay_ref         text,
  created_by      uuid default auth.uid() references public.profiles(id) on delete set null,
  created_by_name text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  paid_at         timestamptz
);
create unique index if not exists fm_bills_month_uq on public.fm_bills (contract_id, month) where status <> 'cancelled';
create table if not exists public.fm_bill_wos (
  wo_id   uuid primary key references public.work_orders(id) on delete cascade,
  bill_id uuid not null references public.fm_bills(id) on delete cascade
);
alter table public.fm_contracts enable row level security;
alter table public.fm_bills enable row level security;
alter table public.fm_bill_wos enable row level security;
create or replace function public.fm_bill_can(p_kind text, p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(case p_kind
    when 'prep'    then public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager','accountant')
                        or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(p_region,'')))
    when 'review'  then public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','ops_manager')
                        or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_region_ok(coalesce(p_region,'')))
    when 'approve' then public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager')
    when 'pay'     then public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','accountant')
    when 'read'    then public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager','accountant','qa_manager')
                        or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_region_ok(coalesce(p_region,'')))
    when 'contract' then public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','accountant')
  end, false) $$;
drop policy if exists p_ct_read on public.fm_contracts;
create policy p_ct_read on public.fm_contracts for select using (public.fm_bill_can('read', region) or contractor_id = auth.uid());
drop policy if exists p_bl_read on public.fm_bills;
create policy p_bl_read on public.fm_bills for select using (exists(select 1 from public.fm_contracts c where c.id = contract_id and (public.fm_bill_can('read', c.region) or c.contractor_id = auth.uid())));
drop policy if exists p_blw_read on public.fm_bill_wos;
create policy p_blw_read on public.fm_bill_wos for select using (exists(select 1 from public.fm_bills b join public.fm_contracts c on c.id = b.contract_id where b.id = bill_id and public.fm_bill_can('read', c.region)));
revoke insert, update, delete on public.fm_contracts, public.fm_bills, public.fm_bill_wos from anon, authenticated;

-- the contractors (accounts with the contractor title) for the contract form
create or replace function public.fm_bill_contractors() returns table(id uuid, name text, regions text[]) language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.full_name, p.email), p.regions from public.profiles p
   where public.fm_bill_can('contract', null) and p.active and public.fm_posx(p.role, p.job_title) = 'contractor' order by 2 $$;
-- add or change a contract
create or replace function public.fm_contract_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id','')::uuid; cid uuid := nullif(p->>'contractor_id','')::uuid; cn text;
begin
  if auth.uid() is null or not public.fm_bill_can('contract', null) then raise exception 'not allowed'; end if;
  if btrim(coalesce(p->>'name','')) = '' then raise exception 'name required'; end if;
  cn := coalesce(nullif(btrim(coalesce(p->>'contractor_name','')),''), (select coalesce(full_name, email) from public.profiles where id = cid));
  if cn is null then raise exception 'contractor required'; end if;
  if v_id is null then insert into public.fm_contracts(name, contractor_name) values (left(btrim(p->>'name'),200), cn) returning id into v_id; end if;
  update public.fm_contracts set name = left(btrim(p->>'name'),200), contractor_id = cid, contractor_name = left(cn,200), region = nullif(btrim(coalesce(p->>'region','')),''),
    start_date = nullif(p->>'start_date','')::date, end_date = nullif(p->>'end_date','')::date, monthly_fixed = coalesce(nullif(p->>'monthly_fixed','')::numeric,0),
    rates = case when jsonb_typeof(p->'rates') = 'object' then p->'rates' else '{}' end, mat_mode = coalesce(nullif(p->>'mat_mode',''),'buy'),
    mat_markup = coalesce(nullif(p->>'mat_markup','')::numeric,0), retention_pct = coalesce(nullif(p->>'retention_pct','')::numeric,0),
    vat_pct = coalesce(nullif(p->>'vat_pct','')::numeric,15), penalty_cap_pct = coalesce(nullif(p->>'penalty_cap_pct','')::numeric,10),
    notes = left(nullif(btrim(coalesce(p->>'notes','')),''),1000), active = coalesce((p->>'active')::boolean,true)
   where id = v_id;
  return v_id;
end $$;
-- proposed lines of a month (nothing is saved)
create or replace function public.fm_bill_build(p_contract uuid, p_month text, p_bill uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare c public.fm_contracts; a timestamptz; b timestamptz; w record; m record; L jsonb := '[]'; pr numeric; fac numeric;
begin
  select * into c from public.fm_contracts where id = p_contract;
  if auth.uid() is null or not found or not public.fm_bill_can('prep', c.region) then raise exception 'not allowed'; end if;
  if coalesce(p_month,'') !~ '^\d{4}-\d{2}$' then raise exception 'invalid month'; end if;
  a := (p_month || '-01')::date::timestamp at time zone 'Asia/Riyadh'; b := ((p_month || '-01')::date + interval '1 month')::timestamp at time zone 'Asia/Riyadh';
  if c.monthly_fixed > 0 then L := L || jsonb_build_object('k','fixed','t','المبلغ الشهري الثابت — ' || c.name,'q',1,'p',c.monthly_fixed,'a',c.monthly_fixed); end if;
  fac := 1 + coalesce(c.mat_markup,0) / 100;
  for w in select * from public.work_orders o
            where o.status = 'closed' and coalesce(o.closed_at, o.updated_at) >= a and coalesce(o.closed_at, o.updated_at) < b
              and (o.assignee = c.contractor_id or (c.contractor_id is null and o.assignee_name = c.contractor_name))
              and (c.region is null or o.region = c.region)
              and not exists(select 1 from public.fm_bill_wos x where x.wo_id = o.id and x.bill_id is distinct from p_bill)
            order by coalesce(o.closed_at, o.updated_at) loop
    pr := coalesce(nullif(c.rates->>w.type,'')::numeric, 0);
    L := L || jsonb_build_object('k','wo','t', coalesce(w.code,'') || ' — ' || w.title,'q',1,'p',pr,'a',pr,'wo_id',w.id,'ref',w.code,'school',w.school);
    if c.mat_mode <> 'none' then
      for m in select mt.m->>'n' n, coalesce(nullif(mt.m->>'q','')::numeric,0) q, coalesce(nullif(mt.m->>'price','')::numeric,0) p, coalesce(mt.m->>'src','store') src
                 from jsonb_array_elements(case when jsonb_typeof(w.checklist) = 'array' then w.checklist else '[]' end) it(e)
                 cross join lateral jsonb_array_elements(case when jsonb_typeof(it.e->'materials') = 'array' then it.e->'materials' else '[]' end) mt(m)
                where jsonb_typeof(mt.m) = 'object' and (c.mat_mode = 'all' or coalesce(mt.m->>'src','store') = 'buy') loop
        if m.q > 0 and m.p > 0 then
          L := L || jsonb_build_object('k','mat','t', 'مواد: ' || coalesce(m.n,'') || ' (' || coalesce(w.code,'') || ')' || case when m.src = 'buy' then ' — شراء' else '' end,
                                       'q', m.q, 'p', round(m.p * fac, 2), 'a', round(m.q * m.p * fac, 2), 'ref', w.code);
        end if;
      end loop;
    end if;
  end loop;
  return L;
end $$;
-- totals from the lines (penalties capped)
create or replace function public.fm_bill_totals(p_lines jsonb, c public.fm_contracts) returns jsonb language plpgsql immutable as $$
declare g numeric := 0; d numeric := 0; pn numeric := 0; x jsonb; a numeric; net numeric; v numeric; r numeric; cap numeric;
begin
  for x in select * from jsonb_array_elements(coalesce(p_lines,'[]')) loop
    a := abs(coalesce(nullif(x->>'a','')::numeric, 0));
    if x->>'k' in ('fixed','wo','mat','add') then g := g + a; elsif x->>'k' = 'pen' then pn := pn + a; else d := d + a; end if;
  end loop;
  cap := case when coalesce(c.penalty_cap_pct,0) > 0 then g * c.penalty_cap_pct / 100 end;
  if cap is not null and pn > cap then pn := cap; end if;
  d := d + pn; net := g - d; v := round(net * coalesce(c.vat_pct,0) / 100, 2); r := round(net * coalesce(c.retention_pct,0) / 100, 2);
  return jsonb_build_object('gross', round(g,2), 'deductions', round(d,2), 'pen', round(pn,2), 'net', round(net,2), 'vat', v, 'retention', r, 'total', round(net + v - r, 2));
end $$;
-- save a draft (or a returned bill): p {id?, contract_id, month, lines, note}
create or replace function public.fm_bill_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id','')::uuid; bl public.fm_bills; c public.fm_contracts; L jsonb := '[]'; x jsonb; q numeric; pr numeric; t jsonb; w uuid; nm text := public.fm_me_name();
begin
  if v_id is not null then
    select * into bl from public.fm_bills where id = v_id for update;
    if not found or bl.status not in ('draft','returned') then raise exception 'invalid status'; end if;
    select * into c from public.fm_contracts where id = bl.contract_id;
  else
    select * into c from public.fm_contracts where id = nullif(p->>'contract_id','')::uuid and active;
    if not found then raise exception 'unknown contract'; end if;
  end if;
  if auth.uid() is null or not public.fm_bill_can('prep', c.region) then raise exception 'not allowed'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    if coalesce(x->>'k','') not in ('fixed','wo','mat','add','ded','pen') then raise exception 'invalid line'; end if;
    q := coalesce(nullif(x->>'q','')::numeric, 1); pr := coalesce(nullif(x->>'p','')::numeric, 0);
    if q < 0 or pr < 0 or pr > 100000000 then raise exception 'invalid line'; end if;
    L := L || (x - 'a' || jsonb_build_object('t', left(coalesce(x->>'t',''),300), 'q', q, 'p', pr, 'a', round(q * pr, 2)));
  end loop;
  if jsonb_array_length(L) > 2000 then raise exception 'too many lines'; end if;
  t := public.fm_bill_totals(L, c);
  if v_id is null then
    if coalesce(p->>'month','') !~ '^\d{4}-\d{2}$' then raise exception 'invalid month'; end if;
    if exists(select 1 from public.fm_bills where contract_id = c.id and month = p->>'month' and status <> 'cancelled') then raise exception 'bill exists for this month'; end if;
    insert into public.fm_bills(contract_id, month, created_by_name, history) values (c.id, p->>'month', nm,
      jsonb_build_array(jsonb_build_object('at', now(), 'by', nm, 'a', 'create'))) returning id into v_id;
  end if;
  update public.fm_bills set lines = L, gross = (t->>'gross')::numeric, deductions = (t->>'deductions')::numeric, net = (t->>'net')::numeric, vat = (t->>'vat')::numeric,
    retention = (t->>'retention')::numeric, total = (t->>'total')::numeric, note = left(nullif(btrim(coalesce(p->>'note','')),''),1000), updated_at = now() where id = v_id;
  delete from public.fm_bill_wos where bill_id = v_id;
  for x in select * from jsonb_array_elements(L) loop
    w := nullif(x->>'wo_id','')::uuid;
    if x->>'k' = 'wo' and w is not null then
      if exists(select 1 from public.fm_bill_wos where wo_id = w) then raise exception 'order already billed: %', x->>'ref'; end if;
      insert into public.fm_bill_wos(wo_id, bill_id) values (w, v_id);
    end if;
  end loop;
  return jsonb_build_object('id', v_id) || t;
end $$;
-- move a bill: submit | review | approve | return | pay | cancel
create or replace function public.fm_bill_act(p_id uuid, p_action text, p_note text) returns text language plpgsql security definer set search_path = public as $$
declare bl public.fm_bills; c public.fm_contracts; nx text; nm text := public.fm_me_name();
begin
  select * into bl from public.fm_bills where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  select * into c from public.fm_contracts where id = bl.contract_id;
  if p_action = 'submit' and bl.status in ('draft','returned') and public.fm_bill_can('prep', c.region) then nx := 'submitted';
  elsif p_action = 'review' and bl.status = 'submitted' and public.fm_bill_can('review', c.region) then nx := 'reviewed';
  elsif p_action = 'approve' and bl.status in ('submitted','reviewed') and public.fm_bill_can('approve', c.region) then nx := 'approved';
  elsif p_action = 'return' and bl.status in ('submitted','reviewed') and (public.fm_bill_can('review', c.region) or public.fm_bill_can('approve', c.region)) then
    if btrim(coalesce(p_note,'')) = '' then raise exception 'note required'; end if; nx := 'returned';
  elsif p_action = 'pay' and bl.status = 'approved' and public.fm_bill_can('pay', c.region) then nx := 'paid';
  elsif p_action = 'cancel' and bl.status in ('draft','returned') and public.fm_bill_can('prep', c.region) then nx := 'cancelled';
  else raise exception 'not allowed'; end if;
  update public.fm_bills set status = nx, updated_at = now(), paid_at = case when nx = 'paid' then now() else paid_at end,
    pay_ref = case when nx = 'paid' then left(nullif(btrim(coalesce(p_note,'')),''),120) else pay_ref end,
    history = history || jsonb_build_array(jsonb_build_object('at', now(), 'by', nm, 'a', p_action, 'note', nullif(btrim(coalesce(p_note,'')),'')))
   where id = p_id;
  if nx = 'cancelled' then delete from public.fm_bill_wos where bill_id = p_id; end if;
  return nx;
end $$;
revoke all on function public.fm_bill_totals(jsonb, public.fm_contracts) from public, anon, authenticated;
revoke all on function public.fm_bill_can(text, text), public.fm_bill_contractors(), public.fm_contract_save(jsonb), public.fm_bill_build(uuid, text, uuid),
  public.fm_bill_save(jsonb), public.fm_bill_act(uuid, text, text) from public, anon;
grant execute on function public.fm_bill_can(text, text), public.fm_bill_contractors(), public.fm_contract_save(jsonb), public.fm_bill_build(uuid, text, uuid),
  public.fm_bill_save(jsonb), public.fm_bill_act(uuid, text, text) to authenticated;
-- V184: the bills are a part sold separately (key «bill»)
create or replace function public.fm_mods_on() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(k), '[]') from unnest(array['tickets','wo','wh','eng','portal','costs','bill']) k where public.fm_mod(k) $$;
drop trigger if exists fm_mod_guard on public.fm_bills;
create trigger fm_mod_guard before insert on public.fm_bills for each row execute function public.fm_mod_guard('bill');

-- ---------- 27) daily usage sent to the platform owner (V185) ----------
-- fm_plan_usage() returns today's numbers of this company (no names, no data of schools or tickets) signed with the company
-- secret; the platform of a signed-in manager posts it once a day to the owner's control project (saas_ping), which checks
-- the signature. No subscription row = nothing to send.
create or replace function public.fm_plan_usage() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare pl public.fm_plan; j jsonb; t text;
begin
  if auth.uid() is null or public.fm_role() not in ('admin','manager','staff','engineer','viewer') then return null; end if;
  select * into pl from public.fm_plan where id = 1;
  if not found then return null; end if;
  j := jsonb_build_object('c', pl.company, 'd', current_date,
    'users', (select count(*) from public.profiles where active and role <> 'pending'),
    'active7', (select count(distinct user_id) from public.fm_activity where day > current_date - 7),
    'active30', (select count(distinct user_id) from public.fm_activity where day > current_date - 30),
    'field7', (select count(distinct user_id) from public.fm_activity where day > current_date - 7 and app = 'field'),
    'schools', coalesce((public.fm_plan_info()->>'schools')::int, 0), 'limit', pl.schools_limit,
    'tickets', (select count(*) from public.tickets),
    'wo30', (select count(*) from public.work_orders where created_at > now() - interval '30 days'),
    'wo_closed30', (select count(*) from public.work_orders where status = 'closed' and coalesce(closed_at, updated_at) > now() - interval '30 days'),
    'on', public.fm_mods_on(), 'until', pl.active_until);
  t := j::text;
  return jsonb_build_object('p', t, 's', public.fm_plan_hmac(t, pl.secret));
end $$;
revoke all on function public.fm_plan_usage() from public, anon;
grant execute on function public.fm_plan_usage() to authenticated;

-- ---------- 28) cost centers — مركز التكلفة (V186, part «cc») ----------
-- Revenue, cost and profit of the project per cost center and month, against a budget.
-- Centers: one per region (kind region) with sub-centers (kind dept) such as building maintenance, vehicles, admin, store.
-- A sub-center lists the automatic categories it receives (auto); what no sub-center of the region claims goes to the
-- region center. Costs are read where they already live:
--   sub   = contractor bills (fm_bills approved / paid; net before VAT), to the contract's cc_id or by its region
--   mat   = store materials used in closed work orders, buy = direct purchases of closed orders — both by building (bkey),
--           without what a contractor bill already charges (contract mat_mode buy / all)
--   exp   = building expenses (fm_expenses, once / monthly, split per school)
--   labour = the staff list (fm_cc_staff: salary + allowances + employer insurance %, prorated by the days in the month)
--   manual entries (fm_cc_entries): vehicles, fuel, housing, telecom, tools, rent, overhead, other, extra labour,
--   and revenue: contract (the monthly client invoice; otherwise the center's rev_monthly), extra works, client deductions.
-- Purchases into the store and issues to custody are not costs until the material is used in a closed order.
-- Who sees / enters what is set by the system admin in fm_settings.cc_perms {view, entry, budget, salaries, revenue}
-- (titles); the area manager / area engineer see only the centers of their regions. Tables have RLS on and no policies:
-- everything goes through the functions below.
insert into public.fm_settings(key, value) values ('cc_perms',
  '{"view":["dept_manager","project_manager","accountant"],"entry":["accountant"],"budget":["project_manager"],"salaries":["accountant"],"revenue":["dept_manager","project_manager","accountant"]}')
on conflict (key) do nothing;
create table if not exists public.fm_cc_centers (
  id          uuid primary key default gen_random_uuid(),
  code        text not null unique,
  name        text not null,
  parent_id   uuid references public.fm_cc_centers(id) on delete restrict,
  kind        text not null default 'dept' check (kind in ('project','region','dept')),
  region      text,
  auto        text[] not null default '{}',         -- automatic categories it receives: sub, mat, buy, exp
  rev_monthly numeric(14,2) not null default 0,     -- monthly contract value (revenue) when no «contract» entry is made
  rev_from    date,
  rev_to      date,
  active      boolean not null default true,
  notes       text,
  created_at  timestamptz not null default now()
);
create table if not exists public.fm_cc_budget (
  center_id uuid not null references public.fm_cc_centers(id) on delete cascade,
  year      int not null,
  month     int not null check (month between 1 and 12),
  cat       text not null,
  amount    numeric(14,2) not null default 0,
  primary key (center_id, year, month, cat)
);
create table if not exists public.fm_cc_entries (
  id              uuid primary key default gen_random_uuid(),
  center_id       uuid not null references public.fm_cc_centers(id) on delete restrict,
  month           text not null check (month ~ '^\d{4}-\d{2}$'),
  kind            text not null check (kind in ('cost','rev')),
  cat             text not null,
  amount          numeric(14,2) not null,
  bkey            text,
  ref             text,
  note            text,
  cancelled       boolean not null default false,
  cancel_reason   text,
  created_by_name text,
  created_at      timestamptz not null default now()
);
create index if not exists fm_cc_entries_idx on public.fm_cc_entries (month, center_id);
create table if not exists public.fm_cc_staff (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  emp_no      text,
  job         text,
  profile_id  uuid references public.profiles(id) on delete set null,
  center_id   uuid not null references public.fm_cc_centers(id) on delete restrict,
  salary      numeric(12,2) not null default 0,
  housing     numeric(12,2) not null default 0,
  transport   numeric(12,2) not null default 0,
  other       numeric(12,2) not null default 0,
  gosi_pct    numeric(5,2) not null default 0,       -- employer social insurance and other on-costs %
  start_date  date,
  end_date    date,
  active      boolean not null default true,
  updated_at  timestamptz not null default now()
);
alter table public.fm_contracts add column if not exists cc_id uuid references public.fm_cc_centers(id) on delete set null;
alter table public.fm_cc_centers enable row level security;
alter table public.fm_cc_budget enable row level security;
alter table public.fm_cc_entries enable row level security;
alter table public.fm_cc_staff enable row level security;
revoke all on public.fm_cc_centers, public.fm_cc_budget, public.fm_cc_entries, public.fm_cc_staff from anon, authenticated;

-- may the caller … (view | entry | budget | salaries | revenue)? the system admin always
create or replace function public.fm_cc_can(k text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin'
    or (public.fm_my_pos() = any(array(select jsonb_array_elements_text(coalesce(public.fm_setting('cc_perms')->k, '[]'))))
        and (k = 'view' or public.fm_my_pos() = any(array(select jsonb_array_elements_text(coalesce(public.fm_setting('cc_perms')->'view', '[]')))))), false) $$;
-- the centers the caller sees: all, or those of his regions for the area manager / engineer
create or replace function public.fm_cc_sees(c public.fm_cc_centers) returns boolean language sql stable security definer set search_path = public as $$
  select public.fm_cc_can('view') and (public.fm_my_pos() not in ('area_manager','area_engineer') or (c.region is not null and public.fm_region_ok(c.region))) $$;
-- the center that receives an automatic category in a region
create or replace function public.fm_cc_route(p_region text, p_cat text) returns uuid language sql stable security definer set search_path = public as $$
  select coalesce(
    (select id from public.fm_cc_centers where active and kind = 'dept' and region is not distinct from p_region and p_cat = any(auto) order by code limit 1),
    (select id from public.fm_cc_centers where active and kind = 'region' and region is not distinct from p_region order by code limit 1),
    (select id from public.fm_cc_centers where active and kind = 'project' order by code limit 1)) $$;

-- actual revenue and cost of a year: (center, month, category, source, building, amount)
create or replace function public.fm_cc_actuals(p_year int) returns table(center_id uuid, m int, cat text, src text, bkey text, amount numeric)
language plpgsql stable security definer set search_path = public as $$
declare a date := make_date(p_year,1,1); b date := make_date(p_year+1,1,1); cur int := case when extract(year from current_date) = p_year then extract(month from current_date)::int when p_year < extract(year from current_date) then 12 else 0 end;
begin
  if auth.uid() is not null and not public.fm_cc_can('view') then return; end if;
  return query
  with sdb as (   -- building key → region, from the school DB
    select public.fm_bkey(x->>'buildingId', x->>'school') bk, x->>'region' reg
      from public.app_kv k, jsonb_array_elements(case when jsonb_typeof(k.value) = 'array' then k.value when jsonb_typeof(k.value) = 'string' and left(k.value #>> '{}',1) = '[' then (k.value #>> '{}')::jsonb else '[]' end) x
     where k.key = 'fm_school_master_db_v1'),
  billed as (select bw.wo_id, ct.mat_mode from public.fm_bill_wos bw join public.fm_bills bl on bl.id = bw.bill_id join public.fm_contracts ct on ct.id = bl.contract_id where bl.status <> 'cancelled'),
  mats as (     -- materials of orders closed in the year
    select o.region, public.fm_bkey(o.building_id, o.school) bk, extract(month from (coalesce(o.closed_at, o.updated_at) at time zone 'Asia/Riyadh'))::int mm,
           coalesce(mt.m->>'src','store') srcm, coalesce(nullif(mt.m->>'q','')::numeric,0) * coalesce(nullif(mt.m->>'price','')::numeric,0) v, bd.mat_mode
      from public.work_orders o
      cross join lateral jsonb_array_elements(case when jsonb_typeof(o.checklist) = 'array' then o.checklist else '[]' end) it(e)
      cross join lateral jsonb_array_elements(case when jsonb_typeof(it.e->'materials') = 'array' then it.e->'materials' else '[]' end) mt(m)
      left join billed bd on bd.wo_id = o.id
     where o.status = 'closed' and coalesce(o.closed_at, o.updated_at) >= a and coalesce(o.closed_at, o.updated_at) < b and jsonb_typeof(mt.m) = 'object'),
  exps as (     -- expenses spread over the months of the year and their schools
    select e.*, gs::date mon from public.fm_expenses e
      cross join lateral generate_series(date_trunc('month', greatest(e.start_on, a))::date, date_trunc('month', least(coalesce(e.end_on, b - 1), b - 1))::date, interval '1 month') gs
     where e.active and e.cancelled_by is null and e.start_on < b and coalesce(e.end_on, b) >= a and (e.kind = 'monthly' or date_trunc('month', e.start_on) = gs)),
  exp_rows as (
    select x.region reg, null::text bk, extract(month from x.mon)::int mm, x.amount v from exps x where x.scope = 'region'
    union all
    select coalesce(s.reg, x.region), k.bk, extract(month from x.mon)::int, case when x.split = 'each' then x.amount else x.amount / greatest(cardinality(x.schools),1) end
      from exps x cross join lateral unnest(x.schools) k(bk) left join sdb s on s.bk = k.bk where x.scope <> 'region'),
  staff_rows as (
    select s.center_id cid, mm, round((s.salary + s.housing + s.transport + s.other) * (1 + s.gosi_pct / 100)
           * greatest(0, (least(coalesce(s.end_date, make_date(p_year,mm,1) + interval '1 month' - interval '1 day')::date, (make_date(p_year,mm,1) + interval '1 month' - interval '1 day')::date)
                        - greatest(coalesce(s.start_date, make_date(p_year,mm,1)), make_date(p_year,mm,1)) + 1))::numeric
           / extract(day from make_date(p_year,mm,1) + interval '1 month' - interval '1 day'), 2) v
      from public.fm_cc_staff s cross join generate_series(1, greatest(cur,0)) mm where s.active),
  ent as (select e.* from public.fm_cc_entries e where not e.cancelled and e.month like p_year || '-%'),
  allrows as (
    select coalesce(ct.cc_id, public.fm_cc_route(ct.region, 'sub')) cid, substr(bl.month,6,2)::int mm, 'sub'::text c, 'bill'::text s, null::text bk, (bl.gross - bl.deductions) v
      from public.fm_bills bl join public.fm_contracts ct on ct.id = bl.contract_id where bl.status in ('approved','paid') and bl.month like p_year || '-%'
    union all
    select public.fm_cc_route(x.region, case when x.srcm = 'buy' then 'buy' else 'mat' end), x.mm, case when x.srcm = 'buy' then 'buy' else 'mat' end, 'wo', x.bk, x.v
      from mats x where x.v > 0 and not (x.srcm = 'buy' and coalesce(x.mat_mode,'') in ('buy','all')) and not (x.srcm <> 'buy' and coalesce(x.mat_mode,'') = 'all')
    union all
    select public.fm_cc_route(r.reg, 'exp'), r.mm, 'exp', 'exp', r.bk, r.v from exp_rows r
    union all
    select sr.cid, sr.mm, 'labour', 'staff', null, sr.v from staff_rows sr where sr.v > 0
    union all
    select e.center_id, substr(e.month,6,2)::int, e.cat, 'entry', e.bkey, case when e.kind = 'rev' and e.cat = 'client_ded' then -abs(e.amount) when e.kind = 'rev' then e.amount else e.amount end from ent e
    union all     -- the monthly contract value when no «contract» entry was made for that center and month
    select c.id, mm, 'contract', 'auto', null, c.rev_monthly from public.fm_cc_centers c cross join generate_series(1, greatest(cur,0)) mm
     where c.active and c.rev_monthly > 0 and (c.rev_from is null or make_date(p_year,mm,1) >= date_trunc('month', c.rev_from)) and (c.rev_to is null or make_date(p_year,mm,1) <= c.rev_to)
       and not exists(select 1 from ent e where e.center_id = c.id and e.kind = 'rev' and e.cat = 'contract' and substr(e.month,6,2)::int = mm))
  select r.cid, r.mm, r.c, r.s, r.bk, round(sum(r.v),2) from allrows r group by 1,2,3,4,5;
end $$;

-- everything the page needs for a year, filtered by the caller's permissions
create or replace function public.fm_cc_data(p_year int) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare rv boolean := public.fm_cc_can('revenue'); sal boolean := public.fm_cc_can('salaries'); vis uuid[];
begin
  if auth.uid() is null or not public.fm_cc_can('view') then raise exception 'not allowed'; end if;
  select coalesce(array_agg(c.id),'{}') into vis from public.fm_cc_centers c where public.fm_cc_sees(c);
  return jsonb_build_object(
    'me', jsonb_build_object('entry', public.fm_cc_can('entry'), 'budget', public.fm_cc_can('budget'), 'salaries', sal, 'revenue', rv,
                             'scope', case when public.fm_my_pos() in ('area_manager','area_engineer') then 'region' else 'all' end),
    'centers', coalesce((select jsonb_agg(to_jsonb(c) - case when rv then 'x' else 'rev_monthly' end order by c.code) from public.fm_cc_centers c where c.id = any(vis)), '[]'),
    'budget', coalesce((select jsonb_agg(to_jsonb(x)) from public.fm_cc_budget x where x.year = p_year and x.center_id = any(vis) and (rv or x.cat not in ('rev','contract','extra','client_ded'))), '[]'),
    'entries', coalesce((select jsonb_agg(to_jsonb(e) order by e.month desc, e.created_at desc) from public.fm_cc_entries e where e.month like p_year || '-%' and e.center_id = any(vis) and (rv or e.kind = 'cost')), '[]'),
    'staff', case when sal then coalesce((select jsonb_agg(to_jsonb(s) order by s.name) from public.fm_cc_staff s where s.center_id = any(vis)), '[]') else '[]' end,
    'actuals', coalesce((select jsonb_agg(jsonb_build_object('c', a.center_id, 'm', a.m, 'cat', a.cat, 'src', a.src, 'b', a.bkey, 'v', a.amount))
                         from public.fm_cc_actuals(p_year) a where (a.center_id = any(vis) or (a.center_id is null and public.fm_my_pos() not in ('area_manager','area_engineer')))
                           and (rv or a.cat not in ('contract','extra','client_ded'))), '[]'));
end $$;

create or replace function public.fm_cc_center_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id','')::uuid; k text := coalesce(nullif(p->>'kind',''),'dept');
begin
  if auth.uid() is null or not public.fm_cc_can('budget') then raise exception 'not allowed'; end if;
  if btrim(coalesce(p->>'name','')) = '' or btrim(coalesce(p->>'code','')) = '' then raise exception 'name required'; end if;
  if exists(select 1 from public.fm_cc_centers where lower(code) = lower(btrim(p->>'code')) and id is distinct from v_id) then raise exception 'duplicate code'; end if;
  if nullif(p->>'parent_id','')::uuid = v_id then raise exception 'invalid parent'; end if;
  if v_id is null then insert into public.fm_cc_centers(code, name, kind) values (upper(btrim(p->>'code')), btrim(p->>'name'), k) returning id into v_id; end if;
  update public.fm_cc_centers set code = upper(left(btrim(p->>'code'),30)), name = left(btrim(p->>'name'),150), kind = k, parent_id = nullif(p->>'parent_id','')::uuid,
    region = nullif(btrim(coalesce(p->>'region','')),''),
    auto = coalesce((select array_agg(x) from jsonb_array_elements_text(case when jsonb_typeof(p->'auto') = 'array' then p->'auto' else '[]' end) x where x in ('sub','mat','buy','exp')), '{}'),
    rev_monthly = case when public.fm_cc_can('revenue') then coalesce(nullif(p->>'rev_monthly','')::numeric, 0) else rev_monthly end,
    rev_from = case when public.fm_cc_can('revenue') then nullif(p->>'rev_from','')::date else rev_from end,
    rev_to = case when public.fm_cc_can('revenue') then nullif(p->>'rev_to','')::date else rev_to end,
    active = coalesce((p->>'active')::boolean, true), notes = left(nullif(btrim(coalesce(p->>'notes','')),''),500)
   where id = v_id;
  return v_id;
end $$;
-- the budget of a center for a year: p_rows [{m, cat, amount}] (replaces those cells)
create or replace function public.fm_cc_budget_set(p_center uuid, p_year int, p_rows jsonb) returns int language plpgsql security definer set search_path = public as $$
declare x jsonb; n int := 0; v numeric;
begin
  if auth.uid() is null or not public.fm_cc_can('budget') then raise exception 'not allowed'; end if;
  if not exists(select 1 from public.fm_cc_centers c where c.id = p_center and public.fm_cc_sees(c)) then raise exception 'not allowed'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_rows,'[]')) loop
    if x->>'cat' in ('rev','contract','extra','client_ded') and not public.fm_cc_can('revenue') then raise exception 'not allowed'; end if;
    v := coalesce(nullif(x->>'amount','')::numeric, 0);
    if v < 0 or (x->>'m')::int not between 1 and 12 then raise exception 'invalid'; end if;
    insert into public.fm_cc_budget(center_id, year, month, cat, amount) values (p_center, p_year, (x->>'m')::int, left(x->>'cat',20), v)
      on conflict (center_id, year, month, cat) do update set amount = excluded.amount;
    n := n + 1;
  end loop;
  return n;
end $$;
-- a manual entry: p {center_id, month, kind cost | rev, cat, amount, bkey, ref, note}
create or replace function public.fm_cc_entry_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid; k text := p->>'kind'; c public.fm_cc_centers;
begin
  select * into c from public.fm_cc_centers where id = nullif(p->>'center_id','')::uuid and active;
  if auth.uid() is null or not found or not public.fm_cc_can('entry') or not public.fm_cc_sees(c) then raise exception 'not allowed'; end if;
  if k = 'rev' and not public.fm_cc_can('revenue') then raise exception 'not allowed'; end if;
  if k not in ('cost','rev') or coalesce(p->>'month','') !~ '^\d{4}-\d{2}$' or coalesce(nullif(p->>'amount','')::numeric, 0) <= 0 then raise exception 'invalid'; end if;
  insert into public.fm_cc_entries(center_id, month, kind, cat, amount, bkey, ref, note, created_by_name)
  values (c.id, p->>'month', k, left(coalesce(nullif(p->>'cat',''),'other'),20), (p->>'amount')::numeric, nullif(btrim(coalesce(p->>'bkey','')),''),
          left(nullif(btrim(coalesce(p->>'ref','')),''),80), left(nullif(btrim(coalesce(p->>'note','')),''),500), public.fm_me_name()) returning id into v_id;
  return v_id;
end $$;
create or replace function public.fm_cc_entry_cancel(p_id uuid, p_reason text) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.fm_cc_can('entry') then raise exception 'not allowed'; end if;
  if btrim(coalesce(p_reason,'')) = '' then raise exception 'reason required'; end if;
  update public.fm_cc_entries set cancelled = true, cancel_reason = left(btrim(p_reason),300) || ' — ' || public.fm_me_name() where id = p_id and not cancelled;
  return found;
end $$;
-- a person on the staff list: p {id?, name, emp_no, job, profile_id, center_id, salary, housing, transport, other, gosi_pct, start_date, end_date, active, delete}
create or replace function public.fm_cc_staff_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id','')::uuid; c public.fm_cc_centers;
begin
  if auth.uid() is null or not public.fm_cc_can('salaries') then raise exception 'not allowed'; end if;
  if coalesce((p->>'delete')::boolean,false) then delete from public.fm_cc_staff where id = v_id; return v_id; end if;
  select * into c from public.fm_cc_centers where id = nullif(p->>'center_id','')::uuid;
  if not found or not public.fm_cc_sees(c) then raise exception 'unknown center'; end if;
  if btrim(coalesce(p->>'name','')) = '' then raise exception 'name required'; end if;
  if v_id is null then insert into public.fm_cc_staff(name, center_id) values (btrim(p->>'name'), c.id) returning id into v_id; end if;
  update public.fm_cc_staff set name = left(btrim(p->>'name'),150), emp_no = left(nullif(btrim(coalesce(p->>'emp_no','')),''),40), job = left(nullif(btrim(coalesce(p->>'job','')),''),80),
    profile_id = nullif(p->>'profile_id','')::uuid, center_id = c.id,
    salary = greatest(0, coalesce(nullif(p->>'salary','')::numeric,0)), housing = greatest(0, coalesce(nullif(p->>'housing','')::numeric,0)),
    transport = greatest(0, coalesce(nullif(p->>'transport','')::numeric,0)), other = greatest(0, coalesce(nullif(p->>'other','')::numeric,0)),
    gosi_pct = least(100, greatest(0, coalesce(nullif(p->>'gosi_pct','')::numeric,0))), start_date = nullif(p->>'start_date','')::date, end_date = nullif(p->>'end_date','')::date,
    active = coalesce((p->>'active')::boolean, true), updated_at = now()
   where id = v_id;
  return v_id;
end $$;
revoke all on function public.fm_cc_route(text, text), public.fm_cc_sees(public.fm_cc_centers) from public, anon, authenticated;
revoke all on function public.fm_cc_can(text), public.fm_cc_actuals(int), public.fm_cc_data(int), public.fm_cc_center_save(jsonb), public.fm_cc_budget_set(uuid, int, jsonb),
  public.fm_cc_entry_save(jsonb), public.fm_cc_entry_cancel(uuid, text), public.fm_cc_staff_save(jsonb) from public, anon;
grant execute on function public.fm_cc_can(text), public.fm_cc_data(int), public.fm_cc_center_save(jsonb), public.fm_cc_budget_set(uuid, int, jsonb),
  public.fm_cc_entry_save(jsonb), public.fm_cc_entry_cancel(uuid, text), public.fm_cc_staff_save(jsonb) to authenticated;
revoke all on function public.fm_cc_actuals(int) from authenticated;
-- the cost centers are a part sold separately (key «cc»)
create or replace function public.fm_mods_on() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(k), '[]') from unnest(array['tickets','wo','wh','eng','portal','costs','bill','cc']) k where public.fm_mod(k) $$;
drop trigger if exists fm_mod_guard on public.fm_cc_entries;
create trigger fm_mod_guard before insert on public.fm_cc_entries for each row execute function public.fm_mod_guard('cc');

-- ---------- 29) push notifications on the phone / computer (V187) ----------
-- An event (a new work order, «done» waiting for approval, a return, an escalation, a parts request, parts issued, an item waiting
-- for approval, a bill to review / approve / pay, overdue scrap) adds one row per person to fm_push_queue. The Edge Function
-- «fm-push» (supabase/functions/fm-push/index.ts) sends the rows with Web Push to every device the person turned on.
-- fm_settings.push = {enabled, vapid_public, subject, off:[kinds]} (read by all; only the PUBLIC key is here). The function URL
-- and its shared secret are in fm_push_cfg (no policies: only the system admin through fm_push_config). The private VAPID key is
-- only in the function's secrets (VAPID_PRIVATE), never in the database or the repository.
create table if not exists public.fm_push_subs (
  endpoint   text primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  p256dh     text not null,
  auth       text not null,
  app        text,
  ua         text,
  created_at timestamptz not null default now(),
  last_ok    timestamptz,
  fails      int not null default 0
);
create index if not exists fm_push_subs_user_idx on public.fm_push_subs (user_id);
create table if not exists public.fm_push_prefs (user_id uuid primary key references public.profiles(id) on delete cascade, off text[] not null default '{}');
create table if not exists public.fm_push_queue (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  kind       text not null,
  title      text not null,
  body       text,
  url        text,
  tag        text,
  created_at timestamptz not null default now(),
  claimed_at timestamptz,
  sent_at    timestamptz,
  tries      int not null default 0,
  err        text
);
create index if not exists fm_push_queue_open_idx on public.fm_push_queue (id) where sent_at is null;
create table if not exists public.fm_push_cfg (id int primary key default 1 check (id = 1), fn_url text, hook_secret text, anon_key text, kicked_at timestamptz);
alter table public.fm_push_subs  enable row level security;
alter table public.fm_push_prefs enable row level security;
alter table public.fm_push_queue enable row level security;
alter table public.fm_push_cfg   enable row level security;
revoke all on public.fm_push_subs, public.fm_push_prefs, public.fm_push_queue, public.fm_push_cfg from anon, authenticated;
do $do$ begin execute 'create extension if not exists pg_net'; exception when others then raise notice 'pg_net is not available: notifications go out every minute (pg_cron) or when the function is called'; end $do$;

-- the page a notification opens: the field app for supervisors / contractors, the platform for the others
create or replace function public.fm_push_url(p_user uuid, p_hash text) returns text language sql stable security definer set search_path = public as $$
  select case when (select public.fm_posx(role, job_title) from public.profiles where id = p_user) in ('supervisor','contractor') then 'field.html' else 'index.html' end
         || coalesce('#' || nullif(p_hash,''), '') $$;
-- active people with these titles (and the region, when given)
create or replace function public.fm_push_people(p_titles text[], p_region text) returns setof uuid language sql stable security definer set search_path = public as $$
  select p.id from public.profiles p where p.active and public.fm_posx(p.role, p.job_title) = any(p_titles)
     and (p_region is null or cardinality(coalesce(p.regions,'{}')) = 0 or p_region = any(p.regions)) $$;

-- call the Edge Function (at most every 3 seconds; pg_cron runs fm_push_flush every minute for what is left)
create or replace function public.fm_push_kick() returns void language plpgsql security definer set search_path = public as $$
declare c public.fm_push_cfg;
begin
  update public.fm_push_cfg set kicked_at = now() where id = 1 and fn_url is not null and coalesce(kicked_at, 'epoch') < now() - interval '3 seconds' returning * into c;
  if not found then return; end if;
  begin
    execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 20000)'
      using c.fn_url, jsonb_build_object('Content-Type','application/json','x-fm-hook', c.hook_secret)
                     || case when c.anon_key is not null then jsonb_build_object('Authorization','Bearer ' || c.anon_key, 'apikey', c.anon_key) else '{}'::jsonb end;
  exception when others then null;
  end;
end $$;
create or replace function public.fm_push_flush() returns void language plpgsql security definer set search_path = public as $$
begin
  if exists(select 1 from public.fm_push_queue where sent_at is null and tries < 5 and created_at > now() - interval '1 day') then
    update public.fm_push_cfg set kicked_at = null where id = 1;
    perform public.fm_push_kick();
  end if;
  delete from public.fm_push_queue where created_at < now() - interval '30 days';
end $$;
create or replace function public.fm_push_q_kick() returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.fm_push_kick(); return null; end $$;
drop trigger if exists fm_push_q_kick on public.fm_push_queue;
create trigger fm_push_q_kick after insert on public.fm_push_queue for each statement execute function public.fm_push_q_kick();

-- add one notification (internal). Skipped when notifications are off, the kind is off for everyone or for that person, the
-- person has no device turned on, or he did it himself.
create or replace function public.fm_push_add(p_user uuid, p_kind text, p_title text, p_body text, p_hash text, p_tag text, p_self boolean default false)
returns boolean language plpgsql security definer set search_path = public as $$
declare s jsonb := coalesce(public.fm_setting('push'), '{}');
begin
  if p_user is null or not coalesce((s->>'enabled')::boolean, false) then return false; end if;
  if not p_self and (p_user = auth.uid()
      or p_kind = any(array(select jsonb_array_elements_text(case when jsonb_typeof(s->'off') = 'array' then s->'off' else '[]' end)))
      or exists(select 1 from public.fm_push_prefs where user_id = p_user and p_kind = any(off))) then return false; end if;
  if not exists(select 1 from public.fm_push_subs where user_id = p_user)
     or not exists(select 1 from public.profiles where id = p_user and active) then return false; end if;
  -- a campaign / approvals / scrap: one notification per person in 10 minutes
  if (p_tag like 'batch-%' or p_tag in ('appr','scrap')) and exists(select 1 from public.fm_push_queue where user_id = p_user and tag = p_tag and created_at > now() - interval '10 minutes') then
    return false; end if;
  insert into public.fm_push_queue(user_id, kind, title, body, url, tag)
  values (p_user, p_kind, left(coalesce(p_title,''),120), left(coalesce(p_body,''),300), public.fm_push_url(p_user, p_hash), left(p_tag,80));
  return true;
end $$;

-- ---- what each person does on his own devices ----
create or replace function public.fm_push_subscribe(p jsonb) returns boolean language plpgsql security definer set search_path = public as $$
declare e text := btrim(coalesce(p->>'endpoint',''));
begin
  if auth.uid() is null or public.fm_role() = 'pending' then raise exception 'not allowed'; end if;
  if e !~ '^https://' or length(e) > 1000 or coalesce(p->>'p256dh','') !~ '^[A-Za-z0-9_-]{40,200}$' or coalesce(p->>'auth','') !~ '^[A-Za-z0-9_-]{10,60}$' then
    raise exception 'invalid subscription'; end if;
  if (select count(*) from public.fm_push_subs where user_id = auth.uid() and endpoint <> e) >= 10 then
    delete from public.fm_push_subs where endpoint = (select endpoint from public.fm_push_subs where user_id = auth.uid() order by coalesce(last_ok, created_at) limit 1);
  end if;
  insert into public.fm_push_subs(endpoint, user_id, p256dh, auth, app, ua) values (e, auth.uid(), p->>'p256dh', p->>'auth', left(p->>'app',20), left(p->>'ua',200))
  on conflict (endpoint) do update set user_id = auth.uid(), p256dh = excluded.p256dh, auth = excluded.auth, app = excluded.app, ua = excluded.ua, fails = 0;
  return true;
end $$;
create or replace function public.fm_push_unsubscribe(p_endpoint text) returns boolean language plpgsql security definer set search_path = public as $$
begin
  delete from public.fm_push_subs where endpoint = p_endpoint and user_id = auth.uid();
  return found;
end $$;
create or replace function public.fm_push_prefs_set(p_off text[]) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  insert into public.fm_push_prefs(user_id, off) values (auth.uid(), coalesce(p_off,'{}')) on conflict (user_id) do update set off = excluded.off;
  return true;
end $$;
create or replace function public.fm_push_me() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('devices', (select count(*) from public.fm_push_subs where user_id = auth.uid()),
    'endpoints', coalesce((select jsonb_agg(endpoint) from public.fm_push_subs where user_id = auth.uid()), '[]'),
    'off', coalesce((select to_jsonb(off) from public.fm_push_prefs where user_id = auth.uid()), '[]'),
    'last', (select max(sent_at) from public.fm_push_queue where user_id = auth.uid())) where auth.uid() is not null $$;
-- a test notification to my own devices
create or replace function public.fm_push_test() returns boolean language plpgsql security definer set search_path = public as $$
declare ok boolean;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  ok := public.fm_push_add(auth.uid(), 'test', '🔔 تجربة الإشعارات', 'وصلك هذا الإشعار، فالإشعارات تعمل على هذا الجهاز.', null, 'test', true);
  if ok then update public.fm_push_cfg set kicked_at = null where id = 1; perform public.fm_push_kick(); end if;
  return ok;
end $$;

-- ---- system admin ----
create or replace function public.fm_push_config(p jsonb) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed'; end if;
  if nullif(p->>'fn_url','') is not null and p->>'fn_url' !~ '^https://[^ ]+$' then raise exception 'invalid url'; end if;
  if nullif(p->>'hook_secret','') is not null and length(p->>'hook_secret') < 24 then raise exception 'secret too short'; end if;
  insert into public.fm_push_cfg(id) values (1) on conflict do nothing;
  update public.fm_push_cfg set fn_url = case when p ? 'fn_url' then nullif(btrim(p->>'fn_url'),'') else fn_url end,
    hook_secret = case when nullif(p->>'hook_secret','') is not null then p->>'hook_secret' else hook_secret end,
    anon_key = case when p ? 'anon_key' then nullif(btrim(p->>'anon_key'),'') else anon_key end, kicked_at = null where id = 1;
  return true;
end $$;
create or replace function public.fm_push_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed'; end if;
  return jsonb_build_object(
    'fn_url', (select fn_url from public.fm_push_cfg where id = 1), 'has_secret', (select hook_secret is not null from public.fm_push_cfg where id = 1),
    'has_anon', (select anon_key is not null from public.fm_push_cfg where id = 1),
    'pg_net', exists(select 1 from pg_extension where extname = 'pg_net'), 'pg_cron', exists(select 1 from pg_extension where extname = 'pg_cron'),
    'devices', (select count(*) from public.fm_push_subs), 'people', (select count(distinct user_id) from public.fm_push_subs),
    'waiting', (select count(*) from public.fm_push_queue where sent_at is null and tries < 5 and created_at > now() - interval '1 day'),
    'sent24', (select count(*) from public.fm_push_queue where sent_at > now() - interval '1 day'),
    'failed24', (select count(*) from public.fm_push_queue where sent_at is null and err is not null and created_at > now() - interval '1 day'),
    'last_err', (select err from public.fm_push_queue where err is not null order by id desc limit 1),
    'last_sent', (select max(sent_at) from public.fm_push_queue),
    'by_kind', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) n from public.fm_push_queue where created_at > now() - interval '30 days' group by kind) k), '{}'));
end $$;

-- ---- the Edge Function (service role only) ----
-- take up to n rows to send, with the devices of each person
create or replace function public.fm_push_claim(n int) returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  with c as (
    update public.fm_push_queue q set claimed_at = now(), tries = q.tries + 1
     where q.id in (select id from public.fm_push_queue where sent_at is null and tries < 5 and created_at > now() - interval '1 day'
                      and (claimed_at is null or claimed_at < now() - interval '2 minutes') order by id limit greatest(1, least(coalesce(n,100), 500)) for update skip locked)
    returning q.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'body', c.body, 'url', c.url, 'tag', c.tag, 'kind', c.kind,
           'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) from public.fm_push_subs s where s.user_id = c.user_id), '[]'))), '[]')
    into r from c;
  return r;
end $$;
-- the result: p [{id, ok, err, sent:[endpoints], gone:[endpoints]}]
create or replace function public.fm_push_result(p jsonb) returns int language plpgsql security definer set search_path = public as $$
declare x jsonb; n int := 0;
begin
  for x in select * from jsonb_array_elements(coalesce(p,'[]')) loop
    update public.fm_push_queue set sent_at = case when (x->>'ok')::boolean then now() end, err = left(nullif(x->>'err',''),300), claimed_at = null where id = (x->>'id')::bigint;
    delete from public.fm_push_subs where endpoint in (select jsonb_array_elements_text(coalesce(x->'gone','[]')));
    update public.fm_push_subs set last_ok = now(), fails = 0 where endpoint in (select jsonb_array_elements_text(coalesce(x->'sent','[]')));
    update public.fm_push_subs set fails = fails + 1 where endpoint in (select jsonb_array_elements_text(coalesce(x->'failed','[]')));
    n := n + 1;
  end loop;
  delete from public.fm_push_subs where fails >= 20;
  return n;
end $$;

revoke all on function public.fm_push_url(uuid, text), public.fm_push_people(text[], text), public.fm_push_kick(), public.fm_push_flush(), public.fm_push_q_kick(),
  public.fm_push_add(uuid, text, text, text, text, text, boolean), public.fm_push_claim(int), public.fm_push_result(jsonb) from public, anon, authenticated;
revoke all on function public.fm_push_subscribe(jsonb), public.fm_push_unsubscribe(text), public.fm_push_prefs_set(text[]), public.fm_push_me(), public.fm_push_test(),
  public.fm_push_config(jsonb), public.fm_push_status() from public, anon;
grant execute on function public.fm_push_subscribe(jsonb), public.fm_push_unsubscribe(text), public.fm_push_prefs_set(text[]), public.fm_push_me(), public.fm_push_test(),
  public.fm_push_config(jsonb), public.fm_push_status() to authenticated;
do $do$ begin
  execute 'grant execute on function public.fm_push_claim(int), public.fm_push_result(jsonb) to service_role';
exception when undefined_object then null; end $do$;

-- ---- the events ----
-- work orders (one trigger on the order's events)
create or replace function public.fm_push_wo_ev() returns trigger language plpgsql security definer set search_path = public as $$
declare w public.work_orders; h text; t text; b text;
begin
  select * into w from public.work_orders where id = new.wo_id;
  if not found then return null; end if;
  h := 'wo=' || w.id; t := coalesce(w.code,'');
  b := w.title || coalesce(' — ' || w.school, '');
  if new.type in ('create','reassign','deputy') then
    if w.batch_id is not null and new.type = 'create' then
      perform public.fm_push_add(w.assignee, 'wo_new', '🛠️ أوامر عمل جديدة: ' || coalesce(w.batch_title, 'حملة'), 'أُسندت إليك أوامر في الحملة — افتح «الأوامر»', 'wo', 'batch-' || w.batch_id);
    else
      perform public.fm_push_add(w.assignee, 'wo_new', '🛠️ أمر عمل جديد ' || t, b, h, 'wo-' || w.id);
    end if;
  elsif new.type = 'done' then
    perform public.fm_push_add(w.created_by, 'wo_done', '✅ أمر بانتظار اعتمادك ' || t, b || ' — ' || coalesce(w.assignee_name,''), h, 'wo-' || w.id);
  elsif new.type = 'reject' then
    perform public.fm_push_add(w.created_by, 'wo_done', '❌ رُفض أمر العمل ' || t, coalesce(new.text, b), h, 'wo-' || w.id);
  elsif new.type = 'return' then
    perform public.fm_push_add(w.assignee, 'wo_return', '↩️ أُعيد إليك أمر العمل ' || t, coalesce(new.text, b), h, 'wo-' || w.id);
  elsif new.type = 'close' then
    perform public.fm_push_add(w.assignee, 'wo_closed', '🎉 اعتُمد أمر العمل ' || t, b, h, 'wo-' || w.id);
  elsif new.type = 'escalate' then
    perform public.fm_push_add(w.esc_to, 'wo_esc', '⏫ تصعيد أمر متأخر ' || t, coalesce(new.text, b), h, 'esc-' || w.id);
  elsif new.type = 'stop' then
    perform public.fm_push_add(w.assignee, 'wo_stop', '⛔ إيقاف العمل في ' || t, coalesce(new.text, b), h, 'wo-' || w.id);
    perform public.fm_push_add(w.created_by, 'wo_stop', '⛔ إيقاف العمل في ' || t, coalesce(new.text, b), h, 'wo-' || w.id);
  end if;
  return null;
exception when others then return null;   -- a notification never blocks the work
end $$;
drop trigger if exists fm_push_wo_ev on public.wo_events;
create trigger fm_push_wo_ev after insert on public.wo_events for each row execute function public.fm_push_wo_ev();

-- parts requests: the storekeeper gets a new request; the holder gets what was issued or rejected
create or replace function public.fm_push_ir() returns trigger language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; u uuid; n int := jsonb_array_length(coalesce(new.lines,'[]'));
begin
  if tg_op = 'INSERT' then
    select * into st from public.wo_stores where id = new.store_id;
    for u in select id from public.profiles p where p.active and public.fm_posx(p.role, p.job_title) = 'storekeeper'
               and (p.id = st.keeper or (st.keeper is null and (cardinality(coalesce(p.regions,'{}')) = 0 or st.region = any(p.regions)))) loop
      perform public.fm_push_add(u, 'wh_req', '📦 طلب صرف ' || new.code, coalesce(new.holder_name,'') || ' — ' || n || ' صنف' || coalesce(' — ' || new.wo_code, '') || coalesce(' — ' || st.name, ''), 'wh=req', 'ir-' || new.id);
    end loop;
  elsif new.status is distinct from old.status then
    if new.status in ('issued','partial') then
      perform public.fm_push_add(new.holder, 'wh_issued', '🧰 صُرفت قطع لعهدتك ' || new.code, 'أكّد الاستلام من «عهدتي»' || coalesce(' — ' || new.wo_code, ''), 'cus', 'ir-' || new.id);
    elsif new.status = 'rejected' then
      perform public.fm_push_add(new.holder, 'wh_issued', '❌ رُفض طلب الصرف ' || new.code, coalesce(new.response, ''), 'cus', 'ir-' || new.id);
    end if;
  end if;
  return null;
exception when others then return null;
end $$;
do $do$ begin
  execute 'drop trigger if exists fm_push_ir on public.wo_issue_requests';
  execute 'create trigger fm_push_ir after insert or update of status on public.wo_issue_requests for each row execute function public.fm_push_ir()';
exception when undefined_table then null; end $do$;

-- items / prices waiting for the owner's representative; purchase requests waiting for approval
create or replace function public.fm_push_appr() returns trigger language plpgsql security definer set search_path = public as $$
declare u uuid; st public.wo_stores;
begin
  if tg_table_name = 'wo_materials' then
    if new.approval = 'nominated' and old.approval is distinct from 'nominated' then
      for u in select * from public.fm_push_people(array['owner_rep'], null) loop
        perform public.fm_push_add(u, 'appr', '🟡 صنف بانتظار اعتمادك', new.name || coalesce(' — ' || new.code, ''), 'wh=appr', 'appr');
      end loop;
    end if;
  elsif tg_table_name = 'wo_purchase_requests' and tg_op = 'INSERT' and new.status = 'requested' then
    select * into st from public.wo_stores where id = new.store_id;
    for u in select * from public.fm_push_people(array['project_manager','ops_manager'], null)
             union select * from public.fm_push_people(array['area_manager'], st.region) loop
      perform public.fm_push_add(u, 'appr', '🛒 طلب شراء بانتظار الاعتماد ' || coalesce(new.code,''), coalesce(st.name,'') || ' — ' || coalesce(round(new.total)::text,'') || ' ر.س', 'wh=po', 'po-' || new.id);
    end loop;
  end if;
  return null;
exception when others then return null;
end $$;
do $do$ begin
  execute 'drop trigger if exists fm_push_appr on public.wo_materials';
  execute 'create trigger fm_push_appr after update of approval on public.wo_materials for each row execute function public.fm_push_appr()';
  execute 'drop trigger if exists fm_push_appr on public.wo_purchase_requests';
  execute 'create trigger fm_push_appr after insert on public.wo_purchase_requests for each row execute function public.fm_push_appr()';
exception when undefined_table then null; end $do$;

-- contractor bills: to review, to approve, to pay, paid
create or replace function public.fm_push_bill() returns trigger language plpgsql security definer set search_path = public as $$
declare c public.fm_contracts; u uuid; t text; b text;
begin
  if new.status is not distinct from old.status then return null; end if;
  select * into c from public.fm_contracts where id = new.contract_id;
  t := coalesce(new.code,'') ; b := c.contractor_name || ' — ' || new.month || ' — ' || round(new.total) || ' ر.س';
  if new.status = 'submitted' then
    for u in select * from public.fm_push_people(array['ops_manager'], null) union select * from public.fm_push_people(array['area_manager','area_engineer'], c.region) loop
      perform public.fm_push_add(u, 'bill', '🧾 مستخلص للمراجعة ' || t, b, 'bill', 'bill-' || new.id); end loop;
  elsif new.status = 'reviewed' then
    for u in select * from public.fm_push_people(array['project_manager','ops_manager'], null) loop
      perform public.fm_push_add(u, 'bill', '🧾 مستخلص بانتظار الاعتماد ' || t, b, 'bill', 'bill-' || new.id); end loop;
  elsif new.status = 'approved' then
    for u in select * from public.fm_push_people(array['accountant'], null) loop
      perform public.fm_push_add(u, 'bill', '💳 مستخلص معتمد للصرف ' || t, b, 'bill', 'bill-' || new.id); end loop;
  elsif new.status = 'paid' and c.contractor_id is not null then
    perform public.fm_push_add(c.contractor_id, 'bill', '💰 صُرف مستخلصك ' || t, b, 'bill', 'bill-' || new.id);
  end if;
  return null;
exception when others then return null;
end $$;
do $do$ begin
  execute 'drop trigger if exists fm_push_bill on public.fm_bills';
  execute 'create trigger fm_push_bill after update of status on public.fm_bills for each row execute function public.fm_push_bill()';
exception when undefined_table then null; end $do$;

-- every morning: scrap that should have been returned (one notification per person) and what is left in the queue
create or replace function public.fm_push_daily() returns int language plpgsql security definer set search_path = public as $$
declare r record; n int := 0;
begin
  begin
    for r in select u.holder, count(*) c, min(u.scrap_due) d from public.wo_custody_moves u
              where u.kind = 'use' and u.scrap_open > 0 and u.scrap_due < current_date group by u.holder loop
      if public.fm_push_add(r.holder, 'wh_scrap', '⏰ تالف لم يُسلَّم بعد', r.c || ' صنف — متأخر منذ ' || to_char(r.d, 'YYYY-MM-DD') || '. سلّمه لأمين المستودع.', 'cus', 'scrap') then n := n + 1; end if;
    end loop;
  exception when undefined_table then null; end;
  perform public.fm_push_flush();
  return n;
end $$;
revoke all on function public.fm_push_daily() from public, anon, authenticated;
do $do$ begin
  begin execute 'create extension if not exists pg_cron'; exception when others then null; end;
  begin
    execute 'select cron.unschedule(''fm-push-flush'')';
  exception when others then null; end;
  begin
    execute 'select cron.unschedule(''fm-push-daily'')';
  exception when others then null; end;
  begin
    execute 'select cron.schedule(''fm-push-flush'', ''* * * * *'', ''select public.fm_push_flush()'')';
    execute 'select cron.schedule(''fm-push-daily'', ''0 5 * * *'', ''select public.fm_push_daily()'')';
  exception when others then raise notice 'pg_cron is not available: overdue-scrap reminders are not sent; notifications go out when the events happen'; end;
end $do$;

-- ---------- 30) reset the platform's data (V190) ----------
-- The system admin chooses the parts to empty, sees how many rows each holds, can download a backup of them first, and
-- confirms by typing «تصفير». Accounts (profiles / auth), fm_settings, fm_plan, work-order templates, engagement targets and
-- the audit log are never touched. Every reset is written to fm_audit_log and to fm_settings.wipe {at, parts, by} so the
-- other devices clear their local copies (tickets, school DB) instead of pushing them back to the cloud.
-- Part → tables, in delete order (children first). A table missing on an older project is skipped.
create or replace function public.fm_wipe_parts() returns jsonb language sql immutable as $$
  select jsonb_build_object(
    'tickets',    jsonb_build_array('ticket_photos','ticket_events','ticket_work','tickets'),
    'schooldb',   jsonb_build_array(),
    'wo',         jsonb_build_array('wo_audits','wo_photos','wo_events','fm_bill_wos','work_orders','wo_schedules'),
    'wh_moves',   jsonb_build_array('wo_serials','wo_purchase_requests','wo_issue_requests','wo_custody_counts','wo_custody_moves','wo_custody','wo_stock_moves','wo_stock'),
    'wh_catalog', jsonb_build_array('wo_material_photos','wo_supplier_prices','wo_suppliers','wo_materials','wo_stores'),
    'eng',        jsonb_build_array('fm_eng_ratings','fm_eng_rate_links','fm_eng_audit','fm_eng_observations','fm_eng_logs','fm_eng_assignments'),
    'portal',     jsonb_build_array('fm_school_requests','fm_school_links'),
    'costs',      jsonb_build_array('fm_expenses','fm_budgets'),
    'bill',       jsonb_build_array('fm_bill_wos','fm_bills','fm_contracts'),
    'cc',         jsonb_build_array('fm_cc_entries','fm_cc_budget','fm_cc_staff','fm_cc_centers'),
    'misc',       jsonb_build_array('fm_news','fm_push_queue','fm_activity')) $$;
-- app_kv keys of a part
create or replace function public.fm_wipe_kv_match(p_part text, k text) returns boolean language sql immutable as $$
  select case p_part when 'tickets' then k like 'fm_ref_date_%' or k like 'fm_rank_%'
                     when 'schooldb' then k = 'fm_school_master_db_v1' else false end $$;
create or replace function public.fm_wipe_ok() returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and public.fm_role() = 'admin' and public.fm_my_pos() = 'sysadmin' $$;

-- how many rows each part holds
create or replace function public.fm_wipe_counts() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare P jsonb := public.fm_wipe_parts(); k text; t text; n bigint; c bigint; r jsonb := '{}';
begin
  if not public.fm_wipe_ok() then raise exception 'not allowed'; end if;
  for k in select jsonb_object_keys(P) loop
    c := 0;
    for t in select jsonb_array_elements_text(P->k) loop
      if to_regclass('public.' || t) is not null then execute format('select count(*) from public.%I', t) into n; c := c + n; end if;
    end loop;
    if k in ('tickets','schooldb') then
      select count(*) into n from public.app_kv a where public.fm_wipe_kv_match(k, a.key);
      if k = 'schooldb' then select coalesce((select jsonb_array_length(value) from public.app_kv where key = 'fm_school_master_db_v1' and jsonb_typeof(value) = 'array'), 0) into n; end if;
      c := c + n;
    end if;
    r := r || jsonb_build_object(k, c);
  end loop;
  return r;
end $$;

-- a copy of the rows of the chosen parts (downloaded by the platform before the reset)
create or replace function public.fm_wipe_backup(p_parts text[]) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare P jsonb := public.fm_wipe_parts(); k text; t text; v jsonb; r jsonb := jsonb_build_object('at', now(), 'parts', to_jsonb(p_parts));
begin
  if not public.fm_wipe_ok() then raise exception 'not allowed'; end if;
  foreach k in array coalesce(p_parts,'{}') loop
    if not P ? k then continue; end if;
    for t in select jsonb_array_elements_text(P->k) loop
      if to_regclass('public.' || t) is not null and not r ? t then
        execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from public.%I x', t) into v; r := r || jsonb_build_object(t, v);
      end if;
    end loop;
    if k in ('tickets','schooldb') then
      select coalesce(jsonb_object_agg(a.key, a.value), '{}') into v from public.app_kv a where public.fm_wipe_kv_match(k, a.key);
      r := r || jsonb_build_object('app_kv:' || k, v);
    end if;
  end loop;
  return r;
end $$;

-- the reset itself: p_parts = the chosen parts, p_confirm must be «تصفير»
create or replace function public.fm_wipe(p_parts text[], p_confirm text) returns jsonb language plpgsql security definer set search_path = public as $$
declare P jsonb := public.fm_wipe_parts(); k text; t text; n bigint; r jsonb := '{}'; parts text[] := '{}'; files int := 0; files_left boolean := false;
  nm text := (select coalesce(full_name, email) from public.profiles where id = auth.uid());
begin
  if not public.fm_wipe_ok() then raise exception 'not allowed'; end if;
  if btrim(coalesce(p_confirm,'')) <> 'تصفير' then raise exception 'confirm required'; end if;
  select coalesce(array_agg(distinct x), '{}') into parts from unnest(coalesce(p_parts,'{}')) x where P ? x;
  if cardinality(parts) = 0 then raise exception 'no parts'; end if;
  perform set_config('fm.wipe', '1', true);   -- V202: let fm_mod_guard allow these deletes (this transaction only)
  -- the warehouse catalog cannot go without its moves
  if 'wh_catalog' = any(parts) and not 'wh_moves' = any(parts) then parts := parts || 'wh_moves'::text; end if;
  -- the order of the parts: what refers to others first
  foreach k in array array['bill','wo','wh_moves','wh_catalog','eng','portal','costs','cc','tickets','schooldb','misc'] loop
    if not k = any(parts) then continue; end if;
    if k = 'cc' and to_regclass('public.fm_cc_centers') is not null then
      if to_regclass('public.fm_contracts') is not null then update public.fm_contracts set cc_id = null where cc_id is not null; end if;
      update public.fm_cc_centers set parent_id = null where parent_id is not null;
    end if;
    for t in select jsonb_array_elements_text(P->k) loop
      if to_regclass('public.' || t) is not null then
        execute format('delete from public.%I where true', t); get diagnostics n = row_count;   -- V203: Supabase (pg_safeupdate) refuses a DELETE without WHERE
        r := r || jsonb_build_object(t, coalesce((r->>t)::bigint, 0) + n);
      end if;
    end loop;
    if k in ('tickets','schooldb') then
      delete from public.app_kv a where public.fm_wipe_kv_match(k, a.key); get diagnostics n = row_count;
      r := r || jsonb_build_object('app_kv:' || k, n);
    end if;
  end loop;
  -- the photo files of the emptied parts (newer projects refuse deletes from storage in SQL: they stay, unseen)
  begin
    if 'tickets' = any(parts) then delete from storage.objects where bucket_id = 'ticket-photos'; get diagnostics n = row_count; files := files + n; end if;
    if 'wo' = any(parts) then delete from storage.objects where bucket_id = 'wo-photos'; get diagnostics n = row_count; files := files + n; end if;
    if 'eng' = any(parts) then delete from storage.objects where bucket_id = 'school-engagement'; get diagnostics n = row_count; files := files + n; end if;
  exception when others then files_left := true; end;
  insert into public.fm_settings(key, value) values ('wipe', jsonb_build_object('at', now(), 'parts', to_jsonb(parts), 'by', nm))
    on conflict (key) do update set value = excluded.value, updated_at = now();
  insert into public.fm_audit_log(actor_name, action, target, details) values (nm, 'wipe', array_to_string(parts, ','), jsonb_build_object('rows', r, 'files', files));
  return jsonb_build_object('parts', to_jsonb(parts), 'rows', r, 'files', files, 'files_left', files_left);
end $$;
revoke all on function public.fm_wipe_parts(), public.fm_wipe_kv_match(text, text), public.fm_wipe_ok() from public, anon, authenticated;
revoke all on function public.fm_wipe_counts(), public.fm_wipe_backup(text[]), public.fm_wipe(text[], text) from public, anon;
grant execute on function public.fm_wipe_counts(), public.fm_wipe_backup(text[]), public.fm_wipe(text[], text) to authenticated;

-- ---------- 31) reset backup in pages (V202) ----------
-- One call with every row (fm_wipe_backup) can pass the API's time / size limits on a real project (≈ 40 MB for 6 000
-- tickets), and then the reset stopped before deleting anything. The platform now reads the backup in pages.
-- fm_wipe_plan(parts) → {tables:[{t, n}], kv:{…}} ; fm_wipe_backup_page(table, offset, limit) → rows (≤ 1000)
create or replace function public.fm_wipe_plan(p_parts text[]) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare P jsonb := public.fm_wipe_parts(); k text; t text; n bigint; tabs jsonb := '[]'; seen text[] := '{}'; kv jsonb := '{}'; v jsonb;
begin
  if not public.fm_wipe_ok() then raise exception 'not allowed'; end if;
  foreach k in array coalesce(p_parts,'{}') loop
    if not P ? k then continue; end if;
    for t in select jsonb_array_elements_text(P->k) loop
      if to_regclass('public.' || t) is not null and not t = any(seen) then
        execute format('select count(*) from public.%I', t) into n; tabs := tabs || jsonb_build_object('t', t, 'n', n); seen := seen || t;
      end if;
    end loop;
    if k in ('tickets','schooldb') then
      select coalesce(jsonb_object_agg(a.key, a.value), '{}') into v from public.app_kv a where public.fm_wipe_kv_match(k, a.key);
      kv := kv || jsonb_build_object(k, v);
    end if;
  end loop;
  return jsonb_build_object('at', now(), 'parts', to_jsonb(p_parts), 'tables', tabs, 'kv', kv);
end $$;
create or replace function public.fm_wipe_backup_page(p_table text, p_offset int, p_limit int) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare ok boolean; r jsonb;
begin
  if not public.fm_wipe_ok() then raise exception 'not allowed'; end if;
  select exists(select 1 from jsonb_each(public.fm_wipe_parts()) e, jsonb_array_elements_text(e.value) x where x = p_table) into ok;
  if not ok or to_regclass('public.' || p_table) is null then raise exception 'unknown table'; end if;
  execute format('select coalesce(jsonb_agg(to_jsonb(x)), ''[]'') from (select * from public.%I order by ctid offset %s limit %s) x',
                 p_table, greatest(coalesce(p_offset,0),0), least(greatest(coalesce(p_limit,500),1),1000)) into r;
  return r;
end $$;
revoke all on function public.fm_wipe_plan(text[]), public.fm_wipe_backup_page(text, int, int) from public, anon;
grant execute on function public.fm_wipe_plan(text[]), public.fm_wipe_backup_page(text, int, int) to authenticated;

-- ---------- 32) personal file of each account (V206, field F38) ----------
-- emp_no (الرقم الوظيفي) is set by the system admin only. personal = the person's own data, written only through
-- fm_update_my_profile (whitelisted keys, trimmed, ≤ 200 chars each). The person cannot change his name or emp_no himself.
alter table public.profiles add column if not exists emp_no   text;
alter table public.profiles add column if not exists personal jsonb not null default '{}'::jsonb;
drop policy if exists p_profiles_self on public.profiles;
create policy p_profiles_self on public.profiles for update using (id = auth.uid())
  with check (id = auth.uid() and role = (select role from public.profiles where id = auth.uid())
              and job_title is not distinct from (select job_title from public.profiles where id = auth.uid())
              and person_names = (select person_names from public.profiles where id = auth.uid())
              and regions = (select regions from public.profiles where id = auth.uid())
              and active = (select active from public.profiles where id = auth.uid())
              and reports_to is not distinct from (select reports_to from public.profiles where id = auth.uid())
              and full_name is not distinct from (select full_name from public.profiles where id = auth.uid())
              and emp_no is not distinct from (select emp_no from public.profiles where id = auth.uid())
              and personal = (select personal from public.profiles where id = auth.uid()));
create or replace function public.fm_profile_keys() returns text[] language sql immutable as $$
  select array['phone2','nid','nid_exp','nationality','birth','blood','marital','city','district','address',
               'emerg_name','emerg_rel','emerg_phone','license_no','license_exp','qualification','specialty','experience','hire_date','bank_iban','notes'] $$;
create or replace function public.fm_update_my_profile(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare k text; v text; outv jsonb := '{}'; cur jsonb;
begin
  if auth.uid() is null then raise exception 'not allowed' using errcode = '42501'; end if;
  select personal into cur from public.profiles where id = auth.uid();
  if not found then raise exception 'not allowed' using errcode = '42501'; end if;
  outv := coalesce(cur, '{}');
  for k in select unnest(public.fm_profile_keys()) loop
    if p ? k then
      v := left(btrim(coalesce(p->>k, '')), 200);
      if k in ('nid_exp','birth','license_exp','hire_date') and v <> '' and v !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'bad date: %', k; end if;
      if v = '' then outv := outv - k; else outv := outv || jsonb_build_object(k, v); end if;
    end if;
  end loop;
  update public.profiles set personal = outv, updated_at = now() where id = auth.uid();
  if p ? 'phone' then
    update public.profiles set phone = nullif(left(btrim(p->>'phone'), 30), '') where id = auth.uid();
    perform public.fm_apply_contact(auth.uid());
  end if;
  return outv;
end $$;
revoke all on function public.fm_update_my_profile(jsonb) from public, anon;
grant execute on function public.fm_update_my_profile(jsonb) to authenticated;
-- the person's own manager line (name and phone) for his profile page
create or replace function public.fm_my_manager() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', b.id, 'name', coalesce(b.full_name, b.email), 'phone', b.phone, 'title', b.job_title)
  from public.profiles m join public.profiles b on b.id = m.reports_to where m.id = auth.uid() $$;
revoke all on function public.fm_my_manager() from public, anon;
grant execute on function public.fm_my_manager() to authenticated;

-- ---------- 33) spare-parts catalog with the client's codes and photos (V207, field F39) ----------
-- ext_code = the item code in the client's system (Logix); thumb = a small JPEG (≤ 60 000 chars) shown in lists and in the
-- field request picker. fm_wh_catalog_import(rows) adds / updates items from a catalog file and returns each row's item id
-- so the platform can upload the row's photos (fm_mat_photo). New items follow the normal approval (fm_mat_save).
alter table public.wo_materials add column if not exists ext_code text;
alter table public.wo_materials add column if not exists thumb text;
alter table public.wo_materials drop constraint if exists wo_materials_thumb_check;
alter table public.wo_materials add constraint wo_materials_thumb_check check (thumb is null or (thumb ~ '^data:image/(jpeg|png|webp);base64,' and length(thumb) <= 60000));
create index if not exists wo_materials_ext_idx on public.wo_materials (lower(ext_code));
-- set the client code and / or the thumbnail of an item: p {ext_code?, thumb?} (a key present = set it, empty = clear)
create or replace function public.fm_mat_extra(p_id uuid, p jsonb) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.fm_wh_edit() then raise exception 'not allowed'; end if;
  if not exists(select 1 from public.wo_materials where id = p_id) then raise exception 'not found'; end if;
  if p ? 'ext_code' then update public.wo_materials set ext_code = left(nullif(btrim(coalesce(p->>'ext_code','')),''),60), updated_at = now() where id = p_id; end if;
  if p ? 'thumb' then update public.wo_materials set thumb = nullif(p->>'thumb',''), updated_at = now() where id = p_id; end if;
end $$;
-- rows [{i, name, ext_code, unit, category, specs}] (≤ 500 a call) → [{i, id, st: new | updated | skipped, err?}]
-- match: the name, else the client code when exactly one item has it (and the row has no nocode flag)
create or replace function public.fm_wh_catalog_import(p_rows jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare x jsonb; mid uuid; n int; out jsonb := '[]'; ec text; nm text; st text;
begin
  if auth.uid() is null or not public.fm_wh_edit() then raise exception 'not allowed'; end if;
  if jsonb_array_length(coalesce(p_rows,'[]')) > 500 then raise exception 'too many rows'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_rows,'[]')) loop
    ec := nullif(btrim(coalesce(x->>'ext_code','')),''); nm := btrim(coalesce(x->>'name','')); mid := null;
    if nm = '' then out := out || jsonb_build_object('i', x->'i', 'st', 'skipped', 'err', 'name required'); continue; end if;
    begin
      select id into mid from public.wo_materials where lower(name) = lower(nm) limit 1;
      -- a renamed item is found by its client code (not when the code repeats in the file: nocode)
      if mid is null and ec is not null and not coalesce((x->>'nocode')::boolean, false) then
        select count(*) into n from public.wo_materials where lower(ext_code) = lower(ec);
        if n = 1 then select id into mid from public.wo_materials where lower(ext_code) = lower(ec); end if;
      end if;
      if mid is null then
        mid := public.fm_mat_save(jsonb_strip_nulls(jsonb_build_object('name', nm, 'unit', x->>'unit', 'category', x->>'category', 'specs', nullif(btrim(coalesce(x->>'specs','')),''))));
        st := 'new';
      else
        perform public.fm_mat_save(jsonb_strip_nulls(jsonb_build_object('id', mid, 'name', (select name from public.wo_materials where id = mid),
          'unit', nullif(btrim(coalesce(x->>'unit','')),''), 'category', nullif(btrim(coalesce(x->>'category','')),''), 'specs', nullif(btrim(coalesce(x->>'specs','')),''))));
        st := 'updated';
      end if;
      if ec is not null then update public.wo_materials set ext_code = left(ec,60) where id = mid; end if;
      out := out || jsonb_build_object('i', x->'i', 'id', mid, 'st', st, 'photos', (select count(*) from public.wo_material_photos where material_id = mid));
    exception when others then
      out := out || jsonb_build_object('i', x->'i', 'st', 'skipped', 'err', left(sqlerrm, 200));
    end;
  end loop;
  return out;
end $$;
revoke all on function public.fm_mat_extra(uuid, jsonb), public.fm_wh_catalog_import(jsonb) from public, anon;
grant execute on function public.fm_mat_extra(uuid, jsonb), public.fm_wh_catalog_import(jsonb) to authenticated;

-- ---------- 34) technician part suggestions and the low-stock alert (V208, field F40) ----------
-- A technician who cannot find a part in the catalog sends its photo and description; the storekeeper (or anyone who edits
-- the warehouse, fm_wh_edit) adds it as a new item (normal approval), links it to an existing item, or rejects it with a reason.
create table if not exists public.wo_part_suggestions (
  id          uuid primary key default gen_random_uuid(),
  code        text unique,
  by_id       uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  by_name     text,
  region      text,
  name        text not null,
  descr       text,
  category    text,
  unit        text,
  qty         numeric,
  photo       text check (photo is null or (photo ~ '^data:image/(jpeg|png|webp);base64,' and length(photo) <= 420000)),
  wo_id       uuid,
  wo_code     text,
  ticket_ref  text,
  status      text not null default 'new' check (status in ('new','added','linked','rejected')),
  material_id uuid references public.wo_materials(id) on delete set null,
  note        text,
  done_by     text,
  done_at     timestamptz,
  at          timestamptz not null default now()
);
create index if not exists wo_part_sugg_idx on public.wo_part_suggestions (status, at desc);
alter table public.wo_part_suggestions enable row level security;
drop policy if exists p_wps_read on public.wo_part_suggestions;
create policy p_wps_read on public.wo_part_suggestions for select using (by_id = auth.uid() or public.fm_wh_edit()
  or coalesce(public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager'), false));
revoke insert, update, delete on public.wo_part_suggestions from anon, authenticated;
create sequence if not exists public.wo_part_sugg_seq;
-- the storekeepers who should hear about a region (the keeper of its stores, else the storekeepers of that region)
create or replace function public.fm_wh_keepers_of(p_region text) returns setof uuid language sql stable security definer set search_path = public as $$
  select distinct u from (
    select s.keeper u from public.wo_stores s where s.active and s.keeper is not null and (p_region is null or s.region is null or s.region = p_region)
    union
    select p.id from public.profiles p where p.active and p.job_title = 'storekeeper'
      and (p_region is null or cardinality(p.regions) = 0 or p_region = any(p.regions))) x where u is not null $$;
revoke all on function public.fm_wh_keepers_of(text) from public, anon, authenticated;
-- p {name, descr, category, unit, qty, photo, wo_id, ticket_ref}
create or replace function public.fm_part_suggest(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; r public.wo_part_suggestions; w public.work_orders; k uuid; q numeric := nullif(p->>'qty','')::numeric;
begin
  select * into me from public.profiles where id = auth.uid() and active;
  if not found or public.fm_role() = 'pending' then raise exception 'not allowed'; end if;
  if btrim(coalesce(p->>'name','')) = '' then raise exception 'name required'; end if;
  if q is not null and (q <= 0 or q > 100000) then raise exception 'invalid qty'; end if;
  if (select count(*) from public.wo_part_suggestions where by_id = auth.uid() and at > now() - interval '1 day') >= 20 then raise exception 'too many today'; end if;
  if nullif(p->>'wo_id','') is not null then select * into w from public.work_orders where id = (p->>'wo_id')::uuid; end if;
  insert into public.wo_part_suggestions(code, by_name, region, name, descr, category, unit, qty, photo, wo_id, wo_code, ticket_ref)
  values ('PS-' || to_char(now(),'YYYY') || '-' || lpad(nextval('public.wo_part_sugg_seq')::text, 4, '0'), coalesce(me.full_name, me.email),
    coalesce(w.region, (me.regions)[1]), left(btrim(p->>'name'),200), left(nullif(btrim(coalesce(p->>'descr','')),''),1000),
    left(nullif(btrim(coalesce(p->>'category','')),''),80), left(nullif(btrim(coalesce(p->>'unit','')),''),40), q, nullif(p->>'photo',''),
    w.id, w.code, left(nullif(btrim(coalesce(p->>'ticket_ref','')),''),60)) returning * into r;
  begin
    for k in select * from public.fm_wh_keepers_of(r.region) loop
      perform public.fm_push_add(k, 'wh_req', '💡 صنف مقترح من ' || coalesce(r.by_name,''), r.name || coalesce(' — ' || r.wo_code, ''), 'wh=sugg', 'sugg');
    end loop;
  exception when others then null; end;
  return jsonb_build_object('id', r.id, 'code', r.code);
end $$;
-- action: add (p {name?, category?, unit?, specs?}: a new item from the suggestion, its photo copied) | link (p {material_id}) | reject (p {note})
create or replace function public.fm_part_suggest_act(p_id uuid, p_action text, p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.wo_part_suggestions; mid uuid; nm text := public.fm_me_name();
begin
  if auth.uid() is null or not public.fm_wh_edit() then raise exception 'not allowed'; end if;
  select * into r from public.wo_part_suggestions where id = p_id for update;
  if not found then raise exception 'not found'; end if;
  if r.status <> 'new' then raise exception 'already handled'; end if;
  if p_action = 'add' then
    mid := public.fm_mat_save(jsonb_strip_nulls(jsonb_build_object('name', coalesce(nullif(btrim(coalesce(p->>'name','')),''), r.name),
      'category', coalesce(nullif(btrim(coalesce(p->>'category','')),''), r.category), 'unit', coalesce(nullif(btrim(coalesce(p->>'unit','')),''), r.unit),
      'specs', coalesce(nullif(btrim(coalesce(p->>'specs','')),''), r.descr), 'notes', 'مقترح من ' || coalesce(r.by_name,'') || ' (' || r.code || ')')));
    if r.photo is not null then insert into public.wo_material_photos(material_id, data) values (mid, r.photo); end if;
    update public.wo_part_suggestions set status = 'added', material_id = mid, note = left(nullif(btrim(coalesce(p->>'note','')),''),500), done_by = nm, done_at = now() where id = r.id;
  elsif p_action = 'link' then
    mid := nullif(p->>'material_id','')::uuid;
    if mid is null or not exists(select 1 from public.wo_materials where id = mid) then raise exception 'unknown material'; end if;
    update public.wo_part_suggestions set status = 'linked', material_id = mid, note = left(nullif(btrim(coalesce(p->>'note','')),''),500), done_by = nm, done_at = now() where id = r.id;
  elsif p_action = 'reject' then
    if btrim(coalesce(p->>'note','')) = '' then raise exception 'reason required'; end if;
    update public.wo_part_suggestions set status = 'rejected', note = left(btrim(p->>'note'),500), done_by = nm, done_at = now() where id = r.id;
  else raise exception 'invalid action'; end if;
  begin
    perform public.fm_push_add(r.by_id, 'wh_issued', case p_action when 'reject' then '✋ لم يُعتمد الصنف المقترح' else '✅ أُضيف الصنف المقترح' end,
      r.name || case when p_action = 'reject' then ' — ' || btrim(p->>'note') when p_action = 'link' then ' → ' || (select name from public.wo_materials where id = mid) else '' end, 'cus', null);
  exception when others then null; end;
  return jsonb_build_object('status', (select status from public.wo_part_suggestions where id = r.id), 'material_id', mid);
end $$;
revoke all on function public.fm_part_suggest(jsonb), public.fm_part_suggest_act(uuid, text, jsonb) from public, anon;
grant execute on function public.fm_part_suggest(jsonb), public.fm_part_suggest_act(uuid, text, jsonb) to authenticated;
-- daily: each storekeeper hears how many items of his stores are below their minimum (wo_stock.min_qty > 0 and qty < min)
create or replace function public.fm_wh_low_daily() returns int language plpgsql security definer set search_path = public as $$
declare s record; k uuid; n int := 0;
begin
  for s in select st.id, st.name, st.region, count(*) c, string_agg(m.name, '، ' order by m.name) names
           from public.wo_stock x join public.wo_stores st on st.id = x.store_id and st.active join public.wo_materials m on m.id = x.material_id and m.active
           where coalesce(x.min_qty,0) > 0 and coalesce(x.qty,0) < x.min_qty group by st.id, st.name, st.region loop
    for k in select * from public.fm_wh_keepers_of(s.region) loop
      begin
        if public.fm_push_add(k, 'wh_low', '⚠️ ' || s.c || ' صنف تحت الحد الأدنى — ' || s.name, left(s.names, 250), 'wh=low', 'low-' || s.id, true) then n := n + 1; end if;
      exception when others then null; end;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.fm_wh_low_daily() from public, anon, authenticated;
do $do$ begin
  begin execute 'select cron.unschedule(''fm-wh-low'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-wh-low'', ''10 5 * * *'', ''select public.fm_wh_low_daily()'')';
  exception when others then raise notice 'pg_cron is not available: the daily low-stock alert is not sent (the platform still shows it)'; end;
end $do$;

-- ---------- 35) the storekeeper issues directly, edits or deletes a pending request (V210) ----------
-- The storekeeper may now raise a request for a supervisor / contractor / area engineer of his regions (and issue it at once),
-- and edit (lines, note) or delete a request that has not been issued yet. A deleted request stays as «cancelled» with the reason.
create or replace function public.fm_wh_may_direct(h uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.profiles p where p.id = h and p.active and public.fm_posx(p.role, p.job_title) in ('supervisor','contractor','area_engineer'))
    and ((coalesce(public.fm_my_pos() in ('sysadmin','project_manager','ops_manager','area_manager','area_engineer') or public.fm_role() = 'admin', false)
      and (public.fm_is_under(h, auth.uid()) or public.fm_wh_admin()
        or (public.fm_my_pos() = 'area_manager' and exists(select 1 from public.profiles p where p.id = h
              and (cardinality(public.fm_regions()) = 0 or p.regions && public.fm_regions())))))
     or (public.fm_my_pos() = 'storekeeper' and exists(select 1 from public.profiles p where p.id = h
              and (cardinality(public.fm_regions()) = 0 or cardinality(p.regions) = 0 or p.regions && public.fm_regions())))) $$;
-- p {lines:[{material_id, qty}], note} | {delete: true, note}
create or replace function public.fm_issue_req_edit(p_id uuid, p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare r public.wo_issue_requests; x jsonb; L jsonb := '[]'; m public.wo_materials; q numeric; nm text := public.fm_me_name();
begin
  select * into r from public.wo_issue_requests where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if not (public.fm_wh_keeper(r.store_id) or r.requested_by = auth.uid()) then raise exception 'not allowed'; end if;
  if r.status <> 'requested' then raise exception 'invalid status'; end if;
  if coalesce((p->>'delete')::boolean, false) then
    if btrim(coalesce(p->>'note','')) = '' and r.requested_by <> auth.uid() then raise exception 'note required'; end if;
    update public.wo_issue_requests set status = 'cancelled', response = left('حُذف بواسطة ' || coalesce(nm,'') || coalesce(': ' || nullif(btrim(p->>'note'),''), ''), 500) where id = p_id;
    return 'cancelled';
  end if;
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    select * into m from public.wo_materials where id = nullif(x->>'material_id','')::uuid;
    if not found or not m.active or m.approved_at is null then raise exception 'item not approved: %', coalesce(m.name, x->>'material_id'); end if;
    q := nullif(x->>'qty','')::numeric;
    if q is null or q <= 0 or q > 100000 then raise exception 'invalid qty'; end if;
    if exists(select 1 from jsonb_array_elements(L) e where e->>'material_id' = m.id::text) then raise exception 'duplicate item: %', m.name; end if;
    L := L || jsonb_build_object('material_id', m.id, 'qty', q, 'issued', 0);
  end loop;
  if jsonb_array_length(L) = 0 then raise exception 'no lines'; end if;
  if jsonb_array_length(L) > 60 then raise exception 'too many lines'; end if;
  update public.wo_issue_requests set lines = L, note = case when p ? 'note' then left(nullif(btrim(coalesce(p->>'note','')),''),500) else note end,
    response = left(coalesce(nullif(response,'') || ' • ', '') || 'عدّله ' || coalesce(nm,''), 500) where id = p_id;
  return 'edited';
end $$;
revoke all on function public.fm_issue_req_edit(uuid, jsonb) from public, anon;
grant execute on function public.fm_issue_req_edit(uuid, jsonb) to authenticated;

-- done. Next: in the platform → الإعدادات → «السحابة والمستخدمين», paste the Project URL and the anon key.


-- V192: shared team readiness.
-- V192: shared team readiness, region-scoped permissions and optimistic concurrency.
begin;
create table if not exists public.fm_team_readiness (
 id uuid primary key default gen_random_uuid(), name text not null check(length(trim(name)) between 1 and 120),
 region text not null check(region in ('riyadh','qassim')), leader text not null default '',
 status text not null default 'ready' check(status in ('ready','limited','stopped')),
 reason text not null default '' check(reason in ('','vehicle','labor','materials','other')),
 owner_name text not null default '', due_at timestamptz, schools text[] not null default '{}',
 note text not null default '', blocked_since timestamptz, revision int not null default 1,
 updated_by uuid references public.profiles(id), updated_at timestamptz not null default now(),
 check(status='ready' or (reason<>'' and length(trim(owner_name))>0 and due_at is not null)),
 check(cardinality(schools)<=500),check(length(note)<=4000),check(length(leader)<=120),check(length(owner_name)<=120)
);
create table if not exists public.fm_team_readiness_events (
 id bigint generated always as identity primary key, team_id uuid not null references public.fm_team_readiness(id),
 at timestamptz not null default now(), by_user uuid references public.profiles(id), old_value jsonb, new_value jsonb not null
);
alter table public.fm_team_readiness enable row level security;
alter table public.fm_team_readiness_events enable row level security;
revoke all on public.fm_team_readiness, public.fm_team_readiness_events from anon, authenticated;
create or replace function public.fm_ready_read(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(public.fm_role()<>'pending' and (public.fm_role()='admin' or public.fm_my_pos() in ('dept_manager','project_manager','ops_manager','qa_manager','hse_manager','owner_rep') or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_region_ok(r))),false) $$;
create or replace function public.fm_ready_write(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(public.fm_role()<>'pending' and (public.fm_role()='admin' or public.fm_my_pos() in ('project_manager','ops_manager') or (public.fm_my_pos()='area_manager' and public.fm_region_ok(r))),false) $$;
create or replace function public.fm_ready_list() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(t)||jsonb_build_object('can_edit',public.fm_ready_write(t.region)) order by t.updated_at desc),'[]'::jsonb) from public.fm_team_readiness t where public.fm_ready_read(t.region) $$;
create or replace function public.fm_ready_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
 declare old public.fm_team_readiness; v public.fm_team_readiness; k uuid; rg text:=p->>'region';
 begin
 if not public.fm_ready_write(rg) then raise exception 'not allowed'; end if;
 if nullif(p->>'id','') is not null then
  select * into old from public.fm_team_readiness where id=(p->>'id')::uuid for update;
  if not found or not public.fm_ready_write(old.region) then raise exception 'not allowed'; end if;
  if old.revision<>coalesce((p->>'revision')::int,0) then raise exception 'version conflict: reload'; end if;
  k:=old.id;
 else k:=gen_random_uuid(); end if;
 insert into public.fm_team_readiness(id,name,region,leader,status,reason,owner_name,due_at,schools,note,blocked_since,revision,updated_by)
 values(k,trim(p->>'name'),rg,coalesce(p->>'leader',''),p->>'status',case when p->>'status'='ready' then '' else coalesce(p->>'reason','') end,
 coalesce(p->>'owner_name',''),nullif(p->>'due_at','')::timestamptz,
 array(select distinct trim(x) from jsonb_array_elements_text(coalesce(p->'schools','[]')) as codes(x) where trim(x)<>''),coalesce(p->>'note',''),
 case when p->>'status'='ready' then null else coalesce(old.blocked_since,now()) end,coalesce(old.revision,0)+1,auth.uid())
 on conflict(id) do update set name=excluded.name,region=excluded.region,leader=excluded.leader,status=excluded.status,reason=excluded.reason,owner_name=excluded.owner_name,due_at=excluded.due_at,schools=excluded.schools,note=excluded.note,blocked_since=excluded.blocked_since,revision=excluded.revision,updated_by=excluded.updated_by,updated_at=now() returning * into v;
 insert into public.fm_team_readiness_events(team_id,by_user,old_value,new_value) values(k,auth.uid(),case when old.id is null then null else to_jsonb(old) end,to_jsonb(v));
 return to_jsonb(v);
 end $$;
create or replace function public.fm_ready_history(p_id uuid) returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(e) order by e.at desc,e.id desc),'[]'::jsonb) from public.fm_team_readiness_events e join public.fm_team_readiness t on t.id=e.team_id where e.team_id=p_id and public.fm_ready_read(t.region) $$;
revoke all on function public.fm_ready_read(text),public.fm_ready_write(text),public.fm_ready_list(),public.fm_ready_save(jsonb),public.fm_ready_history(uuid) from public,anon;
grant execute on function public.fm_ready_read(text),public.fm_ready_write(text),public.fm_ready_list(),public.fm_ready_save(jsonb),public.fm_ready_history(uuid) to authenticated;
commit;


-- V193 parts follow-up; full initial setup includes this migration.
-- V193: follow up existing issue requests, without changing stock or SLA.
-- Prerequisites: current supabase_setup.sql through V192.
begin;
create table if not exists public.fm_parts_followup (
 request_id uuid primary key references public.wo_issue_requests(id) on delete cascade,
 owner_id uuid not null references public.profiles(id), due_at timestamptz not null,
 stage text not null check(stage in ('stock','purchase','ordered','available','hold')),
 supplier text not null default '' check(length(supplier)<=200), team_id uuid references public.fm_team_readiness(id) on delete set null,
 note text not null check(length(trim(note)) between 1 and 4000),
 revision int not null default 1, updated_by uuid references public.profiles(id), updated_at timestamptz not null default now(),
 escalated_to uuid references public.profiles(id), escalated_by uuid references public.profiles(id), escalated_at timestamptz
);
create table if not exists public.fm_parts_events (
 id bigint generated always as identity primary key, request_id uuid not null references public.wo_issue_requests(id) on delete cascade,
 at timestamptz not null default now(), by_user uuid references public.profiles(id), kind text not null check(kind in ('followup','escalation')),
 old_value jsonb, new_value jsonb not null
);
create index if not exists fm_parts_events_request_at on public.fm_parts_events(request_id,at desc);
alter table public.fm_parts_followup enable row level security;
alter table public.fm_parts_events enable row level security;
revoke all on public.fm_parts_followup,public.fm_parts_events from anon,authenticated;
create or replace function public.fm_parts_region(k uuid) returns text language sql stable security definer set search_path=public as $$
 select coalesce(nullif(w.region,''),nullif(s.region,''),case when cardinality(p.regions)=1 then p.regions[1] end,'')
 from public.wo_issue_requests r left join public.work_orders w on w.id=r.wo_id left join public.wo_stores s on s.id=r.store_id left join public.profiles p on p.id=r.holder where r.id=k $$;
create or replace function public.fm_parts_can(k uuid, write_access boolean default false) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role()<>'pending' and public.fm_mod('wh') and exists(select 1 from public.wo_issue_requests r where r.id=k and (
 public.fm_role()='admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager')
 or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_parts_region(k)<>'' and public.fm_region_ok(public.fm_parts_region(k)))
 or (public.fm_my_pos()='storekeeper' and public.fm_wh_keeper(r.store_id))
 or (not write_access and (r.requested_by=auth.uid() or r.holder=auth.uid() or public.fm_my_pos() in ('dept_manager','qa_manager','owner_rep')))
 )),false) $$;
create or replace function public.fm_parts_person(k uuid,p_user uuid,escalation boolean default false) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.profiles p where p.id=p_user and p.active and public.fm_posx(p.role,p.job_title)=any(case when escalation then array['sysadmin','project_manager','ops_manager','area_manager'] else array['sysadmin','project_manager','ops_manager','area_manager','area_engineer','storekeeper'] end)
 and (public.fm_posx(p.role,p.job_title) in ('sysadmin','project_manager','ops_manager') or cardinality(p.regions)=0 or public.fm_parts_region(k)=any(p.regions))) $$;
create or replace function public.fm_parts_list() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(r)||jsonb_build_object('region',public.fm_parts_region(r.id),'can_edit',public.fm_parts_can(r.id,true),'followup',case when f.request_id is null then null else to_jsonb(f)||jsonb_build_object('owner_name',o.full_name,'team_name',t.name,'escalated_name',ep.full_name) end,
 'items',coalesce((select jsonb_agg(l||jsonb_build_object('name',m.name,'unit',m.unit)) from jsonb_array_elements(r.lines) as lines(l) left join public.wo_materials m on m.id=nullif(l->>'material_id','')::uuid),'[]'::jsonb)) order by r.at desc),'[]'::jsonb)
 from public.wo_issue_requests r left join public.fm_parts_followup f on f.request_id=r.id left join public.profiles o on o.id=f.owner_id left join public.fm_team_readiness t on t.id=f.team_id left join public.profiles ep on ep.id=f.escalated_to where public.fm_parts_can(r.id,false) $$;
create or replace function public.fm_parts_options(k uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
 begin
 if not public.fm_parts_can(k,true) then raise exception 'not allowed';end if;
 return jsonb_build_object('people',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(p.full_name,p.email),'can_escalate',public.fm_parts_person(k,p.id,true)) order by p.full_name),'[]'::jsonb) from public.profiles p where public.fm_parts_person(k,p.id,false)),
 'teams',(select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'name',t.name) order by t.name),'[]'::jsonb) from public.fm_team_readiness t where t.region=public.fm_parts_region(k) and public.fm_ready_read(t.region)));
 end $$;
create or replace function public.fm_parts_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
 declare k uuid:=(p->>'request_id')::uuid; r public.wo_issue_requests; old public.fm_parts_followup; v public.fm_parts_followup; own uuid:=(p->>'owner_id')::uuid; team uuid:=nullif(p->>'team_id','')::uuid;
 begin
 -- Lock the source request as well, so first-time follow-up creation cannot race.
 select * into r from public.wo_issue_requests where id=k for update;
 if not found or not public.fm_parts_can(k,true) then raise exception 'not allowed'; end if;
 if r.status not in ('requested','partial','issued') then raise exception 'request finished';end if;
 if not public.fm_parts_person(k,own,false) then raise exception 'invalid owner';end if;
 if team is not null and not exists(select 1 from public.fm_team_readiness t where t.id=team and t.region=public.fm_parts_region(k) and public.fm_ready_read(t.region)) then raise exception 'invalid team';end if;
 select * into old from public.fm_parts_followup where request_id=k for update;
 if coalesce(old.revision,0)<>coalesce((p->>'revision')::int,0) then raise exception 'version conflict: reload';end if;
 insert into public.fm_parts_followup(request_id,owner_id,due_at,stage,supplier,team_id,note,revision,updated_by)
 values(k,own,(p->>'due_at')::timestamptz,p->>'stage',coalesce(p->>'supplier',''),team,trim(p->>'note'),coalesce(old.revision,0)+1,auth.uid())
 on conflict(request_id) do update set owner_id=excluded.owner_id,due_at=excluded.due_at,stage=excluded.stage,supplier=excluded.supplier,team_id=excluded.team_id,note=excluded.note,revision=excluded.revision,updated_by=excluded.updated_by,updated_at=now() returning * into v;
 insert into public.fm_parts_events(request_id,by_user,kind,old_value,new_value) values(k,auth.uid(),'followup',case when old.request_id is null then null else to_jsonb(old) end,to_jsonb(v));return to_jsonb(v);
 end $$;
create or replace function public.fm_parts_escalate(k uuid,p_to uuid,p_note text,p_revision int) returns jsonb language plpgsql security definer set search_path=public as $$
 declare r public.wo_issue_requests; old public.fm_parts_followup; v public.fm_parts_followup;
 begin
 select * into r from public.wo_issue_requests where id=k for update;
 if not found or not public.fm_parts_can(k,true) then raise exception 'not allowed';end if;
 if r.status not in ('requested','partial','issued') then raise exception 'request finished';end if;
 if not public.fm_parts_person(k,p_to,true) or length(trim(coalesce(p_note,''))) not between 1 and 4000 then raise exception 'invalid escalation';end if;
 select * into old from public.fm_parts_followup where request_id=k for update;
 if not found then raise exception 'save followup first';end if;
 if old.revision is distinct from p_revision then raise exception 'version conflict: reload';end if;
 update public.fm_parts_followup set escalated_to=p_to,escalated_by=auth.uid(),escalated_at=now(),note=trim(p_note),revision=revision+1,updated_by=auth.uid(),updated_at=now() where request_id=k returning * into v;
 insert into public.fm_parts_events(request_id,by_user,kind,old_value,new_value) values(k,auth.uid(),'escalation',to_jsonb(old),to_jsonb(v));return to_jsonb(v);
 end $$;
create or replace function public.fm_parts_history(k uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
 begin if not public.fm_parts_can(k,false) then raise exception 'not allowed';end if;
 return (select coalesce(jsonb_agg(to_jsonb(e) order by e.at desc,e.id desc),'[]'::jsonb) from public.fm_parts_events e where e.request_id=k);end $$;
revoke all on function public.fm_parts_region(uuid),public.fm_parts_can(uuid,boolean),public.fm_parts_person(uuid,uuid,boolean),public.fm_parts_list(),public.fm_parts_options(uuid),public.fm_parts_save(jsonb),public.fm_parts_escalate(uuid,uuid,text,int),public.fm_parts_history(uuid) from public,anon;
grant execute on function public.fm_parts_can(uuid,boolean),public.fm_parts_list(),public.fm_parts_options(uuid),public.fm_parts_save(jsonb),public.fm_parts_escalate(uuid,uuid,text,int),public.fm_parts_history(uuid) to authenticated;
notify pgrst, 'reload schema';
commit;

-- V194 quality and bill follow-up.
-- V194: quality-review annotations and contractor-payment follow-up.
begin;
create table if not exists public.fm_close_reviews (
 region text not null, old_id text not null, new_id text not null,
 result text not null check(result in ('pending','confirmed','different','actioned')),
 note text not null check(length(trim(note)) between 1 and 4000), revision int not null default 1,
 updated_by uuid references public.profiles(id),updated_at timestamptz not null default now(),
 primary key(region,old_id,new_id),check(lower(trim(old_id))<>lower(trim(new_id)))
);
create table if not exists public.fm_close_review_events (
 id bigint generated always as identity primary key, region text not null,old_id text not null,new_id text not null,
 at timestamptz not null default now(),by_user uuid references public.profiles(id),old_value jsonb,new_value jsonb not null
);
alter table public.fm_close_reviews enable row level security;
alter table public.fm_close_review_events enable row level security;
revoke all on public.fm_close_reviews,public.fm_close_review_events from anon,authenticated;
create or replace function public.fm_close_can(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role()<>'pending' and public.fm_mod('tickets') and (public.fm_role()='admin' or public.fm_my_pos() in ('sysadmin','qa_manager','project_manager','ops_manager') or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_region_ok(r))),false) $$;
create or replace function public.fm_close_list(r text) returns jsonb language plpgsql stable security definer set search_path=public as $$
 begin if not public.fm_close_can(r) then raise exception 'not allowed';end if;return (select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb) from public.fm_close_reviews x where x.region=r);end $$;
create or replace function public.fm_close_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
 declare rg text:=p->>'region';o text:=trim(p->>'old_id');n text:=trim(p->>'new_id');old public.fm_close_reviews;v public.fm_close_reviews;
 begin
 if not public.fm_close_can(rg) then raise exception 'not allowed';end if;
 if lower(o)=lower(n) or o is null or n is null then raise exception 'distinct tickets required';end if;
 if not exists(select 1 from public.tickets t where t.region=rg and t.ticket_id=o) or not exists(select 1 from public.tickets t where t.region=rg and t.ticket_id=n) then raise exception 'upload both tickets to cloud first';end if;
 perform pg_advisory_xact_lock(hashtextextended('fmclose:'||rg||':'||o||':'||n,0));
 select * into old from public.fm_close_reviews where region=rg and old_id=o and new_id=n for update;
 if coalesce(old.revision,0)<>coalesce((p->>'revision')::int,0) then raise exception 'version conflict: reload';end if;
 insert into public.fm_close_reviews(region,old_id,new_id,result,note,revision,updated_by)
 values(rg,o,n,p->>'result',trim(p->>'note'),coalesce(old.revision,0)+1,auth.uid())
 on conflict(region,old_id,new_id) do update set result=excluded.result,note=excluded.note,revision=excluded.revision,updated_by=excluded.updated_by,updated_at=now() returning * into v;
 insert into public.fm_close_review_events(region,old_id,new_id,by_user,old_value,new_value) values(rg,o,n,auth.uid(),case when old.old_id is null then null else to_jsonb(old) end,to_jsonb(v));return to_jsonb(v);
 end $$;
create or replace function public.fm_close_history(r text,o text,n text) returns jsonb language plpgsql stable security definer set search_path=public as $$
 begin if not public.fm_close_can(r) then raise exception 'not allowed';end if;return(select coalesce(jsonb_agg(to_jsonb(e) order by e.at desc,e.id desc),'[]'::jsonb) from public.fm_close_review_events e where e.region=r and e.old_id=o and e.new_id=n);end $$;
create table if not exists public.fm_bill_followup (
 bill_id uuid primary key references public.fm_bills(id) on delete cascade,
 owner_id uuid not null references public.profiles(id),due_at timestamptz not null,
 documents jsonb not null default '[]' check(jsonb_typeof(documents)='array' and jsonb_array_length(documents)<=20),
 hold_reason text not null default '' check(length(hold_reason)<=1000),impact_note text not null default '' check(length(impact_note)<=2000),
 team_id uuid references public.fm_team_readiness(id) on delete set null,
 note text not null check(length(trim(note)) between 1 and 4000),revision int not null default 1,
 updated_by uuid references public.profiles(id),updated_at timestamptz not null default now()
);
create table if not exists public.fm_bill_followup_events (
 id bigint generated always as identity primary key,bill_id uuid not null references public.fm_bills(id) on delete cascade,
 at timestamptz not null default now(),by_user uuid references public.profiles(id),old_value jsonb,new_value jsonb not null
);
alter table public.fm_bill_followup enable row level security;alter table public.fm_bill_followup_events enable row level security;
revoke all on public.fm_bill_followup,public.fm_bill_followup_events from anon,authenticated;
create or replace function public.fm_bfollow_can(k uuid,w boolean default false) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(public.fm_role()<>'pending' and public.fm_mod('bill') and exists(select 1 from public.fm_bills b join public.fm_contracts c on c.id=b.contract_id where b.id=k and case when w then public.fm_bill_can('prep',c.region) or public.fm_bill_can('pay',c.region) or public.fm_bill_can('review',c.region) else public.fm_bill_can('read',c.region) or c.contractor_id=auth.uid() end),false) $$;
create or replace function public.fm_bfollow_list() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(b)||jsonb_build_object('region',c.region,'contractor_name',c.contractor_name,'contract_name',c.name,'can_edit',public.fm_bfollow_can(b.id,true),'followup',case when f.bill_id is null then null else to_jsonb(f)||jsonb_build_object('owner_name',p.full_name,'team_name',t.name) end) order by b.created_at desc),'[]'::jsonb)
 from public.fm_bills b join public.fm_contracts c on c.id=b.contract_id left join public.fm_bill_followup f on f.bill_id=b.id left join public.profiles p on p.id=f.owner_id left join public.fm_team_readiness t on t.id=f.team_id where public.fm_bfollow_can(b.id,false) $$;
create or replace function public.fm_bfollow_options(k uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
 declare rg text;begin
 if not public.fm_bfollow_can(k,true) then raise exception 'not allowed';end if;
 select c.region into rg from public.fm_contracts c join public.fm_bills b on b.contract_id=c.id where b.id=k;
 return jsonb_build_object('people',(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(p.full_name,p.email)) order by p.full_name),'[]'::jsonb) from public.profiles p where p.active and public.fm_posx(p.role,p.job_title) in ('sysadmin','accountant','project_manager','ops_manager','area_manager','area_engineer') and (public.fm_posx(p.role,p.job_title) in ('sysadmin','accountant','project_manager','ops_manager') or cardinality(p.regions)=0 or rg=any(p.regions))),
 'teams',(select coalesce(jsonb_agg(jsonb_build_object('id',t.id,'name',t.name)),'[]'::jsonb) from public.fm_team_readiness t where t.region=rg and public.fm_ready_read(t.region)));
 end $$;
create or replace function public.fm_bfollow_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
 declare k uuid:=(p->>'bill_id')::uuid; old public.fm_bill_followup;v public.fm_bill_followup;bl public.fm_bills;rg text;own uuid:=(p->>'owner_id')::uuid;tm uuid:=nullif(p->>'team_id','')::uuid;doc jsonb;
 begin
 select * into bl from public.fm_bills where id=k for update;
 if not found or not public.fm_bfollow_can(k,true) then raise exception 'not allowed';end if;
 if bl.status in ('paid','cancelled') then raise exception 'bill finished';end if;
 select c.region into rg from public.fm_contracts c where c.id=bl.contract_id;
 if not exists(select 1 from public.profiles pr where pr.id=own and pr.active and public.fm_posx(pr.role,pr.job_title) in ('sysadmin','accountant','project_manager','ops_manager','area_manager','area_engineer') and (public.fm_posx(pr.role,pr.job_title) in ('sysadmin','accountant','project_manager','ops_manager') or cardinality(pr.regions)=0 or rg=any(pr.regions))) then raise exception 'invalid owner';end if;
 if tm is not null and not exists(select 1 from public.fm_team_readiness t where t.id=tm and t.region=rg and public.fm_ready_read(t.region)) then raise exception 'invalid team';end if;
 if jsonb_typeof(p->'documents') is distinct from 'array' or jsonb_array_length(p->'documents')>20 then raise exception 'invalid documents';end if;
 if (select count(distinct x->>'key') from jsonb_array_elements(p->'documents') x)<>jsonb_array_length(p->'documents') then raise exception 'duplicate document keys';end if;
 for doc in select * from jsonb_array_elements(p->'documents') loop
 if coalesce(doc->>'key','') not in ('scene','invoice','warranty','other') or jsonb_typeof(doc->'required') is distinct from 'boolean' or jsonb_typeof(doc->'received') is distinct from 'boolean' or length(coalesce(doc->>'reference',''))>500 then raise exception 'invalid document';end if;
 if (doc->>'received')::boolean and length(trim(coalesce(doc->>'reference','')))=0 then raise exception 'document reference required';end if;
 end loop;
 select * into old from public.fm_bill_followup where bill_id=k for update;
 if coalesce(old.revision,0)<>coalesce((p->>'revision')::int,0) then raise exception 'version conflict: reload';end if;
 insert into public.fm_bill_followup(bill_id,owner_id,due_at,documents,hold_reason,impact_note,team_id,note,revision,updated_by)
 values(k,own,(p->>'due_at')::timestamptz,p->'documents',coalesce(p->>'hold_reason',''),coalesce(p->>'impact_note',''),tm,trim(p->>'note'),coalesce(old.revision,0)+1,auth.uid())
 on conflict(bill_id) do update set owner_id=excluded.owner_id,due_at=excluded.due_at,documents=excluded.documents,hold_reason=excluded.hold_reason,impact_note=excluded.impact_note,team_id=excluded.team_id,note=excluded.note,revision=excluded.revision,updated_by=excluded.updated_by,updated_at=now() returning * into v;
 insert into public.fm_bill_followup_events(bill_id,by_user,old_value,new_value) values(k,auth.uid(),case when old.bill_id is null then null else to_jsonb(old) end,to_jsonb(v));return to_jsonb(v);
 end $$;
create or replace function public.fm_bfollow_history(k uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
 begin if not public.fm_bfollow_can(k,false) then raise exception 'not allowed';end if;return(select coalesce(jsonb_agg(to_jsonb(e) order by e.at desc,e.id desc),'[]'::jsonb) from public.fm_bill_followup_events e where e.bill_id=k);end $$;
revoke all on function public.fm_close_can(text),public.fm_close_list(text),public.fm_close_save(jsonb),public.fm_close_history(text,text,text),public.fm_bfollow_can(uuid,boolean),public.fm_bfollow_list(),public.fm_bfollow_options(uuid),public.fm_bfollow_save(jsonb),public.fm_bfollow_history(uuid) from public,anon;
grant execute on function public.fm_close_can(text),public.fm_close_list(text),public.fm_close_save(jsonb),public.fm_close_history(text,text,text),public.fm_bfollow_list(),public.fm_bfollow_options(uuid),public.fm_bfollow_save(jsonb),public.fm_bfollow_history(uuid) to authenticated;
notify pgrst,'reload schema';
commit;

-- V195: source-linked operational escalation inbox. Depends on V192-V194.
begin;
create table if not exists public.fm_ops_escalations (
 id uuid primary key default gen_random_uuid(), kind text not null check(kind in ('ticket','wo','parts','bill','team')),
 source_key text not null, region text not null check(region in ('riyadh','qassim')),
 recipient uuid not null references public.profiles(id), due_at timestamptz not null,
 status text not null check(status in ('open','acknowledged','resolved')) default 'open',
 note text not null check(length(trim(note)) between 1 and 4000),
 revision int not null default 1, updated_by uuid references public.profiles(id), updated_at timestamptz not null default now(),
 unique(kind,source_key,region)
);
create table if not exists public.fm_ops_events (
 id bigint generated always as identity primary key, escalation_id uuid not null references public.fm_ops_escalations(id) on delete cascade,
 at timestamptz not null default now(), by_user uuid references public.profiles(id), old_value jsonb, new_value jsonb not null,
 push_queued boolean not null default false
);
alter table public.fm_ops_escalations enable row level security;
alter table public.fm_ops_events enable row level security;
revoke all on public.fm_ops_escalations,public.fm_ops_events from anon,authenticated;
create or replace function public.fm195_manager(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role()<>'pending' and (public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager') or (public.fm_my_pos()='area_manager' and public.fm_region_ok(r))),false) $$;
create or replace function public.fm195_source(k text,s text,r text,w boolean default false) returns boolean language plpgsql stable security definer set search_path=public as $$
begin
 if auth.uid() is null or public.fm_role()='pending' or r not in ('riyadh','qassim') or (w and not public.fm195_manager(r)) then return false;end if;
 if k='ticket' then return public.fm_close_can(r) and exists(select 1 from public.tickets t where t.ticket_id=s and t.region=r);
 elsif k='wo' then return public.fm_mod('wo') and exists(select 1 from public.work_orders x where x.id=public.fm_uuid_or_null(s) and x.region=r and public.fm_wo_can_see(x.id));
 elsif k='parts' then return coalesce(public.fm_parts_can(public.fm_uuid_or_null(s),w) and public.fm_parts_region(public.fm_uuid_or_null(s))=r,false);
 elsif k='bill' then return public.fm_bfollow_can(public.fm_uuid_or_null(s),w) and exists(select 1 from public.fm_bills b join public.fm_contracts c on c.id=b.contract_id where b.id=public.fm_uuid_or_null(s) and c.region=r);
 elsif k='team' then return (case when w then public.fm_ready_write(r) else public.fm_ready_read(r) end) and exists(select 1 from public.fm_team_readiness t where t.id=public.fm_uuid_or_null(s) and t.region=r);
 end if;return false;
end $$;
create or replace function public.fm195_people(r text,k text) returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if not public.fm195_manager(r) then raise exception 'not allowed';end if;
 return(select coalesce(jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(p.full_name,p.email)) order by p.full_name),'[]'::jsonb) from public.profiles p where p.active and public.fm_posx(p.role,p.job_title) in ('sysadmin','project_manager','ops_manager','area_manager') and (public.fm_posx(p.role,p.job_title)<>'area_manager' or cardinality(p.regions)=0 or r=any(p.regions)));
end $$;
create or replace function public.fm195_inbox() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(e)||jsonb_build_object('recipient_name',p.full_name,'can_edit',public.fm195_source(e.kind,e.source_key,e.region,true)) order by e.updated_at desc),'[]'::jsonb) from public.fm_ops_escalations e join public.profiles p on p.id=e.recipient where public.fm195_source(e.kind,e.source_key,e.region,false) $$;
create or replace function public.fm195_escalate(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare k text:=p->>'kind';s text:=trim(p->>'source_key');r text:=p->>'region';u uuid:=(p->>'recipient')::uuid;
 old public.fm_ops_escalations;v public.fm_ops_escalations;queued boolean:=false;st text:=p->>'status';
begin
 if not public.fm195_source(k,s,r,true) then raise exception 'not allowed or source missing';end if;
 if not exists(select 1 from jsonb_array_elements(public.fm195_people(r,k)) x where (x->>'id')::uuid=u) then raise exception 'invalid recipient';end if;
 perform pg_advisory_xact_lock(hashtextextended('fm195:'||k||':'||s||':'||r,0));
 select * into old from public.fm_ops_escalations where kind=k and source_key=s and region=r for update;
 if (p->>'revision')::int is distinct from coalesce(old.revision,0) then raise exception 'version conflict: reload';end if;
 if old.id is null and st<>'open' then raise exception 'new escalation must be open';end if;
 insert into public.fm_ops_escalations(kind,source_key,region,recipient,due_at,status,note,revision,updated_by)
 values(k,s,r,u,(p->>'due_at')::timestamptz,st,trim(p->>'note'),coalesce(old.revision,0)+1,auth.uid())
 on conflict(kind,source_key,region) do update set recipient=excluded.recipient,due_at=excluded.due_at,status=excluded.status,note=excluded.note,revision=excluded.revision,updated_by=excluded.updated_by,updated_at=now() returning * into v;
 -- Each revision is saved once. Push is only attempted for a new/reopened/reassigned escalation.
 if st='open' and (old.id is null or old.status<>'open' or old.recipient<>u) then
  begin queued:=public.fm_push_add(u,'ops_due','تصعيد تشغيلي يحتاج متابعة','المرجع: '||s||' — افتح مركز التنبيهات للمراجعة.','ops195','ops195-'||v.id::text||'-'||v.revision::text);exception when others then queued:=false;end;
 end if;
 insert into public.fm_ops_events(escalation_id,by_user,old_value,new_value,push_queued) values(v.id,auth.uid(),case when old.id is null then null else to_jsonb(old) end,to_jsonb(v),queued);
 return to_jsonb(v)||jsonb_build_object('push_queued',queued);
end $$;
create or replace function public.fm195_ack(k uuid,p_revision int,p_note text) returns jsonb language plpgsql security definer set search_path=public as $$
declare old public.fm_ops_escalations;v public.fm_ops_escalations;
begin
 select * into old from public.fm_ops_escalations where id=k for update;
 if old.id is null or old.recipient<>auth.uid() or not public.fm195_source(old.kind,old.source_key,old.region,false) then raise exception 'not allowed';end if;
 if p_revision is distinct from old.revision then raise exception 'version conflict: reload';end if;
 if old.status<>'open' then raise exception 'escalation is not open';end if;
 if length(trim(coalesce(p_note,''))) not between 1 and 4000 then raise exception 'note required';end if;
 update public.fm_ops_escalations set status='acknowledged',note=trim(p_note),revision=revision+1,updated_by=auth.uid(),updated_at=now() where id=k returning * into v;
 insert into public.fm_ops_events(escalation_id,by_user,old_value,new_value) values(k,auth.uid(),to_jsonb(old),to_jsonb(v));return to_jsonb(v);
end $$;
create or replace function public.fm195_history(k uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare e public.fm_ops_escalations;begin select * into e from public.fm_ops_escalations where id=k;
 if e.id is null or not public.fm195_source(e.kind,e.source_key,e.region,false) then raise exception 'not allowed';end if;
 return(select coalesce(jsonb_agg(to_jsonb(x)||jsonb_build_object('by_name',pr.full_name) order by x.at desc,x.id desc),'[]'::jsonb) from public.fm_ops_events x left join public.profiles pr on pr.id=x.by_user where x.escalation_id=k);end $$;
-- Complete JSON arrays avoid silently truncating a paginated PostgREST table read.
create or replace function public.fm195_orders() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(w) order by w.created_at desc,w.id),'[]'::jsonb) from public.work_orders w where public.fm_role()<>'pending' and public.fm_mod('wo') and public.fm_wo_can_see(w.id) $$;
create or replace function public.fm195_schedules() returns jsonb language sql stable security invoker set search_path=public as $$
 select coalesce(jsonb_agg(to_jsonb(s) order by s.next_run_at,s.id),'[]'::jsonb) from public.wo_schedules s where public.fm_role()<>'pending' and public.fm_mod('wo') $$;
revoke all on function public.fm195_manager(text),public.fm195_source(text,text,text,boolean),public.fm195_people(text,text),public.fm195_inbox(),public.fm195_escalate(jsonb),public.fm195_ack(uuid,int,text),public.fm195_history(uuid),public.fm195_orders(),public.fm195_schedules() from public,anon;
grant execute on function public.fm195_manager(text),public.fm195_people(text,text),public.fm195_inbox(),public.fm195_escalate(jsonb),public.fm195_ack(uuid,int,text),public.fm195_history(uuid),public.fm195_orders(),public.fm195_schedules() to authenticated;
notify pgrst,'reload schema';
commit;

-- V197: subscription enforcement discovered through local PostgreSQL integration tests.
-- Run after V195 on the company project. No user data is changed.
begin;
-- Position-based helpers must honor the same plan state as fm_role().
create or replace function public.fm_my_pos() returns text
language sql stable security definer set search_path=public as $$
 select case when p.active and public.fm_plan_ok() then public.fm_posx(p.role,p.job_title) end
 from public.profiles p where p.id=auth.uid()
$$;
-- Some old SECURITY DEFINER writes check the stored profile directly. Guard the target tables too.
create or replace function public.fm_mod_guard() returns trigger
language plpgsql security definer set search_path=public as $$
begin
 -- V202: the admin data reset (fm_wipe) may empty a table even when the plan or the part is off
 if tg_op='DELETE' and current_setting('fm.wipe',true)='1' and public.fm_wipe_ok() then return old;end if;
 if not public.fm_plan_ok() then raise exception 'subscription expired' using errcode='42501';end if;
 if not public.fm_mod(tg_argv[0]) then raise exception 'module disabled: %',tg_argv[0] using errcode='42501';end if;
 if tg_op='DELETE' then return old;end if;
 return new;
end $$;
do $$ declare x text[];begin
 foreach x slice 1 in array array[
 ['tickets','tickets'],['work_orders','wo'],['wo_schedules','wo'],['wo_issue_requests','wh'],['wo_purchase_requests','wh'],
 ['wo_stock_moves','wh'],['wo_custody_moves','wh'],['fm_eng_logs','eng'],['fm_school_links','portal'],['fm_school_requests','portal'],['fm_expenses','costs'],['fm_budgets','costs']
 ] loop
  if to_regclass('public.'||x[1]) is not null then
   execute format('drop trigger if exists fm_mod_guard on public.%I',x[1]);
   execute format('create trigger fm_mod_guard before insert or update or delete on public.%I for each row execute function public.fm_mod_guard(%L)',x[1],x[2]);
  end if;
 end loop;
end $$;
revoke all on function public.fm_mod_guard() from public,anon,authenticated;
-- Authenticated calls to renewal remain governed by fm_plan_activate's explicit active-admin check.
notify pgrst,'reload schema';
commit;

-- ---------- 36) tools register, parts follow-up notifications, orders waiting for parts (V215, field F43) ----------
-- Returnable tools (drills, ladders, meters, welders…) are tracked one by one, apart from consumable parts: a code TL-#####,
-- the store it belongs to, its condition and who holds it until when. Every change is a row in wo_tool_moves.
-- Parts follow-up (V193) now notifies: the new follow-up owner, the person a request is escalated to, and (daily) the owner of
-- an overdue follow-up. fm_parts_waiting() lists the open issue requests (requested / partial) with their order / ticket,
-- so the work orders and tickets held up by parts can be shown. Nothing here changes stock, custody or the SLA.
begin;
create sequence if not exists public.wo_tool_seq;
create table if not exists public.wo_tools (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null default ('TL-' || lpad(nextval('public.wo_tool_seq')::text, 5, '0')),
  name        text not null check (length(btrim(name)) between 1 and 200),
  category    text, brand text, model text, serial text,
  store_id    uuid references public.wo_stores(id) on delete set null,
  region      text,
  status      text not null default 'available' check (status in ('available','out','maint','lost','retired')),
  cond        text not null default 'good' check (cond in ('new','good','fair','damaged')),
  holder      uuid references public.profiles(id) on delete set null,
  holder_name text,
  out_at      timestamptz,
  due_back    date,
  price       numeric(14,2),
  bought_at   date,
  thumb       text check (thumb is null or length(thumb) <= 60000),
  notes       text,
  created_by  uuid default auth.uid(),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists wo_tools_holder_idx on public.wo_tools (holder) where holder is not null;
create index if not exists wo_tools_status_idx on public.wo_tools (status);
create table if not exists public.wo_tool_moves (
  id          bigint generated always as identity primary key,
  tool_id     uuid not null references public.wo_tools(id) on delete cascade,
  at          timestamptz not null default now(),
  kind        text not null check (kind in ('add','edit','out','in','extend','maint','fixed','lost','found','retire','transfer')),
  holder      uuid, holder_name text, cond text, due_back date, note text,
  by_id       uuid default auth.uid(), by_name text
);
create index if not exists wo_tool_moves_tool_idx on public.wo_tool_moves (tool_id, at desc);
alter table public.wo_tools enable row level security;
alter table public.wo_tool_moves enable row level security;
revoke insert, update, delete on public.wo_tools, public.wo_tool_moves from anon, authenticated;
grant select on public.wo_tools, public.wo_tool_moves to authenticated;
-- who manages the tools of a region: the same people who manage its stores (V180 fm_stock_can, storekeeper included)
create or replace function public.fm_tool_can(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_mod('wh') and public.fm_stock_can(coalesce(p_region,'')), false) $$;
drop policy if exists p_wo_tools_read on public.wo_tools;
create policy p_wo_tools_read on public.wo_tools for select to authenticated using (
  auth.uid() is not null and public.fm_role() <> 'pending' and public.fm_mod('wh') and (
    public.fm_tool_can(region) or holder = auth.uid() or (holder is not null and public.fm_wh_sees_holder(holder))
    or public.fm_my_pos() in ('dept_manager','qa_manager','hse_manager','owner_rep','accountant')));
drop policy if exists p_wo_tool_moves_read on public.wo_tool_moves;
create policy p_wo_tool_moves_read on public.wo_tool_moves for select to authenticated using (
  exists(select 1 from public.wo_tools t where t.id = tool_id));
do $do$ begin
  if to_regprocedure('public.fm_mod_guard()') is not null then
    drop trigger if exists fm_mod_guard on public.wo_tool_moves;
    create trigger fm_mod_guard before insert or update or delete on public.wo_tool_moves for each row execute function public.fm_mod_guard('wh');
  end if;
end $do$;

-- add or edit a tool: p {id?, name, category, brand, model, serial, store_id, region, cond, price, bought_at, thumb, notes}
create or replace function public.fm_tool_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare t public.wo_tools; st public.wo_stores; reg text; tid uuid := nullif(p->>'id','')::uuid; nm text := public.fm_me_name();
begin
  if auth.uid() is null or public.fm_role() = 'pending' then raise exception 'not allowed'; end if;
  if nullif(p->>'store_id','') is not null then
    select * into st from public.wo_stores where id = (p->>'store_id')::uuid;
    if not found then raise exception 'invalid store'; end if;
    reg := st.region;
  else reg := nullif(btrim(coalesce(p->>'region','')),''); end if;
  if not public.fm_tool_can(reg) then raise exception 'not allowed'; end if;
  if length(btrim(coalesce(p->>'name',''))) not between 1 and 200 then raise exception 'name required'; end if;
  if p ? 'thumb' and length(coalesce(p->>'thumb','')) > 60000 then raise exception 'photo too large'; end if;
  if tid is null then
    insert into public.wo_tools(name, category, brand, model, serial, store_id, region, cond, price, bought_at, thumb, notes)
    values (btrim(p->>'name'), nullif(btrim(coalesce(p->>'category','')),''), nullif(btrim(coalesce(p->>'brand','')),''), nullif(btrim(coalesce(p->>'model','')),''),
            nullif(btrim(coalesce(p->>'serial','')),''), st.id, reg, coalesce(nullif(p->>'cond',''),'good'), nullif(p->>'price','')::numeric,
            nullif(p->>'bought_at','')::date, nullif(p->>'thumb',''), nullif(btrim(coalesce(p->>'notes','')),''))
    returning * into t;
    insert into public.wo_tool_moves(tool_id, kind, cond, note, by_name) values (t.id, 'add', t.cond, 'إضافة', nm);
  else
    select * into t from public.wo_tools where id = tid for update;
    if not found or not public.fm_tool_can(t.region) then raise exception 'not allowed'; end if;
    if t.status = 'out' and coalesce(st.id::text,'') <> coalesce(t.store_id::text,'') then raise exception 'tool is out'; end if;
    update public.wo_tools set name = btrim(p->>'name'), category = nullif(btrim(coalesce(p->>'category','')),''), brand = nullif(btrim(coalesce(p->>'brand','')),''),
      model = nullif(btrim(coalesce(p->>'model','')),''), serial = nullif(btrim(coalesce(p->>'serial','')),''), store_id = st.id, region = reg,
      cond = case when p ? 'cond' and t.status <> 'out' then coalesce(nullif(p->>'cond',''), cond) else cond end,
      price = nullif(p->>'price','')::numeric, bought_at = nullif(p->>'bought_at','')::date,
      thumb = case when p ? 'thumb' then nullif(p->>'thumb','') else thumb end, notes = nullif(btrim(coalesce(p->>'notes','')),''), updated_at = now()
    where id = tid returning * into t;
    insert into public.wo_tool_moves(tool_id, kind, cond, note, by_name) values (t.id, 'edit', t.cond, 'تعديل البيانات', nm);
  end if;
  return t.id;
end $$;

-- p_action: out {holder, due_back?, cond?, note?} | in {cond, note?} | extend {due_back, note?} | maint {note} | fixed {cond?, note?}
--           | lost {note} | found {note?} | retire {note} | transfer {store_id, note?}
create or replace function public.fm_tool_act(p_id uuid, p_action text, p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare t public.wo_tools; h public.profiles; st public.wo_stores; nm text := public.fm_me_name(); nt text := nullif(btrim(coalesce(p->>'note','')),'');
  cd text := nullif(p->>'cond',''); du date := nullif(p->>'due_back','')::date;
begin
  if auth.uid() is null or public.fm_role() = 'pending' then raise exception 'not allowed'; end if;
  select * into t from public.wo_tools where id = p_id for update;
  if not found or not public.fm_tool_can(t.region) then raise exception 'not allowed'; end if;
  if cd is not null and cd not in ('new','good','fair','damaged') then raise exception 'invalid condition'; end if;
  if p_action = 'out' then
    if t.status <> 'available' then raise exception 'tool not available'; end if;
    select * into h from public.profiles where id = nullif(p->>'holder','')::uuid and active;
    if not found or public.fm_posx(h.role, h.job_title) is null then raise exception 'invalid holder'; end if;
    if du is not null and du < (now() at time zone 'Asia/Riyadh')::date then raise exception 'invalid date'; end if;
    update public.wo_tools set status = 'out', holder = h.id, holder_name = coalesce(h.full_name, h.email), out_at = now(), due_back = du,
      cond = coalesce(cd, cond), updated_at = now() where id = p_id returning * into t;
    insert into public.wo_tool_moves(tool_id, kind, holder, holder_name, cond, due_back, note, by_name) values (t.id, 'out', h.id, t.holder_name, t.cond, du, nt, nm);
    begin perform public.fm_push_add(h.id, 'tools', '🛠️ سُلّمت لك أداة: ' || t.name, t.code || coalesce(' • الإرجاع ' || to_char(du,'YYYY-MM-DD'),'') || ' • ' || nm, 'tools', 'tool-' || t.id);
    exception when others then null; end;
  elsif p_action = 'in' then
    if t.status <> 'out' then raise exception 'tool not out'; end if;
    if cd is null then raise exception 'condition required'; end if;
    insert into public.wo_tool_moves(tool_id, kind, holder, holder_name, cond, note, by_name) values (t.id, 'in', t.holder, t.holder_name, cd, nt, nm);
    update public.wo_tools set status = 'available', holder = null, holder_name = null, out_at = null, due_back = null, cond = cd, updated_at = now() where id = p_id;
  elsif p_action = 'extend' then
    if t.status <> 'out' or du is null or du < (now() at time zone 'Asia/Riyadh')::date then raise exception 'invalid date'; end if;
    update public.wo_tools set due_back = du, updated_at = now() where id = p_id;
    insert into public.wo_tool_moves(tool_id, kind, holder, holder_name, due_back, note, by_name) values (t.id, 'extend', t.holder, t.holder_name, du, nt, nm);
  elsif p_action = 'maint' then
    if t.status not in ('available','out') or nt is null then raise exception 'note required'; end if;
    insert into public.wo_tool_moves(tool_id, kind, holder, holder_name, cond, note, by_name) values (t.id, 'maint', t.holder, t.holder_name, coalesce(cd,'damaged'), nt, nm);
    update public.wo_tools set status = 'maint', holder = null, holder_name = null, out_at = null, due_back = null, cond = coalesce(cd,'damaged'), updated_at = now() where id = p_id;
  elsif p_action = 'fixed' then
    if t.status <> 'maint' then raise exception 'tool not in maintenance'; end if;
    update public.wo_tools set status = 'available', cond = coalesce(cd,'good'), updated_at = now() where id = p_id;
    insert into public.wo_tool_moves(tool_id, kind, cond, note, by_name) values (t.id, 'fixed', coalesce(cd,'good'), nt, nm);
  elsif p_action = 'lost' then
    if t.status not in ('available','out','maint') or nt is null then raise exception 'note required'; end if;
    insert into public.wo_tool_moves(tool_id, kind, holder, holder_name, note, by_name) values (t.id, 'lost', t.holder, t.holder_name, nt, nm);
    update public.wo_tools set status = 'lost', holder = null, holder_name = null, out_at = null, due_back = null, updated_at = now() where id = p_id;
  elsif p_action = 'found' then
    if t.status <> 'lost' then raise exception 'tool not lost'; end if;
    update public.wo_tools set status = 'available', cond = coalesce(cd, cond), updated_at = now() where id = p_id;
    insert into public.wo_tool_moves(tool_id, kind, cond, note, by_name) values (t.id, 'found', coalesce(cd, t.cond), nt, nm);
  elsif p_action = 'retire' then
    if t.status = 'out' or nt is null then raise exception 'note required'; end if;
    update public.wo_tools set status = 'retired', updated_at = now() where id = p_id;
    insert into public.wo_tool_moves(tool_id, kind, note, by_name) values (t.id, 'retire', nt, nm);
  elsif p_action = 'transfer' then
    if t.status = 'out' then raise exception 'tool is out'; end if;
    select * into st from public.wo_stores where id = nullif(p->>'store_id','')::uuid and active;
    if not found or not public.fm_tool_can(st.region) then raise exception 'invalid store'; end if;
    update public.wo_tools set store_id = st.id, region = st.region, updated_at = now() where id = p_id;
    insert into public.wo_tool_moves(tool_id, kind, note, by_name) values (t.id, 'transfer', concat_ws(' — ', '→ ' || st.name, nt), nm);
  else raise exception 'invalid action'; end if;
  return (select status from public.wo_tools where id = p_id);
end $$;
revoke all on function public.fm_tool_can(text), public.fm_tool_save(jsonb), public.fm_tool_act(uuid, text, jsonb) from public, anon;
grant execute on function public.fm_tool_can(text), public.fm_tool_save(jsonb), public.fm_tool_act(uuid, text, jsonb) to authenticated;

-- open issue requests (requested / partial) the caller may see, with the order / ticket they hold up
create or replace function public.fm_parts_waiting() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'code', r.code, 'status', r.status, 'at', r.at,
      'days', floor(extract(epoch from (now() - r.at)) / 86400)::int, 'source', r.source, 'wo_id', r.wo_id, 'wo_code', coalesce(r.wo_code, w.code),
      'ticket_ref', r.ticket_ref, 'school', coalesce(r.school, w.school), 'holder', r.holder, 'holder_name', r.holder_name, 'store', s.name,
      'region', public.fm_parts_region(r.id), 'due_at', f.due_at, 'stage', f.stage, 'owner_name', o.full_name,
      'items', coalesce((select jsonb_agg(jsonb_build_object('name', m.name, 'unit', m.unit, 'left', greatest(coalesce((l->>'qty')::numeric,0) - coalesce((l->>'issued')::numeric,0), 0)))
                         from jsonb_array_elements(r.lines) l left join public.wo_materials m on m.id = nullif(l->>'material_id','')::uuid), '[]'::jsonb))
      order by r.at), '[]'::jsonb)
  from public.wo_issue_requests r left join public.work_orders w on w.id = r.wo_id left join public.wo_stores s on s.id = r.store_id
       left join public.fm_parts_followup f on f.request_id = r.id left join public.profiles o on o.id = f.owner_id
  where r.status in ('requested','partial') and public.fm_parts_can(r.id, false) $$;
revoke all on function public.fm_parts_waiting() from public, anon;
grant execute on function public.fm_parts_waiting() to authenticated;

-- notifications of the parts follow-up: a new owner and an escalation, the moment they are saved
create or replace function public.fm_parts_notify() returns trigger language plpgsql security definer set search_path = public as $$
declare r public.wo_issue_requests; o uuid := nullif(new.new_value->>'owner_id','')::uuid; oo uuid := nullif(new.old_value->>'owner_id','')::uuid;
  e uuid := nullif(new.new_value->>'escalated_to','')::uuid; d text := to_char((new.new_value->>'due_at')::timestamptz at time zone 'Asia/Riyadh', 'YYYY-MM-DD');
  what text;
begin
  begin
    select * into r from public.wo_issue_requests where id = new.request_id;
    what := concat_ws(' • ', coalesce(r.holder_name,''), coalesce('أمر ' || r.wo_code, 'بلاغ ' || r.ticket_ref, ''), r.school);
    if new.kind = 'escalation' then
      perform public.fm_push_add(e, 'parts_due', '⏫ صُعّد إليك طلب قطع ' || r.code, left(concat_ws(' — ', what, new.new_value->>'note'), 280), 'parts', 'parts-' || r.id);
      if o is not null and o is distinct from e then
        perform public.fm_push_add(o, 'parts_due', '⏫ صُعّد طلب القطع ' || r.code || ' الذي تتابعه', left(what, 280), 'parts', 'parts-' || r.id);
      end if;
    elsif o is not null and o is distinct from oo then
      perform public.fm_push_add(o, 'parts_due', '📋 أنت مسؤول متابعة طلب القطع ' || r.code, left(concat_ws(' • ', what, 'الموعد ' || d), 280), 'parts', 'parts-' || r.id);
    end if;
  exception when others then null; end;
  return null;
end $$;
revoke all on function public.fm_parts_notify() from public, anon, authenticated;
drop trigger if exists fm_parts_notify on public.fm_parts_events;
create trigger fm_parts_notify after insert on public.fm_parts_events for each row execute function public.fm_parts_notify();

-- daily (pg_cron fm-v215-daily 05:20 UTC): overdue parts follow-ups (the day they become late, then every 3 days) to the owner and
-- whoever it was escalated to; tools past their return date to the holder (and one summary per storekeeper of the region)
create or replace function public.fm_v215_daily() returns int language plpgsql security definer set search_path = public as $$
declare x record; k uuid; n int := 0; d int; today date := (now() at time zone 'Asia/Riyadh')::date;
begin
  for x in select r.id, r.code, r.holder_name, r.school, coalesce(r.wo_code, '') wo, f.owner_id, f.escalated_to, f.due_at
           from public.fm_parts_followup f join public.wo_issue_requests r on r.id = f.request_id
           where r.status in ('requested','partial','issued') and f.due_at < now() loop
    d := floor(extract(epoch from (now() - x.due_at)) / 86400)::int;
    if d % 3 <> 0 then continue; end if;
    begin
      if public.fm_push_add(x.owner_id, 'parts_due', '⏱️ طلب قطع متأخر ' || x.code || ' (' || (d + 1) || ' يوم)', concat_ws(' • ', x.holder_name, nullif(x.wo,''), x.school), 'parts', 'parts-' || x.id, true) then n := n + 1; end if;
      if x.escalated_to is not null and x.escalated_to <> x.owner_id
         and public.fm_push_add(x.escalated_to, 'parts_due', '⏱️ طلب قطع متأخر ' || x.code, concat_ws(' • ', x.holder_name, nullif(x.wo,''), x.school), 'parts', 'parts-' || x.id, true) then n := n + 1; end if;
    exception when others then null; end;
  end loop;
  for x in select id, code, name, holder, due_back from public.wo_tools where status = 'out' and due_back is not null and due_back < today loop
    begin
      if public.fm_push_add(x.holder, 'tools', '⏰ موعد إرجاع أداة: ' || x.name, x.code || ' • كان مطلوباً ' || to_char(x.due_back, 'YYYY-MM-DD'), 'tools', 'tool-' || x.id, true) then n := n + 1; end if;
    exception when others then null; end;
  end loop;
  for x in select region, count(*) c, string_agg(name || ' (' || coalesce(holder_name,'') || ')', '، ' order by due_back) names
           from public.wo_tools where status = 'out' and due_back is not null and due_back < today group by region loop
    for k in select * from public.fm_wh_keepers_of(x.region) loop
      begin
        if public.fm_push_add(k, 'tools', '⏰ ' || x.c || ' أداة تجاوزت موعد الإرجاع', left(x.names, 280), 'tools', 'tools-late', true) then n := n + 1; end if;
      exception when others then null; end;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.fm_v215_daily() from public, anon, authenticated;
do $do$ begin
  begin execute 'select cron.unschedule(''fm-v215-daily'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-v215-daily'', ''20 5 * * *'', ''select public.fm_v215_daily()'')';
  exception when others then raise notice 'pg_cron is not available: overdue parts / tools reminders are not sent (the platform still shows them)'; end;
end $do$;
notify pgrst, 'reload schema';
commit;

-- ---------- 37) reserved quantities, count-difference approval, negative-balance alert, goods receipt note (V216) ----------
-- (1) fm_wh_reserved(): per store and item, what open issue requests (requested / partial) still wait for = «محجوز»;
--     balance − reserved = «متاح للصرف». Shown only; issuing still checks the balance as before.
-- (2) A stock count line whose difference is worth more than stock_rules.adj_value (default 200 SAR) — or, for an item without a
--     price, more than variance_pct % of the book balance — is not applied when the counter is a storekeeper / area engineer:
--     it waits in wo_stock_adj (ADJ-YYYY-####) for the area manager of the region, the ops / project manager or the system admin,
--     who approve (the recorded difference is applied) or reject it. Approvers' own counts apply at once.
-- (3) A balance that becomes negative notifies the storekeepers and area managers of the region (push kind wh_neg).
-- (4) A direct receipt is saved through fm_grn_save(p): one GRN-YYYY-#### document (supplier, invoice no / date / photo, lines,
--     total) and the stock «in» moves in one transaction; the moves' note carries the GRN code.
begin;
insert into public.fm_settings(key, value) values ('stock_rules', '{"scrap_days":7,"esc_days":[7,14],"block_overdue":true,"variance_pct":5,"adj_value":200,"cap":{"supervisor":0,"contractor":0,"area_engineer":0}}')
  on conflict (key) do update set value = public.fm_settings.value || jsonb_build_object('adj_value', coalesce(public.fm_settings.value->'adj_value', '200'::jsonb));

-- (1) reserved
create or replace function public.fm_wh_reserved() returns table(store_id uuid, material_id uuid, qty numeric)
language sql stable security definer set search_path = public as $$
  select r.store_id, nullif(l->>'material_id','')::uuid, sum(greatest(coalesce((l->>'qty')::numeric,0) - coalesce((l->>'issued')::numeric,0), 0))
  from public.wo_issue_requests r, jsonb_array_elements(r.lines) l
  where r.status in ('requested','partial') and r.store_id is not null and auth.uid() is not null and public.fm_role() <> 'pending' and public.fm_mod('wh')
  group by 1, 2 having sum(greatest(coalesce((l->>'qty')::numeric,0) - coalesce((l->>'issued')::numeric,0), 0)) > 0 $$;
revoke all on function public.fm_wh_reserved() from public, anon;
grant execute on function public.fm_wh_reserved() to authenticated;

-- (2) count differences waiting for approval
create sequence if not exists public.wo_stock_adj_seq;
create table if not exists public.wo_stock_adj (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null default ('ADJ-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_stock_adj_seq')::text, 4, '0')),
  at           timestamptz not null default now(),
  store_id     uuid not null references public.wo_stores(id) on delete cascade,
  region       text,
  lines        jsonb not null default '[]',   -- [{material_id, book, counted, diff, price, value}]
  value        numeric(14,2) not null default 0,
  note         text,
  status       text not null default 'pending' check (status in ('pending','approved','rejected')),
  by_id        uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name      text,
  decided_by   uuid references public.profiles(id) on delete set null,
  decided_name text,
  decided_at   timestamptz,
  response     text
);
create index if not exists wo_stock_adj_st_idx on public.wo_stock_adj (status, at desc);
alter table public.wo_stock_adj enable row level security;
revoke insert, update, delete on public.wo_stock_adj from anon, authenticated;
grant select on public.wo_stock_adj to authenticated;
-- who approves a count difference of a region
create or replace function public.fm_adj_approver(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager')
    or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(p_region,''))), false) $$;
create or replace function public.fm_adj_approvers(p_region text) returns setof uuid language sql stable security definer set search_path = public as $$
  select p.id from public.profiles p where p.active and (public.fm_posx(p.role, p.job_title) in ('ops_manager','project_manager')
    or (public.fm_posx(p.role, p.job_title) = 'area_manager' and (p_region is null or cardinality(p.regions) = 0 or p_region = any(p.regions)))) $$;
revoke all on function public.fm_adj_approvers(text) from public, anon, authenticated;
drop policy if exists p_stock_adj_read on public.wo_stock_adj;
create policy p_stock_adj_read on public.wo_stock_adj for select to authenticated using (
  public.fm_mod('wh') and (by_id = auth.uid() or public.fm_stock_can(region) or public.fm_adj_approver(region)
    or public.fm_my_pos() in ('dept_manager','qa_manager','owner_rep','accountant')));
-- does a count line need approval? (value over adj_value, or no price and the difference over variance_pct % of the book)
create or replace function public.fm_adj_needs(p_book numeric, p_diff numeric, p_price numeric) returns boolean language sql stable security definer set search_path = public as $$
  select case when coalesce(p_diff,0) = 0 then false
    when coalesce(p_price,0) > 0 then abs(p_diff) * p_price > coalesce((public.fm_setting('stock_rules')->>'adj_value')::numeric, 200)
    when coalesce(p_book,0) <= 0 then true
    else abs(p_diff) / p_book * 100 > coalesce((public.fm_setting('stock_rules')->>'variance_pct')::numeric, 5) end $$;
-- what a count would do, before saving it: p {store_id, lines:[{material_id, count}]}
create or replace function public.fm_adj_preview(p jsonb) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare st public.wo_stores; x jsonb; m public.wo_materials; cur numeric; d numeric; R jsonb := '[]'; ap boolean;
begin
  select * into st from public.wo_stores where id = nullif(p->>'store_id','')::uuid;
  if not found or not public.fm_stock_can(st.region) then raise exception 'not allowed'; end if;
  ap := public.fm_adj_approver(st.region);
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    select * into m from public.wo_materials where id = nullif(x->>'material_id','')::uuid;
    if not found then continue; end if;
    cur := coalesce((select qty from public.wo_stock where store_id = st.id and material_id = m.id), 0);
    d := coalesce(nullif(x->>'count','')::numeric, cur) - cur;
    if d = 0 then continue; end if;
    R := R || jsonb_build_object('material_id', m.id, 'book', cur, 'diff', d, 'value', round(abs(d) * coalesce(m.price,0), 2),
      'needs', (not ap) and public.fm_adj_needs(cur, d, m.price));
  end loop;
  return jsonb_build_object('approver', ap, 'lines', R);
end $$;

-- fm_stock_move (V173) with the count-approval step: unchanged for «in» and «transfer»
create or replace function public.fm_stock_move(p jsonb) returns int language plpgsql security definer set search_path = public as $$
declare k text := p->>'kind'; st public.wo_stores; st2 public.wo_stores; x jsonb; q numeric; cur numeric; n int := 0; m uuid; pr numeric;
  me uuid := auth.uid(); nm text := (select coalesce(full_name, email) from public.profiles where id = auth.uid());
  hold jsonb := '[]'; hv numeric := 0; mp numeric; ap boolean; a public.wo_stock_adj; u uuid;
begin
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
-- approve (apply the recorded differences) or reject a held count
create or replace function public.fm_stock_adj_act(p_id uuid, p_action text, p_note text) returns text language plpgsql security definer set search_path = public as $$
declare a public.wo_stock_adj; st public.wo_stores; x jsonb; m uuid; q numeric; nm text := public.fm_me_name();
begin
  select * into a from public.wo_stock_adj where id = p_id for update;
  if not found or a.status <> 'pending' then raise exception 'not pending'; end if;
  if not public.fm_adj_approver(a.region) then raise exception 'not allowed'; end if;
  if a.by_id = auth.uid() and public.fm_role() <> 'admin' and public.fm_my_pos() <> 'sysadmin' then raise exception 'not allowed'; end if;
  if p_action = 'reject' then
    if length(btrim(coalesce(p_note,''))) = 0 then raise exception 'note required'; end if;
    update public.wo_stock_adj set status = 'rejected', decided_by = auth.uid(), decided_name = nm, decided_at = now(), response = left(btrim(p_note),300) where id = p_id;
  elsif p_action = 'approve' then
    select * into st from public.wo_stores where id = a.store_id;
    for x in select * from jsonb_array_elements(a.lines) loop
      m := (x->>'material_id')::uuid; q := (x->>'diff')::numeric;
      insert into public.wo_stock(store_id, material_id, qty) values (a.store_id, m, q)
        on conflict (store_id, material_id) do update set qty = public.wo_stock.qty + q, updated_at = now();
      insert into public.wo_stock_moves(store_id, material_id, qty, kind, note, by_id, by_name)
      values (a.store_id, m, q, 'adjust', left(concat_ws(' — ', a.code || ' فرق جرد معتمد (' || coalesce(a.by_name,'') || ')', nullif(btrim(coalesce(p_note,'')),'')),300), auth.uid(), nm);
    end loop;
    update public.wo_stock_adj set status = 'approved', decided_by = auth.uid(), decided_name = nm, decided_at = now(), response = left(nullif(btrim(coalesce(p_note,'')),''),300) where id = p_id;
  else raise exception 'invalid action'; end if;
  begin perform public.fm_push_add(a.by_id, 'wh_adj', case when p_action = 'approve' then '✅ اعتُمد فرق الجرد ' else '⛔ رُفض فرق الجرد ' end || a.code, coalesce(nullif(btrim(coalesce(p_note,'')),''), st.name, ''), 'wh=adj', 'adj-' || a.id);
  exception when others then null; end;
  return (select status from public.wo_stock_adj where id = p_id);
end $$;
revoke all on function public.fm_adj_approver(text), public.fm_adj_needs(numeric, numeric, numeric), public.fm_adj_preview(jsonb), public.fm_stock_adj_act(uuid, text, text) from public, anon;
grant execute on function public.fm_adj_approver(text), public.fm_adj_needs(numeric, numeric, numeric), public.fm_adj_preview(jsonb), public.fm_stock_adj_act(uuid, text, text) to authenticated;

-- (3) a balance turning negative
create or replace function public.fm_stock_neg_notify() returns trigger language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; mn text; u uuid;
begin
  if new.qty < 0 and (tg_op = 'INSERT' or coalesce(old.qty,0) >= 0) then
    begin
      select * into st from public.wo_stores where id = new.store_id;
      select name into mn from public.wo_materials where id = new.material_id;
      for u in select distinct x from (select * from public.fm_wh_keepers_of(st.region) x
                 union select p.id from public.profiles p where p.active and public.fm_posx(p.role, p.job_title) = 'area_manager'
                   and (st.region is null or cardinality(p.regions) = 0 or st.region = any(p.regions))) y(x) loop
        perform public.fm_push_add(u, 'wh_neg', '➖ رصيد بالسالب: ' || coalesce(mn,'صنف'), coalesce(st.name,'') || ' • الرصيد ' || trim(to_char(new.qty, 'FM999999990.###')) || ' — سجّل توريداً أو جرداً', 'wh=neg', 'neg-' || new.store_id || '-' || new.material_id, true);
      end loop;
    exception when others then null; end;
  end if;
  return null;
end $$;
revoke all on function public.fm_stock_neg_notify() from public, anon, authenticated;
drop trigger if exists fm_stock_neg_notify on public.wo_stock;
create trigger fm_stock_neg_notify after insert or update of qty on public.wo_stock for each row execute function public.fm_stock_neg_notify();

-- (4) goods receipt notes
create sequence if not exists public.wo_grn_seq;
create table if not exists public.wo_grn (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null default ('GRN-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_grn_seq')::text, 4, '0')),
  at           timestamptz not null default now(),
  store_id     uuid not null references public.wo_stores(id) on delete cascade,
  region       text,
  supplier     text,
  invoice_no   text,
  invoice_date date,
  photo        text check (photo is null or length(photo) <= 560000),
  lines        jsonb not null default '[]',   -- [{material_id, name, unit, qty, price}]
  total        numeric(14,2) not null default 0,
  note         text,
  by_id        uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name      text
);
create index if not exists wo_grn_at_idx on public.wo_grn (store_id, at desc);
alter table public.wo_grn enable row level security;
revoke insert, update, delete on public.wo_grn from anon, authenticated;
grant select on public.wo_grn to authenticated;
drop policy if exists p_grn_read on public.wo_grn;
create policy p_grn_read on public.wo_grn for select to authenticated using (
  public.fm_mod('wh') and (public.fm_stock_can(region) or public.fm_role() in ('admin','manager','viewer')
    or public.fm_my_pos() in ('dept_manager','qa_manager','owner_rep','accountant')));
-- p = the fm_stock_move «in» body + {invoice_date, photo}; returns {id, code, moves}
create or replace function public.fm_grn_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; g public.wo_grn; n int; L jsonb := '[]'; x jsonb; m public.wo_materials; tot numeric := 0;
begin
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
revoke all on function public.fm_grn_save(jsonb) from public, anon;
grant execute on function public.fm_grn_save(jsonb) to authenticated;
do $do$ begin
  if to_regprocedure('public.fm_mod_guard()') is not null then
    drop trigger if exists fm_mod_guard on public.wo_stock_adj;
    create trigger fm_mod_guard before insert or update or delete on public.wo_stock_adj for each row execute function public.fm_mod_guard('wh');
    drop trigger if exists fm_mod_guard on public.wo_grn;
    create trigger fm_mod_guard before insert or update or delete on public.wo_grn for each row execute function public.fm_mod_guard('wh');
  end if;
end $do$;
notify pgrst, 'reload schema';
commit;

-- ---------- 38) goods receipt note for purchase-request receipts (V217) ----------
-- fm_po_receive(id, p) = fm_po_act(id, 'receive', p) (same checks, stock, variance, serials) + one wo_grn row for what was received
-- now (supplier of the request, invoice no / date / photo, po_code); the new «in» moves get the GRN code in their note.
begin;
alter table public.wo_grn add column if not exists po_code text;
create or replace function public.fm_po_receive(p_id uuid, p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.wo_purchase_requests; st public.wo_stores; s text; g public.wo_grn; before uuid[]; L jsonb := '[]'; x jsonb; ln jsonb; m public.wo_materials;
  q numeric; pr numeric; tot numeric := 0;
begin
  if length(coalesce(p->>'photo','')) > 560000 then raise exception 'photo too large'; end if;
  select * into r from public.wo_purchase_requests where id = p_id;
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
revoke all on function public.fm_po_receive(uuid, jsonb) from public, anon;
grant execute on function public.fm_po_receive(uuid, jsonb) to authenticated;
notify pgrst, 'reload schema';
commit;

-- ---------- 39) transfers in transit, signed custody receipts, stagnant items, what partial issues still need (V218) ----------
-- (1) A transfer between stores leaves the source at once and waits «في الطريق» (wo_stock_transfers, TR-YYYY-####) until the
--     destination's storekeeper / manager confirms what arrived (fm_transfer_act receive; a shortage needs a note and is not added
--     anywhere) or the sender cancels it (the quantities go back). Push kind wh_tr.
-- (2) The holder signs the custody receipt on the screen (fm_issue_req_sign; signatures in wo_issue_signs so the request rows stay
--     small); the storekeeper may record a signature made in front of him. Signing also confirms the receipt.
-- (3) fm_wh_stagnant(days): items with a balance and no consumption (out / issue) in the period, with the stores that used them.
-- (4) fm_issue_remaining(): what open issue requests still wait for, with the store balance and what is on order; a balance that
--     now covers the remainder of a partial request notifies the storekeepers (wh_req).
begin;
create sequence if not exists public.wo_stock_tr_seq;
create table if not exists public.wo_stock_transfers (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null default ('TR-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_stock_tr_seq')::text, 4, '0')),
  at          timestamptz not null default now(),
  from_store  uuid not null references public.wo_stores(id) on delete cascade,
  to_store    uuid not null references public.wo_stores(id) on delete cascade,
  from_region text,
  to_region   text,
  lines       jsonb not null default '[]',   -- [{material_id, qty, price, recv, short}]
  value       numeric(14,2) not null default 0,
  status      text not null default 'transit' check (status in ('transit','received','cancelled')),
  note        text,
  by_id       uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name     text,
  recv_by     uuid references public.profiles(id) on delete set null,
  recv_name   text,
  recv_at     timestamptz,
  recv_note   text,
  short_value numeric(14,2) not null default 0
);
create index if not exists wo_stock_transfers_st_idx on public.wo_stock_transfers (status, at desc);
alter table public.wo_stock_transfers enable row level security;
revoke insert, update, delete on public.wo_stock_transfers from anon, authenticated;
grant select on public.wo_stock_transfers to authenticated;
drop policy if exists p_stock_tr_read on public.wo_stock_transfers;
create policy p_stock_tr_read on public.wo_stock_transfers for select to authenticated using (
  public.fm_mod('wh') and public.fm_role() <> 'pending' and (by_id = auth.uid() or public.fm_stock_can(from_region) or public.fm_stock_can(to_region)
    or public.fm_wh_keeper(from_store) or public.fm_wh_keeper(to_store) or public.fm_my_pos() in ('dept_manager','qa_manager','owner_rep','accountant')));
do $do$ begin
  if to_regprocedure('public.fm_mod_guard()') is not null then
    drop trigger if exists fm_mod_guard on public.wo_stock_transfers;
    create trigger fm_mod_guard before insert on public.wo_stock_transfers for each row execute function public.fm_mod_guard('wh');
  end if;
end $do$;

-- send: p {store_id, to_store, lines:[{material_id, qty}], note} → {id, code}
create or replace function public.fm_transfer_send(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; st2 public.wo_stores; t public.wo_stock_transfers; x record; cur numeric; L jsonb := '[]'; v numeric := 0;
  nm text := public.fm_me_name(); u uuid; mn text;
begin
  if auth.uid() is null or not public.fm_mod('wh') then raise exception 'not allowed'; end if;
  select * into st from public.wo_stores where id = nullif(p->>'store_id','')::uuid and active;
  if not found or not (public.fm_stock_can(st.region) or public.fm_wh_keeper(st.id)) then raise exception 'not allowed'; end if;
  select * into st2 from public.wo_stores where id = nullif(p->>'to_store','')::uuid and active;
  if not found or st2.id = st.id then raise exception 'invalid store'; end if;
  insert into public.wo_stock_transfers(from_store, to_store, from_region, to_region, note, by_name)
  values (st.id, st2.id, st.region, st2.region, left(nullif(btrim(coalesce(p->>'note','')),''),300), nm) returning * into t;
  for x in select nullif(e->>'material_id','')::uuid m, sum(nullif(e->>'qty','')::numeric) q
           from jsonb_array_elements(coalesce(p->'lines','[]')) e group by 1 loop
    if x.m is null or not exists(select 1 from public.wo_materials where id = x.m) then raise exception 'unknown material'; end if;
    if x.q is null or x.q <= 0 or x.q > 1000000 then raise exception 'invalid qty'; end if;
    select qty into cur from public.wo_stock where store_id = st.id and material_id = x.m for update;
    if coalesce(cur,0) < x.q then select name into mn from public.wo_materials where id = x.m; raise exception 'insufficient: % (%)', mn, coalesce(cur,0); end if;
    update public.wo_stock set qty = qty - x.q, updated_at = now() where store_id = st.id and material_id = x.m;
    insert into public.wo_stock_moves(store_id, material_id, qty, kind, unit_price, ref, note, by_id, by_name)
    values (st.id, x.m, -x.q, 'transfer', (select price from public.wo_materials where id = x.m), t.code,
            left(concat_ws(' — ', t.code || ' 🚚 في الطريق إلى ' || st2.name, t.note),300), auth.uid(), nm);
    L := L || jsonb_build_object('material_id', x.m, 'qty', x.q, 'price', (select price from public.wo_materials where id = x.m));
    v := v + x.q * coalesce((select price from public.wo_materials where id = x.m), 0);
  end loop;
  if jsonb_array_length(L) = 0 then raise exception 'no lines'; end if;
  update public.wo_stock_transfers set lines = L, value = round(v, 2) where id = t.id;
  begin
    for u in select * from public.fm_wh_keepers_of(st2.region) loop
      perform public.fm_push_add(u, 'wh_tr', '🚚 تحويل في الطريق إليك — ' || t.code, st.name || ' ← ' || st2.name || ' • ' || jsonb_array_length(L) || ' صنف • أكّد الاستلام عند الوصول', 'wh=tr', 'tr-' || t.id);
    end loop;
  exception when others then null; end;
  return jsonb_build_object('id', t.id, 'code', t.code);
end $$;

-- receive (p {lines:[{material_id, qty}], note}; a missing line = all of it) or cancel (p {note})
create or replace function public.fm_transfer_act(p_id uuid, p_action text, p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare t public.wo_stock_transfers; st public.wo_stores; st2 public.wo_stores; x jsonb; g jsonb; q numeric; s numeric; L jsonb := '[]'; sv numeric := 0;
  nm text := public.fm_me_name(); u uuid; nt text := nullif(btrim(coalesce(p->>'note','')),'');
begin
  select * into t from public.wo_stock_transfers where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if t.status <> 'transit' then raise exception 'not in transit'; end if;
  select * into st from public.wo_stores where id = t.from_store;
  select * into st2 from public.wo_stores where id = t.to_store;
  if p_action = 'receive' then
    if not (public.fm_stock_can(t.to_region) or public.fm_wh_keeper(t.to_store)) then raise exception 'not allowed'; end if;
    for x in select * from jsonb_array_elements(t.lines) loop
      g := (select e from jsonb_array_elements(coalesce(p->'lines','[]')) z(e) where e->>'material_id' = x->>'material_id' limit 1);
      q := case when g is null then (x->>'qty')::numeric else nullif(g->>'qty','')::numeric end;
      if q is null or q < 0 or q > (x->>'qty')::numeric then raise exception 'invalid qty'; end if;
      s := (x->>'qty')::numeric - q;
      if q > 0 then
        insert into public.wo_stock(store_id, material_id, qty) values (t.to_store, (x->>'material_id')::uuid, q)
          on conflict (store_id, material_id) do update set qty = public.wo_stock.qty + q, updated_at = now();
        insert into public.wo_stock_moves(store_id, material_id, qty, kind, unit_price, ref, note, by_id, by_name)
        values (t.to_store, (x->>'material_id')::uuid, q, 'transfer', nullif(x->>'price','')::numeric, t.code,
                left(concat_ws(' — ', t.code || ' 🚚 وصل من ' || st.name, nt),300), auth.uid(), nm);
      end if;
      sv := sv + s * coalesce(nullif(x->>'price','')::numeric, 0);
      L := L || (x || jsonb_build_object('recv', q, 'short', s));
    end loop;
    if exists(select 1 from jsonb_array_elements(L) e where (e->>'short')::numeric > 0) and nt is null then raise exception 'note required'; end if;
    update public.wo_stock_transfers set lines = L, status = 'received', recv_by = auth.uid(), recv_name = nm, recv_at = now(), recv_note = nt,
      short_value = round(sv, 2) where id = p_id;
    begin
      perform public.fm_push_add(t.by_id, 'wh_tr', case when sv > 0 or exists(select 1 from jsonb_array_elements(L) e where (e->>'short')::numeric > 0)
        then '⚠️ وصل التحويل ' || t.code || ' بنقص' else '✅ وصل التحويل ' || t.code end, st2.name || ' • استلمه ' || coalesce(nm,'') || coalesce(' — ' || nt, ''), 'wh=tr', 'tr-' || t.id);
      if exists(select 1 from jsonb_array_elements(L) e where (e->>'short')::numeric > 0) then
        for u in select * from public.fm_adj_approvers(t.from_region) loop
          perform public.fm_push_add(u, 'wh_tr', '⚠️ نقص في التحويل ' || t.code, st.name || ' ← ' || st2.name || ' • ' || round(sv) || ' ر.س — ' || coalesce(nt,''), 'wh=tr', 'tr-' || t.id);
        end loop;
      end if;
    exception when others then null; end;
    return 'received';
  elsif p_action = 'cancel' then
    if not (t.by_id = auth.uid() or public.fm_stock_can(t.from_region) or public.fm_wh_keeper(t.from_store)) then raise exception 'not allowed'; end if;
    for x in select * from jsonb_array_elements(t.lines) loop
      q := (x->>'qty')::numeric;
      insert into public.wo_stock(store_id, material_id, qty) values (t.from_store, (x->>'material_id')::uuid, q)
        on conflict (store_id, material_id) do update set qty = public.wo_stock.qty + q, updated_at = now();
      insert into public.wo_stock_moves(store_id, material_id, qty, kind, unit_price, ref, note, by_id, by_name)
      values (t.from_store, (x->>'material_id')::uuid, q, 'transfer', nullif(x->>'price','')::numeric, t.code,
              left(concat_ws(' — ', t.code || ' ↩️ أُلغي التحويل إلى ' || st2.name, nt),300), auth.uid(), nm);
    end loop;
    update public.wo_stock_transfers set status = 'cancelled', recv_name = nm, recv_at = now(), recv_note = nt where id = p_id;
    return 'cancelled';
  end if;
  raise exception 'invalid action';
end $$;
revoke all on function public.fm_transfer_send(jsonb), public.fm_transfer_act(uuid, text, jsonb) from public, anon;
grant execute on function public.fm_transfer_send(jsonb), public.fm_transfer_act(uuid, text, jsonb) to authenticated;

-- (2) signed custody receipts
alter table public.wo_issue_requests add column if not exists signed_at timestamptz;
alter table public.wo_issue_requests add column if not exists sign_mode text;
create table if not exists public.wo_issue_signs (
  id        uuid primary key default gen_random_uuid(),
  req_id    uuid not null references public.wo_issue_requests(id) on delete cascade,
  at        timestamptz not null default now(),
  holder    uuid references public.profiles(id) on delete set null,
  sign      text not null,                     -- PNG data URL of the drawn signature
  mode      text not null check (mode in ('self','inperson')),
  lines     jsonb not null default '[]',        -- [{material_id, issued}] at the time of signing
  by_id     uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name   text
);
create index if not exists wo_issue_signs_req_idx on public.wo_issue_signs (req_id, at desc);
alter table public.wo_issue_signs enable row level security;
revoke insert, update, delete on public.wo_issue_signs from anon, authenticated;
grant select on public.wo_issue_signs to authenticated;
drop policy if exists p_issue_signs_read on public.wo_issue_signs;
create policy p_issue_signs_read on public.wo_issue_signs for select to authenticated using (
  exists(select 1 from public.wo_issue_requests r where r.id = req_id));
create or replace function public.fm_issue_req_sign(p_id uuid, p_sign text, p_inperson boolean default false) returns text language plpgsql security definer set search_path = public as $$
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
revoke all on function public.fm_issue_req_sign(uuid, text, boolean) from public, anon;
grant execute on function public.fm_issue_req_sign(uuid, text, boolean) to authenticated;

-- (3) stagnant items
create or replace function public.fm_wh_stagnant(p_days int) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d int := greatest(30, least(coalesce(p_days, 180), 1095)); since timestamptz;
begin
  if auth.uid() is null or not public.fm_mod('wh') or public.fm_role() not in ('admin','manager','staff','engineer','viewer') then raise exception 'not allowed'; end if;
  since := now() - make_interval(days => d);
  return coalesce((select jsonb_agg(z order by (z->>'value')::numeric desc nulls last) from (
    select jsonb_build_object('store_id', s.store_id, 'material_id', s.material_id, 'qty', s.qty, 'price', m.price,
      'value', round(s.qty * coalesce(m.price, 0), 2), 'last_use', u.last_use, 'last_in', u.last_in, 'first_at', u.first_at,
      'elsewhere', (select coalesce(jsonb_agg(jsonb_build_object('store_id', e.store_id, 'used', e.used, 'qty', coalesce(w.qty,0))), '[]'::jsonb) from (
          select v.store_id, sum(-v.qty) used from public.wo_stock_moves v
          where v.material_id = s.material_id and v.store_id <> s.store_id and v.kind in ('out','issue') and v.at >= since
          group by v.store_id having sum(-v.qty) > 0) e left join public.wo_stock w on w.store_id = e.store_id and w.material_id = s.material_id)) z
    from public.wo_stock s join public.wo_materials m on m.id = s.material_id
    left join lateral (select max(v.at) filter (where v.kind in ('out','issue')) last_use,
        max(v.at) filter (where v.qty > 0 and v.kind in ('in','transfer','return')) last_in, min(v.at) first_at
      from public.wo_stock_moves v where v.store_id = s.store_id and v.material_id = s.material_id) u on true
    where s.qty > 0 and coalesce(u.last_use, u.first_at, s.updated_at) < since) q), '[]'::jsonb);
end $$;
revoke all on function public.fm_wh_stagnant(int) from public, anon;
grant execute on function public.fm_wh_stagnant(int) to authenticated;

-- (4) what open issue requests still wait for: one row per request line with remainder > 0
create or replace function public.fm_issue_remaining() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'code', r.code, 'at', r.at, 'status', r.status, 'holder', r.holder, 'holder_name', r.holder_name,
      'source', r.source, 'wo_code', r.wo_code, 'ticket_ref', r.ticket_ref, 'school', r.school, 'store_id', r.store_id,
      'material_id', l->>'material_id', 'qty', coalesce((l->>'qty')::numeric,0), 'issued', coalesce((l->>'issued')::numeric,0),
      'left', coalesce((l->>'qty')::numeric,0) - coalesce((l->>'issued')::numeric,0),
      'bal', coalesce((select w.qty from public.wo_stock w where w.store_id = r.store_id and w.material_id = nullif(l->>'material_id','')::uuid), 0),
      'on_order', coalesce((select sum(greatest(coalesce((pl->>'qty')::numeric,0) - coalesce((pl->>'recv')::numeric,0), 0))
          from public.wo_purchase_requests po, jsonb_array_elements(po.lines) pl
          where po.store_id = r.store_id and po.status in ('requested','approved','partial') and pl->>'material_id' = l->>'material_id'), 0))
      order by r.at), '[]'::jsonb)
  from public.wo_issue_requests r, jsonb_array_elements(r.lines) l
  where r.status in ('requested','partial') and r.store_id is not null
    and coalesce((l->>'qty')::numeric,0) > coalesce((l->>'issued')::numeric,0) and public.fm_parts_can(r.id) $$;
revoke all on function public.fm_issue_remaining() from public, anon;
grant execute on function public.fm_issue_remaining() to authenticated;
-- a receipt that now covers the remainder of a partial request tells the storekeepers
create or replace function public.fm_issue_rem_notify() returns trigger language plpgsql security definer set search_path = public as $$
declare r record; u uuid; st public.wo_stores; mn text;
begin
  if new.qty <= coalesce(old.qty, 0) then return new; end if;
  begin
    select * into st from public.wo_stores where id = new.store_id;
    select name into mn from public.wo_materials where id = new.material_id;
    for r in select q.id, q.code, q.holder_name, coalesce((l->>'qty')::numeric,0) - coalesce((l->>'issued')::numeric,0) lft
             from public.wo_issue_requests q, jsonb_array_elements(q.lines) l
             where q.status = 'partial' and q.store_id = new.store_id and l->>'material_id' = new.material_id::text loop
      if r.lft > 0 and coalesce(old.qty, 0) < r.lft and new.qty >= r.lft then
        for u in select * from public.fm_wh_keepers_of(st.region) loop
          perform public.fm_push_add(u, 'wh_req', '📦 الرصيد يكفي الآن المتبقي من ' || r.code, coalesce(mn,'صنف') || ' ×' || trim(to_char(r.lft, 'FM999999990.###')) || ' • ' || coalesce(r.holder_name,'') || ' • ' || coalesce(st.name,''), 'wh=req', 'rem-' || r.id);
        end loop;
      end if;
    end loop;
  exception when others then null; end;
  return new;
end $$;
drop trigger if exists fm_issue_rem_notify on public.wo_stock;
create trigger fm_issue_rem_notify after update of qty on public.wo_stock for each row execute function public.fm_issue_rem_notify();
notify pgrst, 'reload schema';
commit;

-- ---------- 40) idle custody reminders, approval of large issue requests, shelf locations (V219) ----------
-- (1) fm_custody_idle(days): parts in a person's custody with no issue / use for that item since `days` (stock_rules.idle_days
--     [30, 60]); fm_v219_daily (pg_cron fm-v219-daily 05:30 UTC) reminds the holder from the first limit and his manager
--     (reports_to) from the second, then every 7 days (push kind wh_idle, one per person).
-- (2) stock_rules.issue_appr (SAR, 0 = off): a new request (or an edit) worth more than the limit, raised by someone who is not an
--     approver, waits for the area engineer above the holder / of the region, the area manager, or the ops / project manager
--     (appr_status needed); the storekeeper cannot issue it before (trigger fm_issue_appr_guard). fm_issue_req_approve(id, ok, note);
--     a rejection rejects the request.
-- (3) wo_stock.bin = the shelf / location of an item in a store (fm_stock_bin), printed on the QR labels.
begin;
insert into public.fm_settings(key, value) values ('stock_rules', '{"scrap_days":7,"esc_days":[7,14],"block_overdue":true,"variance_pct":5,"adj_value":200,"issue_appr":0,"idle_days":[30,60],"cap":{"supervisor":0,"contractor":0,"area_engineer":0}}')
  on conflict (key) do update set value = public.fm_settings.value
    || jsonb_build_object('issue_appr', coalesce(public.fm_settings.value->'issue_appr', '0'::jsonb), 'idle_days', coalesce(public.fm_settings.value->'idle_days', '[30,60]'::jsonb));

-- (1) idle custody
create or replace function public.fm_custody_idle_rows(p_days int) returns table(holder uuid, holder_name text, material_id uuid, qty numeric, price numeric, last_at timestamptz, days int)
language sql stable security definer set search_path = public as $$
  select c.holder, coalesce(p.full_name, p.email), c.material_id, c.qty, m.price, l.last_at,
         floor(extract(epoch from (now() - coalesce(l.last_at, c.updated_at))) / 86400)::int
  from public.wo_custody c join public.profiles p on p.id = c.holder join public.wo_materials m on m.id = c.material_id
  left join lateral (select max(v.at) last_at from public.wo_custody_moves v where v.holder = c.holder and v.material_id = c.material_id and v.kind in ('issue','use')) l on true
  where c.qty > 0 and p.active and coalesce(l.last_at, c.updated_at) < now() - make_interval(days => greatest(1, coalesce(p_days, 30))) $$;
revoke all on function public.fm_custody_idle_rows(int) from public, anon, authenticated;
create or replace function public.fm_custody_idle(p_days int default null) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('holder', x.holder, 'holder_name', x.holder_name, 'material_id', x.material_id, 'qty', x.qty, 'price', x.price,
      'value', round(x.qty * coalesce(x.price, 0), 2), 'last_at', x.last_at, 'days', x.days) order by x.days desc), '[]'::jsonb)
  from public.fm_custody_idle_rows(coalesce(p_days, nullif(public.fm_setting('stock_rules')->'idle_days'->>0,'')::int, 30)) x
  where auth.uid() is not null and public.fm_mod('wh') and public.fm_wh_sees_holder(x.holder) $$;
revoke all on function public.fm_custody_idle(int) from public, anon;
grant execute on function public.fm_custody_idle(int) to authenticated;
create or replace function public.fm_v219_daily() returns int language plpgsql security definer set search_path = public as $$
declare d1 int := coalesce(nullif(public.fm_setting('stock_rules')->'idle_days'->>0,'')::int, 30);
  d2 int := coalesce(nullif(public.fm_setting('stock_rules')->'idle_days'->>1,'')::int, 60); x record; b uuid; n int := 0;
begin
  if not public.fm_mod('wh') or d1 <= 0 then return 0; end if;
  for x in select holder, max(holder_name) hn, count(*) k, round(sum(qty * coalesce(price,0))) v, max(days) mx,
                  bool_or(days >= d1 and (days - d1) % 7 = 0) h1, bool_or(d2 > 0 and days >= d2 and (days - d2) % 7 = 0) h2
           from public.fm_custody_idle_rows(d1) group by holder loop
    if x.h1 or x.h2 then
      perform public.fm_push_add(x.holder, 'wh_idle', '💤 قطع في عهدتك لم تُستخدم منذ ' || x.mx || ' يوماً', x.k || ' صنف • ' || x.v || ' ر.س — أرجعها لأمين المستودع إن لم تحتجها', 'cus', 'idle-' || x.holder, true);
      n := n + 1;
    end if;
    if x.h2 then
      select reports_to into b from public.profiles where id = x.holder;
      if b is not null then perform public.fm_push_add(b, 'wh_idle', '💤 عهدة راكدة لدى ' || coalesce(x.hn,''), x.k || ' صنف • ' || x.v || ' ر.س منذ ' || x.mx || ' يوماً بلا استخدام', 'wh=idle', 'idle-' || x.holder, true); end if;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.fm_v219_daily() from public, anon, authenticated;
do $do$ begin
  begin execute 'select cron.unschedule(''fm-v219-daily'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-v219-daily'', ''30 5 * * *'', ''select public.fm_v219_daily()'')';
  exception when others then raise notice 'pg_cron is not available: idle custody reminders are not sent (the platform still shows them)'; end;
end $do$;

-- (2) approval of large issue requests
alter table public.wo_issue_requests add column if not exists appr_status text;
alter table public.wo_issue_requests add column if not exists appr_value numeric(14,2);
alter table public.wo_issue_requests add column if not exists appr_by_name text;
alter table public.wo_issue_requests add column if not exists appr_at timestamptz;
alter table public.wo_issue_requests add column if not exists appr_note text;
do $do$ begin
  alter table public.wo_issue_requests add constraint wo_issue_requests_appr_check check (appr_status in ('needed','approved','rejected'));
exception when duplicate_object then null; end $do$;
create or replace function public.fm_issue_value(p_lines jsonb) returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(round(sum(coalesce((l->>'qty')::numeric,0) * coalesce(m.price,0)), 2), 0)
  from jsonb_array_elements(coalesce(p_lines,'[]')) l left join public.wo_materials m on m.id = nullif(l->>'material_id','')::uuid $$;
create or replace function public.fm_issue_region(p_store uuid, p_holder uuid) returns text language sql stable security definer set search_path = public as $$
  select coalesce((select region from public.wo_stores where id = p_store), (select (regions)[1] from public.profiles where id = p_holder)) $$;
create or replace function public.fm_issue_approver(p_region text, p_holder uuid) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager')
    or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(p_region,'')))
    or (public.fm_my_pos() = 'area_engineer' and (public.fm_is_under(p_holder, auth.uid()) or public.fm_region_ok(coalesce(p_region,'')))), false) $$;
create or replace function public.fm_issue_approvers(p_region text, p_holder uuid) returns setof uuid language sql stable security definer set search_path = public as $$
  select p.id from public.profiles p where p.active and p.id <> p_holder and (
    (public.fm_posx(p.role, p.job_title) = 'area_engineer' and public.fm_is_under(p_holder, p.id))
    or (public.fm_posx(p.role, p.job_title) = 'area_manager' and (p_region is null or cardinality(p.regions) = 0 or p_region = any(p.regions)))) $$;
revoke all on function public.fm_issue_approvers(text, uuid), public.fm_issue_value(jsonb), public.fm_issue_region(uuid, uuid) from public, anon, authenticated;
revoke all on function public.fm_issue_approver(text, uuid) from public, anon;
grant execute on function public.fm_issue_approver(text, uuid) to authenticated;
-- a new request / an edit of a request still waiting: does it need approval?
create or replace function public.fm_issue_appr_check() returns trigger language plpgsql security definer set search_path = public as $$
declare lim numeric := coalesce(nullif(public.fm_setting('stock_rules')->>'issue_appr','')::numeric, 0); v numeric;
begin
  if new.status <> 'requested' then return new; end if;
  if tg_op = 'UPDATE' and new.lines is not distinct from old.lines then return new; end if;
  v := public.fm_issue_value(new.lines);
  if lim <= 0 or v <= lim then
    if new.appr_status = 'needed' then new.appr_status := null; end if;
    return new;
  end if;
  if tg_op = 'UPDATE' and new.appr_status = 'approved' and v <= coalesce(new.appr_value, 0) then return new; end if;
  if public.fm_issue_approver(public.fm_issue_region(new.store_id, new.holder), new.holder) then
    new.appr_status := 'approved'; new.appr_value := v; new.appr_by_name := public.fm_me_name(); new.appr_at := now();
  else
    new.appr_status := 'needed'; new.appr_value := v; new.appr_by_name := null; new.appr_at := null;
  end if;
  return new;
end $$;
drop trigger if exists fm_issue_appr_check on public.wo_issue_requests;
create trigger fm_issue_appr_check before insert or update of lines on public.wo_issue_requests for each row execute function public.fm_issue_appr_check();
-- nothing is issued while the approval is pending
create or replace function public.fm_issue_appr_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if old.appr_status = 'needed' and new.status in ('issued','partial') then raise exception 'approval required'; end if;
  return new;
end $$;
drop trigger if exists fm_issue_appr_guard on public.wo_issue_requests;
create trigger fm_issue_appr_guard before update of status on public.wo_issue_requests for each row execute function public.fm_issue_appr_guard();
create or replace function public.fm_issue_req_approve(p_id uuid, p_ok boolean, p_note text) returns text language plpgsql security definer set search_path = public as $$
declare r public.wo_issue_requests; nm text := public.fm_me_name(); nt text := nullif(btrim(coalesce(p_note,'')),'');
begin
  select * into r from public.wo_issue_requests where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if r.appr_status is distinct from 'needed' or r.status <> 'requested' then raise exception 'not pending'; end if;
  if not public.fm_issue_approver(public.fm_issue_region(r.store_id, r.holder), r.holder) then raise exception 'not allowed'; end if;
  if auth.uid() in (r.holder, coalesce(r.requested_by, r.holder)) and public.fm_role() <> 'admin' and public.fm_my_pos() <> 'sysadmin' then raise exception 'not allowed'; end if;
  if coalesce(p_ok, false) then
    update public.wo_issue_requests set appr_status = 'approved', appr_by_name = nm, appr_at = now(), appr_note = left(nt, 300) where id = p_id;
    return 'approved';
  end if;
  if nt is null then raise exception 'note required'; end if;
  update public.wo_issue_requests set appr_status = 'rejected', appr_by_name = nm, appr_at = now(), appr_note = left(nt, 300),
    status = 'rejected', response = left('لم يُعتمد: ' || nt, 500) where id = p_id;
  return 'rejected';
end $$;
revoke all on function public.fm_issue_req_approve(uuid, boolean, text) from public, anon;
grant execute on function public.fm_issue_req_approve(uuid, boolean, text) to authenticated;
-- notifications: a request waiting for approval goes to the approvers (not yet to the storekeeper); once approved, to the storekeeper
create or replace function public.fm_push_ir() returns trigger language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; u uuid; n int := jsonb_array_length(coalesce(new.lines,'[]'));
begin
  select * into st from public.wo_stores where id = new.store_id;
  if (tg_op = 'INSERT' and new.appr_status is distinct from 'needed')
     or (tg_op = 'UPDATE' and new.appr_status = 'approved' and old.appr_status = 'needed' and new.status = 'requested') then
    for u in select id from public.profiles p where p.active and public.fm_posx(p.role, p.job_title) = 'storekeeper'
               and (p.id = st.keeper or (st.keeper is null and (cardinality(coalesce(p.regions,'{}')) = 0 or st.region = any(p.regions)))) loop
      perform public.fm_push_add(u, 'wh_req', case when tg_op = 'INSERT' then '📦 طلب صرف ' else '✅ اعتُمد طلب الصرف ' end || new.code, coalesce(new.holder_name,'') || ' — ' || n || ' صنف' || coalesce(' — ' || new.wo_code, '') || coalesce(' — ' || st.name, ''), 'wh=req', 'ir-' || new.id);
    end loop;
  end if;
  if tg_op = 'INSERT' and new.appr_status = 'needed' then
    for u in select * from public.fm_issue_approvers(st.region, new.holder) loop
      perform public.fm_push_add(u, 'appr', '🟡 طلب صرف بانتظار اعتمادك ' || new.code, coalesce(new.holder_name,'') || ' — ' || round(coalesce(new.appr_value,0)) || ' ر.س' || coalesce(' — ' || new.wo_code, ''), 'wh=req', 'irap-' || new.id);
    end loop;
  elsif tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status in ('issued','partial') then
      perform public.fm_push_add(new.holder, 'wh_issued', '🧰 صُرفت قطع لعهدتك ' || new.code, 'أكّد الاستلام من «عهدتي»' || coalesce(' — ' || new.wo_code, ''), 'cus', 'ir-' || new.id);
    elsif new.status = 'rejected' then
      perform public.fm_push_add(new.holder, 'wh_issued', '❌ رُفض طلب الصرف ' || new.code, coalesce(new.response, ''), 'cus', 'ir-' || new.id);
    end if;
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists fm_push_ir on public.wo_issue_requests;
create trigger fm_push_ir after insert or update of status, appr_status on public.wo_issue_requests for each row execute function public.fm_push_ir();

-- (3) shelf / location of an item in a store: p_rows [{material_id, bin}]
alter table public.wo_stock add column if not exists bin text;
create or replace function public.fm_stock_bin(p_store uuid, p_rows jsonb) returns int language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; x jsonb; n int := 0;
begin
  select * into st from public.wo_stores where id = p_store and active;
  if auth.uid() is null or not found or not (public.fm_stock_can(st.region) or public.fm_wh_keeper(st.id)) then raise exception 'not allowed'; end if;
  for x in select * from jsonb_array_elements(coalesce(p_rows,'[]')) loop
    if not exists(select 1 from public.wo_materials where id = nullif(x->>'material_id','')::uuid) then continue; end if;
    insert into public.wo_stock(store_id, material_id, bin) values (st.id, (x->>'material_id')::uuid, left(nullif(btrim(coalesce(x->>'bin','')),''),40))
      on conflict (store_id, material_id) do update set bin = excluded.bin;
    n := n + 1;
  end loop;
  return n;
end $$;
revoke all on function public.fm_stock_bin(uuid, jsonb) from public, anon;
grant execute on function public.fm_stock_bin(uuid, jsonb) to authenticated;
notify pgrst, 'reload schema';
commit;


-- ---------- 41) tool inspection / calibration, tool loss or damage reports, cycle counts by ABC class (V220) ----------
-- (1) wo_tools.insp_kind (calib = معايرة / safety = فحص سلامة), insp_every (days), insp_last, insp_due; fm_tool_insp(id, p) sets
--     the schedule or records an inspection (result ok / fail; fail sends the tool to maintenance); a tool past its inspection date
--     cannot be handed over (trigger fm_tool_insp_guard). Reminders in fm_v220_daily.
-- (2) wo_tool_reports (TLR-YYYY-####): the holder (or the storekeeper) reports a tool lost or damaged with a note and a photo; the
--     tool goes to «lost» / «maint»; the area manager / ops / project manager decides: writeoff (retired), deduct (retired + amount
--     charged to the holder), repair (stays in maintenance), found (available again) or reject.
-- (3) every counted line is logged in wo_stock_counts (fm_stock_move redefined: same behaviour + the log, held lines flagged);
--     fm_cycle_plan(store): A / B / C by 365-day consumption value (80 % / 15 % / 5 %), counted every stock_rules.abc {a, b, c}
--     days (30 / 90 / 180), due = last count + days (never counted = due now). Weekly reminder (Sunday) to the storekeepers.
begin;
insert into public.fm_settings(key, value) values ('stock_rules', '{"scrap_days":7,"esc_days":[7,14],"block_overdue":true,"variance_pct":5,"adj_value":200,"issue_appr":0,"idle_days":[30,60],"abc":{"a":30,"b":90,"c":180},"cap":{"supervisor":0,"contractor":0,"area_engineer":0}}')
  on conflict (key) do update set value = public.fm_settings.value || jsonb_build_object('abc', coalesce(public.fm_settings.value->'abc', '{"a":30,"b":90,"c":180}'::jsonb));

-- (1) inspection
alter table public.wo_tools add column if not exists insp_kind text;
alter table public.wo_tools add column if not exists insp_every int;
alter table public.wo_tools add column if not exists insp_last date;
alter table public.wo_tools add column if not exists insp_due date;
do $do$ begin
  alter table public.wo_tools add constraint wo_tools_insp_kind_check check (insp_kind in ('calib','safety'));
exception when duplicate_object then null; end $do$;
alter table public.wo_tool_moves drop constraint if exists wo_tool_moves_kind_check;
alter table public.wo_tool_moves add constraint wo_tool_moves_kind_check check (kind in ('add','edit','out','in','extend','maint','fixed','lost','found','retire','transfer','inspect','report'));
create or replace function public.fm_tool_insp(p_id uuid, p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.wo_tools; nm text := public.fm_me_name(); nt text := nullif(btrim(coalesce(p->>'note','')),''); today date := (now() at time zone 'Asia/Riyadh')::date;
  k text; ev int; d date; res text := nullif(p->>'result','');
begin
  select * into t from public.wo_tools where id = p_id for update;
  if auth.uid() is null or not found or not public.fm_tool_can(t.region) then raise exception 'not allowed'; end if;
  k := case when p ? 'kind' then nullif(p->>'kind','') else t.insp_kind end;
  ev := case when p ? 'every' then nullif(p->>'every','')::int else t.insp_every end;
  if k is not null and k not in ('calib','safety') then raise exception 'invalid kind'; end if;
  if ev is not null and (ev < 1 or ev > 3650) then raise exception 'invalid period'; end if;
  if res is null then
    d := case when p ? 'last' then nullif(p->>'last','')::date else t.insp_last end;
    update public.wo_tools set insp_kind = k, insp_every = ev, insp_last = d,
      insp_due = case when k is null then null when d is null then (case when p ? 'due' then nullif(p->>'due','')::date else today end) when ev is null then nullif(p->>'due','')::date else d + ev end,
      updated_at = now() where id = p_id returning * into t;
  else
    if res not in ('ok','fail') then raise exception 'invalid result'; end if;
    if res = 'fail' and nt is null then raise exception 'note required'; end if;
    d := coalesce(nullif(p->>'date','')::date, today);
    if d > today then raise exception 'invalid date'; end if;
    insert into public.wo_tool_moves(tool_id, kind, holder, holder_name, cond, note, by_name)
    values (t.id, 'inspect', t.holder, t.holder_name, case when res = 'fail' then 'damaged' else t.cond end,
            left(concat_ws(' — ', case when k = 'calib' then 'معايرة' else 'فحص' end || ' ' || to_char(d,'YYYY-MM-DD') || case when res = 'ok' then ' ✅ صالح' else ' ⛔ غير صالح' end,
                           nullif(btrim(coalesce(p->>'cert','')),''), nt), 300), nm);
    update public.wo_tools set insp_kind = coalesce(k, 'safety'), insp_every = ev, insp_last = d,
      insp_due = case when res = 'ok' and ev is not null then d + ev when res = 'ok' then nullif(p->>'due','')::date else insp_due end,
      status = case when res = 'fail' and status in ('available','out') then 'maint' else status end,
      holder = case when res = 'fail' and status in ('available','out') then null else holder end,
      holder_name = case when res = 'fail' and status in ('available','out') then null else holder_name end,
      out_at = case when res = 'fail' and status in ('available','out') then null else out_at end,
      due_back = case when res = 'fail' and status in ('available','out') then null else due_back end,
      cond = case when res = 'fail' then 'damaged' else cond end, updated_at = now() where id = p_id returning * into t;
  end if;
  return jsonb_build_object('status', t.status, 'insp_due', t.insp_due);
end $$;
revoke all on function public.fm_tool_insp(uuid, jsonb) from public, anon;
grant execute on function public.fm_tool_insp(uuid, jsonb) to authenticated;
create or replace function public.fm_tool_insp_guard() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'out' and old.status is distinct from 'out' and new.insp_due is not null and new.insp_due < (now() at time zone 'Asia/Riyadh')::date then
    raise exception 'inspection overdue';
  end if;
  return new;
end $$;
drop trigger if exists fm_tool_insp_guard on public.wo_tools;
create trigger fm_tool_insp_guard before update of status on public.wo_tools for each row execute function public.fm_tool_insp_guard();

-- (2) loss / damage reports
create sequence if not exists public.wo_tool_rep_seq;
create table if not exists public.wo_tool_reports (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null default ('TLR-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_tool_rep_seq')::text, 4, '0')),
  at           timestamptz not null default now(),
  tool_id      uuid not null references public.wo_tools(id) on delete cascade,
  region       text,
  kind         text not null check (kind in ('lost','damaged')),
  note         text not null,
  photo        text check (photo is null or length(photo) <= 420000),
  by_id        uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name      text,
  holder       uuid references public.profiles(id) on delete set null,
  holder_name  text,
  status       text not null default 'open' check (status in ('open','writeoff','deduct','repair','found','rejected')),
  amount       numeric(14,2),
  decided_by   uuid references public.profiles(id) on delete set null,
  decided_name text,
  decided_at   timestamptz,
  response     text
);
create index if not exists wo_tool_reports_st_idx on public.wo_tool_reports (status, at desc);
alter table public.wo_tool_reports enable row level security;
revoke insert, update, delete on public.wo_tool_reports from anon, authenticated;
grant select on public.wo_tool_reports to authenticated;
drop policy if exists p_tool_reports_read on public.wo_tool_reports;
create policy p_tool_reports_read on public.wo_tool_reports for select to authenticated using (
  public.fm_mod('wh') and (by_id = auth.uid() or holder = auth.uid() or public.fm_tool_can(region) or public.fm_adj_approver(region)
    or public.fm_my_pos() in ('dept_manager','qa_manager','hse_manager','owner_rep','accountant')));
do $do$ begin
  if to_regprocedure('public.fm_mod_guard()') is not null then
    drop trigger if exists fm_mod_guard on public.wo_tool_reports;
    create trigger fm_mod_guard before insert on public.wo_tool_reports for each row execute function public.fm_mod_guard('wh');
  end if;
end $do$;
create or replace function public.fm_tool_report(p_tool uuid, p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare t public.wo_tools; r public.wo_tool_reports; k text := p->>'kind'; nt text := nullif(btrim(coalesce(p->>'note','')),''); nm text := public.fm_me_name(); u uuid;
begin
  select * into t from public.wo_tools where id = p_tool for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if not (t.holder = auth.uid() or public.fm_tool_can(t.region)) then raise exception 'not allowed'; end if;
  if k not in ('lost','damaged') then raise exception 'invalid kind'; end if;
  if nt is null then raise exception 'note required'; end if;
  if t.status in ('lost','retired') then raise exception 'invalid status'; end if;
  if length(coalesce(p->>'photo','')) > 420000 then raise exception 'photo too large'; end if;
  if exists(select 1 from public.wo_tool_reports where tool_id = t.id and status = 'open') then raise exception 'already reported'; end if;
  insert into public.wo_tool_reports(tool_id, region, kind, note, photo, by_name, holder, holder_name)
  values (t.id, t.region, k, left(nt, 500), nullif(p->>'photo',''), nm, t.holder, t.holder_name) returning * into r;
  insert into public.wo_tool_moves(tool_id, kind, holder, holder_name, cond, note, by_name)
  values (t.id, 'report', t.holder, t.holder_name, case when k = 'damaged' then 'damaged' else t.cond end, left(r.code || ' ' || case when k = 'lost' then 'بلاغ فقد' else 'بلاغ تلف' end || ' — ' || nt, 300), nm);
  update public.wo_tools set status = case when k = 'lost' then 'lost' else 'maint' end, cond = case when k = 'damaged' then 'damaged' else cond end,
    holder = null, holder_name = null, out_at = null, due_back = null, updated_at = now() where id = t.id;
  begin
    for u in select * from public.fm_adj_approvers(t.region) union select * from public.fm_wh_keepers_of(t.region) loop
      perform public.fm_push_add(u, 'tools', case when k = 'lost' then '⚠️ بلاغ فقد أداة ' else '⚠️ بلاغ تلف أداة ' end || r.code, t.code || ' ' || t.name || ' • ' || coalesce(nm,'') || ' — ' || left(nt, 120), 'tools', 'tlr-' || r.id);
    end loop;
  exception when others then null; end;
  return jsonb_build_object('id', r.id, 'code', r.code);
end $$;
create or replace function public.fm_tool_report_act(p_id uuid, p_action text, p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare r public.wo_tool_reports; t public.wo_tools; nm text := public.fm_me_name(); nt text := nullif(btrim(coalesce(p->>'note','')),''); am numeric;
begin
  select * into r from public.wo_tool_reports where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if r.status <> 'open' then raise exception 'not pending'; end if;
  if not public.fm_adj_approver(r.region) then raise exception 'not allowed'; end if;
  if r.by_id = auth.uid() and public.fm_role() <> 'admin' and public.fm_my_pos() <> 'sysadmin' then raise exception 'not allowed'; end if;
  select * into t from public.wo_tools where id = r.tool_id for update;
  if p_action in ('writeoff','deduct') then
    if nt is null then raise exception 'note required'; end if;
    am := case when p_action = 'deduct' then coalesce(nullif(p->>'amount','')::numeric, t.price) end;
    if p_action = 'deduct' and (am is null or am < 0) then raise exception 'amount required'; end if;
    update public.wo_tools set status = 'retired', holder = null, holder_name = null, out_at = null, due_back = null, updated_at = now() where id = t.id;
    insert into public.wo_tool_moves(tool_id, kind, note, by_name) values (t.id, 'retire', left(r.code || case when p_action = 'deduct' then ' شطب مع خصم ' || am || ' ر.س على ' || coalesce(r.holder_name,'المسؤول') else ' شطب' end || ' — ' || nt, 300), nm);
  elsif p_action = 'repair' then
    if r.kind <> 'damaged' then raise exception 'invalid action'; end if;
  elsif p_action = 'found' then
    if r.kind <> 'lost' then raise exception 'invalid action'; end if;
    update public.wo_tools set status = 'available', updated_at = now() where id = t.id and status = 'lost';
    insert into public.wo_tool_moves(tool_id, kind, cond, note, by_name) values (t.id, 'found', t.cond, left(concat_ws(' — ', r.code || ' وُجدت', nt), 300), nm);
  elsif p_action = 'reject' then
    if nt is null then raise exception 'note required'; end if;
  else raise exception 'invalid action'; end if;
  update public.wo_tool_reports set status = case when p_action = 'reject' then 'rejected' else p_action end, amount = am,
    decided_by = auth.uid(), decided_name = nm, decided_at = now(), response = left(nt, 300) where id = p_id;
  begin
    perform public.fm_push_add(r.by_id, 'tools', 'قرار بلاغ ' || r.code, t.name || ' — ' || case p_action when 'writeoff' then 'شُطبت' when 'deduct' then 'شُطبت مع خصم ' || am || ' ر.س' when 'repair' then 'تُصلح' when 'found' then 'وُجدت' else 'رُفض البلاغ' end || coalesce(' — ' || nt, ''), 'tools', 'tlr-' || r.id);
    if r.holder is not null and r.holder <> r.by_id then
      perform public.fm_push_add(r.holder, 'tools', 'قرار بلاغ ' || r.code, t.name || ' — ' || case p_action when 'deduct' then 'خصم ' || am || ' ر.س' when 'writeoff' then 'شُطبت' else p_action end, 'tools', 'tlr-' || r.id);
    end if;
  exception when others then null; end;
  return (select status from public.wo_tool_reports where id = p_id);
end $$;
revoke all on function public.fm_tool_report(uuid, jsonb), public.fm_tool_report_act(uuid, text, jsonb) from public, anon;
grant execute on function public.fm_tool_report(uuid, jsonb), public.fm_tool_report_act(uuid, text, jsonb) to authenticated;

-- (3) count log and cycle counts
create table if not exists public.wo_stock_counts (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  store_id    uuid not null references public.wo_stores(id) on delete cascade,
  material_id uuid not null references public.wo_materials(id) on delete cascade,
  book        numeric(14,3), counted numeric(14,3), diff numeric(14,3), price numeric(14,2),
  held        boolean not null default false,
  by_id       uuid default auth.uid(), by_name text
);
create index if not exists wo_stock_counts_idx on public.wo_stock_counts (store_id, material_id, at desc);
alter table public.wo_stock_counts enable row level security;
revoke insert, update, delete on public.wo_stock_counts from anon, authenticated;
grant select on public.wo_stock_counts to authenticated;
drop policy if exists p_stock_counts_read on public.wo_stock_counts;
create policy p_stock_counts_read on public.wo_stock_counts for select to authenticated using (public.fm_role() in ('admin','manager','staff','engineer','viewer'));
create or replace function public.fm_stock_move(p jsonb) returns int language plpgsql security definer set search_path = public as $$
declare k text := p->>'kind'; st public.wo_stores; st2 public.wo_stores; x jsonb; q numeric; cur numeric; n int := 0; m uuid; pr numeric;
  me uuid := auth.uid(); nm text := (select coalesce(full_name, email) from public.profiles where id = auth.uid());
  hold jsonb := '[]'; hv numeric := 0; mp numeric; ap boolean; a public.wo_stock_adj; u uuid;
begin
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
create or replace function public.fm_cycle_rows(p_store uuid) returns table(material_id uuid, cls text, value numeric, qty numeric, last_count timestamptz, due date)
language sql stable security definer set search_path = public as $$
  with r as (select coalesce(public.fm_setting('stock_rules')->'abc', '{"a":30,"b":90,"c":180}'::jsonb) j),
  items as (select m.id, coalesce(s.qty, 0) qty,
      coalesce((select sum(abs(v.qty) * coalesce(v.unit_price, m.price, 0)) from public.wo_stock_moves v
        where v.store_id = p_store and v.material_id = m.id and v.kind in ('out','issue') and v.at >= now() - interval '365 days'), 0) val
    from public.wo_materials m left join public.wo_stock s on s.store_id = p_store and s.material_id = m.id
    where m.active is not false and (coalesce(s.qty, 0) <> 0 or coalesce(s.min_qty, 0) > 0
      or exists(select 1 from public.wo_stock_moves v where v.store_id = p_store and v.material_id = m.id and v.at >= now() - interval '365 days'))),
  ranked as (select i.*, sum(val) over (order by val desc, id rows unbounded preceding) cum, sum(val) over () tot from items i)
  select x.id, x.c, round(x.val, 2), x.qty, lc.at,
         coalesce((lc.at at time zone 'Asia/Riyadh')::date + (select coalesce(nullif(j->>lower(x.c),'')::int, 90) from r), (now() at time zone 'Asia/Riyadh')::date)
  from (select ranked.*, case when tot <= 0 or val <= 0 then 'C' when cum - val < 0.8 * tot then 'A' when cum - val < 0.95 * tot then 'B' else 'C' end c from ranked) x
  left join lateral (select max(c.at) at from public.wo_stock_counts c where c.store_id = p_store and c.material_id = x.id) lc on true $$;
revoke all on function public.fm_cycle_rows(uuid) from public, anon, authenticated;
create or replace function public.fm_cycle_plan(p_store uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.fm_mod('wh') or public.fm_role() not in ('admin','manager','staff','engineer','viewer') then raise exception 'not allowed'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('material_id', material_id, 'cls', cls, 'value', value, 'qty', qty, 'last_count', last_count, 'due', due) order by due, cls, value desc)
    from public.fm_cycle_rows(p_store)), '[]'::jsonb);
end $$;
revoke all on function public.fm_cycle_plan(uuid) from public, anon;
grant execute on function public.fm_cycle_plan(uuid) to authenticated;

-- the cycle-count reminder (called on Sundays by fm_v220_daily)
create or replace function public.fm_v220_cnt_push() returns int language plpgsql security definer set search_path = public as $$
declare x record; u uuid; n int := 0; k int; today date := (now() at time zone 'Asia/Riyadh')::date;
begin
  for x in select s.id, s.name, s.region, s.keeper from public.wo_stores s where s.active loop
    select count(*) into k from public.fm_cycle_rows(x.id) c where c.due <= today;
    if k > 0 then
      for u in select kk from public.fm_wh_keepers_of(x.region) kk where x.keeper is null or kk = x.keeper loop
        perform public.fm_push_add(u, 'wh_cnt', '🔁 الجرد الدوري: ' || k || ' صنف مستحق', x.name || ' — افتح «🔁 الجرد الدوري» في المخزون', 'wh=cnt', 'cnt-' || x.id, true);
        n := n + 1;
      end loop;
    end if;
  end loop;
  return n;
end $$;
revoke all on function public.fm_v220_cnt_push() from public, anon, authenticated;
-- daily (pg_cron fm-v220-daily 05:40 UTC): inspections due in 14 / 7 / 0 days or overdue (weekly) → storekeepers of the region and
-- the holder; on Sundays the number of items due for the cycle count → the storekeepers of each store
create or replace function public.fm_v220_daily() returns int language plpgsql security definer set search_path = public as $$
declare x record; u uuid; n int := 0; today date := (now() at time zone 'Asia/Riyadh')::date; k int;
begin
  if not public.fm_mod('wh') then return 0; end if;
  for x in select * from public.wo_tools where insp_due is not null and status not in ('retired','lost')
             and ((insp_due - today) in (14, 7, 0) or (today > insp_due and (today - insp_due) % 7 = 0)) loop
    for u in select * from public.fm_wh_keepers_of(x.region) union select x.holder where x.holder is not null loop
      perform public.fm_push_add(u, 'tools', case when x.insp_due < today then '⛔ انتهى موعد ' else '🔬 يقترب موعد ' end || case when x.insp_kind = 'calib' then 'معايرة ' else 'فحص ' end || x.name,
        x.code || ' • ' || to_char(x.insp_due, 'YYYY-MM-DD') || case when x.insp_due < today then ' — لا تُسلَّم قبل الفحص' else '' end, 'tools', 'insp-' || x.id, true);
      n := n + 1;
    end loop;
  end loop;
  if extract(dow from now() at time zone 'Asia/Riyadh') = 0 then n := n + public.fm_v220_cnt_push(); end if;
  return n;
end $$;
revoke all on function public.fm_v220_daily() from public, anon, authenticated;
do $do$ begin
  begin execute 'select cron.unschedule(''fm-v220-daily'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-v220-daily'', ''40 5 * * *'', ''select public.fm_v220_daily()'')';
  exception when others then raise notice 'pg_cron is not available: inspection / cycle-count reminders are not sent (the platform still shows them)'; end;
end $do$;
notify pgrst, 'reload schema';
commit;

-- ---------- 42) parts kits for preventive maintenance, tool kits per job title and clearance, scrap disposal (V221) ----------
-- (1) wo_kits (KIT-###): a named set of parts per order (one school) for a preventive template («match» = text found in the
--     order / campaign title); fm_kit_save(p); fm_kit_request(p {kit_id, wo_ids[], store_id?}) raises one issue request per order
--     for its assignee (through fm_issue_req_new, so the usual permissions, approval limit and notifications apply), skipping
--     closed orders, orders without an assignee and orders that already have a live request for that kit.
-- (2) fm_settings.tool_kits {job title: [{name, qty}]} (the basic tools of each title, compared in the browser);
--     fm_clearance(user) = what the person still holds (tools, parts in custody, scrap owed, open requests, open tool reports);
--     fm_clearance_sign(user, p) records a clearance (wo_clearances, CLR-YYYY-####) only when nothing is left.
-- (3) wo_scrap_disposals (SCR-YYYY-####): a disposal record for scrap kept in a store (sell / destroy / return to the supplier,
--     committee, party, proceeds, photo); approval by the area manager / ops / project manager lowers wo_stock.scrap_qty and
--     writes «dispose» moves.
begin;
-- (1) parts kits
create sequence if not exists public.wo_kit_seq;
create table if not exists public.wo_kits (
  id         uuid primary key default gen_random_uuid(),
  code       text unique not null default ('KIT-' || lpad(nextval('public.wo_kit_seq')::text, 3, '0')),
  name       text not null check (length(btrim(name)) between 1 and 200),
  match      text,                               -- text of the template / order title this kit is for
  tpl        text,                               -- template id (ppm:NN or wo_templates id), informative
  lines      jsonb not null default '[]',        -- [{material_id, qty}] per order (one school)
  note       text,
  active     boolean not null default true,
  created_by uuid default auth.uid(), updated_by_name text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
alter table public.wo_kits enable row level security;
revoke insert, update, delete on public.wo_kits from anon, authenticated;
grant select on public.wo_kits to authenticated;
drop policy if exists p_kits_read on public.wo_kits;
create policy p_kits_read on public.wo_kits for select to authenticated using (public.fm_role() <> 'pending' and public.fm_mod('wh'));
create or replace function public.fm_kit_save(p jsonb) returns uuid language plpgsql security definer set search_path = public as $$
declare k public.wo_kits; x jsonb; L jsonb := '[]'; m public.wo_materials; q numeric; id_ uuid := nullif(p->>'id','')::uuid;
begin
  if auth.uid() is null or not (public.fm_wh_edit() or public.fm_wh_admin()) or not public.fm_mod('wh') then raise exception 'not allowed'; end if;
  if btrim(coalesce(p->>'name','')) = '' then raise exception 'name required'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    select * into m from public.wo_materials where id = nullif(x->>'material_id','')::uuid;
    if not found or not m.active or m.approved_at is null then raise exception 'item not approved: %', coalesce(m.name, x->>'material_id'); end if;
    q := nullif(x->>'qty','')::numeric;
    if q is null or q <= 0 or q > 100000 then raise exception 'invalid qty'; end if;
    if exists(select 1 from jsonb_array_elements(L) e where e->>'material_id' = m.id::text) then raise exception 'duplicate item: %', m.name; end if;
    L := L || jsonb_build_object('material_id', m.id, 'qty', q);
  end loop;
  if jsonb_array_length(L) = 0 then raise exception 'no lines'; end if;
  if id_ is null then
    insert into public.wo_kits(name, match, tpl, lines, note, updated_by_name)
    values (left(btrim(p->>'name'),200), left(nullif(btrim(coalesce(p->>'match','')),''),200), left(nullif(p->>'tpl',''),80), L,
            left(nullif(btrim(coalesce(p->>'note','')),''),500), public.fm_me_name()) returning * into k;
  else
    update public.wo_kits set name = left(btrim(p->>'name'),200), match = left(nullif(btrim(coalesce(p->>'match','')),''),200), tpl = left(nullif(p->>'tpl',''),80),
      lines = L, note = left(nullif(btrim(coalesce(p->>'note','')),''),500), active = coalesce((p->>'active')::boolean, active),
      updated_by_name = public.fm_me_name(), updated_at = now() where id = id_ returning * into k;
    if not found then raise exception 'not found'; end if;
  end if;
  return k.id;
end $$;
create or replace function public.fm_kit_request(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare k public.wo_kits; w public.work_orders; wid uuid; made int := 0; sk int := 0; errs jsonb := '[]'; r jsonb;
begin
  if auth.uid() is null or not public.fm_mod('wh') then raise exception 'not allowed'; end if;
  select * into k from public.wo_kits where id = nullif(p->>'kit_id','')::uuid and active;
  if not found then raise exception 'kit not found'; end if;
  if jsonb_array_length(coalesce(p->'wo_ids','[]')) > 300 then raise exception 'too many orders'; end if;
  for wid in select (e #>> '{}')::uuid from jsonb_array_elements(coalesce(p->'wo_ids','[]')) e loop
    select * into w from public.work_orders where id = wid;
    if not found or w.assignee is null or w.status in ('closed','cancelled','rejected','done') then sk := sk + 1; continue; end if;
    if exists(select 1 from public.wo_issue_requests q where q.wo_id = w.id and q.status not in ('cancelled','rejected') and q.note like k.code || '%') then sk := sk + 1; continue; end if;
    begin
      r := public.fm_issue_req_new(jsonb_build_object('holder', w.assignee, 'source', 'wo', 'wo_id', w.id, 'store_id', nullif(p->>'store_id',''),
             'lines', k.lines, 'note', k.code || ' — طقم: ' || k.name));
      made := made + 1;
    exception when others then
      errs := errs || jsonb_build_object('code', w.code, 'err', sqlerrm);
    end;
  end loop;
  return jsonb_build_object('created', made, 'skipped', sk, 'errors', errs);
end $$;
revoke all on function public.fm_kit_save(jsonb), public.fm_kit_request(jsonb) from public, anon;
grant execute on function public.fm_kit_save(jsonb), public.fm_kit_request(jsonb) to authenticated;

-- (2) clearance
insert into public.fm_settings(key, value) values ('tool_kits', '{}') on conflict (key) do nothing;
create sequence if not exists public.wo_clearance_seq;
create table if not exists public.wo_clearances (
  id        uuid primary key default gen_random_uuid(),
  code      text unique not null default ('CLR-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_clearance_seq')::text, 4, '0')),
  at        timestamptz not null default now(),
  user_id   uuid not null references public.profiles(id) on delete cascade,
  user_name text,
  reason    text check (reason in ('transfer','resign','end','other')),
  note      text,
  snapshot  jsonb not null default '{}',
  by_id     uuid default auth.uid(), by_name text
);
alter table public.wo_clearances enable row level security;
revoke insert, update, delete on public.wo_clearances from anon, authenticated;
grant select on public.wo_clearances to authenticated;
drop policy if exists p_clearances_read on public.wo_clearances;
create policy p_clearances_read on public.wo_clearances for select to authenticated using (user_id = auth.uid() or public.fm_wh_sees_holder(user_id));
create or replace function public.fm_clearance(p_user uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare t jsonb; c jsonb; r jsonb; tr jsonb;
begin
  if auth.uid() is null or not public.fm_wh_sees_holder(p_user) then raise exception 'not allowed'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'name', name, 'due_back', due_back, 'price', price)), '[]') into t from public.wo_tools where holder = p_user and status = 'out';
  select coalesce(jsonb_agg(jsonb_build_object('material_id', material_id, 'qty', qty, 'scrap', scrap)), '[]') into c from public.wo_custody where holder = p_user and (qty <> 0 or scrap <> 0);
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'status', status)), '[]') into r from public.wo_issue_requests
    where holder = p_user and (status in ('requested','partial') or (status = 'issued' and received_at is null));
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'code', code, 'kind', kind)), '[]') into tr from public.wo_tool_reports where holder = p_user and status = 'open';
  return jsonb_build_object('user', p_user, 'name', (select coalesce(full_name, email) from public.profiles where id = p_user), 'tools', t, 'custody', c, 'requests', r, 'reports', tr,
    'clear', jsonb_array_length(t) = 0 and jsonb_array_length(c) = 0 and jsonb_array_length(r) = 0 and jsonb_array_length(tr) = 0,
    'last', (select jsonb_build_object('code', code, 'at', at, 'by_name', by_name) from public.wo_clearances where user_id = p_user order by at desc limit 1));
end $$;
create or replace function public.fm_clearance_sign(p_user uuid, p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare s jsonb := public.fm_clearance(p_user); x public.wo_clearances;
begin
  if not (public.fm_wh_admin() or public.fm_my_pos() in ('storekeeper','area_manager')) then raise exception 'not allowed'; end if;
  if p_user = auth.uid() then raise exception 'not allowed'; end if;
  if not (s->>'clear')::boolean then raise exception 'not clear'; end if;
  insert into public.wo_clearances(user_id, user_name, reason, note, snapshot, by_name)
  values (p_user, s->>'name', coalesce(nullif(p->>'reason',''), 'other'), left(nullif(btrim(coalesce(p->>'note','')),''),500), s, public.fm_me_name()) returning * into x;
  return jsonb_build_object('id', x.id, 'code', x.code);
end $$;
revoke all on function public.fm_clearance(uuid), public.fm_clearance_sign(uuid, jsonb) from public, anon;
grant execute on function public.fm_clearance(uuid), public.fm_clearance_sign(uuid, jsonb) to authenticated;

-- (3) scrap disposal
alter table public.wo_stock_moves drop constraint if exists wo_stock_moves_kind_check;
alter table public.wo_stock_moves add constraint wo_stock_moves_kind_check check (kind in ('in','out','adjust','transfer','issue','return','scrap','dispose'));
create sequence if not exists public.wo_scrap_disp_seq;
create table if not exists public.wo_scrap_disposals (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null default ('SCR-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_scrap_disp_seq')::text, 4, '0')),
  at           timestamptz not null default now(),
  store_id     uuid not null references public.wo_stores(id) on delete cascade,
  region       text,
  method       text not null check (method in ('sell','destroy','return_supplier')),
  lines        jsonb not null default '[]',      -- [{material_id, qty}]
  party        text,                             -- buyer / supplier / disposal company
  amount       numeric(14,2),                    -- sale proceeds or supplier credit
  ref          text,                             -- receipt / credit note number
  committee    text[] not null default '{}',
  note         text,
  photo        text check (photo is null or length(photo) <= 420000),
  status       text not null default 'pending' check (status in ('pending','approved','rejected')),
  by_id        uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name      text,
  decided_by   uuid references public.profiles(id) on delete set null,
  decided_name text, decided_at timestamptz, response text
);
alter table public.wo_scrap_disposals enable row level security;
revoke insert, update, delete on public.wo_scrap_disposals from anon, authenticated;
grant select on public.wo_scrap_disposals to authenticated;
drop policy if exists p_scrap_disp_read on public.wo_scrap_disposals;
create policy p_scrap_disp_read on public.wo_scrap_disposals for select to authenticated using (
  public.fm_mod('wh') and (by_id = auth.uid() or public.fm_stock_can(region) or public.fm_wh_keeper(store_id) or public.fm_adj_approver(region)
    or public.fm_my_pos() in ('dept_manager','qa_manager','owner_rep','accountant')));
do $do$ begin
  if to_regprocedure('public.fm_mod_guard()') is not null then
    drop trigger if exists fm_mod_guard on public.wo_scrap_disposals;
    create trigger fm_mod_guard before insert on public.wo_scrap_disposals for each row execute function public.fm_mod_guard('wh');
  end if;
end $do$;
create or replace function public.fm_scrap_dispose_new(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; x record; L jsonb := '[]'; avail numeric; d public.wo_scrap_disposals; u uuid; mn text;
begin
  select * into st from public.wo_stores where id = nullif(p->>'store_id','')::uuid and active;
  if auth.uid() is null or not found or not (public.fm_stock_can(st.region) or public.fm_wh_keeper(st.id)) then raise exception 'not allowed'; end if;
  if coalesce(p->>'method','') not in ('sell','destroy','return_supplier') then raise exception 'invalid method'; end if;
  if length(coalesce(p->>'photo','')) > 420000 then raise exception 'photo too large'; end if;
  for x in select nullif(e->>'material_id','')::uuid m, sum(nullif(e->>'qty','')::numeric) q from jsonb_array_elements(coalesce(p->'lines','[]')) e group by 1 loop
    if x.q is null or x.q <= 0 then raise exception 'invalid qty'; end if;
    avail := coalesce((select scrap_qty from public.wo_stock where store_id = st.id and material_id = x.m), 0)
      - coalesce((select sum((dl->>'qty')::numeric) from public.wo_scrap_disposals s, jsonb_array_elements(s.lines) dl
                  where s.store_id = st.id and s.status = 'pending' and dl->>'material_id' = x.m::text), 0);
    if x.q > avail then select name into mn from public.wo_materials where id = x.m; raise exception 'more than scrap: % (%)', mn, avail; end if;
    L := L || jsonb_build_object('material_id', x.m, 'qty', x.q);
  end loop;
  if jsonb_array_length(L) = 0 then raise exception 'no lines'; end if;
  insert into public.wo_scrap_disposals(store_id, region, method, lines, party, amount, ref, committee, note, photo, by_name)
  values (st.id, st.region, p->>'method', L, left(nullif(btrim(coalesce(p->>'party','')),''),200), nullif(p->>'amount','')::numeric,
          left(nullif(btrim(coalesce(p->>'ref','')),''),80), coalesce(array(select left(btrim(v),100) from jsonb_array_elements_text(coalesce(p->'committee','[]')) v where btrim(v) <> '' limit 6), '{}'),
          left(nullif(btrim(coalesce(p->>'note','')),''),500), nullif(p->>'photo',''), public.fm_me_name()) returning * into d;
  begin
    for u in select * from public.fm_adj_approvers(st.region) loop
      perform public.fm_push_add(u, 'appr', '♻️ محضر تخلص من تالف بانتظار اعتمادك ' || d.code, st.name || ' • ' || jsonb_array_length(L) || ' صنف', 'wh=scr', 'scr-' || d.id);
    end loop;
  exception when others then null; end;
  return jsonb_build_object('id', d.id, 'code', d.code);
end $$;
create or replace function public.fm_scrap_dispose_act(p_id uuid, p_action text, p_note text) returns text language plpgsql security definer set search_path = public as $$
declare d public.wo_scrap_disposals; x jsonb; q numeric; cur numeric; nm text := public.fm_me_name(); nt text := nullif(btrim(coalesce(p_note,'')),''); mn text;
  M jsonb := '{"sell":"بيع","destroy":"إتلاف","return_supplier":"إرجاع للمورد"}';
begin
  select * into d from public.wo_scrap_disposals where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if d.status <> 'pending' then raise exception 'not pending'; end if;
  if not public.fm_adj_approver(d.region) then raise exception 'not allowed'; end if;
  if d.by_id = auth.uid() and public.fm_role() <> 'admin' and public.fm_my_pos() <> 'sysadmin' then raise exception 'not allowed'; end if;
  if p_action = 'approve' then
    for x in select * from jsonb_array_elements(d.lines) loop
      q := (x->>'qty')::numeric;
      select scrap_qty into cur from public.wo_stock where store_id = d.store_id and material_id = (x->>'material_id')::uuid for update;
      if coalesce(cur,0) < q then select name into mn from public.wo_materials where id = (x->>'material_id')::uuid; raise exception 'more than scrap: % (%)', mn, coalesce(cur,0); end if;
      update public.wo_stock set scrap_qty = scrap_qty - q, updated_at = now() where store_id = d.store_id and material_id = (x->>'material_id')::uuid;
      insert into public.wo_stock_moves(store_id, material_id, qty, kind, ref, note, by_id, by_name)
      values (d.store_id, (x->>'material_id')::uuid, -q, 'dispose', d.code, left(concat_ws(' — ', d.code || ' ' || (M->>d.method) || ' تالف', d.party), 300), auth.uid(), nm);
    end loop;
    update public.wo_scrap_disposals set status = 'approved', decided_by = auth.uid(), decided_name = nm, decided_at = now(), response = left(nt,300) where id = p_id;
  elsif p_action = 'reject' then
    if nt is null then raise exception 'note required'; end if;
    update public.wo_scrap_disposals set status = 'rejected', decided_by = auth.uid(), decided_name = nm, decided_at = now(), response = left(nt,300) where id = p_id;
  else raise exception 'invalid action'; end if;
  begin perform public.fm_push_add(d.by_id, 'wh_adj', case when p_action = 'approve' then '✅ اعتُمد محضر التخلص ' else '⛔ رُفض محضر التخلص ' end || d.code, coalesce(nt,''), 'wh=scr', 'scr-' || d.id);
  exception when others then null; end;
  return (select status from public.wo_scrap_disposals where id = p_id);
end $$;
revoke all on function public.fm_scrap_dispose_new(jsonb), public.fm_scrap_dispose_act(uuid, text, text) from public, anon;
grant execute on function public.fm_scrap_dispose_new(jsonb), public.fm_scrap_dispose_act(uuid, text, text) to authenticated;
notify pgrst, 'reload schema';
commit;

-- ---------- 43) offline-safe parts requests, warranty claims / supplier returns, quotations (RFQ), weighted average cost (V222) ----------
-- (1) wo_issue_requests.client_id: the field app queues a request made without a connection and sends it later through
--     fm_issue_req_new_once(p {…, client_id}) — the same request is never created twice (unique per requester).
-- (2) wo_claims (WC-YYYY-####): a defective part sent back to the supplier under warranty, or a supplier return; optional serial
--     (warranty date from wo_serials), «from_stock» takes the quantity out of the store now (move claim_out); the supplier's answer
--     brings it back (replaced / repaired → claim_in), credits an amount, or rejects it (the part goes to the store's scrap).
-- (3) wo_rfqs + wo_rfq_quotes (RFQ-YYYY-####): ask suppliers for quotations, record each quotation (prices per item, delivery
--     days, validity), compare and award — the award creates the purchase request (fm_po_save) with the winning prices; fewer
--     quotations than stock_rules.rfq_min (default 3) need a written reason.
-- (4) weighted average cost per store × item (wo_stock.avg_cost): every receipt / incoming transfer / return with a price updates
--     it; with stock_rules.costing = 'avg' (default) issues, work-order consumption and outgoing transfers are priced at the
--     average of that moment, so past consumption keeps its value when the item price changes later.
begin;
insert into public.fm_settings(key, value) values ('stock_rules', '{"scrap_days":7,"esc_days":[7,14],"block_overdue":true,"variance_pct":5,"adj_value":200,"issue_appr":0,"idle_days":[30,60],"abc":{"a":30,"b":90,"c":180},"rfq_min":3,"costing":"avg","cap":{"supervisor":0,"contractor":0,"area_engineer":0}}')
  on conflict (key) do update set value = public.fm_settings.value || jsonb_build_object('rfq_min', coalesce(public.fm_settings.value->'rfq_min', '3'::jsonb), 'costing', coalesce(public.fm_settings.value->'costing', '"avg"'::jsonb));

-- (1) offline-safe requests
alter table public.wo_issue_requests add column if not exists client_id text;
create unique index if not exists wo_issue_requests_client_uq on public.wo_issue_requests (requested_by, client_id) where client_id is not null;
create or replace function public.fm_issue_req_new_once(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare cid text := left(nullif(btrim(coalesce(p->>'client_id','')),''), 80); r public.wo_issue_requests; x jsonb;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if cid is not null then
    select * into r from public.wo_issue_requests where requested_by = auth.uid() and client_id = cid;
    if found then return jsonb_build_object('id', r.id, 'code', r.code, 'dup', true); end if;
  end if;
  x := public.fm_issue_req_new(p - 'client_id');
  if cid is not null then
    begin
      update public.wo_issue_requests set client_id = cid where id = (x->>'id')::uuid;
    exception when unique_violation then
      raise exception 'duplicate request';
    end;
  end if;
  return x;
end $$;
revoke all on function public.fm_issue_req_new_once(jsonb) from public, anon;
grant execute on function public.fm_issue_req_new_once(jsonb) to authenticated;

-- move kinds used below
alter table public.wo_stock_moves drop constraint if exists wo_stock_moves_kind_check;
alter table public.wo_stock_moves add constraint wo_stock_moves_kind_check check (kind in ('in','out','adjust','transfer','issue','return','scrap','dispose','claim_out','claim_in'));

-- (2) warranty claims / supplier returns
create sequence if not exists public.wo_claim_seq;
create table if not exists public.wo_claims (
  id             uuid primary key default gen_random_uuid(),
  code           text unique not null default ('WC-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_claim_seq')::text, 4, '0')),
  at             timestamptz not null default now(),
  kind           text not null check (kind in ('warranty','return')),
  store_id       uuid not null references public.wo_stores(id) on delete cascade,
  region         text,
  material_id    uuid not null references public.wo_materials(id) on delete cascade,
  qty            numeric(14,3) not null check (qty > 0),
  serial_id      uuid references public.wo_serials(id) on delete set null,
  serial         text,
  warranty_until date,
  supplier_id    uuid references public.wo_suppliers(id) on delete set null,
  supplier_name  text,
  reason         text not null,
  photo          text check (photo is null or length(photo) <= 420000),
  from_stock     boolean not null default false,
  status         text not null default 'open' check (status in ('open','sent','replaced','repaired','credited','rejected','cancelled')),
  sent_at        timestamptz,
  ref            text,
  amount         numeric(14,2),
  result_note    text,
  closed_at      timestamptz,
  by_id          uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name        text,
  decided_name   text
);
create index if not exists wo_claims_st_idx on public.wo_claims (status, at desc);
alter table public.wo_claims enable row level security;
revoke insert, update, delete on public.wo_claims from anon, authenticated;
grant select on public.wo_claims to authenticated;
drop policy if exists p_claims_read on public.wo_claims;
create policy p_claims_read on public.wo_claims for select to authenticated using (
  public.fm_mod('wh') and (by_id = auth.uid() or public.fm_stock_can(region) or public.fm_wh_keeper(store_id)
    or public.fm_my_pos() in ('dept_manager','qa_manager','owner_rep','accountant')));
do $do$ begin
  if to_regprocedure('public.fm_mod_guard()') is not null then
    drop trigger if exists fm_mod_guard on public.wo_claims;
    create trigger fm_mod_guard before insert on public.wo_claims for each row execute function public.fm_mod_guard('wh');
  end if;
end $do$;
create or replace function public.fm_claim_new(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; m public.wo_materials; s public.wo_serials; q numeric := nullif(p->>'qty','')::numeric; cur numeric; c public.wo_claims;
  sup uuid := nullif(p->>'supplier_id','')::uuid; fs boolean := coalesce((p->>'from_stock')::boolean, false); nm text := public.fm_me_name();
begin
  select * into st from public.wo_stores where id = nullif(p->>'store_id','')::uuid and active;
  if auth.uid() is null or not found or not (public.fm_stock_can(st.region) or public.fm_wh_keeper(st.id)) then raise exception 'not allowed'; end if;
  select * into m from public.wo_materials where id = nullif(p->>'material_id','')::uuid;
  if not found then raise exception 'unknown material'; end if;
  if coalesce(p->>'kind','') not in ('warranty','return') then raise exception 'invalid kind'; end if;
  if q is null or q <= 0 then raise exception 'invalid qty'; end if;
  if btrim(coalesce(p->>'reason','')) = '' then raise exception 'reason required'; end if;
  if length(coalesce(p->>'photo','')) > 420000 then raise exception 'photo too large'; end if;
  if nullif(p->>'serial_id','') is not null then
    select * into s from public.wo_serials where id = (p->>'serial_id')::uuid and material_id = m.id;
    if not found then raise exception 'unknown serial'; end if;
    sup := coalesce(sup, s.supplier_id);
  end if;
  if fs then
    select qty into cur from public.wo_stock where store_id = st.id and material_id = m.id for update;
    if coalesce(cur,0) < q then raise exception 'insufficient: % (%)', m.name, coalesce(cur,0); end if;
  end if;
  insert into public.wo_claims(kind, store_id, region, material_id, qty, serial_id, serial, warranty_until, supplier_id, supplier_name, reason, photo, from_stock, by_name)
  values (p->>'kind', st.id, st.region, m.id, q, s.id, coalesce(s.serial, left(nullif(btrim(coalesce(p->>'serial','')),''),80)), s.warranty_until, sup,
          coalesce((select name from public.wo_suppliers where id = sup), left(nullif(btrim(coalesce(p->>'supplier_name','')),''),200)),
          left(btrim(p->>'reason'),500), nullif(p->>'photo',''), fs, nm) returning * into c;
  if fs then
    update public.wo_stock set qty = qty - q, updated_at = now() where store_id = st.id and material_id = m.id;
    insert into public.wo_stock_moves(store_id, material_id, qty, kind, unit_price, supplier_id, supplier, ref, note, by_id, by_name)
    values (st.id, m.id, -q, 'claim_out', m.price, sup, c.supplier_name, c.code, left(c.code || ' ' || case when c.kind = 'warranty' then 'مطالبة ضمان' else 'إرجاع للمورد' end, 300), auth.uid(), nm);
  end if;
  if s.id is not null then update public.wo_serials set status = 'claim', updated_at = now() where id = s.id; end if;
  return jsonb_build_object('id', c.id, 'code', c.code, 'in_warranty', s.warranty_until >= (now() at time zone 'Asia/Riyadh')::date);
end $$;
-- send (p {ref, note}), replaced / repaired (back into the store when it left it), credited (p {amount}), rejected (note; the part
-- goes to the store's scrap when it left the store), cancel (still open; the quantity goes back)
create or replace function public.fm_claim_act(p_id uuid, p_action text, p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare c public.wo_claims; nm text := public.fm_me_name(); nt text := nullif(btrim(coalesce(p->>'note','')),''); pr numeric;
begin
  select * into c from public.wo_claims where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if not (public.fm_stock_can(c.region) or public.fm_wh_keeper(c.store_id)) then raise exception 'not allowed'; end if;
  select price into pr from public.wo_materials where id = c.material_id;
  if p_action = 'send' then
    if c.status <> 'open' then raise exception 'invalid status'; end if;
    update public.wo_claims set status = 'sent', sent_at = now(), ref = left(nullif(btrim(coalesce(p->>'ref','')),''),80), result_note = left(nt,500) where id = p_id;
  elsif p_action in ('replaced','repaired','credited','rejected') then
    if c.status not in ('open','sent') then raise exception 'invalid status'; end if;
    if p_action = 'rejected' and nt is null then raise exception 'note required'; end if;
    if p_action = 'credited' and nullif(p->>'amount','') is null then raise exception 'amount required'; end if;
    if c.from_stock and p_action in ('replaced','repaired') then
      insert into public.wo_stock(store_id, material_id, qty) values (c.store_id, c.material_id, c.qty)
        on conflict (store_id, material_id) do update set qty = public.wo_stock.qty + c.qty, updated_at = now();
      insert into public.wo_stock_moves(store_id, material_id, qty, kind, unit_price, supplier_id, supplier, ref, note, by_id, by_name)
      values (c.store_id, c.material_id, c.qty, 'claim_in', (select unit_price from public.wo_stock_moves where ref = c.code and kind = 'claim_out' limit 1), c.supplier_id, c.supplier_name, c.code,
              left(c.code || case when p_action = 'replaced' then ' استبدلها المورد' else ' أصلحها المورد' end || coalesce(' — ' || nt, ''), 300), auth.uid(), nm);
    elsif c.from_stock and p_action = 'rejected' then
      insert into public.wo_stock(store_id, material_id) values (c.store_id, c.material_id) on conflict do nothing;
      update public.wo_stock set scrap_qty = scrap_qty + c.qty, updated_at = now() where store_id = c.store_id and material_id = c.material_id;
    end if;
    update public.wo_claims set status = p_action, amount = case when p_action = 'credited' then (p->>'amount')::numeric else amount end,
      result_note = left(coalesce(nt, result_note),500), closed_at = now(), decided_name = nm where id = p_id;
    if c.serial_id is not null then
      update public.wo_serials set status = case when p_action in ('replaced','repaired') then 'store' when p_action = 'rejected' then 'scrapped' else 'returned' end, updated_at = now() where id = c.serial_id;
    end if;
  elsif p_action = 'cancel' then
    if c.status <> 'open' then raise exception 'invalid status'; end if;
    if c.from_stock then
      insert into public.wo_stock(store_id, material_id, qty) values (c.store_id, c.material_id, c.qty)
        on conflict (store_id, material_id) do update set qty = public.wo_stock.qty + c.qty, updated_at = now();
      insert into public.wo_stock_moves(store_id, material_id, qty, kind, unit_price, ref, note, by_id, by_name)
      values (c.store_id, c.material_id, c.qty, 'claim_in', (select unit_price from public.wo_stock_moves where ref = c.code and kind = 'claim_out' limit 1), c.code, left(c.code || ' أُلغيت المطالبة', 300), auth.uid(), nm);
    end if;
    if c.serial_id is not null then update public.wo_serials set status = 'store', updated_at = now() where id = c.serial_id; end if;
    update public.wo_claims set status = 'cancelled', closed_at = now(), decided_name = nm, result_note = left(nt,500) where id = p_id;
  else raise exception 'invalid action'; end if;
  return (select status from public.wo_claims where id = p_id);
end $$;
revoke all on function public.fm_claim_new(jsonb), public.fm_claim_act(uuid, text, jsonb) from public, anon;
grant execute on function public.fm_claim_new(jsonb), public.fm_claim_act(uuid, text, jsonb) to authenticated;

-- (3) quotations
create sequence if not exists public.wo_rfq_seq;
create table if not exists public.wo_rfqs (
  id            uuid primary key default gen_random_uuid(),
  code          text unique not null default ('RFQ-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_rfq_seq')::text, 4, '0')),
  at            timestamptz not null default now(),
  store_id      uuid not null references public.wo_stores(id) on delete cascade,
  region        text,
  lines         jsonb not null default '[]',       -- [{material_id, qty}]
  due_date      date,
  note          text,
  status        text not null default 'open' check (status in ('open','awarded','cancelled')),
  award_supplier_id uuid references public.wo_suppliers(id) on delete set null,
  award_name    text,
  award_note    text,
  po_id         uuid,
  po_code       text,
  by_id         uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name       text,
  decided_name  text,
  decided_at    timestamptz
);
create table if not exists public.wo_rfq_quotes (
  id            uuid primary key default gen_random_uuid(),
  rfq_id        uuid not null references public.wo_rfqs(id) on delete cascade,
  supplier_id   uuid not null references public.wo_suppliers(id) on delete cascade,
  supplier_name text,
  prices        jsonb not null default '[]',       -- [{material_id, price}]
  total         numeric(14,2),
  delivery_days int,
  valid_until   date,
  note          text,
  photo         text check (photo is null or length(photo) <= 420000),
  at            timestamptz not null default now(),
  by_name       text,
  unique (rfq_id, supplier_id)
);
alter table public.wo_rfqs enable row level security;
alter table public.wo_rfq_quotes enable row level security;
revoke insert, update, delete on public.wo_rfqs, public.wo_rfq_quotes from anon, authenticated;
grant select on public.wo_rfqs, public.wo_rfq_quotes to authenticated;
drop policy if exists p_rfqs_read on public.wo_rfqs;
create policy p_rfqs_read on public.wo_rfqs for select to authenticated using (
  public.fm_mod('wh') and (by_id = auth.uid() or public.fm_stock_can(region) or public.fm_wh_keeper(store_id) or public.fm_wh_admin()
    or public.fm_my_pos() in ('dept_manager','qa_manager','owner_rep','accountant')));
drop policy if exists p_rfq_quotes_read on public.wo_rfq_quotes;
create policy p_rfq_quotes_read on public.wo_rfq_quotes for select to authenticated using (exists(select 1 from public.wo_rfqs r where r.id = rfq_id));
do $do$ begin
  if to_regprocedure('public.fm_mod_guard()') is not null then
    drop trigger if exists fm_mod_guard on public.wo_rfqs;
    create trigger fm_mod_guard before insert on public.wo_rfqs for each row execute function public.fm_mod_guard('wh');
  end if;
end $do$;
create or replace function public.fm_rfq_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; x record; L jsonb := '[]'; r public.wo_rfqs;
begin
  select * into st from public.wo_stores where id = nullif(p->>'store_id','')::uuid and active;
  if auth.uid() is null or not found or not (public.fm_stock_can(st.region) or public.fm_wh_keeper(st.id)) then raise exception 'not allowed'; end if;
  for x in select nullif(e->>'material_id','')::uuid m, sum(nullif(e->>'qty','')::numeric) q from jsonb_array_elements(coalesce(p->'lines','[]')) e group by 1 loop
    if x.m is null or not exists(select 1 from public.wo_materials where id = x.m and active) then raise exception 'unknown material'; end if;
    if x.q is null or x.q <= 0 then raise exception 'invalid qty'; end if;
    L := L || jsonb_build_object('material_id', x.m, 'qty', x.q);
  end loop;
  if jsonb_array_length(L) = 0 then raise exception 'no lines'; end if;
  insert into public.wo_rfqs(store_id, region, lines, due_date, note, by_name)
  values (st.id, st.region, L, nullif(p->>'due_date','')::date, left(nullif(btrim(coalesce(p->>'note','')),''),500), public.fm_me_name()) returning * into r;
  return jsonb_build_object('id', r.id, 'code', r.code);
end $$;
-- add or replace one supplier's quotation: p {supplier_id, prices:[{material_id, price}], delivery_days, valid_until, note, photo}
create or replace function public.fm_rfq_quote(p_rfq uuid, p jsonb) returns numeric language plpgsql security definer set search_path = public as $$
declare r public.wo_rfqs; s public.wo_suppliers; ln jsonb; pr numeric; PQ jsonb := '[]'; t numeric := 0;
begin
  select * into r from public.wo_rfqs where id = p_rfq for update;
  if auth.uid() is null or not found or not (public.fm_stock_can(r.region) or public.fm_wh_keeper(r.store_id)) then raise exception 'not allowed'; end if;
  if r.status <> 'open' then raise exception 'invalid status'; end if;
  select * into s from public.wo_suppliers where id = nullif(p->>'supplier_id','')::uuid and active;
  if not found then raise exception 'unknown supplier'; end if;
  if length(coalesce(p->>'photo','')) > 420000 then raise exception 'photo too large'; end if;
  for ln in select * from jsonb_array_elements(r.lines) loop
    pr := (select nullif(e->>'price','')::numeric from jsonb_array_elements(coalesce(p->'prices','[]')) z(e) where e->>'material_id' = ln->>'material_id' limit 1);
    if pr is not null and pr < 0 then raise exception 'invalid price'; end if;
    PQ := PQ || jsonb_build_object('material_id', ln->>'material_id', 'price', pr);
    t := t + coalesce(pr, 0) * (ln->>'qty')::numeric;
  end loop;
  if not exists(select 1 from jsonb_array_elements(PQ) e where e->>'price' is not null) then raise exception 'no prices'; end if;
  insert into public.wo_rfq_quotes(rfq_id, supplier_id, supplier_name, prices, total, delivery_days, valid_until, note, photo, by_name)
  values (r.id, s.id, s.name, PQ, round(t,2), nullif(p->>'delivery_days','')::int, nullif(p->>'valid_until','')::date, left(nullif(btrim(coalesce(p->>'note','')),''),500), nullif(p->>'photo',''), public.fm_me_name())
  on conflict (rfq_id, supplier_id) do update set prices = excluded.prices, total = excluded.total, delivery_days = excluded.delivery_days,
    valid_until = excluded.valid_until, note = excluded.note, photo = coalesce(excluded.photo, public.wo_rfq_quotes.photo), at = now(), by_name = excluded.by_name;
  return round(t,2);
end $$;
-- award: the purchase request takes the winning supplier and his prices; a supplier who did not price an item leaves it out
create or replace function public.fm_rfq_award(p_rfq uuid, p_supplier uuid, p_note text) returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.wo_rfqs; q public.wo_rfq_quotes; n int; mn int := coalesce(nullif(public.fm_setting('stock_rules')->>'rfq_min','')::int, 3); L jsonb := '[]'; ln jsonb; pr numeric; po jsonb;
  nt text := nullif(btrim(coalesce(p_note,'')),''); lowest uuid;
begin
  select * into r from public.wo_rfqs where id = p_rfq for update;
  if auth.uid() is null or not found or not (public.fm_stock_can(r.region) or public.fm_wh_keeper(r.store_id)) then raise exception 'not allowed'; end if;
  if r.status <> 'open' then raise exception 'invalid status'; end if;
  select * into q from public.wo_rfq_quotes where rfq_id = r.id and supplier_id = p_supplier;
  if not found then raise exception 'no quote'; end if;
  select count(*) into n from public.wo_rfq_quotes where rfq_id = r.id;
  if n < mn and nt is null then raise exception 'too few quotes: %', mn; end if;
  -- the lowest is taken among complete quotations (every item priced); a partial or higher one needs a reason
  select z.supplier_id into lowest from public.wo_rfq_quotes z where z.rfq_id = r.id
    and not exists(select 1 from jsonb_array_elements(z.prices) e where e->>'price' is null)
    and jsonb_array_length(z.prices) = jsonb_array_length(r.lines) order by z.total asc limit 1;
  if (lowest is null or lowest <> p_supplier) and nt is null then raise exception 'not lowest'; end if;
  for ln in select * from jsonb_array_elements(r.lines) loop
    pr := (select nullif(e->>'price','')::numeric from jsonb_array_elements(q.prices) z(e) where e->>'material_id' = ln->>'material_id' limit 1);
    if pr is not null then L := L || jsonb_build_object('material_id', ln->>'material_id', 'qty', ln->'qty', 'price', pr); end if;
  end loop;
  po := public.fm_po_save(jsonb_build_object('store_id', r.store_id, 'supplier_id', p_supplier, 'lines', L,
          'note', left(r.code || ' — ' || n || ' عروض' || coalesce(' — ' || nt, ''), 500)));
  update public.wo_rfqs set status = 'awarded', award_supplier_id = p_supplier, award_name = q.supplier_name, award_note = nt,
    po_id = (po->>'id')::uuid, po_code = po->>'code', decided_name = public.fm_me_name(), decided_at = now() where id = r.id;
  return po;
end $$;
create or replace function public.fm_rfq_cancel(p_rfq uuid, p_note text) returns text language plpgsql security definer set search_path = public as $$
declare r public.wo_rfqs;
begin
  select * into r from public.wo_rfqs where id = p_rfq for update;
  if auth.uid() is null or not found or not (public.fm_stock_can(r.region) or public.fm_wh_keeper(r.store_id)) then raise exception 'not allowed'; end if;
  if r.status <> 'open' then raise exception 'invalid status'; end if;
  update public.wo_rfqs set status = 'cancelled', award_note = left(nullif(btrim(coalesce(p_note,'')),''),300), decided_name = public.fm_me_name(), decided_at = now() where id = r.id;
  return 'cancelled';
end $$;
revoke all on function public.fm_rfq_save(jsonb), public.fm_rfq_quote(uuid, jsonb), public.fm_rfq_award(uuid, uuid, text), public.fm_rfq_cancel(uuid, text) from public, anon;
grant execute on function public.fm_rfq_save(jsonb), public.fm_rfq_quote(uuid, jsonb), public.fm_rfq_award(uuid, uuid, text), public.fm_rfq_cancel(uuid, text) to authenticated;

-- (4) weighted average cost
alter table public.wo_stock add column if not exists avg_cost numeric(14,4);
update public.wo_stock s set avg_cost = m.price from public.wo_materials m where m.id = s.material_id and s.avg_cost is null and m.price is not null;
-- price outgoing moves at the average (costing = avg); an incoming transfer takes the price of its outgoing half
create or replace function public.fm_move_cost() returns trigger language plpgsql security definer set search_path = public as $$
declare a numeric;
begin
  if new.qty < 0 and new.kind in ('out','issue','transfer','claim_out','dispose')
     and coalesce(public.fm_setting('stock_rules')->>'costing', 'avg') = 'avg' then
    select avg_cost into a from public.wo_stock where store_id = new.store_id and material_id = new.material_id;
    if a is not null then new.unit_price := round(a, 4); end if;
  elsif new.qty > 0 and new.kind = 'transfer' and new.ref is not null then
    select v.unit_price into a from public.wo_stock_moves v where v.ref = new.ref and v.material_id = new.material_id and v.qty < 0 order by v.at limit 1;
    if a is not null then new.unit_price := a; end if;
  end if;
  return new;
end $$;
drop trigger if exists fm_move_cost on public.wo_stock_moves;
create trigger fm_move_cost before insert on public.wo_stock_moves for each row execute function public.fm_move_cost();
-- blend priced incoming quantities into the average (the balance already includes them when the move is written)
create or replace function public.fm_move_avg() returns trigger language plpgsql security definer set search_path = public as $$
declare s public.wo_stock; old_q numeric; base numeric;
begin
  if new.qty > 0 and new.unit_price is not null and new.kind in ('in','transfer','return','claim_in') then
    select * into s from public.wo_stock where store_id = new.store_id and material_id = new.material_id for update;
    if not found then return null; end if;
    old_q := greatest(coalesce(s.qty, 0) - new.qty, 0);
    base := coalesce(s.avg_cost, (select price from public.wo_materials where id = new.material_id), new.unit_price);
    update public.wo_stock set avg_cost = round((old_q * base + new.qty * new.unit_price) / nullif(old_q + new.qty, 0), 4)
    where store_id = new.store_id and material_id = new.material_id;
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists fm_move_avg on public.wo_stock_moves;
create trigger fm_move_avg after insert on public.wo_stock_moves for each row execute function public.fm_move_avg();
notify pgrst, 'reload schema';
commit;

-- ---------- 44) the school confirms a finished work order, alerts before a ticket breaches its SLA, automatic reorder drafts (V223) ----------
-- (1) When an order of a school that has an active portal link (section 22) is reported «done», work_orders.sc_status = pending and the
--     principal sees it in school.html: fm_school_wo_confirm(token, id, ok, note, name) → confirmed / rejected (reason required).
--     fm_settings.school_confirm {enabled (default true), required (default false), days (default 3)}: with «required» the approver
--     cannot close an order the school rejected, nor one still pending for less than «days» days after it was reported done.
-- (2) fm_sla_watch: the uploader's platform sends the open tickets with their SLA due time (created + the priority's hours, the same
--     calculation as the platform) and the supervisor / engineer names; people are matched by person_names / full name.
--     fm_sla_warn_run() (pg_cron every 15 minutes): one push «sla_due» per person for tickets due within sla_warn.hours (2), outside
--     the quiet hours (22–06 Riyadh), and a morning summary of what breaches today. The list is as fresh as the last upload.
-- (3) wo_purchase_requests.status «draft» + auto: fm_wh_auto_po(store?) builds one draft per store with the items below their minimum
--     (qty = max(2 × min, 2 × 30-day use) − balance − quantity already on open purchase requests); the storekeeper reviews it and
--     sends it for approval (fm_po_draft_act submit) or cancels it. stock_rules.auto_po {enabled, dow 0–6 (Sunday = 0)}: pg_cron
--     runs fm_wh_auto_po_run() daily and builds the drafts on that weekday.
begin;
-- (1) school confirmation
alter table public.work_orders add column if not exists sc_status text;
alter table public.work_orders add column if not exists sc_at     timestamptz;
alter table public.work_orders add column if not exists sc_note   text;
alter table public.work_orders add column if not exists sc_name   text;
do $do$ begin
  alter table public.work_orders add constraint work_orders_sc_check check (sc_status in ('pending','confirmed','rejected'));
exception when duplicate_object then null; end $do$;
create or replace function public.fm_sc_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('enabled', coalesce((s->>'enabled')::boolean, true), 'required', coalesce((s->>'required')::boolean, false),
                            'days', greatest(1, least(coalesce(nullif(s->>'days','')::int, 3), 30)))
    from (select coalesce(public.fm_setting('school_confirm'), '{}'::jsonb) s) x $$;
-- the active portal link of an order's school
create or replace function public.fm_wo_school_token(p_bid text, p_school text) returns text language sql stable security definer set search_path = public as $$
  select k.token from public.fm_school_links k
   where k.active and nullif(btrim(coalesce(p_school,'')),'') is not null
     and (k.bkey = public.fm_bkey(p_bid, btrim(p_school)) or k.school_name = btrim(p_school))
   order by (k.bkey = public.fm_bkey(p_bid, btrim(p_school))) desc limit 1 $$;
create or replace function public.fm_wo_sc_trg() returns trigger language plpgsql security definer set search_path = public as $$
declare c jsonb := public.fm_sc_cfg();
begin
  if new.status = 'done' and old.status is distinct from 'done' then
    if (c->>'enabled')::boolean and public.fm_wo_school_token(new.building_id, new.school) is not null then
      new.sc_status := 'pending';
    else
      new.sc_status := null;
    end if;
    new.sc_at := null; new.sc_note := null; new.sc_name := null;
  elsif new.status = 'closed' and old.status = 'done' and (c->>'required')::boolean then
    if new.sc_status = 'rejected' then raise exception 'school rejected'; end if;
    if new.sc_status = 'pending' and coalesce(old.done_at, now()) > now() - make_interval(days => (c->>'days')::int) then
      raise exception 'school confirmation pending'; end if;
  end if;
  return new;
end $$;
drop trigger if exists fm_wo_sc on public.work_orders;
create trigger fm_wo_sc before update of status on public.work_orders for each row execute function public.fm_wo_sc_trg();
-- public (anon): the principal confirms or rejects (reason required) an order waiting for him
create or replace function public.fm_school_wo_confirm(p_token text, p_id uuid, p_ok boolean, p_note text, p_name text) returns text
language plpgsql security definer set search_path = public as $$
declare k public.fm_school_links; w public.work_orders; nt text := nullif(btrim(coalesce(p_note,'')),''); nm text := left(nullif(btrim(coalesce(p_name,'')),''),100); ns text;
begin
  select * into k from public.fm_school_links where token = p_token and length(p_token) = 64 and active;
  if not found then raise exception 'invalid link'; end if;
  select * into w from public.work_orders where id = p_id for update;
  if not found or public.fm_wo_school_token(w.building_id, w.school) is distinct from p_token then raise exception 'not found'; end if;
  if w.status <> 'done' or w.sc_status is distinct from 'pending' then raise exception 'not waiting'; end if;
  if not coalesce(p_ok, false) and length(coalesce(nt,'')) < 3 then raise exception 'reason required'; end if;
  ns := case when coalesce(p_ok, false) then 'confirmed' else 'rejected' end;
  update public.work_orders set sc_status = ns, sc_at = now(), sc_note = left(nt, 500), sc_name = nm where id = w.id;
  insert into public.wo_events (wo_id, by_id, by_name, type, status, text)
  values (w.id, null, 'مدير المدرسة' || coalesce(' — ' || nm, ''), case when ns = 'confirmed' then 'school_ok' else 'school_no' end, w.status,
          case when ns = 'confirmed' then '🏫 أكّد مدير المدرسة إنجاز العمل' else '🏫 أفاد مدير المدرسة أن العمل لم يُنجز' end || coalesce(' — ' || left(nt, 500), ''));
  return ns;
end $$;
-- the portal: same as section 22 + «confirm» (orders waiting for the principal) and sc on each order
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
    'orders', coalesce((select jsonb_agg(jsonb_build_object('code', w.code, 'title', w.title, 'type', w.type, 'status', w.status, 'at', w.created_at, 'sc', w.sc_status) order by w.created_at desc)
        from (select * from public.work_orders w where (public.fm_bkey(w.building_id, null) = k.bkey or btrim(w.school) = k.school_name)
                and w.status not in ('closed','cancelled','rejected') order by w.created_at desc limit 50) w), '[]'::jsonb),
    'confirm', coalesce((select jsonb_agg(jsonb_build_object('id', w.id, 'code', w.code, 'title', w.title, 'type', w.type, 'done_at', w.done_at, 'by', w.assignee_name,
          'items', (select count(*) from jsonb_array_elements(case when jsonb_typeof(w.checklist) = 'array' then w.checklist else '[]' end)),
          'items_done', (select count(*) from jsonb_array_elements(case when jsonb_typeof(w.checklist) = 'array' then w.checklist else '[]' end) e where (e->>'done')::boolean is true or e->>'res' in ('ok','fixed')),
          'note', (select e.text from public.wo_events e where e.wo_id = w.id and e.type = 'done' order by e.at desc limit 1),
          'sr', (select r.code from public.fm_school_requests r where r.wo_id = w.id limit 1)) order by w.done_at)
        from (select * from public.work_orders w where w.status = 'done' and w.sc_status = 'pending'
                and public.fm_wo_school_token(w.building_id, w.school) = p_token order by w.done_at limit 30) w), '[]'::jsonb),
    'confirmed', coalesce((select jsonb_agg(jsonb_build_object('code', w.code, 'title', w.title, 'sc', w.sc_status, 'sc_at', w.sc_at, 'sc_note', w.sc_note) order by w.sc_at desc)
        from (select * from public.work_orders w where w.sc_at > now() - interval '30 days' and w.sc_status in ('confirmed','rejected')
                and public.fm_wo_school_token(w.building_id, w.school) = p_token order by w.sc_at desc limit 20) w), '[]'::jsonb));
end $$;
-- the push: the approver (and, on a rejection, the assignee) hear what the school said
create or replace function public.fm_push_sc() returns trigger language plpgsql security definer set search_path = public as $$
declare w public.work_orders; t text;
begin
  if new.type not in ('school_ok','school_no') then return null; end if;
  select * into w from public.work_orders where id = new.wo_id;
  if not found then return null; end if;
  t := coalesce(w.code,'') || ' — ' || coalesce(w.school,'');
  if new.type = 'school_ok' then
    perform public.fm_push_add(w.created_by, 'wo_done', '🏫 أكّدت المدرسة إنجاز ' || t, w.title, 'wo=' || w.id, 'wo-' || w.id, true);
  else
    perform public.fm_push_add(w.created_by, 'wo_done', '🏫 المدرسة تفيد أن العمل لم يُنجز: ' || t, coalesce(new.text, w.title), 'wo=' || w.id, 'wo-' || w.id, true);
    perform public.fm_push_add(w.assignee, 'wo_return', '🏫 المدرسة تفيد أن العمل لم يُنجز: ' || t, coalesce(new.text, w.title), 'wo=' || w.id, 'wo-' || w.id, true);
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists fm_push_sc on public.wo_events;
create trigger fm_push_sc after insert on public.wo_events for each row execute function public.fm_push_sc();
revoke all on function public.fm_sc_cfg(), public.fm_wo_school_token(text, text), public.fm_wo_sc_trg(), public.fm_push_sc() from public, anon, authenticated;
revoke all on function public.fm_school_wo_confirm(text, uuid, boolean, text, text) from public;
grant execute on function public.fm_school_wo_confirm(text, uuid, boolean, text, text) to anon, authenticated;
grant execute on function public.fm_school_portal(text) to anon, authenticated;

-- (2) alerts before a ticket breaches its SLA
create table if not exists public.fm_sla_watch (
  region      text not null,
  ticket_id   text not null,
  school      text,
  building_id text,
  priority    text,
  category    text,
  descr       text,
  due_at      timestamptz not null,
  sup         text,
  eng         text,
  users       uuid[] not null default '{}',
  warned_at   timestamptz,
  updated_at  timestamptz not null default now(),
  primary key (region, ticket_id)
);
create index if not exists fm_sla_watch_due_idx on public.fm_sla_watch (due_at);
create table if not exists public.fm_sla_watch_meta (region text primary key, synced_at timestamptz not null default now(), file_date timestamptz, n int, by_name text);
create table if not exists public.fm_sla_morning (user_id uuid not null, day date not null, primary key (user_id, day));
alter table public.fm_sla_watch enable row level security;
alter table public.fm_sla_watch_meta enable row level security;
alter table public.fm_sla_morning enable row level security;
revoke all on public.fm_sla_watch, public.fm_sla_watch_meta, public.fm_sla_morning from anon, authenticated;
create or replace function public.fm_sla_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('enabled', coalesce((s->>'enabled')::boolean, true), 'hours', greatest(0.5, least(coalesce(nullif(s->>'hours','')::numeric, 2), 24)),
           'quiet_from', coalesce(nullif(s->>'quiet_from','')::int, 22), 'quiet_to', coalesce(nullif(s->>'quiet_to','')::int, 6),
           'morning', greatest(0, least(coalesce(nullif(s->>'morning','')::int, 7), 23)), 'boss', coalesce((s->>'boss')::boolean, false))
    from (select coalesce(public.fm_setting('sla_warn'), '{}'::jsonb) s) x $$;
-- the accounts behind a supervisor / engineer name in the tickets
create or replace function public.fm_sla_people(p_sup text, p_eng text) returns uuid[] language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct p.id), '{}') from public.profiles p, unnest(array[nullif(btrim(coalesce(p_sup,'')),''), nullif(btrim(coalesce(p_eng,'')),'')]) n(nm)
   where n.nm is not null and p.active and public.fm_posx(p.role, p.job_title) is not null
     and (n.nm = any(coalesce(p.person_names,'{}')) or btrim(coalesce(p.full_name,'')) = n.nm) $$;
-- the uploader sends a region's open tickets: p {file_date, rows:[{t, s, b, p, c, d, due (ISO or ms), sup, eng}]} (≤ 5000)
create or replace function public.fm_sla_watch_set(p_region text, p jsonb) returns int language plpgsql security definer set search_path = public as $$
declare n int; rows jsonb := coalesce(p->'rows','[]');
begin
  if auth.uid() is null or not public.fm_can_upload(p_region) or btrim(coalesce(p_region,'')) = '' then raise exception 'not allowed'; end if;
  if not public.fm_mod('tickets') then raise exception 'module disabled: tickets'; end if;
  if jsonb_typeof(rows) <> 'array' or jsonb_array_length(rows) > 5000 then raise exception 'too many rows'; end if;
  create temp table if not exists fm_sla_in (t text, s text, b text, pr text, c text, d text, due timestamptz, sup text, eng text) on commit drop;
  delete from fm_sla_in;
  insert into fm_sla_in
  select distinct on (btrim(e->>'t')) left(btrim(e->>'t'),80), left(e->>'s',200), left(e->>'b',40), left(e->>'p',30), left(e->>'c',120), left(e->>'d',300),
         case when (e->>'due') ~ '^[0-9]+$' then to_timestamp((e->>'due')::numeric / 1000) else (e->>'due')::timestamptz end,
         left(nullif(btrim(coalesce(e->>'sup','')),''),120), left(nullif(btrim(coalesce(e->>'eng','')),''),120)
    from jsonb_array_elements(rows) e where btrim(coalesce(e->>'t','')) <> '' and coalesce(e->>'due','') <> '';
  delete from public.fm_sla_watch w where w.region = p_region and not exists (select 1 from fm_sla_in i where i.t = w.ticket_id);
  insert into public.fm_sla_watch (region, ticket_id, school, building_id, priority, category, descr, due_at, sup, eng, users, updated_at)
  select p_region, i.t, i.s, i.b, i.pr, i.c, i.d, i.due, i.sup, i.eng, public.fm_sla_people(i.sup, i.eng), now() from fm_sla_in i
  on conflict (region, ticket_id) do update set school = excluded.school, building_id = excluded.building_id, priority = excluded.priority,
     category = excluded.category, descr = excluded.descr, sup = excluded.sup, eng = excluded.eng, users = excluded.users, updated_at = now(),
     warned_at = case when public.fm_sla_watch.due_at = excluded.due_at then public.fm_sla_watch.warned_at end, due_at = excluded.due_at;
  get diagnostics n = row_count;
  insert into public.fm_sla_watch_meta (region, synced_at, file_date, n, by_name)
  values (p_region, now(), case when coalesce(p->>'file_date','') ~ '^[0-9]+$' then to_timestamp((p->>'file_date')::numeric / 1000) else nullif(p->>'file_date','')::timestamptz end,
          n, public.fm_me_name())
  on conflict (region) do update set synced_at = now(), file_date = excluded.file_date, n = excluded.n, by_name = excluded.by_name;
  return n;
end $$;
-- what the caller may see: managers of the region, the people on the ticket and their managers
create or replace function public.fm_sla_watch_list() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('cfg', public.fm_sla_cfg(),
    'meta', coalesce((select jsonb_agg(to_jsonb(m)) from public.fm_sla_watch_meta m), '[]'::jsonb),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('region', w.region, 't', w.ticket_id, 's', w.school, 'b', w.building_id, 'p', w.priority, 'c', w.category,
          'd', w.descr, 'due', w.due_at, 'sup', w.sup, 'eng', w.eng, 'linked', cardinality(w.users), 'warned_at', w.warned_at, 'mine', auth.uid() = any(w.users)) order by w.due_at)
        from public.fm_sla_watch w
       where w.due_at > now() - interval '1 day'
         and (public.fm_scope_region(w.region) or public.fm_can_upload(w.region) or auth.uid() = any(w.users)
              or exists (select 1 from unnest(w.users) u where public.fm_is_under(u, auth.uid())))), '[]'::jsonb))
   where public.fm_role() not in ('pending') $$;
-- every 15 minutes: the alert before the deadline, the morning summary
create or replace function public.fm_sla_warn_run() returns int language plpgsql security definer set search_path = public as $$
declare c jsonb := public.fm_sla_cfg(); hr int := extract(hour from now() at time zone 'Asia/Riyadh')::int; qf int := (c->>'quiet_from')::int; qt int := (c->>'quiet_to')::int;
  quiet boolean; u record; n int := 0; today date := (now() at time zone 'Asia/Riyadh')::date; b uuid;
begin
  if not (c->>'enabled')::boolean or not public.fm_mod('tickets') then return 0; end if;
  quiet := case when qf = qt then false when qf < qt then hr >= qf and hr < qt else hr >= qf or hr < qt end;
  if not quiet then
    for u in select x.uid, count(*) cnt, min(w.due_at) first_due, array_agg(w.ticket_id order by w.due_at) ids,
                    string_agg(coalesce(w.school,'') || ' (' || w.ticket_id || ')', '، ' order by w.due_at) names
               from public.fm_sla_watch w cross join lateral unnest(w.users) x(uid)
              where w.warned_at is null and w.due_at > now() and w.due_at <= now() + make_interval(mins => ((c->>'hours')::numeric * 60)::int)
              group by x.uid loop
      if public.fm_push_add(u.uid, 'sla_due',
           case when u.cnt = 1 then '⏰ بلاغ سيتجاوز المهلة خلال ' || greatest(1, ceil(extract(epoch from u.first_due - now()) / 60))::int || ' دقيقة'
                else '⏰ ' || u.cnt || ' بلاغات ستتجاوز المهلة خلال ' || (c->>'hours') || ' ساعة' end,
           left(u.names, 280), 'sla', 'sla', true) then n := n + 1; end if;
      if (c->>'boss')::boolean then
        select reports_to into b from public.profiles where id = u.uid;
        if b is not null then perform public.fm_push_add(b, 'sla_due', '⏰ ' || u.cnt || ' بلاغ لفريقك يقترب من تجاوز المهلة', left(u.names, 280), 'sla', 'sla-team', true); end if;
      end if;
    end loop;
    update public.fm_sla_watch set warned_at = now()
     where warned_at is null and due_at > now() and due_at <= now() + make_interval(mins => ((c->>'hours')::numeric * 60)::int);
  end if;
  if hr >= (c->>'morning')::int and not quiet then
    for u in select x.uid, count(*) cnt, string_agg(coalesce(w.school,'') || ' (' || w.ticket_id || ')', '، ' order by w.due_at) names
               from public.fm_sla_watch w cross join lateral unnest(w.users) x(uid)
              where w.due_at > now() and (w.due_at at time zone 'Asia/Riyadh')::date = today
                and not exists (select 1 from public.fm_sla_morning m where m.user_id = x.uid and m.day = today)
              group by x.uid loop
      insert into public.fm_sla_morning (user_id, day) values (u.uid, today) on conflict do nothing;
      if public.fm_push_add(u.uid, 'sla_due', '☀️ ' || u.cnt || ' بلاغ يتجاوز المهلة اليوم إن لم يُغلق', left(u.names, 280), 'sla', 'sla-am', true) then n := n + 1; end if;
    end loop;
  end if;
  delete from public.fm_sla_morning where day < today - 7;
  return n;
end $$;
revoke all on function public.fm_sla_cfg(), public.fm_sla_people(text, text), public.fm_sla_warn_run() from public, anon, authenticated;
revoke all on function public.fm_sla_watch_set(text, jsonb), public.fm_sla_watch_list() from public, anon;
grant execute on function public.fm_sla_watch_set(text, jsonb), public.fm_sla_watch_list() to authenticated;
do $do$ begin
  begin execute 'select cron.unschedule(''fm-sla-warn'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-sla-warn'', ''*/15 * * * *'', ''select public.fm_sla_warn_run()'')';
  exception when others then raise notice 'pg_cron is not available: the SLA alerts are not sent (the platform page still lists them)'; end;
end $do$;

-- (3) automatic reorder drafts
alter table public.wo_purchase_requests add column if not exists auto boolean not null default false;
alter table public.wo_purchase_requests drop constraint if exists wo_purchase_requests_status_check;
alter table public.wo_purchase_requests add constraint wo_purchase_requests_status_check check (status in ('draft','requested','approved','rejected','cancelled','partial','received'));
-- what a store should reorder now
create or replace function public.fm_wh_auto_po_rows(p_store uuid) returns table(material_id uuid, qty numeric, price numeric, min_qty numeric, bal numeric, on_order numeric, use30 numeric)
language sql stable security definer set search_path = public as $$
  select x.material_id, ceil(greatest(2 * x.min_qty, 2 * u.use30) - greatest(x.qty, 0) - o.q) qty, coalesce(m.price, 0), x.min_qty, x.qty, o.q, u.use30
    from public.wo_stock x join public.wo_materials m on m.id = x.material_id and m.active
                                and (m.approved_at is not null or coalesce(m.approval,'approved') = 'approved')
    cross join lateral (select coalesce(-sum(v.qty), 0) use30 from public.wo_stock_moves v where v.store_id = x.store_id and v.material_id = x.material_id
                         and v.kind in ('out','issue') and v.qty < 0 and v.at > now() - interval '30 days') u
    cross join lateral (select coalesce(sum(greatest(coalesce((l->>'qty')::numeric,0) - coalesce((l->>'recv')::numeric,0), 0)), 0) q
                          from public.wo_purchase_requests po, jsonb_array_elements(po.lines) l
                         where po.store_id = x.store_id and po.status in ('requested','approved','partial') and l->>'material_id' = x.material_id::text) o
   where x.store_id = p_store and coalesce(x.min_qty, 0) > 0 and coalesce(x.qty, 0) < x.min_qty
     and ceil(greatest(2 * x.min_qty, 2 * u.use30) - greatest(x.qty, 0) - o.q) > 0 $$;
-- build / refresh the draft of one store (internal)
create or replace function public.fm_wh_auto_po_store(p_store uuid) returns jsonb language plpgsql security definer set search_path = public as $$
declare st public.wo_stores; L jsonb; t numeric; d public.wo_purchase_requests; k uuid;
begin
  select * into st from public.wo_stores where id = p_store and active;
  if not found then return null; end if;
  select coalesce(jsonb_agg(jsonb_build_object('material_id', r.material_id, 'qty', r.qty, 'price', r.price, 'recv', 0, 'min', r.min_qty, 'bal', r.bal, 'on_order', r.on_order, 'use30', r.use30)), '[]'),
         coalesce(sum(r.qty * r.price), 0) into L, t from public.fm_wh_auto_po_rows(p_store) r;
  select * into d from public.wo_purchase_requests where store_id = p_store and status = 'draft' and auto order by at desc limit 1 for update;
  if jsonb_array_length(L) = 0 then
    if d.id is not null then update public.wo_purchase_requests set status = 'cancelled', response = 'لم يعد هناك صنف تحت الحد الأدنى' where id = d.id; end if;
    return jsonb_build_object('store', st.name, 'lines', 0);
  end if;
  if d.id is null then
    insert into public.wo_purchase_requests (store_id, lines, total, status, auto, note, requested_by, requested_by_name)
    values (p_store, L, round(t, 2), 'draft', true, '🤖 مسودة آلية: أصناف تحت الحد الأدنى — راجعها ثم أرسلها للاعتماد', null, 'إعادة الطلب الآلية') returning * into d;
  else
    update public.wo_purchase_requests set lines = L, total = round(t, 2), at = now() where id = d.id returning * into d;
  end if;
  for k in select * from public.fm_wh_keepers_of(st.region) loop
    begin perform public.fm_push_add(k, 'wh_low', '🤖 مسودة طلب شراء ' || d.code || ' — ' || st.name, jsonb_array_length(L) || ' صنف تحت الحد الأدنى — راجعها وأرسلها للاعتماد', 'wh=po', 'apo-' || st.id, true);
    exception when others then null; end;
  end loop;
  return jsonb_build_object('store', st.name, 'lines', jsonb_array_length(L), 'code', d.code, 'id', d.id, 'total', round(t, 2));
end $$;
-- on demand (storekeeper / stock manager): one store, or every store the caller manages
create or replace function public.fm_wh_auto_po(p_store uuid default null) returns jsonb language plpgsql security definer set search_path = public as $$
declare s public.wo_stores; R jsonb := '[]'; x jsonb;
begin
  if auth.uid() is null then raise exception 'not allowed'; end if;
  if not public.fm_mod('wh') then raise exception 'module disabled: wh'; end if;
  for s in select * from public.wo_stores where active and (p_store is null or id = p_store) loop
    if public.fm_wh_keeper(s.id) or public.fm_stock_can(s.region) then
      x := public.fm_wh_auto_po_store(s.id); if x is not null then R := R || x; end if;
    elsif p_store is not null then raise exception 'not allowed'; end if;
  end loop;
  return R;
end $$;
-- pg_cron (daily): builds the drafts on the configured weekday
create or replace function public.fm_wh_auto_po_run() returns int language plpgsql security definer set search_path = public as $$
declare a jsonb := coalesce(public.fm_setting('stock_rules')->'auto_po', '{}'); s uuid; n int := 0;
begin
  if not coalesce((a->>'enabled')::boolean, false) or not public.fm_mod('wh') then return 0; end if;
  if extract(dow from now() at time zone 'Asia/Riyadh')::int <> coalesce(nullif(a->>'dow','')::int, 0) then return 0; end if;
  for s in select id from public.wo_stores where active loop
    if (public.fm_wh_auto_po_store(s)->>'lines')::int > 0 then n := n + 1; end if;
  end loop;
  return n;
end $$;
-- the storekeeper / stock manager reviews a draft: submit p {lines:[{material_id, qty, price}], supplier_id, note} | cancel p {note}
create or replace function public.fm_po_draft_act(p_id uuid, p_action text, p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare r public.wo_purchase_requests; st public.wo_stores; s uuid := nullif(p->>'supplier_id','')::uuid; x jsonb; L jsonb := '[]'; t numeric := 0; q numeric; pr numeric; u uuid;
begin
  select * into r from public.wo_purchase_requests where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  select * into st from public.wo_stores where id = r.store_id;
  if not (public.fm_wh_keeper(st.id) or public.fm_stock_can(st.region)) then raise exception 'not allowed'; end if;
  if r.status <> 'draft' then raise exception 'invalid status'; end if;
  if p_action = 'cancel' then
    update public.wo_purchase_requests set status = 'cancelled', response = left(coalesce(nullif(btrim(coalesce(p->>'note','')),''), 'أُلغيت المسودة') || ' — ' || public.fm_me_name(), 500) where id = p_id;
    return 'cancelled';
  elsif p_action <> 'submit' then raise exception 'invalid action'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'lines', r.lines)) loop
    if not exists(select 1 from public.wo_materials where id = nullif(x->>'material_id','')::uuid and active) then raise exception 'unknown material'; end if;
    q := nullif(x->>'qty','')::numeric; if q is null or q <= 0 or q > 1000000 then raise exception 'invalid qty'; end if;
    pr := coalesce(nullif(x->>'price','')::numeric, public.fm_wh_agreed((x->>'material_id')::uuid, s), 0);
    if pr < 0 then raise exception 'invalid price'; end if;
    L := L || jsonb_build_object('material_id', x->>'material_id', 'qty', q, 'price', pr, 'recv', 0); t := t + q * pr;
  end loop;
  if jsonb_array_length(L) = 0 then raise exception 'no lines'; end if;
  update public.wo_purchase_requests set status = 'requested', lines = L, total = round(t, 2), supplier_id = s, supplier_name = (select name from public.wo_suppliers where id = s),
         note = left(coalesce(nullif(btrim(coalesce(p->>'note','')),''), '🤖 من إعادة الطلب الآلية'), 500), requested_by = auth.uid(), requested_by_name = public.fm_me_name(), at = now()
   where id = p_id;
  for u in select * from public.fm_push_people(array['project_manager','ops_manager'], null) union select * from public.fm_push_people(array['area_manager'], st.region) loop
    begin perform public.fm_push_add(u, 'appr', '🛒 طلب شراء بانتظار الاعتماد ' || coalesce(r.code,''), coalesce(st.name,'') || ' — ' || round(t)::text || ' ر.س', 'wh=po', 'po-' || r.id);
    exception when others then null; end;
  end loop;
  return 'requested';
end $$;
revoke all on function public.fm_wh_auto_po_rows(uuid), public.fm_wh_auto_po_store(uuid), public.fm_wh_auto_po_run() from public, anon, authenticated;
revoke all on function public.fm_wh_auto_po(uuid), public.fm_po_draft_act(uuid, text, jsonb) from public, anon;
grant execute on function public.fm_wh_auto_po(uuid), public.fm_po_draft_act(uuid, text, jsonb) to authenticated;
do $do$ begin
  begin execute 'select cron.unschedule(''fm-wh-auto-po'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-wh-auto-po'', ''15 5 * * *'', ''select public.fm_wh_auto_po_run()'')';
  exception when others then raise notice 'pg_cron is not available: the weekly reorder drafts are built only from the platform button'; end;
end $do$;
notify pgrst, 'reload schema';
commit;

-- ---------- 45) attendance, vehicles, documents and certificates, electricity / water meters (V224) ----------
-- (1) fm_att: start / end of the working day and school visits with the phone's location (the distance to the school is
--     measured on the phone from the school DB coordinates); fm_att_add(p) (offline-safe: client_id once per person, «at» from
--     the phone accepted up to 48 hours back), fm_att_list(from, to) — own rows, the team below (fm_is_under), the area
--     manager's regions, every row for fm_scope_all / admin.
-- (2) fm_vehicles (VH-###) + fm_vehicle_logs (fuel / km / maint / other, odometer, liters, amount, receipt photo): managers
--     (fm_vh_can: admin, sysadmin, project / ops manager, accountant, area manager of the region) save vehicles; the driver or a
--     manager logs; an amount on a vehicle with a cost center (part «cc») becomes an fm_cc_entries cost (fuel → fuel, else
--     vehicles) and is cancelled with the log. The odometer may not go back.
-- (3) fm_docs (DOC-YYYY-####) + fm_doc_files: certificates / contracts / warranties / licences per building, the company or a
--     vehicle, with an expiry date; all through RPCs (fm_docs_list, fm_doc_save, fm_doc_file_set / _get, fm_doc_archive).
-- (4) fm_meters + fm_meter_reads: monthly electricity / water readings per school (reading ≥ the previous one unless «reset»,
--     amount, photo); fm_meters_list(months), fm_meter_save, fm_meter_read, fm_meter_photo.
-- fm_v224_daily() (pg_cron fm-v224-daily 05:50 UTC): push «docs» for documents and vehicle insurance / registration / periodic
-- inspection expiring in remind_days (30), 7 or 0 days, and every 7 days after expiry.
begin;
-- (1) attendance
create table if not exists public.fm_att (
  id        uuid primary key default gen_random_uuid(),
  user_id   uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  name      text,
  at        timestamptz not null default now(),
  day       date not null default ((now() at time zone 'Asia/Riyadh')::date),
  kind      text not null check (kind in ('in','out','visit')),
  lat       numeric(9,6),
  lng       numeric(9,6),
  acc       int,
  school    text,
  bkey      text,
  dist_m    int,
  note      text,
  client_id text,
  synced_at timestamptz not null default now()
);
create unique index if not exists fm_att_client on public.fm_att (user_id, client_id) where client_id is not null;
create index if not exists fm_att_day_idx on public.fm_att (day, user_id);
alter table public.fm_att enable row level security;
revoke all on public.fm_att from anon, authenticated;
create or replace function public.fm_att_add(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; at_ timestamptz := now(); r public.fm_att; k text := p->>'kind';
begin
  select * into me from public.profiles where id = auth.uid();
  if me.id is null or not me.active or public.fm_role() = 'pending' then raise exception 'not allowed'; end if;
  if k not in ('in','out','visit') then raise exception 'invalid kind'; end if;
  if nullif(p->>'client_id','') is not null then
    select * into r from public.fm_att where user_id = me.id and client_id = p->>'client_id';
    if found then return jsonb_build_object('id', r.id, 'dup', true); end if;
  end if;
  if nullif(p->>'at','') is not null then
    at_ := (p->>'at')::timestamptz;
    if at_ > now() + interval '5 minutes' or at_ < now() - interval '48 hours' then at_ := now(); end if;
  end if;
  if (select count(*) from public.fm_att where user_id = me.id and day = (at_ at time zone 'Asia/Riyadh')::date) >= 60 then raise exception 'too many'; end if;
  if k = 'visit' and btrim(coalesce(p->>'school','')) = '' then raise exception 'school required'; end if;
  insert into public.fm_att (user_id, name, at, day, kind, lat, lng, acc, school, bkey, dist_m, note, client_id)
  values (me.id, coalesce(me.full_name, me.email), at_, (at_ at time zone 'Asia/Riyadh')::date, k,
          nullif(p->>'lat','')::numeric, nullif(p->>'lng','')::numeric, nullif(p->>'acc','')::numeric::int,
          left(nullif(btrim(coalesce(p->>'school','')),''),200), left(nullif(p->>'bkey',''),80), nullif(p->>'dist_m','')::numeric::int,
          left(nullif(btrim(coalesce(p->>'note','')),''),300), left(nullif(p->>'client_id',''),80))
  returning * into r;
  return jsonb_build_object('id', r.id, 'at', r.at, 'day', r.day);
end $$;
create or replace function public.fm_att_list(p_from date, p_to date) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.id, 'user_id', a.user_id, 'name', coalesce(pr.full_name, a.name), 'title', public.fm_posx(pr.role, pr.job_title),
      'regions', pr.regions, 'at', a.at, 'day', a.day, 'kind', a.kind, 'lat', a.lat, 'lng', a.lng, 'acc', a.acc, 'school', a.school, 'dist_m', a.dist_m, 'note', a.note,
      'late_sync', a.synced_at - a.at > interval '10 minutes') order by a.at), '[]'::jsonb)
    from public.fm_att a join public.profiles pr on pr.id = a.user_id
   where a.day between p_from and least(p_to, p_from + 92)
     and public.fm_role() <> 'pending'
     and (a.user_id = auth.uid() or public.fm_role() = 'admin' or public.fm_scope_all() or public.fm_is_under(a.user_id, auth.uid())
          or (public.fm_my_pos() = 'area_manager' and (cardinality(public.fm_regions()) = 0 or pr.regions && public.fm_regions()))) $$;
revoke all on function public.fm_att_add(jsonb), public.fm_att_list(date, date) from public, anon;
grant execute on function public.fm_att_add(jsonb), public.fm_att_list(date, date) to authenticated;

-- (2) vehicles
create sequence if not exists public.fm_vehicle_seq;
create table if not exists public.fm_vehicles (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null default ('VH-' || lpad(nextval('public.fm_vehicle_seq')::text, 3, '0')),
  plate       text not null,
  make        text,
  model       text,
  year        int,
  region      text,
  driver      uuid references public.profiles(id) on delete set null,
  driver_name text,
  status      text not null default 'active' check (status in ('active','maint','out')),
  odometer    numeric(12,1),
  cc_id       uuid,
  ins_exp     date,
  reg_exp     date,
  check_exp   date,
  notes       text,
  active      boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create unique index if not exists fm_vehicles_plate on public.fm_vehicles (upper(regexp_replace(plate, '\s', '', 'g'))) where active;
create table if not exists public.fm_vehicle_logs (
  id            uuid primary key default gen_random_uuid(),
  vehicle_id    uuid not null references public.fm_vehicles(id) on delete cascade,
  at            timestamptz not null default now(),
  day           date not null default ((now() at time zone 'Asia/Riyadh')::date),
  kind          text not null check (kind in ('fuel','km','maint','other')),
  odometer      numeric(12,1),
  liters        numeric(10,2),
  amount        numeric(12,2),
  station       text,
  note          text,
  photo         text check (photo is null or length(photo) <= 420000),
  by_id         uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name       text,
  cc_entry      uuid,
  cancelled     boolean not null default false,
  cancel_reason text
);
create index if not exists fm_vehicle_logs_idx on public.fm_vehicle_logs (vehicle_id, at desc);
create or replace function public.fm_vh_can(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select public.fm_role() = 'admin' or coalesce(public.fm_my_pos() in ('sysadmin','project_manager','ops_manager','accountant'), false)
      or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(p_region,''))) $$;
create or replace function public.fm_vh_sees(v public.fm_vehicles) returns boolean language sql stable security definer set search_path = public as $$
  select public.fm_vh_can(v.region) or v.driver = auth.uid() or coalesce(public.fm_my_pos() in ('dept_manager','hse_manager','qa_manager'), false)
      or (v.driver is not null and public.fm_is_under(v.driver, auth.uid())) $$;
alter table public.fm_vehicles enable row level security;
alter table public.fm_vehicle_logs enable row level security;
drop policy if exists p_vh_read on public.fm_vehicles;
create policy p_vh_read on public.fm_vehicles for select using (public.fm_vh_sees(fm_vehicles));
drop policy if exists p_vhl_read on public.fm_vehicle_logs;
create policy p_vhl_read on public.fm_vehicle_logs for select using (exists (select 1 from public.fm_vehicles v where v.id = vehicle_id and public.fm_vh_sees(v)));
revoke insert, update, delete on public.fm_vehicles, public.fm_vehicle_logs from anon, authenticated;
grant select on public.fm_vehicles, public.fm_vehicle_logs to authenticated;
-- p {id?, plate, make, model, year, region, driver, status, odometer, cc_id, ins_exp, reg_exp, check_exp, notes, active}
create or replace function public.fm_vehicle_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.fm_vehicles; d public.profiles; rg text := nullif(btrim(coalesce(p->>'region','')),'');
begin
  if auth.uid() is null or not public.fm_vh_can(rg) then raise exception 'not allowed'; end if;
  if btrim(coalesce(p->>'plate','')) = '' then raise exception 'plate required'; end if;
  if nullif(p->>'driver','') is not null then select * into d from public.profiles where id = (p->>'driver')::uuid and active; if d.id is null then raise exception 'driver not found'; end if; end if;
  if nullif(p->>'id','') is not null then
    select * into v from public.fm_vehicles where id = (p->>'id')::uuid for update;
    if not found or not public.fm_vh_can(v.region) then raise exception 'not allowed'; end if;
    update public.fm_vehicles set plate = left(btrim(p->>'plate'),20), make = left(nullif(p->>'make',''),60), model = left(nullif(p->>'model',''),60),
      year = nullif(p->>'year','')::int, region = rg, driver = d.id, driver_name = coalesce(d.full_name, d.email),
      status = coalesce(nullif(p->>'status',''), status), odometer = greatest(coalesce(nullif(p->>'odometer','')::numeric, odometer), coalesce(odometer, 0)),
      cc_id = nullif(p->>'cc_id','')::uuid, ins_exp = nullif(p->>'ins_exp','')::date, reg_exp = nullif(p->>'reg_exp','')::date, check_exp = nullif(p->>'check_exp','')::date,
      notes = left(nullif(p->>'notes',''),500), active = coalesce((p->>'active')::boolean, active), updated_at = now()
    where id = v.id returning * into v;
  else
    insert into public.fm_vehicles (plate, make, model, year, region, driver, driver_name, status, odometer, cc_id, ins_exp, reg_exp, check_exp, notes)
    values (left(btrim(p->>'plate'),20), left(nullif(p->>'make',''),60), left(nullif(p->>'model',''),60), nullif(p->>'year','')::int, rg, d.id, coalesce(d.full_name, d.email),
            coalesce(nullif(p->>'status',''),'active'), nullif(p->>'odometer','')::numeric, nullif(p->>'cc_id','')::uuid,
            nullif(p->>'ins_exp','')::date, nullif(p->>'reg_exp','')::date, nullif(p->>'check_exp','')::date, left(nullif(p->>'notes',''),500))
    returning * into v;
  end if;
  return jsonb_build_object('id', v.id, 'code', v.code);
end $$;
-- p {vehicle_id, kind, odometer, liters, amount, station, note, photo, at}
create or replace function public.fm_vehicle_log(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare v public.fm_vehicles; l public.fm_vehicle_logs; od numeric := nullif(p->>'odometer','')::numeric; am numeric := nullif(p->>'amount','')::numeric;
  at_ timestamptz := coalesce(nullif(p->>'at','')::timestamptz, now()); ce uuid; k text := p->>'kind';
begin
  select * into v from public.fm_vehicles where id = nullif(p->>'vehicle_id','')::uuid for update;
  if auth.uid() is null or not found or not (v.driver = auth.uid() or public.fm_vh_can(v.region)) then raise exception 'not allowed'; end if;
  if not v.active then raise exception 'vehicle inactive'; end if;
  if k not in ('fuel','km','maint','other') then raise exception 'invalid kind'; end if;
  if at_ > now() + interval '5 minutes' or at_ < now() - interval '60 days' then raise exception 'invalid date'; end if;
  if od is not null and (od < 0 or od < coalesce(v.odometer, 0) and at_ >= coalesce((select max(at) from public.fm_vehicle_logs where vehicle_id = v.id and not cancelled and odometer is not null), 'epoch')) then
    raise exception 'odometer lower'; end if;
  if k = 'km' and od is null then raise exception 'odometer required'; end if;
  if k = 'fuel' and (am is null or am <= 0) then raise exception 'amount required'; end if;
  if am is not null and (am < 0 or am > 1000000) then raise exception 'invalid amount'; end if;
  if nullif(p->>'liters','') is not null and ((p->>'liters')::numeric <= 0 or (p->>'liters')::numeric > 2000) then raise exception 'invalid liters'; end if;
  if p->>'photo' is not null and (p->>'photo') !~ '^data:image/(jpeg|png|webp);base64,' then raise exception 'invalid photo'; end if;
  if am > 0 and v.cc_id is not null and public.fm_mod('cc') and exists (select 1 from public.fm_cc_centers where id = v.cc_id) then
    insert into public.fm_cc_entries (center_id, month, kind, cat, amount, ref, note, created_by_name)
    values (v.cc_id, to_char(at_ at time zone 'Asia/Riyadh', 'YYYY-MM'), 'cost', case when k = 'fuel' then 'fuel' else 'vehicles' end, am, v.code,
            left(v.plate || ' — ' || case k when 'fuel' then 'وقود' when 'maint' then 'صيانة' when 'km' then 'كيلومترات' else 'أخرى' end || coalesce(' — ' || nullif(p->>'note',''), ''), 300), public.fm_me_name())
    returning id into ce;
  end if;
  insert into public.fm_vehicle_logs (vehicle_id, at, day, kind, odometer, liters, amount, station, note, photo, by_name, cc_entry)
  values (v.id, at_, (at_ at time zone 'Asia/Riyadh')::date, k, od, nullif(p->>'liters','')::numeric, am, left(nullif(p->>'station',''),100),
          left(nullif(btrim(coalesce(p->>'note','')),''),300), p->>'photo', public.fm_me_name(), ce)
  returning * into l;
  if od is not null and od > coalesce(v.odometer, 0) then update public.fm_vehicles set odometer = od, updated_at = now() where id = v.id; end if;
  if k = 'maint' and p->>'status' in ('active','maint') then update public.fm_vehicles set status = p->>'status' where id = v.id; end if;
  return jsonb_build_object('id', l.id, 'cc', ce is not null);
end $$;
create or replace function public.fm_vehicle_log_cancel(p_id uuid, p_reason text) returns void language plpgsql security definer set search_path = public as $$
declare l public.fm_vehicle_logs; v public.fm_vehicles;
begin
  select * into l from public.fm_vehicle_logs where id = p_id for update;
  if not found then raise exception 'not found'; end if;
  select * into v from public.fm_vehicles where id = l.vehicle_id;
  if auth.uid() is null or not public.fm_vh_can(v.region) then raise exception 'not allowed'; end if;
  if l.cancelled then raise exception 'invalid status'; end if;
  if btrim(coalesce(p_reason,'')) = '' then raise exception 'reason required'; end if;
  update public.fm_vehicle_logs set cancelled = true, cancel_reason = left(p_reason,300) where id = p_id;
  if l.cc_entry is not null then update public.fm_cc_entries set cancelled = true, cancel_reason = 'إلغاء سجل السيارة ' || v.code || ': ' || left(p_reason,200) where id = l.cc_entry; end if;
end $$;
-- the people a vehicle manager may choose as driver
create or replace function public.fm_vh_people() returns table(id uuid, name text, title text, regions text[]) language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.full_name, p.email), public.fm_posx(p.role, p.job_title), p.regions from public.profiles p
   where p.active and public.fm_role() <> 'pending' and public.fm_posx(p.role, p.job_title) is not null
     and (public.fm_vh_can(null) or public.fm_my_pos() = 'area_manager' and (cardinality(public.fm_regions()) = 0 or p.regions && public.fm_regions()))
   order by p.full_name $$;
revoke all on function public.fm_vh_people() from public, anon;
grant execute on function public.fm_vh_people() to authenticated;
revoke all on function public.fm_vh_can(text), public.fm_vh_sees(public.fm_vehicles) from public, anon;
grant execute on function public.fm_vh_can(text), public.fm_vh_sees(public.fm_vehicles) to authenticated;
revoke all on function public.fm_vehicle_save(jsonb), public.fm_vehicle_log(jsonb), public.fm_vehicle_log_cancel(uuid, text) from public, anon;
grant execute on function public.fm_vehicle_save(jsonb), public.fm_vehicle_log(jsonb), public.fm_vehicle_log_cancel(uuid, text) to authenticated;

-- (3) documents and certificates
create sequence if not exists public.fm_doc_seq;
create table if not exists public.fm_docs (
  id              uuid primary key default gen_random_uuid(),
  code            text unique not null default ('DOC-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.fm_doc_seq')::text, 4, '0')),
  scope           text not null check (scope in ('building','company','vehicle')),
  bkey            text,
  school_name     text,
  region          text,
  vehicle_id      uuid references public.fm_vehicles(id) on delete cascade,
  kind            text not null,
  title           text not null,
  number          text,
  issuer          text,
  issue_date      date,
  expiry_date     date,
  remind_days     int not null default 30 check (remind_days between 1 and 365),
  notes           text,
  file_name       text,
  has_file        boolean not null default false,
  active          boolean not null default true,
  created_by      uuid default auth.uid() references public.profiles(id) on delete set null,
  created_by_name text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
create index if not exists fm_docs_exp_idx on public.fm_docs (expiry_date) where active;
create table if not exists public.fm_doc_files (
  doc_id uuid primary key references public.fm_docs(id) on delete cascade,
  data   text not null check (length(data) <= 2800000 and data ~ '^data:(image/(jpeg|png|webp)|application/pdf);base64,'),
  at     timestamptz not null default now()
);
alter table public.fm_docs enable row level security;
alter table public.fm_doc_files enable row level security;
revoke all on public.fm_docs, public.fm_doc_files from anon, authenticated;
-- may the caller see / edit this document?
create or replace function public.fm_doc_ok(d public.fm_docs, p_edit boolean) returns boolean language plpgsql stable security definer set search_path = public as $$
declare v public.fm_vehicles; r text := public.fm_role(); pos text := public.fm_my_pos();
begin
  if auth.uid() is null or r = 'pending' then return false; end if;
  if d.scope = 'company' then
    return r = 'admin' or coalesce(pos in ('sysadmin','dept_manager','project_manager','ops_manager'), false) or (not p_edit and r in ('manager','staff','viewer'));
  elsif d.scope = 'vehicle' then
    select * into v from public.fm_vehicles where id = d.vehicle_id;
    return v.id is not null and (public.fm_vh_can(v.region) or (not p_edit and public.fm_vh_sees(v)));
  end if;
  if p_edit and r not in ('admin','manager','engineer') then return false; end if;
  if not p_edit and r not in ('admin','manager','staff','viewer','engineer','supervisor') then return false; end if;
  return r = 'admin' or public.fm_scope_all() or exists (select 1 from public.fm_my_schools() m where m.bkey = d.bkey);
end $$;
create or replace function public.fm_docs_list() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare keys text[]; r text := public.fm_role();
begin
  if auth.uid() is null or r = 'pending' then return '[]'::jsonb; end if;
  if not (r = 'admin' or public.fm_scope_all()) then select coalesce(array_agg(bkey), '{}') into keys from public.fm_my_schools(); end if;
  return coalesce((select jsonb_agg(to_jsonb(d) order by d.expiry_date nulls last) from public.fm_docs d
     where d.active and (case when d.scope = 'building' then r in ('admin','manager','staff','viewer','engineer','supervisor') and (keys is null or d.bkey = any(keys))
                              else public.fm_doc_ok(d, false) end)), '[]'::jsonb);
end $$;
-- p {id?, scope, bkey, school_name, region, vehicle_id, kind, title, number, issuer, issue_date, expiry_date, remind_days, notes}
create or replace function public.fm_doc_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.fm_docs; n public.fm_docs; v public.fm_vehicles;
begin
  if nullif(p->>'id','') is not null then
    select * into d from public.fm_docs where id = (p->>'id')::uuid for update;
    if not found or not public.fm_doc_ok(d, true) then raise exception 'not allowed'; end if;
  end if;
  n.scope := coalesce(nullif(p->>'scope',''), d.scope);
  if n.scope not in ('building','company','vehicle') then raise exception 'invalid scope'; end if;
  n.bkey := case when n.scope = 'building' then nullif(p->>'bkey','') end;
  n.vehicle_id := case when n.scope = 'vehicle' then nullif(p->>'vehicle_id','')::uuid end;
  if n.scope = 'building' and n.bkey is null then raise exception 'school required'; end if;
  if n.scope = 'vehicle' then select * into v from public.fm_vehicles where id = n.vehicle_id; if v.id is null then raise exception 'vehicle required'; end if; end if;
  if btrim(coalesce(p->>'title','')) = '' or btrim(coalesce(p->>'kind','')) = '' then raise exception 'title required'; end if;
  if not public.fm_doc_ok(n, true) then raise exception 'not allowed'; end if;
  if d.id is null then
    insert into public.fm_docs (scope, bkey, school_name, region, vehicle_id, kind, title, number, issuer, issue_date, expiry_date, remind_days, notes, created_by_name)
    values (n.scope, n.bkey, left(nullif(p->>'school_name',''),200), coalesce(nullif(p->>'region',''), v.region), n.vehicle_id, left(p->>'kind',40), left(btrim(p->>'title'),200),
            left(nullif(p->>'number',''),80), left(nullif(p->>'issuer',''),120), nullif(p->>'issue_date','')::date, nullif(p->>'expiry_date','')::date,
            coalesce(nullif(p->>'remind_days','')::int, 30), left(nullif(p->>'notes',''),1000), public.fm_me_name())
    returning * into d;
  else
    update public.fm_docs set scope = n.scope, bkey = n.bkey, school_name = left(nullif(p->>'school_name',''),200), region = coalesce(nullif(p->>'region',''), v.region),
      vehicle_id = n.vehicle_id, kind = left(p->>'kind',40), title = left(btrim(p->>'title'),200), number = left(nullif(p->>'number',''),80), issuer = left(nullif(p->>'issuer',''),120),
      issue_date = nullif(p->>'issue_date','')::date, expiry_date = nullif(p->>'expiry_date','')::date, remind_days = coalesce(nullif(p->>'remind_days','')::int, 30),
      notes = left(nullif(p->>'notes',''),1000), updated_at = now()
    where id = d.id returning * into d;
  end if;
  return jsonb_build_object('id', d.id, 'code', d.code);
end $$;
create or replace function public.fm_doc_file_set(p_id uuid, p_data text, p_name text) returns void language plpgsql security definer set search_path = public as $$
declare d public.fm_docs;
begin
  select * into d from public.fm_docs where id = p_id;
  if not found or not public.fm_doc_ok(d, true) then raise exception 'not allowed'; end if;
  if p_data is null then delete from public.fm_doc_files where doc_id = p_id; update public.fm_docs set has_file = false, file_name = null where id = p_id; return; end if;
  if length(p_data) > 2800000 or p_data !~ '^data:(image/(jpeg|png|webp)|application/pdf);base64,' then raise exception 'invalid file'; end if;
  insert into public.fm_doc_files (doc_id, data) values (p_id, p_data) on conflict (doc_id) do update set data = excluded.data, at = now();
  update public.fm_docs set has_file = true, file_name = left(nullif(p_name,''),120), updated_at = now() where id = p_id;
end $$;
create or replace function public.fm_doc_file_get(p_id uuid) returns text language plpgsql stable security definer set search_path = public as $$
declare d public.fm_docs;
begin
  select * into d from public.fm_docs where id = p_id;
  if not found or not public.fm_doc_ok(d, false) then raise exception 'not allowed'; end if;
  return (select data from public.fm_doc_files where doc_id = p_id);
end $$;
create or replace function public.fm_doc_archive(p_id uuid) returns void language plpgsql security definer set search_path = public as $$
declare d public.fm_docs;
begin
  select * into d from public.fm_docs where id = p_id for update;
  if not found or not public.fm_doc_ok(d, true) then raise exception 'not allowed'; end if;
  update public.fm_docs set active = false, updated_at = now() where id = p_id;
end $$;
revoke all on function public.fm_doc_ok(public.fm_docs, boolean) from public, anon, authenticated;
revoke all on function public.fm_docs_list(), public.fm_doc_save(jsonb), public.fm_doc_file_set(uuid, text, text), public.fm_doc_file_get(uuid), public.fm_doc_archive(uuid) from public, anon;
grant execute on function public.fm_docs_list(), public.fm_doc_save(jsonb), public.fm_doc_file_set(uuid, text, text), public.fm_doc_file_get(uuid), public.fm_doc_archive(uuid) to authenticated;

-- (4) electricity / water meters
create table if not exists public.fm_meters (
  id          uuid primary key default gen_random_uuid(),
  bkey        text not null,
  school_name text not null,
  region      text,
  kind        text not null check (kind in ('elec','water')),
  number      text,
  account_no  text,
  notes       text,
  active      boolean not null default true,
  created_at  timestamptz not null default now()
);
create index if not exists fm_meters_bkey on public.fm_meters (bkey);
create table if not exists public.fm_meter_reads (
  id        uuid primary key default gen_random_uuid(),
  meter_id  uuid not null references public.fm_meters(id) on delete cascade,
  month     text not null check (month ~ '^\d{4}-\d{2}$'),
  read_at   date,
  reading   numeric(14,2) not null check (reading >= 0),
  reset     boolean not null default false,
  amount    numeric(12,2),
  photo     text check (photo is null or length(photo) <= 420000),
  by_id     uuid default auth.uid() references public.profiles(id) on delete set null,
  by_name   text,
  at        timestamptz not null default now(),
  unique (meter_id, month)
);
alter table public.fm_meters enable row level security;
alter table public.fm_meter_reads enable row level security;
revoke all on public.fm_meters, public.fm_meter_reads from anon, authenticated;
create or replace function public.fm_meter_keys(p_edit boolean) returns text[] language plpgsql stable security definer set search_path = public as $$
declare r text := public.fm_role();
begin
  if auth.uid() is null then return '{}'; end if;
  if p_edit and r not in ('admin','manager','engineer','supervisor','contractor') then return '{}'; end if;
  if not p_edit and r not in ('admin','manager','staff','viewer','engineer','supervisor','contractor') then return '{}'; end if;
  if r = 'admin' or public.fm_scope_all() then return null; end if;      -- null = every school
  return coalesce((select array_agg(bkey) from public.fm_my_schools()), '{}');
end $$;
-- p {id?, bkey, school_name, region, kind, number, account_no, notes, active}
create or replace function public.fm_meter_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare k text[] := public.fm_meter_keys(true); m public.fm_meters; b text := coalesce(nullif(p->>'bkey',''), '');
begin
  if public.fm_role() not in ('admin','manager','engineer','supervisor') then raise exception 'not allowed'; end if;
  if nullif(p->>'id','') is not null then select * into m from public.fm_meters where id = (p->>'id')::uuid for update; if not found then raise exception 'not found'; end if; b := m.bkey; end if;
  if b = '' or (k is not null and not b = any(k)) then raise exception 'not allowed'; end if;
  if m.id is null then
    if p->>'kind' not in ('elec','water') or btrim(coalesce(p->>'school_name','')) = '' then raise exception 'invalid meter'; end if;
    insert into public.fm_meters (bkey, school_name, region, kind, number, account_no, notes)
    values (b, left(btrim(p->>'school_name'),200), nullif(p->>'region',''), p->>'kind', left(nullif(p->>'number',''),60), left(nullif(p->>'account_no',''),60), left(nullif(p->>'notes',''),300))
    returning * into m;
  else
    update public.fm_meters set number = left(nullif(p->>'number',''),60), account_no = left(nullif(p->>'account_no',''),60), notes = left(nullif(p->>'notes',''),300),
      active = coalesce((p->>'active')::boolean, active) where id = m.id returning * into m;
  end if;
  return jsonb_build_object('id', m.id);
end $$;
-- p {meter_id, month 'YYYY-MM', reading, amount, photo, read_at, reset}
create or replace function public.fm_meter_read(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare k text[] := public.fm_meter_keys(true); m public.fm_meters; prev numeric; rd numeric := nullif(p->>'reading','')::numeric; mo text := p->>'month'; r public.fm_meter_reads;
begin
  select * into m from public.fm_meters where id = nullif(p->>'meter_id','')::uuid and active;
  if not found or (k is not null and not m.bkey = any(k)) then raise exception 'not allowed'; end if;
  if mo !~ '^\d{4}-\d{2}$' or mo > to_char(now() at time zone 'Asia/Riyadh', 'YYYY-MM') then raise exception 'invalid month'; end if;
  if rd is null or rd < 0 then raise exception 'invalid reading'; end if;
  if p->>'photo' is not null and (p->>'photo') !~ '^data:image/(jpeg|png|webp);base64,' then raise exception 'invalid photo'; end if;
  select reading into prev from public.fm_meter_reads where meter_id = m.id and month < mo order by month desc limit 1;
  if prev is not null and rd < prev and not coalesce((p->>'reset')::boolean, false) then raise exception 'reading lower: %', prev; end if;
  insert into public.fm_meter_reads (meter_id, month, read_at, reading, reset, amount, photo, by_name)
  values (m.id, mo, coalesce(nullif(p->>'read_at','')::date, (now() at time zone 'Asia/Riyadh')::date), rd, coalesce((p->>'reset')::boolean, false),
          nullif(p->>'amount','')::numeric, p->>'photo', public.fm_me_name())
  on conflict (meter_id, month) do update set read_at = excluded.read_at, reading = excluded.reading, reset = excluded.reset, amount = excluded.amount,
     photo = coalesce(excluded.photo, public.fm_meter_reads.photo), by_id = auth.uid(), by_name = excluded.by_name, at = now()
  returning * into r;
  return jsonb_build_object('id', r.id, 'use', case when prev is not null and not r.reset then rd - prev end);
end $$;
create or replace function public.fm_meters_list(p_months int default 13) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare k text[] := public.fm_meter_keys(false); since text := to_char((now() at time zone 'Asia/Riyadh') - make_interval(months => greatest(2, least(coalesce(p_months,13), 37))), 'YYYY-MM');
begin
  if public.fm_role() in ('pending') or (k is not null and cardinality(k) = 0) then return jsonb_build_object('meters','[]'::jsonb,'reads','[]'::jsonb,'edit',false); end if;
  return jsonb_build_object('edit', public.fm_role() in ('admin','manager','engineer','supervisor','contractor'),
    'meters', coalesce((select jsonb_agg(to_jsonb(m) order by m.school_name, m.kind) from public.fm_meters m where m.active and (k is null or m.bkey = any(k))), '[]'::jsonb),
    'reads', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'meter_id', r.meter_id, 'month', r.month, 'read_at', r.read_at, 'reading', r.reading, 'reset', r.reset,
               'amount', r.amount, 'photo', r.photo is not null, 'by_name', r.by_name) order by r.month)
             from public.fm_meter_reads r join public.fm_meters m on m.id = r.meter_id where m.active and (k is null or m.bkey = any(k)) and r.month >= since), '[]'::jsonb));
end $$;
create or replace function public.fm_meter_photo(p_id uuid) returns text language plpgsql stable security definer set search_path = public as $$
declare k text[] := public.fm_meter_keys(false); b text;
begin
  select m.bkey into b from public.fm_meter_reads r join public.fm_meters m on m.id = r.meter_id where r.id = p_id;
  if b is null or (k is not null and not b = any(k)) then raise exception 'not allowed'; end if;
  return (select photo from public.fm_meter_reads where id = p_id);
end $$;
revoke all on function public.fm_meter_keys(boolean) from public, anon, authenticated;
revoke all on function public.fm_meter_save(jsonb), public.fm_meter_read(jsonb), public.fm_meters_list(int), public.fm_meter_photo(uuid) from public, anon;
grant execute on function public.fm_meter_save(jsonb), public.fm_meter_read(jsonb), public.fm_meters_list(int), public.fm_meter_photo(uuid) to authenticated;

-- daily: documents and vehicle papers about to expire
create or replace function public.fm_v224_daily() returns int language plpgsql security definer set search_path = public as $$
declare d record; u uuid; n int := 0; today date := (now() at time zone 'Asia/Riyadh')::date; left_ int; t text;
begin
  for d in select x.*, v.driver, v.plate from public.fm_docs x left join public.fm_vehicles v on v.id = x.vehicle_id where x.active and x.expiry_date is not null
           union all
           select null::uuid, 'VH', 'vehicle', null::text, null::text, v.region, v.id, e.k, e.t || ' — ' || v.plate, null::text, null::text, null::date, e.d, 30, null::text, null::text, false, true, null::uuid, null::text, now(), now(), v.driver, v.plate
             from public.fm_vehicles v cross join lateral (values ('ins','تأمين السيارة',v.ins_exp),('reg','استمارة السيارة',v.reg_exp),('check','الفحص الدوري للسيارة',v.check_exp)) e(k,t,d)
            where v.active and e.d is not null loop
    left_ := d.expiry_date - today;
    if not (left_ in (d.remind_days, 7, 0) or (left_ < 0 and (-left_) % 7 = 0)) then continue; end if;
    t := case when left_ < 0 then '⛔ انتهت: ' when left_ = 0 then '⛔ تنتهي اليوم: ' else '📄 تنتهي خلال ' || left_ || ' يوم: ' end || d.title;
    for u in select x from (select d.created_by x union select d.driver
               union select y from public.fm_push_people(array['area_manager'], d.region) y
               union select y from public.fm_push_people(case when d.scope = 'company' then array['sysadmin','project_manager'] else array[]::text[] end, null) y) z where x is not null loop
      begin if public.fm_push_add(u, 'docs', t, coalesce(d.school_name, d.plate, '') || coalesce(' — ' || d.number, ''), 'docs', 'doc-' || coalesce(d.id::text, d.vehicle_id::text || d.kind), true) then n := n + 1; end if;
      exception when others then null; end;
    end loop;
  end loop;
  return n;
end $$;
revoke all on function public.fm_v224_daily() from public, anon, authenticated;
do $do$ begin
  begin execute 'select cron.unschedule(''fm-v224-daily'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-v224-daily'', ''50 5 * * *'', ''select public.fm_v224_daily()'')';
  exception when others then raise notice 'pg_cron is not available: expiry reminders are not sent (the platform page still shows them)'; end;
end $do$;
notify pgrst, 'reload schema';
commit;

-- ---------- 46) AI assistant usage and automatic WhatsApp messages (V226) ----------
-- (1) The Edge Function fm-ai calls the Claude API (its key and model id are function secrets, never here or in the browser).
--     fm_ai_begin(kind) runs with the caller's token: active non-pending account, fm_settings.ai.enabled, at most
--     ai.daily_limit (30) calls per person a day (Riyadh); it records the call in fm_ai_usage; fm_ai_end stores the tokens.
--     fm_ai_stats() (system admin): use per day and per person over 30 days.
-- (2) fm_wa_queue holds template messages for the WhatsApp Business Cloud API, sent by the Edge Function fm-wa (pg_net kick on
--     insert, pg_cron fm-wa-flush every minute). fm_settings.wa {enabled, lang, base_url, tenant, templates {req_update,
--     confirm}}: when a school-portal request changes status the person who raised it gets req_update [code, school, status,
--     reply, link]; when a work order of a school with a portal link waits for the principal (V223) the principal (school DB
--     «جوال مدير المدرسة») gets confirm [school, work, link]. fm_wa_config (function URL + hook secret), fm_wa_test(phone)
--     (Meta's hello_world template), fm_wa_status() — system admin only. Phone numbers are normalised to 9665XXXXXXXX.
begin;
-- (1) AI
create table if not exists public.fm_ai_usage (
  id         bigserial primary key,
  user_id    uuid not null references public.profiles(id) on delete cascade,
  at         timestamptz not null default now(),
  day        date not null default ((now() at time zone 'Asia/Riyadh')::date),
  kind       text not null,
  tokens_in  int,
  tokens_out int,
  ok         boolean,
  err        text
);
create index if not exists fm_ai_usage_day on public.fm_ai_usage (user_id, day);
alter table public.fm_ai_usage enable row level security;
revoke all on public.fm_ai_usage from anon, authenticated;
create or replace function public.fm_ai_begin(p_kind text) returns bigint language plpgsql security definer set search_path = public as $$
declare s jsonb := coalesce(public.fm_setting('ai'), '{}'); lim int := greatest(1, least(coalesce(nullif(s->>'daily_limit','')::int, 30), 1000)); id_ bigint;
begin
  if auth.uid() is null or public.fm_role() in ('pending') or public.fm_role() is null then raise exception 'not allowed'; end if;
  if not coalesce((s->>'enabled')::boolean, false) then raise exception 'ai disabled'; end if;
  if p_kind not in ('classify','summary','recurring') then raise exception 'invalid kind'; end if;
  if (select count(*) from public.fm_ai_usage where user_id = auth.uid() and day = (now() at time zone 'Asia/Riyadh')::date) >= lim then raise exception 'daily limit reached'; end if;
  insert into public.fm_ai_usage (user_id, kind) values (auth.uid(), p_kind) returning id into id_;
  return id_;
end $$;
create or replace function public.fm_ai_end(p_id bigint, p_in int, p_out int, p_ok boolean, p_err text) returns void language sql security definer set search_path = public as $$
  update public.fm_ai_usage set tokens_in = p_in, tokens_out = p_out, ok = p_ok, err = left(p_err, 300) where id = p_id and user_id = auth.uid() $$;
create or replace function public.fm_ai_me() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('enabled', coalesce((public.fm_setting('ai')->>'enabled')::boolean, false),
    'limit', coalesce(nullif(public.fm_setting('ai')->>'daily_limit','')::int, 30),
    'used', (select count(*) from public.fm_ai_usage where user_id = auth.uid() and day = (now() at time zone 'Asia/Riyadh')::date)) $$;
create or replace function public.fm_ai_stats() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if public.fm_role() is distinct from 'admin' and public.fm_my_pos() is distinct from 'sysadmin' then raise exception 'not allowed'; end if;
  return jsonb_build_object(
    'days', coalesce((select jsonb_agg(jsonb_build_object('day', day, 'n', n, 'tin', tin, 'tout', tout, 'fail', fail) order by day desc)
       from (select day, count(*) n, sum(coalesce(tokens_in,0)) tin, sum(coalesce(tokens_out,0)) tout, count(*) filter (where ok is false) fail
               from public.fm_ai_usage where day > (now() at time zone 'Asia/Riyadh')::date - 30 group by day) x), '[]'::jsonb),
    'people', coalesce((select jsonb_agg(jsonb_build_object('name', coalesce(p.full_name, p.email), 'n', x.n) order by x.n desc)
       from (select user_id, count(*) n from public.fm_ai_usage where day > (now() at time zone 'Asia/Riyadh')::date - 30 group by user_id) x
       join public.profiles p on p.id = x.user_id), '[]'::jsonb),
    'last_err', (select err from public.fm_ai_usage where ok is false order by id desc limit 1));
end $$;
revoke all on function public.fm_ai_begin(text), public.fm_ai_end(bigint, int, int, boolean, text), public.fm_ai_me(), public.fm_ai_stats() from public, anon;
grant execute on function public.fm_ai_begin(text), public.fm_ai_end(bigint, int, int, boolean, text), public.fm_ai_me(), public.fm_ai_stats() to authenticated;

-- (2) WhatsApp
create table if not exists public.fm_wa_queue (
  id         bigserial primary key,
  created_at timestamptz not null default now(),
  phone      text not null,
  template   text not null,
  lang       text not null default 'ar',
  params     jsonb not null default '[]',
  kind       text,
  ref        text,
  status     text not null default 'queued' check (status in ('queued','sent','failed')),
  tries      int not null default 0,
  claimed_at timestamptz,
  sent_at    timestamptz,
  wa_id      text,
  err        text
);
create index if not exists fm_wa_queue_wait on public.fm_wa_queue (status, id);
create table if not exists public.fm_wa_cfg (id int primary key default 1 check (id = 1), fn_url text, hook_secret text, anon_key text, kicked_at timestamptz);
alter table public.fm_wa_queue enable row level security;
alter table public.fm_wa_cfg enable row level security;
revoke all on public.fm_wa_queue, public.fm_wa_cfg from anon, authenticated;
create or replace function public.fm_wa_norm(p text) returns text language sql immutable as $$
  select case when d ~ '^05[0-9]{8}$' then '966' || substr(d, 2) when d ~ '^5[0-9]{8}$' then '966' || d
              when d ~ '^9665[0-9]{8}$' then d when d ~ '^009665[0-9]{8}$' then substr(d, 3) end
    from (select regexp_replace(translate(coalesce(p,''), '٠١٢٣٤٥٦٧٨٩', '0123456789'), '[^0-9]', '', 'g') d) x $$;
create or replace function public.fm_wa_add(p_phone text, p_tkey text, p_params text[], p_kind text, p_ref text) returns boolean
language plpgsql security definer set search_path = public as $$
declare s jsonb := coalesce(public.fm_setting('wa'), '{}'); ph text := public.fm_wa_norm(p_phone); tpl text := nullif(btrim(coalesce(s->'templates'->>p_tkey, '')), '');
begin
  if not coalesce((s->>'enabled')::boolean, false) or ph is null or tpl is null then return false; end if;
  -- the same message for the same thing once in 10 minutes
  if exists (select 1 from public.fm_wa_queue where phone = ph and kind = p_kind and ref is not distinct from p_ref and created_at > now() - interval '10 minutes') then return false; end if;
  insert into public.fm_wa_queue (phone, template, lang, params, kind, ref)
  values (ph, tpl, coalesce(nullif(s->>'lang',''), 'ar'), to_jsonb(coalesce(p_params, '{}'::text[])), p_kind, left(p_ref, 80));
  return true;
end $$;
create or replace function public.fm_wa_kick() returns void language plpgsql security definer set search_path = public as $$
declare c public.fm_wa_cfg;
begin
  update public.fm_wa_cfg set kicked_at = now() where id = 1 and fn_url is not null and coalesce(kicked_at, 'epoch') < now() - interval '3 seconds' returning * into c;
  if not found then return; end if;
  begin
    execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 20000)'
      using c.fn_url, jsonb_build_object('Content-Type','application/json','x-fm-hook', c.hook_secret)
                     || case when c.anon_key is not null then jsonb_build_object('Authorization','Bearer ' || c.anon_key, 'apikey', c.anon_key) else '{}'::jsonb end;
  exception when others then null; end;
end $$;
create or replace function public.fm_wa_flush() returns void language plpgsql security definer set search_path = public as $$
begin
  if exists (select 1 from public.fm_wa_queue where status = 'queued' and tries < 5) then
    update public.fm_wa_cfg set kicked_at = null where id = 1; perform public.fm_wa_kick();
  end if;
end $$;
create or replace function public.fm_wa_q_kick() returns trigger language plpgsql security definer set search_path = public as $$
begin perform public.fm_wa_kick(); return null; end $$;
drop trigger if exists fm_wa_q_kick on public.fm_wa_queue;
create trigger fm_wa_q_kick after insert on public.fm_wa_queue for each statement execute function public.fm_wa_q_kick();
-- the Edge Function (service role)
create or replace function public.fm_wa_claim(n int) returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  with c as (
    update public.fm_wa_queue q set claimed_at = now(), tries = q.tries + 1
     where q.id in (select id from public.fm_wa_queue where status = 'queued' and tries < 5 and created_at > now() - interval '2 days'
                      and (claimed_at is null or claimed_at < now() - interval '2 minutes') order by id limit greatest(1, least(coalesce(n,50), 200)) for update skip locked)
    returning q.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'phone', c.phone, 'template', c.template, 'lang', c.lang, 'params', c.params)), '[]'::jsonb) into r from c;
  return r;
end $$;
create or replace function public.fm_wa_result(p jsonb) returns int language plpgsql security definer set search_path = public as $$
declare x jsonb; n int := 0;
begin
  for x in select * from jsonb_array_elements(coalesce(p,'[]')) loop
    update public.fm_wa_queue set
      status = case when (x->>'ok')::boolean then 'sent' when coalesce((x->>'final')::boolean, false) or tries >= 5 then 'failed' else 'queued' end,
      sent_at = case when (x->>'ok')::boolean then now() end, wa_id = left(x->>'wa_id', 100), err = left(nullif(x->>'err',''), 300), claimed_at = null
     where id = (x->>'id')::bigint;
    n := n + 1;
  end loop;
  return n;
end $$;
-- the principal's mobile from the school DB (key or name)
create or replace function public.fm_wa_principal(p_bkey text, p_name text) returns text language plpgsql stable security definer set search_path = public as $$
declare v jsonb; ph text;
begin
  select value into v from public.app_kv where key = 'fm_school_master_db_v1';
  if jsonb_typeof(v) = 'string' then v := (v #>> '{}')::jsonb; end if;
  if v is null or jsonb_typeof(v) <> 'array' then return null; end if;
  select e->>'principalPhone' into ph from jsonb_array_elements(v) e
   where jsonb_typeof(e) = 'object' and (public.fm_bkey(e->>'buildingId', e->>'school') = p_bkey or btrim(coalesce(e->>'school','')) = btrim(coalesce(p_name,'')))
     and nullif(btrim(coalesce(e->>'principalPhone','')),'') is not null
   order by (public.fm_bkey(e->>'buildingId', e->>'school') = p_bkey) desc limit 1;
  return ph;
end $$;
create or replace function public.fm_wa_link(p_token text) returns text language sql stable security definer set search_path = public as $$
  select case when nullif(s->>'base_url','') is null or p_token is null then '—'
              else rtrim(s->>'base_url', '/') || '/school.html?k=' || p_token || coalesce('&c=' || nullif(s->>'tenant',''), '') end
    from (select coalesce(public.fm_setting('wa'), '{}') s) x $$;
-- events
create or replace function public.fm_wa_req_trg() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.status is distinct from old.status and new.status in ('accepted','in_progress','done','rejected') and nullif(new.contact_phone,'') is not null then
    perform public.fm_wa_add(new.contact_phone, 'req_update',
      array[coalesce(new.code,''), new.school_name,
            case new.status when 'accepted' then 'تم استلام الطلب' when 'in_progress' then 'قيد التنفيذ' when 'done' then 'تم الإنجاز' else 'لم يُقبل الطلب' end,
            coalesce(nullif(left(new.response, 300),''), '—'), public.fm_wa_link(new.token)],
      'req_' || new.status, new.id::text);
  end if;
  return null;
exception when others then return null;
end $$;
drop trigger if exists fm_wa_req on public.fm_school_requests;
create trigger fm_wa_req after update of status on public.fm_school_requests for each row execute function public.fm_wa_req_trg();
create or replace function public.fm_wa_sc_trg() returns trigger language plpgsql security definer set search_path = public as $$
declare tk text;
begin
  -- runs after update of status: sc_status is set by the before trigger fm_wo_sc, so a trigger «of sc_status» would not fire
  if new.sc_status = 'pending' and new.status = 'done' and old.status is distinct from 'done' then
    tk := public.fm_wo_school_token(new.building_id, new.school);
    perform public.fm_wa_add(public.fm_wa_principal(public.fm_bkey(new.building_id, new.school), new.school), 'confirm',
      array[coalesce(new.school,''), left(new.title, 200), public.fm_wa_link(tk)], 'confirm', new.id::text);
  end if;
  return null;
exception when others then return null;
end $$;
do $do$ begin
  if exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'work_orders' and column_name = 'sc_status') then
    execute 'drop trigger if exists fm_wa_sc on public.work_orders';
    execute 'create trigger fm_wa_sc after update of status on public.work_orders for each row execute function public.fm_wa_sc_trg()';
  end if;
end $do$;
-- system admin
create or replace function public.fm_wa_config(p jsonb) returns boolean language plpgsql security definer set search_path = public as $$
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed'; end if;
  if nullif(p->>'fn_url','') is not null and p->>'fn_url' !~ '^https://[^ ]+$' then raise exception 'invalid url'; end if;
  if nullif(p->>'hook_secret','') is not null and length(p->>'hook_secret') < 24 then raise exception 'secret too short'; end if;
  insert into public.fm_wa_cfg(id) values (1) on conflict do nothing;
  update public.fm_wa_cfg set fn_url = case when p ? 'fn_url' then nullif(btrim(p->>'fn_url'),'') else fn_url end,
    hook_secret = case when nullif(p->>'hook_secret','') is not null then p->>'hook_secret' else hook_secret end,
    anon_key = case when p ? 'anon_key' then nullif(btrim(p->>'anon_key'),'') else anon_key end, kicked_at = null where id = 1;
  return true;
end $$;
create or replace function public.fm_wa_test(p_phone text) returns boolean language plpgsql security definer set search_path = public as $$
declare ph text := public.fm_wa_norm(p_phone);
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed'; end if;
  if ph is null then raise exception 'invalid phone'; end if;
  insert into public.fm_wa_queue (phone, template, lang, params, kind, ref) values (ph, 'hello_world', 'en_US', '[]', 'test', null);
  return true;
end $$;
create or replace function public.fm_wa_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed'; end if;
  return jsonb_build_object(
    'fn', (select fn_url from public.fm_wa_cfg where id = 1), 'hook', (select hook_secret is not null from public.fm_wa_cfg where id = 1),
    'counts', (select jsonb_object_agg(status, n) from (select status, count(*) n from public.fm_wa_queue where created_at > now() - interval '30 days' group by status) x),
    'last', coalesce((select jsonb_agg(jsonb_build_object('at', q.created_at, 'phone', '…' || right(q.phone, 4), 'template', q.template, 'kind', q.kind, 'status', q.status, 'err', q.err) order by q.id desc)
       from (select * from public.fm_wa_queue order by id desc limit 20) q), '[]'::jsonb));
end $$;
revoke all on function public.fm_wa_add(text, text, text[], text, text), public.fm_wa_kick(), public.fm_wa_flush(), public.fm_wa_q_kick(), public.fm_wa_claim(int),
  public.fm_wa_result(jsonb), public.fm_wa_principal(text, text), public.fm_wa_link(text), public.fm_wa_req_trg(), public.fm_wa_sc_trg() from public, anon, authenticated;
revoke all on function public.fm_wa_config(jsonb), public.fm_wa_test(text), public.fm_wa_status() from public, anon;
grant execute on function public.fm_wa_config(jsonb), public.fm_wa_test(text), public.fm_wa_status() to authenticated;
do $do$ begin
  execute 'grant execute on function public.fm_wa_claim(int), public.fm_wa_result(jsonb) to service_role';
exception when undefined_object then null; end $do$;
do $do$ begin
  begin execute 'select cron.unschedule(''fm-wa-flush'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-wa-flush'', ''* * * * *'', ''select public.fm_wa_flush()'')';
  exception when others then raise notice 'pg_cron is not available: WhatsApp messages go out when the queue is kicked'; end;
end $do$;
notify pgrst, 'reload schema';
commit;

-- ---------- 47) V230 integrity ----------
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

-- ---------- 48) V231 pre-breach escalation ----------
-- V231 / F53: configurable pre-breach recipients, durable account inbox, WhatsApp and Push.
begin;
create or replace function public.fm231_manage(r text) returns boolean language sql stable security definer set search_path=public as $$
 select auth.uid() is not null and public.fm_role()<>'pending' and public.fm_mod('tickets') and
 (public.fm_role()='admin' or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager') or
 (r is not null and public.fm_my_pos()='area_manager' and public.fm_region_ok(r))) $$;
create or replace function public.fm231_target(u uuid,r text) returns boolean language sql stable security definer set search_path=public as $$
 select exists(select 1 from public.profiles p where p.id=u and p.active and p.role<>'pending' and
 (r is null or cardinality(coalesce(p.regions,'{}'))=0 or r=any(p.regions) or public.fm_posx(p.role,p.job_title) in ('sysadmin','dept_manager','project_manager','ops_manager'))) $$;
create table if not exists public.fm_sla_rules231(
 id uuid primary key default gen_random_uuid(),name text not null check(length(name) between 1 and 120),region text,
 lead_minutes int not null check(lead_minutes between 5 and 10080),recipients uuid[] not null check(cardinality(recipients) between 1 and 30),
 whatsapp boolean not null default true,push boolean not null default true,enabled boolean not null default false,
 max_age_hours int not null default 24 check(max_age_hours between 1 and 168),revision int not null default 1,
 updated_at timestamptz not null default now(),updated_by uuid references public.profiles(id) on delete set null);
alter table public.fm_sla_rules231 enable row level security;
revoke insert,update,delete on public.fm_sla_rules231 from anon,authenticated;
grant select on public.fm_sla_rules231 to authenticated;
drop policy if exists p_rule231 on public.fm_sla_rules231;
create policy p_rule231 on public.fm_sla_rules231 for select to authenticated using(public.fm231_manage(region));
create table if not exists public.fm_sla_inbox231(
 id uuid primary key default gen_random_uuid(),rule_id uuid references public.fm_sla_rules231(id) on delete set null,
 region text not null,ticket_id text not null,due_at timestamptz not null,recipient uuid not null references public.profiles(id) on delete cascade,
 lead_minutes int not null,school text,priority text,descr text,title text not null,body text not null,created_at timestamptz not null default now(),read_at timestamptz,
 whatsapp boolean not null,push boolean not null,wa_state text not null default 'pending',wa_reason text,wa_id bigint references public.fm_wa_queue(id) on delete set null,
 push_state text not null default 'pending',push_id bigint references public.fm_push_queue(id) on delete set null,
 unique(region,ticket_id,due_at,recipient,lead_minutes));
create index if not exists fm_sla_inbox231_user on public.fm_sla_inbox231(recipient,created_at desc);
alter table public.fm_sla_inbox231 enable row level security;
revoke insert,update,delete on public.fm_sla_inbox231 from anon,authenticated;
grant select on public.fm_sla_inbox231 to authenticated;
drop policy if exists p_inbox231 on public.fm_sla_inbox231;
create policy p_inbox231 on public.fm_sla_inbox231 for select to authenticated using(public.fm_role()<>'pending' and public.fm_mod('tickets') and(recipient=auth.uid() or public.fm231_manage(region)));
create or replace function public.fm231_open(r text,t text) returns boolean language sql stable security definer set search_path=public as $$
 select not exists(select 1 from public.ticket_work w where w.region=r and w.ticket_id=t and(w.resolved_at is not null or w.stage in('resolved','closed','cancelled')))
 and not exists(select 1 from public.tickets k where k.region=r and k.ticket_id=t and lower(btrim(coalesce(k.status,''))) in('مغلق','تم حله','ملغى','خارج النطاق','closed','resolved','cancelled','canceled','out of scope')) $$;
create or replace function public.fm_sla231_rule_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare old public.fm_sla_rules231;v public.fm_sla_rules231;r text:=nullif(btrim(p->>'region'),'');ids uuid[];u uuid;k uuid:=nullif(p->>'id','')::uuid;
begin
 if not public.fm231_manage(r) then raise exception 'not allowed';end if;
 if jsonb_typeof(p->'recipients') is distinct from 'array' then raise exception 'select recipients';end if;
 select array_agg(distinct x::uuid) into ids from jsonb_array_elements_text(p->'recipients') x;
 if cardinality(ids) is null or cardinality(ids) not between 1 and 30 or array_position(ids,null) is not null then raise exception 'select 1 to 30 recipients';end if;
 foreach u in array ids loop if coalesce((p->>'enabled')::boolean,false) and not public.fm231_target(u,r) then raise exception 'recipient inactive or outside region';end if;end loop;
 if k is not null then
  select * into old from public.fm_sla_rules231 where id=k for update;
  if not found or not public.fm231_manage(old.region) then raise exception 'not allowed';end if;
  if (p->>'revision')::int is distinct from old.revision then raise exception 'version conflict: reload';end if;
 else k:=gen_random_uuid();end if;
 perform pg_advisory_xact_lock(231,2);
 if coalesce((p->>'enabled')::boolean,false) and exists(select 1 from public.fm_sla_rules231 q where q.id<>k and q.enabled and(q.region is null or r is null or q.region=r) and q.lead_minutes=(p->>'lead_minutes')::int and q.recipients&&ids) then raise exception 'duplicate stage recipient: edit the existing stage';end if;
 insert into public.fm_sla_rules231(id,name,region,lead_minutes,recipients,whatsapp,push,enabled,max_age_hours,updated_by)
 values(k,btrim(p->>'name'),r,(p->>'lead_minutes')::int,ids,coalesce((p->>'whatsapp')::boolean,true),coalesce((p->>'push')::boolean,true),coalesce((p->>'enabled')::boolean,false),coalesce((p->>'max_age_hours')::int,24),auth.uid())
 on conflict(id) do update set name=excluded.name,region=excluded.region,lead_minutes=excluded.lead_minutes,recipients=excluded.recipients,whatsapp=excluded.whatsapp,push=excluded.push,enabled=excluded.enabled,max_age_hours=excluded.max_age_hours,revision=public.fm_sla_rules231.revision+1,updated_at=now(),updated_by=auth.uid() returning * into v;
 return to_jsonb(v);
end $$;
create or replace function public.fm_sla231_template(n text) returns boolean language plpgsql security definer set search_path=public as $$
declare s jsonb:=coalesce(public.fm_setting('wa'),'{}');
begin
 if not public.fm231_manage(null) then raise exception 'not allowed';end if;
 if n is null or n!~'^[a-z0-9_]{1,100}$' then raise exception 'invalid template name';end if;
 s:=jsonb_set(s,'{templates}',coalesce(s->'templates','{}')||jsonb_build_object('sla_prebreach',n));
 insert into public.fm_settings(key,value) values('wa',s) on conflict(key) do update set value=excluded.value;
 return true;
end $$;
-- Only the recipient may acknowledge their alert. Admin visibility does not confer that acknowledgement.
create or replace function public.fm_sla231_read(k uuid) returns boolean language plpgsql security definer set search_path=public as $$
begin
 if public.fm_role()='pending' or not public.fm_mod('tickets') then raise exception 'not allowed';end if;
 update public.fm_sla_inbox231 set read_at=coalesce(read_at,now()) where id=k and recipient=auth.uid();return found;
end $$;
-- Worker and retry loop: one durable inbox event for each ticket/deadline/recipient/threshold.
create or replace function public.fm_sla231_run(p_region text default null) returns int language plpgsql security definer set search_path=public as $$
declare rr record;e public.fm_sla_inbox231;n int:=0;ph text;wa jsonb:=coalesce(public.fm_setting('wa'),'{}');ok boolean;event_ref text;pk bigint;
begin
 if not public.fm_plan_ok() or not public.fm_mod('tickets') then return 0;end if;
 if not pg_try_advisory_xact_lock(231,1) then return 0;end if;
 for rr in select q.id rule_id,q.lead_minutes,q.whatsapp,q.push,w.*,u.uid recipient from public.fm_sla_rules231 q
 join public.fm_sla_watch w on(q.region is null or q.region=w.region) cross join lateral unnest(q.recipients) u(uid)
 where q.enabled and(p_region is null or w.region=p_region) and w.due_at>now() and w.due_at<=now()+make_interval(mins=>q.lead_minutes)
 and w.updated_at>=now()-make_interval(hours=>q.max_age_hours) and public.fm231_target(u.uid,w.region) and public.fm231_open(w.region,w.ticket_id)
 order by w.region,w.ticket_id,q.id,u.uid loop
  insert into public.fm_sla_inbox231(rule_id,region,ticket_id,due_at,recipient,lead_minutes,school,priority,descr,title,body,whatsapp,push)
  values(rr.rule_id,rr.region,rr.ticket_id,rr.due_at,rr.recipient,rr.lead_minutes,rr.school,rr.priority,rr.descr,
   '⏰ تصعيد قبل اختراق البلاغ '||rr.ticket_id,
   coalesce(rr.school,'')||' • البلاغ '||rr.ticket_id||' • الأولوية '||coalesce(rr.priority,'')||' • يتبقى '||greatest(1,ceil(extract(epoch from rr.due_at-now())/60))::int||' دقيقة • نهاية المهلة '||to_char(rr.due_at at time zone 'Asia/Riyadh','YYYY-MM-DD HH24:MI'),rr.whatsapp,rr.push)
  on conflict(region,ticket_id,due_at,recipient,lead_minutes) do nothing;
  if found then n:=n+1;end if;
 end loop;
 for e in select i.* from public.fm_sla_inbox231 i join public.fm_sla_rules231 q on q.id=i.rule_id
 where q.enabled and(p_region is null or i.region=p_region) and q.lead_minutes=i.lead_minutes and(q.region is null or q.region=i.region) and i.recipient=any(q.recipients) and i.due_at>now() and public.fm231_target(i.recipient,i.region) and public.fm231_open(i.region,i.ticket_id)
 and exists(select 1 from public.fm_sla_watch w where w.region=i.region and w.ticket_id=i.ticket_id and w.due_at=i.due_at and w.updated_at>=now()-make_interval(hours=>q.max_age_hours))
 and (i.wa_state in('pending','blocked') or i.push_state='pending') order by i.created_at,i.id for update of i loop
  event_ref:='sla231-'||e.id::text;
  if e.push_state='pending' then
   if not e.push or not (select push from public.fm_sla_rules231 where id=e.rule_id) then update public.fm_sla_inbox231 set push_state='not_requested' where id=e.id;
   else
    begin
     -- Honor the recipient's notification preferences; inbox delivery is independent of Push.
     if not exists(select 1 from public.fm_push_prefs where user_id=e.recipient and 'sla_due'=any(off)) and not coalesce((public.fm_setting('push')->'off')?'sla_due',false) and public.fm_push_add(e.recipient,'sla_due',e.title,e.body,'sla-escalation',event_ref,true) then
      select id into pk from public.fm_push_queue where user_id=e.recipient and tag=event_ref order by id desc limit 1;
      update public.fm_sla_inbox231 set push_state='queued',push_id=pk where id=e.id;
     else update public.fm_sla_inbox231 set push_state='unavailable' where id=e.id;end if;
    exception when others then update public.fm_sla_inbox231 set push_state='unavailable' where id=e.id;end;
   end if;
  end if;
  if e.wa_state in('pending','blocked') then
   if not e.whatsapp or not (select whatsapp from public.fm_sla_rules231 where id=e.rule_id) then update public.fm_sla_inbox231 set wa_state='not_requested',wa_reason=null where id=e.id;
   else
    select public.fm_wa_norm(phone) into ph from public.profiles where id=e.recipient;
    if not coalesce((wa->>'enabled')::boolean,false) then update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='whatsapp_disabled' where id=e.id;
    elsif ph is null then update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='invalid_profile_phone' where id=e.id;
    elsif nullif(wa->'templates'->>'sla_prebreach','') is null then update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='template_missing' where id=e.id;
    elsif not exists(select 1 from public.fm_wa_cfg where id=1 and fn_url is not null and hook_secret is not null) then update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='sender_not_configured' where id=e.id;
    else
     begin
      ok:=public.fm_wa_add(ph,'sla_prebreach',array[coalesce((select coalesce(full_name,email) from public.profiles where id=e.recipient),''),e.ticket_id,coalesce(e.school,''),coalesce(e.priority,''),to_char(e.due_at at time zone 'Asia/Riyadh','YYYY-MM-DD HH24:MI'),greatest(1,ceil(extract(epoch from e.due_at-now())/60))::int::text],'sla_prebreach',event_ref);
      select id into pk from public.fm_wa_queue where kind='sla_prebreach' and ref=event_ref and phone=ph order by id desc limit 1;
      if pk is not null then update public.fm_sla_inbox231 set wa_state='queued',wa_reason=null,wa_id=pk where id=e.id;
      else update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='queue_rejected' where id=e.id;end if;
     exception when others then update public.fm_sla_inbox231 set wa_state='blocked',wa_reason='queue_error' where id=e.id;end;
    end if;
   end if;
  end if;
 end loop;
 return n;
end $$;
create or replace function public.fm_sla231_run_now(r text) returns int language plpgsql security definer set search_path=public as $$
begin if not public.fm231_manage(r) then raise exception 'not allowed';end if;return public.fm_sla231_run(r);end $$;
-- Expiration/closure check immediately before channel workers claim an escalation message.
create or replace function public.fm231_valid(k uuid) returns boolean language sql stable security definer set search_path=public as $$
 select public.fm_plan_ok() and public.fm_mod('tickets') and exists(select 1 from public.fm_sla_inbox231 i join public.fm_sla_rules231 q on q.id=i.rule_id join public.fm_sla_watch w on w.region=i.region and w.ticket_id=i.ticket_id and w.due_at=i.due_at
 where i.id=k and q.enabled and q.lead_minutes=i.lead_minutes and(q.region is null or q.region=i.region) and i.recipient=any(q.recipients) and public.fm231_target(i.recipient,i.region) and public.fm231_open(i.region,i.ticket_id) and i.due_at>now() and w.updated_at>=now()-make_interval(hours=>q.max_age_hours)) $$;
create or replace function public.fm_sla231_setup() returns jsonb language plpgsql stable security definer set search_path=public as $$
declare mgr boolean:=public.fm231_manage(null);wa jsonb:=coalesce(public.fm_setting('wa'),'{}');cron_on boolean:=false;
begin
 if auth.uid() is null or public.fm_role()='pending' or not public.fm_mod('tickets') then raise exception 'not allowed';end if;
 begin execute 'select exists(select 1 from cron.job where jobname=''fm-sla-escalation231'' and active)' into cron_on;exception when undefined_table or invalid_schema_name or insufficient_privilege then cron_on:=false;end;
 return jsonb_build_object('all_regions',mgr,'can_manage',mgr or public.fm_my_pos()='area_manager',
 'regions',case when mgr or cardinality(public.fm_regions())=0 then array['riyadh','qassim'] else public.fm_regions() end,
 'rules',coalesce((select jsonb_agg(to_jsonb(q) order by q.updated_at desc) from public.fm_sla_rules231 q where public.fm231_manage(q.region)),'[]'),
 'people',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'name',coalesce(p.full_name,p.email),'title',public.fm_posx(p.role,p.job_title),'regions',p.regions,'phone_ready',public.fm_wa_norm(p.phone) is not null) order by p.full_name) from public.profiles p where p.active and p.role<>'pending' and(mgr or(public.fm_my_pos()='area_manager' and(cardinality(public.fm_regions())=0 or p.regions&&public.fm_regions() or cardinality(coalesce(p.regions,'{}'))=0)))),'[]'),
 'meta',coalesce((select jsonb_agg(to_jsonb(m)) from public.fm_sla_watch_meta m where public.fm231_manage(m.region)),'[]'),
 'cron',cron_on,'whatsapp_enabled',coalesce((wa->>'enabled')::boolean,false),'template',wa->'templates'->>'sla_prebreach',
 'sender_configured',exists(select 1 from public.fm_wa_cfg where id=1 and fn_url is not null and hook_secret is not null));
end $$;
create or replace function public.fm_sla231_list(p_all boolean default false,p_offset int default 0) returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if auth.uid() is null or public.fm_role()='pending' or not public.fm_mod('tickets') then raise exception 'not allowed';end if;
 return jsonb_build_object('unread',(select count(*) from public.fm_sla_inbox231 where recipient=auth.uid() and read_at is null),
 'total',(select count(*) from public.fm_sla_inbox231 i where i.recipient=auth.uid() or(p_all and public.fm231_manage(i.region))),
 'items',coalesce((select jsonb_agg(to_jsonb(x) order by x.created_at desc,x.id desc) from(
 select i.id,i.region,i.ticket_id,i.school,i.priority,i.due_at,i.lead_minutes,i.title,i.body,i.created_at,i.read_at,i.recipient,
 coalesce(p.full_name,p.email) recipient_name,i.recipient=auth.uid() mine,public.fm231_open(i.region,i.ticket_id) source_open,
 case when i.wa_id is not null then w.status else i.wa_state end wa_state,coalesce(w.err,i.wa_reason) wa_reason,w.sent_at wa_sent_at,
 case when q.sent_at is not null then 'sent' when q.tries>=5 then 'failed' else i.push_state end push_state
 from public.fm_sla_inbox231 i left join public.profiles p on p.id=i.recipient left join public.fm_wa_queue w on w.id=i.wa_id left join public.fm_push_queue q on q.id=i.push_id
 where i.recipient=auth.uid() or(p_all and public.fm231_manage(i.region)) order by i.created_at desc,i.id desc offset greatest(0,coalesce(p_offset,0)) limit 100)x),'[]'));
end $$;
revoke all on function public.fm231_manage(text),public.fm231_target(uuid,text),public.fm231_open(text,text),public.fm_sla231_run(text),public.fm231_valid(uuid),public.fm_sla231_rule_save(jsonb),public.fm_sla231_template(text),public.fm_sla231_read(uuid),public.fm_sla231_run_now(text),public.fm_sla231_setup(),public.fm_sla231_list(boolean,int) from public,anon,authenticated;
grant execute on function public.fm231_manage(text),public.fm_sla231_rule_save(jsonb),public.fm_sla231_template(text),public.fm_sla231_read(uuid),public.fm_sla231_run_now(text),public.fm_sla231_setup(),public.fm_sla231_list(boolean,int) to authenticated;
-- The scheduled job does not depend on an open browser. Existing general SLA warnings are preserved.
do $do$ begin
 begin execute 'select cron.unschedule(''fm-sla-escalation231'')';exception when others then null;end;
 begin execute 'select cron.schedule(''fm-sla-escalation231'',''* * * * *'',''select public.fm_sla231_run(null)'')';
 exception when others then raise notice 'pg_cron is unavailable; configure the job to enable unattended SLA escalations';end;
end $do$;

create or replace function public.fm_wa_claim(n int) returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  update public.fm_wa_queue set status='failed',err='SLA event no longer current' where kind='sla_prebreach' and status='queued' and exists(select 1 from public.fm_sla_inbox231 i where fm_wa_queue.ref='sla231-'||i.id::text and (not public.fm231_valid(i.id) or not (select whatsapp from public.fm_sla_rules231 where id=i.rule_id)));
  with c as (
    update public.fm_wa_queue q set claimed_at = now(), tries = q.tries + 1
     where q.id in (select id from public.fm_wa_queue where status = 'queued' and tries < 5 and created_at > now() - interval '2 days'
                      and (claimed_at is null or claimed_at < now() - interval '2 minutes') order by id limit greatest(1, least(coalesce(n,50), 200)) for update skip locked)
    returning q.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'phone', c.phone, 'template', c.template, 'lang', c.lang, 'params', c.params)), '[]'::jsonb) into r from c;
  return r;
end $$;

create or replace function public.fm_push_claim(n int) returns jsonb language plpgsql security definer set search_path = public as $$
declare r jsonb;
begin
  update public.fm_push_queue set tries=5,err='SLA event no longer current' where tag like 'sla231-%' and sent_at is null and exists(select 1 from public.fm_sla_inbox231 i where fm_push_queue.tag='sla231-'||i.id::text and (not public.fm231_valid(i.id) or not (select push from public.fm_sla_rules231 where id=i.rule_id)));
  with c as (
    update public.fm_push_queue q set claimed_at = now(), tries = q.tries + 1
     where q.id in (select id from public.fm_push_queue where sent_at is null and tries < 5 and created_at > now() - interval '1 day'
                      and (claimed_at is null or claimed_at < now() - interval '2 minutes') order by id limit greatest(1, least(coalesce(n,100), 500)) for update skip locked)
    returning q.*)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'title', c.title, 'body', c.body, 'url', c.url, 'tag', c.tag, 'kind', c.kind,
           'subs', coalesce((select jsonb_agg(jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth)) from public.fm_push_subs s where s.user_id = c.user_id), '[]'))), '[]')
    into r from c;
  return r;
end $$;

notify pgrst,'reload schema';
commit;

-- 49: incremental ticket imports V232
begin;
-- V232: incremental Excel source import; requires V231. Never writes field work.
create table if not exists public.fm_ticket_imports232 (
 id uuid primary key default gen_random_uuid(), region text not null,
 by_id uuid not null default auth.uid(), at timestamptz not null default now(), summary jsonb not null
);
alter table public.fm_ticket_imports232 enable row level security;
drop policy if exists p_import232 on public.fm_ticket_imports232;
create policy p_import232 on public.fm_ticket_imports232 for select to authenticated using(public.fm_can_upload(region));
revoke insert,update,delete on public.fm_ticket_imports232 from anon,authenticated;
create or replace function public.fm_tickets_import232(p_rows jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r text; x jsonb; n int; added int:=0; updated int:=0; unchanged int:=0; retained int; old public.tickets; v public.tickets; conflicts jsonb; result jsonb;
begin
 if auth.uid() is null or not public.fm_plan_ok() or not public.fm_mod('tickets') or coalesce(public.fm_role(),'pending')='pending' then raise exception 'not allowed';end if;
 if jsonb_typeof(p_rows) is distinct from 'array' then raise exception 'array required';end if;
 n:=jsonb_array_length(p_rows);if n<1 or n>50000 then raise exception 'import requires 1..50000 rows';end if;
 r:=p_rows->0->>'region';
 if r not in ('riyadh','qassim') or r is null or not coalesce(public.fm_can_upload(r),false) then raise exception 'not allowed';end if;
 if exists(select 1 from jsonb_array_elements(p_rows) a where jsonb_typeof(a)<>'object' or a->>'region' is distinct from r or coalesce(btrim(a->>'ticket_id'),'')='' or jsonb_typeof(a->'raw') is distinct from 'object') then raise exception 'invalid ticket row';end if;
 if exists(select 1 from jsonb_array_elements(p_rows) a group by btrim(a->>'ticket_id') having count(*)>1) then raise exception 'duplicate ticket id';end if;
 perform pg_advisory_xact_lock(232,hashtext(r));
 select count(*) into retained from public.tickets t where t.region=r and not exists(select 1 from jsonb_array_elements(p_rows) a where btrim(a->>'ticket_id')=t.ticket_id);
 for x in select value from jsonb_array_elements(p_rows) loop
  v:=jsonb_populate_record(null::public.tickets,x);v.ticket_id:=btrim(v.ticket_id);
  select * into old from public.tickets t where t.region=r and t.ticket_id=v.ticket_id for update;
  if not found then added:=added+1;
  elsif (to_jsonb(old)-array['uploaded_at','uploaded_by'])=(to_jsonb(v)-array['uploaded_at','uploaded_by']) then unchanged:=unchanged+1;continue;
  else updated:=updated+1;end if;
  insert into public.tickets(region,ticket_id,school,building_id,supervisor,engineer,contractor,priority,sub_category,status,created_at,raw,uploaded_at,uploaded_by)
  values(r,v.ticket_id,v.school,v.building_id,v.supervisor,v.engineer,v.contractor,v.priority,v.sub_category,v.status,v.created_at,v.raw,now(),auth.uid())
  on conflict(region,ticket_id) do update set school=excluded.school,building_id=excluded.building_id,supervisor=excluded.supervisor,engineer=excluded.engineer,contractor=excluded.contractor,priority=excluded.priority,sub_category=excluded.sub_category,status=excluded.status,created_at=excluded.created_at,raw=excluded.raw,uploaded_at=excluded.uploaded_at,uploaded_by=excluded.uploaded_by;
 end loop;
 select coalesce(jsonb_agg(jsonb_build_object('ticket_id',t.ticket_id,'source',t.status,'stage',w.stage) order by t.ticket_id),'[]') into conflicts
 from public.tickets t join public.ticket_work w using(region,ticket_id)
 where t.region=r and exists(select 1 from jsonb_array_elements(p_rows) a where btrim(a->>'ticket_id')=t.ticket_id)
 and w.stage in ('assigned','inspected','progress','parts','reopened','resolved','closed','cancelled')
 and coalesce(t.status,'')<>case w.stage when 'assigned' then 'تم التعيين' when 'resolved' then 'تم حله' when 'closed' then 'مغلق' when 'cancelled' then 'ملغى' else 'قيد التنفيذ' end;
 result:=jsonb_build_object('received',n,'added',added,'updated',updated,'unchanged',unchanged,'retained',retained,'conflicts',conflicts,'max_created_at',(select max(created_at) from public.tickets where region=r),'at',now());
 insert into public.fm_ticket_imports232(region,summary) values(r,result);
 return result;
end $$;
revoke all on function public.fm_tickets_import232(jsonb) from public,anon;
grant execute on function public.fm_tickets_import232(jsonb) to authenticated;
-- Block old clients' destructive "delete tickets missing from this file" behavior.
-- Explicit administrative wipe is a separate permission-checked security-definer RPC.
drop policy if exists p_tickets_write on public.tickets;
drop policy if exists p_tickets_insert232 on public.tickets;
drop policy if exists p_tickets_update232 on public.tickets;
create policy p_tickets_insert232 on public.tickets for insert to authenticated with check(public.fm_can_upload(region));
create policy p_tickets_update232 on public.tickets for update to authenticated using(public.fm_can_upload(region)) with check(public.fm_can_upload(region));

-- Field stage is authoritative for escalation eligibility as well as field/desktop display.
create or replace function public.fm231_open(r text,t text) returns boolean language sql stable security definer set search_path=public as $$
 select case when exists(select 1 from public.ticket_work w where w.region=r and w.ticket_id=t and w.stage in('assigned','inspected','progress','parts','reopened','resolved','closed','cancelled'))
 then exists(select 1 from public.ticket_work w where w.region=r and w.ticket_id=t and w.resolved_at is null and w.stage in('assigned','inspected','progress','parts','reopened'))
 else not exists(select 1 from public.ticket_work w where w.region=r and w.ticket_id=t and w.resolved_at is not null)
 and not exists(select 1 from public.tickets k where k.region=r and k.ticket_id=t and lower(btrim(coalesce(k.status,''))) in('مغلق','تم حله','ملغى','خارج النطاق','closed','resolved','cancelled','canceled','out of scope')) end $$;

commit;

-- 50: operational home / workforce V233
begin;
-- V233: explicitly recorded workforce deployment groups. Never infer labour from login accounts.
create or replace function public.fm233_manage(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role()<>'pending' and
 (public.fm_role()='admin' or public.fm_my_pos() in('dept_manager','project_manager','ops_manager') or (public.fm_my_pos()='area_manager' and public.fm_region_ok(r))),false) $$;
create or replace function public.fm233_read(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role()<>'pending' and (public.fm_scope_region(r) or public.fm_role()='admin'),false) $$;
create table if not exists public.fm_workforce233(
 id uuid primary key default gen_random_uuid(),region text not null check(region in('riyadh','qassim')),
 contractor text not null check(length(btrim(contractor)) between 1 and 160),
 trade text not null check(length(btrim(trade)) between 1 and 160),
 supervisor text not null default '' check(length(supervisor)<=160),headcount int not null check(headcount between 0 and 100000),
 active boolean not null default true,note text not null default '',revision int not null default 1,
 updated_at timestamptz not null default now(),updated_by uuid default auth.uid()
);
create unique index if not exists fm_workforce233_group on public.fm_workforce233(region,lower(btrim(contractor)),lower(btrim(trade)),lower(btrim(supervisor))) where active;
create table if not exists public.fm_workforce_events233(id uuid primary key default gen_random_uuid(),group_id uuid not null,at timestamptz not null default now(),by_id uuid not null default auth.uid(),region text not null,old_value jsonb,new_value jsonb);
alter table public.fm_workforce233 enable row level security;
alter table public.fm_workforce_events233 enable row level security;
drop policy if exists p_workforce233 on public.fm_workforce233;
create policy p_workforce233 on public.fm_workforce233 for select to authenticated using(public.fm233_read(region));
drop policy if exists p_workforce_events233 on public.fm_workforce_events233;
create policy p_workforce_events233 on public.fm_workforce_events233 for select to authenticated using(public.fm233_read(region));
revoke insert,update,delete on public.fm_workforce233,public.fm_workforce_events233 from anon,authenticated;
create or replace function public.fm_workforce233_save(p jsonb) returns jsonb language plpgsql security definer set search_path=public as $$
declare v public.fm_workforce233;old public.fm_workforce233;k uuid:=nullif(p->>'id','')::uuid;r text:=p->>'region';
begin
 if not public.fm233_manage(r) then raise exception 'not allowed';end if;
 if btrim(coalesce(p->>'note',''))='' or length(p->>'note')>2000 then raise exception 'note required';end if;
 if coalesce(p->>'headcount','')!~'^\d{1,6}$' then raise exception 'invalid headcount';end if;
 if k is not null then
  select * into old from public.fm_workforce233 where id=k for update;
  if not found or not public.fm233_manage(old.region) then raise exception 'not allowed';end if;
  if old.revision is distinct from (p->>'revision')::int then raise exception 'stale revision';end if;
 end if;
 insert into public.fm_workforce233(id,region,contractor,trade,supervisor,headcount,active,note,revision,updated_at,updated_by)
 values(coalesce(k,gen_random_uuid()),r,btrim(p->>'contractor'),btrim(p->>'trade'),btrim(coalesce(p->>'supervisor','')),(p->>'headcount')::int,coalesce((p->>'active')::boolean,true),btrim(p->>'note'),coalesce(old.revision,0)+1,now(),auth.uid())
 on conflict(id) do update set region=excluded.region,contractor=excluded.contractor,trade=excluded.trade,supervisor=excluded.supervisor,headcount=excluded.headcount,active=excluded.active,note=excluded.note,revision=excluded.revision,updated_at=excluded.updated_at,updated_by=excluded.updated_by returning * into v;
 insert into public.fm_workforce_events233(group_id,region,old_value,new_value) values(v.id,r,case when old.id is not null then to_jsonb(old) end,to_jsonb(v));
 return to_jsonb(v);
end $$;
revoke all on function public.fm233_manage(text),public.fm233_read(text),public.fm_workforce233_save(jsonb) from public,anon;
grant execute on function public.fm233_manage(text),public.fm233_read(text),public.fm_workforce233_save(jsonb) to authenticated;
commit;

-- =====================================================================
-- Section 51 (V239): approved SLA breach causes
-- =====================================================================
-- V239: the approved cause of an SLA breach, chosen per ticket from a drop-list by an authorised person (section 51).
-- Needs the earlier sections (fm_role, fm_my_pos, fm_region_ok, fm_mod, fm_settings). Idempotent.
create table if not exists public.fm_breach_reasons(
 region text not null, ticket_id text not null check(length(ticket_id) between 1 and 120),
 cause text not null check(length(cause) between 1 and 120), note text not null default '' check(length(note)<=500),
 by_id uuid not null default auth.uid(), by_name text not null default '', at timestamptz not null default now(),
 revision int not null default 1, primary key(region, ticket_id));
create table if not exists public.fm_breach_reason_log(
 id bigserial primary key, region text not null, ticket_id text not null, old_cause text, new_cause text, old_note text, new_note text,
 by_id uuid, by_name text, at timestamptz not null default now());
alter table public.fm_breach_reasons enable row level security;
alter table public.fm_breach_reason_log enable row level security;
revoke all on public.fm_breach_reasons, public.fm_breach_reason_log from anon, authenticated;

-- the drop-list: fm_settings.breach_reasons (array of text) written by the system admin, else the defaults
create or replace function public.fm_breach_reason_list() returns jsonb language sql stable security definer set search_path=public as $$
 select coalesce((select value from public.fm_settings where key='breach_reasons' and jsonb_typeof(value)='array' and jsonb_array_length(value)>0),
  '["تأخر توفير قطع الغيار","تأخر المقاول في المباشرة","نقص العمالة أو الفنيين","يحتاج مقاول أو فني متخصص","تعذر الوصول للمدرسة أو المدرسة مغلقة","بانتظار اعتماد أو موافقة","بانتظار موافقة الاستشاري","عطل كبير يحتاج وقتاً أطول من المهلة","خطأ في تسجيل البلاغ أو الأولوية","بلاغ مكرر","تأخر الإغلاق في النظام رغم التنفيذ","ظروف جوية أو قاهرة","أخرى"]'::jsonb) $$;

-- who may set / change a cause: system admin, department / project / ops / QA managers, area manager and area engineer of the region
create or replace function public.fm_breach_can(r text) returns boolean language sql stable security definer set search_path=public as $$
 select coalesce(auth.uid() is not null and public.fm_role() not in ('pending','viewer') and
  (public.fm_role()='admin' or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager','qa_manager')
   or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_region_ok(r))),false) $$;

create or replace function public.fm_breach_reasons_get(p_region text) returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if auth.uid() is null or public.fm_role()='pending' then raise exception 'not allowed'; end if;
 if not (public.fm_role()='admin' or public.fm_region_ok(p_region)) then raise exception 'not allowed'; end if;
 return jsonb_build_object('can',public.fm_breach_can(p_region),'list',public.fm_breach_reason_list(),
  'rows',coalesce((select jsonb_agg(jsonb_build_object('t',ticket_id,'c',cause,'n',note,'by',by_name,'at',at,'rev',revision)) from public.fm_breach_reasons where region=p_region),'[]'::jsonb));
end $$;

create or replace function public.fm_breach_reason_set(p_region text, p_ticket text, p_cause text, p_note text default '', p_rev int default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare o public.fm_breach_reasons; nm text; c text:=nullif(btrim(coalesce(p_cause,'')),''); n text:=btrim(coalesce(p_note,''));
begin
 if not public.fm_breach_can(p_region) then raise exception 'not allowed'; end if;
 if exists(select 1 from pg_proc where proname='fm_mod') and not public.fm_mod('tickets') then raise exception 'module disabled'; end if;
 if p_region is null or btrim(p_region)='' or p_ticket is null or btrim(p_ticket)='' then raise exception 'invalid ticket'; end if;
 if length(n)>500 then raise exception 'note too long'; end if;
 select * into o from public.fm_breach_reasons where region=p_region and ticket_id=p_ticket for update;
 if found and p_rev is not null and o.revision<>p_rev then raise exception 'version conflict'; end if;
 select coalesce(nullif(full_name,''),email,'') into nm from public.profiles where id=auth.uid();
 if c is null then
  if found then delete from public.fm_breach_reasons where region=p_region and ticket_id=p_ticket;
   insert into public.fm_breach_reason_log(region,ticket_id,old_cause,new_cause,old_note,new_note,by_id,by_name) values(p_region,p_ticket,o.cause,null,o.note,null,auth.uid(),nm); end if;
  return jsonb_build_object('ok',true,'cleared',true);
 end if;
 if not (public.fm_breach_reason_list() ? c) then raise exception 'unknown cause'; end if;
 if c='أخرى' and length(n)<3 then raise exception 'note required'; end if;
 if found and o.cause=c and o.note=n then return jsonb_build_object('ok',true,'rev',o.revision); end if;
 insert into public.fm_breach_reasons(region,ticket_id,cause,note,by_id,by_name,at,revision) values(p_region,p_ticket,c,n,auth.uid(),coalesce(nm,''),now(),1)
  on conflict(region,ticket_id) do update set cause=excluded.cause,note=excluded.note,by_id=excluded.by_id,by_name=excluded.by_name,at=now(),revision=public.fm_breach_reasons.revision+1;
 insert into public.fm_breach_reason_log(region,ticket_id,old_cause,new_cause,old_note,new_note,by_id,by_name) values(p_region,p_ticket,o.cause,c,o.note,n,auth.uid(),nm);
 return jsonb_build_object('ok',true,'rev',(select revision from public.fm_breach_reasons where region=p_region and ticket_id=p_ticket));
end $$;

create or replace function public.fm_breach_reason_history(p_region text, p_ticket text) returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
 if auth.uid() is null or public.fm_role()='pending' or not (public.fm_role()='admin' or public.fm_region_ok(p_region)) then raise exception 'not allowed'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('old',old_cause,'new',new_cause,'note',new_note,'by',by_name,'at',at) order by at desc) from public.fm_breach_reason_log where region=p_region and ticket_id=p_ticket),'[]'::jsonb);
end $$;

revoke all on function public.fm_breach_reason_list(),public.fm_breach_can(text),public.fm_breach_reasons_get(text),public.fm_breach_reason_set(text,text,text,text,int),public.fm_breach_reason_history(text,text) from public,anon;
grant execute on function public.fm_breach_reason_list(),public.fm_breach_can(text),public.fm_breach_reasons_get(text),public.fm_breach_reason_set(text,text,text,text,int),public.fm_breach_reason_history(text,text) to authenticated;
notify pgrst,'reload schema';

-- =====================================================================
-- Section 52 (V246): badges «🏅 لوحة الشرف»
-- Monthly automatic badges (work orders, school ratings, warehouse) computed on the server, ticket badges
-- (zero SLA breaches, star of the month) computed by the platform from the uploaded tickets and sent by an
-- uploader, and manual appreciation badges given by managers with a reason. Everyone signed in sees the
-- honour board; a new badge sends a push notification and a news-ticker item.
-- Idempotent.
-- =====================================================================

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

-- one news item for the whole project naming this run's winners (badges inserted in this transaction)
create or replace function public.fm_badge_month_news(p_month text) returns void language plpgsql security definer set search_path = public as $$
declare k jsonb := public.fm_badge_kinds(); mn text; head text; body text;
  ar text[] := array['يناير','فبراير','مارس','أبريل','مايو','يونيو','يوليو','أغسطس','سبتمبر','أكتوبر','نوفمبر','ديسمبر'];
begin
  mn := ar[substr(p_month,6,2)::int] || ' ' || substr(p_month,1,4);
  select string_agg((k->b.kind->>'i') || ' ' || b.user_name, '، ' order by b.kind, b.user_name) into head
    from public.fm_badges b where b.period = p_month and b.auto and not b.revoked and b.at = now();
  if head is null then return; end if;
  select string_agg((k->x.kind->>'i') || ' ' || (k->x.kind->>'t') || ': ' || x.names, E'\n' order by x.kind) into body
    from (select b.kind, string_agg(b.user_name || coalesce(' (' || nullif(b.reason,'') || ')',''), '، ' order by b.user_name) names
            from public.fm_badges b where b.period = p_month and b.auto and not b.revoked and b.at = now() group by b.kind) x;
  head := '🏅 متميزو ' || mn || ': ' || head;
  if length(head) > 300 then head := left(head, 290) || ' …'; end if;
  perform public.fm_badge_news(head, coalesce(body,'') || E'\n\nالتفاصيل في «🏅 لوحة الشرف».');
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
  if n > 0 then perform public.fm_badge_month_news(m); end if;
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
  if n > 0 then perform public.fm_badge_month_news(p_month); end if;
  return n;
end $$;

revoke all on function public.fm_badge_put(uuid,text,text,boolean,numeric,text,uuid,text), public.fm_badge_news(text,text), public.fm_badge_month_news(text) from public, anon, authenticated;
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

-- =====================================================================
-- Section 53 (V247): weekly summary for managers «📬 الملخص الأسبوعي»
-- Every Sunday morning each manager gets one push notification (and optionally one WhatsApp message) with
-- last week's numbers for his regions: tickets (sent by the platform from the uploaded file, so the SLA
-- logic is the platform's own), work orders, stock under the minimum and school requests.
-- Idempotent.
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

-- =====================================================================
-- Section 54 (V249): ideas and problems bank «💡 بنك المقترحات»
-- Anyone in the project raises an idea or a problem with its solution; it goes to his direct manager
-- (reports_to) and to top management (fm_settings.ideas.top). Colleagues support it, managers study /
-- recommend, top management approves, implements or rejects. An implemented idea gives its owner points,
-- the 💡 badge and a news item; management may add impact points later while the idea keeps helping.
-- Idempotent.
-- =====================================================================

-- V246 fix: push hashes are given without '#' (fm_push_url adds it)
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
        'badges', 'badge', false);
    exception when others then null; end;
  end if;
  return rc > 0;
end $$;
revoke all on function public.fm_badge_put(uuid,text,text,boolean,numeric,text,uuid,text) from public, anon, authenticated;

create table if not exists public.fm_ideas (
  id         uuid primary key default gen_random_uuid(),
  code       text unique,
  kind       text not null default 'idea' check (kind in ('idea','problem')),
  title      text not null check (length(btrim(title)) between 5 and 150),
  body       text not null check (length(btrim(body)) between 10 and 3000),
  solution   text not null default '' check (length(solution) <= 3000),
  benefit    text not null default '' check (length(benefit) <= 1000),
  category   text not null default 'other',
  region     text not null default '',
  by_id      uuid references public.profiles(id) on delete set null,
  by_name    text not null default '',
  by_title   text,
  mgr_id     uuid references public.profiles(id) on delete set null,
  mgr_name   text,
  status     text not null default 'new' check (status in ('new','study','approved','implemented','rejected','duplicate','withdrawn')),
  dup_of     text,
  decided_by text,
  decided_at timestamptz,
  impl_at    timestamptz,
  points     int not null default 0,
  votes      int not null default 0,
  photo      text check (photo is null or length(photo) <= 420000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists fm_ideas_by on public.fm_ideas (by_id);
create index if not exists fm_ideas_status on public.fm_ideas (status, created_at);
create table if not exists public.fm_idea_votes (
  idea_id uuid not null references public.fm_ideas(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  at      timestamptz not null default now(),
  primary key (idea_id, user_id)
);
create table if not exists public.fm_idea_events (
  id      uuid primary key default gen_random_uuid(),
  idea_id uuid not null references public.fm_ideas(id) on delete cascade,
  kind    text not null check (kind in ('create','comment','status','points','recommend')),
  status  text,
  pts     int,
  ok      boolean,
  note    text not null default '' check (length(note) <= 2000),
  by_id   uuid references public.profiles(id) on delete set null,
  by_name text,
  at      timestamptz not null default now()
);
create index if not exists fm_idea_events_idea on public.fm_idea_events (idea_id, at);
alter table public.fm_ideas enable row level security;
alter table public.fm_idea_votes enable row level security;
alter table public.fm_idea_events enable row level security;
revoke all on public.fm_ideas, public.fm_idea_votes, public.fm_idea_events from public, anon, authenticated;

-- settings: {public (true), top [titles], pts_approve (5), pts_implement (20), pts_max (50), daily (10)}
create or replace function public.fm_idea_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'public', coalesce((s->>'public')::boolean, true),
    'top', case when jsonb_typeof(s->'top') = 'array' then s->'top' else '["sysadmin","project_manager","ops_manager"]'::jsonb end,
    'pts_approve', coalesce((s->>'pts_approve')::int, 5),
    'pts_implement', coalesce((s->>'pts_implement')::int, 20),
    'pts_max', coalesce((s->>'pts_max')::int, 50),
    'daily', coalesce((s->>'daily')::int, 10))
  from (select coalesce(public.fm_setting('ideas'), '{}') s) x $$;

-- top management decides (approve / implement / reject / points); the area manager for his regions
create or replace function public.fm_idea_decider(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin'
    or public.fm_my_pos() in (select jsonb_array_elements_text(public.fm_idea_cfg()->'top'))
    or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(p_region,''))), false) $$;
-- the author's managers up the line (direct manager first) may study, recommend and comment
create or replace function public.fm_idea_line(i public.fm_ideas) returns boolean language sql stable security definer set search_path = public as $$
  select i.by_id is not null and auth.uid() is not null and (i.mgr_id = auth.uid() or public.fm_is_under(i.by_id, auth.uid())) $$;
create or replace function public.fm_idea_sees(i public.fm_ideas) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() <> 'pending', false) and (coalesce((public.fm_idea_cfg()->>'public')::boolean, true)
    or i.by_id = auth.uid() or public.fm_idea_line(i) or public.fm_idea_decider(i.region)) $$;

-- internal: one event + the push to the author / managers
create or replace function public.fm_idea_log(p_id uuid, p_kind text, p_status text, p_pts int, p_ok boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare nm text;
begin
  select coalesce(nullif(full_name,''), email) into nm from public.profiles where id = auth.uid();
  insert into public.fm_idea_events(idea_id, kind, status, pts, ok, note, by_id, by_name)
  values (p_id, p_kind, p_status, p_pts, p_ok, left(coalesce(p_note,''),2000), auth.uid(), coalesce(nm, 'النظام'));
end $$;

create or replace function public.fm_idea_new(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare me record; cfg jsonb := public.fm_idea_cfg(); r public.fm_ideas; k text := coalesce(p->>'kind','idea'); n int; u uuid; tt text; ph text := nullif(p->>'photo','');
begin
  select id, coalesce(nullif(full_name,''), email) nm, public.fm_posx(role, job_title) pos, coalesce(regions[1],'') rg, reports_to into me
    from public.profiles where id = auth.uid() and active;
  if not found or public.fm_role() = 'pending' then raise exception 'not allowed'; end if;
  if k not in ('idea','problem') then raise exception 'invalid kind'; end if;
  if length(btrim(coalesce(p->>'title',''))) < 5 then raise exception 'title required'; end if;
  if length(btrim(coalesce(p->>'body',''))) < 10 then raise exception 'description required'; end if;
  if k = 'problem' and length(btrim(coalesce(p->>'solution',''))) < 5 then raise exception 'solution required'; end if;
  if ph is not null and (ph !~ '^data:image/(jpeg|png|webp);base64,' or length(ph) > 420000) then raise exception 'invalid photo'; end if;
  select count(*) into n from public.fm_ideas where by_id = auth.uid() and created_at > now() - interval '1 day';
  if n >= (cfg->>'daily')::int then raise exception 'too many today'; end if;
  insert into public.fm_ideas(code, kind, title, body, solution, benefit, category, region, by_id, by_name, by_title, mgr_id, mgr_name, photo)
  values ('IDEA-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad((select count(*) + 1 from public.fm_ideas
           where code like 'IDEA-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-%')::text, 4, '0'),
          k, btrim(p->>'title'), btrim(p->>'body'), btrim(coalesce(p->>'solution','')), btrim(coalesce(p->>'benefit','')),
          case when p->>'category' in ('safety','quality','cost','time','tools','schools','process','other') then p->>'category' else 'other' end,
          coalesce(nullif(p->>'region',''), me.rg), me.id, me.nm, me.pos, me.reports_to,
          (select coalesce(nullif(full_name,''), email) from public.profiles where id = me.reports_to), ph)
  returning * into r;
  perform public.fm_idea_log(r.id, 'create', 'new', null, null, '');
  tt := case when k = 'problem' then '⚠️ مشكلة وحلها' else '💡 مقترح جديد' end || ' من ' || me.nm;
  begin
    for u in select distinct x from (select me.reports_to x union all
               select public.fm_push_people(array(select jsonb_array_elements_text(cfg->'top')), null)
               union all select public.fm_push_people(array['area_manager'], nullif(r.region,''))) y where x is not null and x <> me.id loop
      perform public.fm_push_add(u, 'idea', tt, r.code || ' — ' || r.title, 'ideas=' || r.id, 'idea', false);
    end loop;
  exception when others then null; end;
  return jsonb_build_object('id', r.id, 'code', r.code);
end $$;

-- the bank (year = created in that year, null = all) + the points board
create or replace function public.fm_idea_list(p_year int default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare rows jsonb; lead jsonb;
begin
  if auth.uid() is null or public.fm_role() = 'pending' then raise exception 'not allowed'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'code', i.code, 'kind', i.kind, 'title', i.title, 'body', i.body, 'solution', i.solution,
      'benefit', i.benefit, 'category', i.category, 'region', i.region, 'by', i.by_name, 'by_title', i.by_title, 'mgr', i.mgr_name,
      'mine', i.by_id = auth.uid(), 'status', i.status, 'dup_of', i.dup_of, 'decided_by', i.decided_by, 'decided_at', i.decided_at,
      'impl_at', i.impl_at, 'points', i.points, 'votes', i.votes, 'photo', i.photo is not null, 'at', i.created_at,
      'voted', exists(select 1 from public.fm_idea_votes v where v.idea_id = i.id and v.user_id = auth.uid()),
      'can_decide', i.by_id is distinct from auth.uid() and public.fm_idea_decider(i.region),
      'in_line', public.fm_idea_line(i),
      'last', (select e.at from public.fm_idea_events e where e.idea_id = i.id order by e.at desc limit 1)) order by i.created_at desc), '[]'::jsonb)
    into rows from public.fm_ideas i
   where public.fm_idea_sees(i) and (p_year is null or extract(year from i.created_at at time zone 'Asia/Riyadh') = p_year);
  select coalesce(jsonb_agg(x order by x.points desc, x.impl desc, x.name), '[]'::jsonb) into lead from (
    select i.by_id uid, max(i.by_name) name, max(i.by_title) title, sum(i.points)::int points, count(*)::int ideas,
           count(*) filter (where i.status = 'implemented')::int impl, count(*) filter (where i.status in ('approved','implemented'))::int ok
      from public.fm_ideas i where i.by_id is not null and i.status <> 'withdrawn' and public.fm_idea_sees(i)
       and (p_year is null or extract(year from i.created_at at time zone 'Asia/Riyadh') = p_year)
     group by i.by_id) x;
  return jsonb_build_object('me', auth.uid(), 'cfg', public.fm_idea_cfg(), 'rows', rows, 'leaders', lead,
    'can_decide', public.fm_idea_decider(null) or public.fm_my_pos() = 'area_manager',
    'can_set', coalesce(public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin', false));
end $$;

-- one idea with its photo and history
create or replace function public.fm_idea_get(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare i public.fm_ideas;
begin
  select * into i from public.fm_ideas where id = p_id;
  if not found or not public.fm_idea_sees(i) then raise exception 'not found'; end if;
  return jsonb_build_object('photo', i.photo, 'events', coalesce((select jsonb_agg(jsonb_build_object('kind', e.kind, 'status', e.status, 'pts', e.pts,
    'ok', e.ok, 'note', e.note, 'by', e.by_name, 'at', e.at) order by e.at) from public.fm_idea_events e where e.idea_id = p_id), '[]'::jsonb),
    'voters', coalesce((select jsonb_agg(coalesce(nullif(p.full_name,''), p.email) order by v.at) from public.fm_idea_votes v join public.profiles p on p.id = v.user_id
      where v.idea_id = p_id), '[]'::jsonb));
end $$;

create or replace function public.fm_idea_vote(p_id uuid, p_on boolean) returns int
language plpgsql security definer set search_path = public as $$
declare i public.fm_ideas;
begin
  select * into i from public.fm_ideas where id = p_id for update;
  if not found or not public.fm_idea_sees(i) then raise exception 'not found'; end if;
  if i.by_id = auth.uid() then raise exception 'own idea'; end if;
  if i.status in ('rejected','duplicate','withdrawn') then raise exception 'closed'; end if;
  if p_on then insert into public.fm_idea_votes(idea_id, user_id) values (p_id, auth.uid()) on conflict do nothing;
  else delete from public.fm_idea_votes where idea_id = p_id and user_id = auth.uid(); end if;
  update public.fm_ideas set votes = (select count(*) from public.fm_idea_votes where idea_id = p_id) where id = p_id returning votes into i.votes;
  return i.votes;
end $$;

create or replace function public.fm_idea_comment(p_id uuid, p_note text) returns boolean
language plpgsql security definer set search_path = public as $$
declare i public.fm_ideas;
begin
  select * into i from public.fm_ideas where id = p_id;
  if not found or not public.fm_idea_sees(i) then raise exception 'not found'; end if;
  if length(btrim(coalesce(p_note,''))) < 2 then raise exception 'note required'; end if;
  if (select count(*) from public.fm_idea_events where by_id = auth.uid() and kind = 'comment' and at > now() - interval '1 day') >= 50 then raise exception 'too many today'; end if;
  perform public.fm_idea_log(p_id, 'comment', null, null, null, btrim(p_note));
  update public.fm_ideas set updated_at = now() where id = p_id;
  begin
    if i.by_id is distinct from auth.uid() then perform public.fm_push_add(i.by_id, 'idea', '💬 تعليق على مقترحك ' || i.code, left(btrim(p_note), 200), 'ideas=' || i.id, 'idea-' || i.id, false);
    elsif i.mgr_id is not null then perform public.fm_push_add(i.mgr_id, 'idea', '💬 ' || i.by_name || ' علّق على مقترحه ' || i.code, left(btrim(p_note), 200), 'ideas=' || i.id, 'idea-' || i.id, false); end if;
  exception when others then null; end;
  return true;
end $$;

-- study | recommend (managers of the author's line or deciders), approve | implement | reject | duplicate | reopen (deciders, never on their own),
-- withdraw (the author while new / study)
create or replace function public.fm_idea_act(p_id uuid, p_action text, p_note text default '', p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare i public.fm_ideas; cfg jsonb := public.fm_idea_cfg(); nm text; st text; pts int := 0; note text := btrim(coalesce(p_note,'')); msg text; ok boolean;
begin
  select * into i from public.fm_ideas where id = p_id for update;
  if not found or not public.fm_idea_sees(i) then raise exception 'not found'; end if;
  select coalesce(nullif(full_name,''), email) into nm from public.profiles where id = auth.uid();
  if p_action = 'withdraw' then
    if i.by_id is distinct from auth.uid() or i.status not in ('new','study') then raise exception 'not allowed'; end if;
    update public.fm_ideas set status = 'withdrawn', updated_at = now() where id = p_id;
    perform public.fm_idea_log(p_id, 'status', 'withdrawn', null, null, note);
    return jsonb_build_object('status', 'withdrawn');
  end if;
  if i.by_id = auth.uid() then raise exception 'own idea'; end if;
  if p_action in ('study','recommend') then
    if not (public.fm_idea_line(i) or public.fm_idea_decider(i.region)) then raise exception 'not allowed'; end if;
    if i.status not in ('new','study') then raise exception 'invalid status'; end if;
    if p_action = 'recommend' then
      ok := coalesce((p->>'ok')::boolean, true);
      if length(note) < 3 then raise exception 'note required'; end if;
      perform public.fm_idea_log(p_id, 'recommend', null, null, ok, note);
      begin
        for st in select distinct x::text from public.fm_push_people(array(select jsonb_array_elements_text(cfg->'top')), null) x loop
          perform public.fm_push_add(st::uuid, 'idea', case when ok then '👍 ' else '👎 ' end || nm || (case when ok then ' يوصي بتطبيق ' else ' لا يوصي بتطبيق ' end) || i.code, i.title, 'ideas=' || i.id, 'idea-' || i.id, false);
        end loop;
      exception when others then null; end;
    end if;
    if i.status = 'new' then update public.fm_ideas set status = 'study', updated_at = now() where id = p_id;
      if p_action = 'study' then perform public.fm_idea_log(p_id, 'status', 'study', null, null, note); end if;
      msg := '🔎 مقترحك ' || i.code || ' قيد الدراسة'; end if;
  elsif p_action in ('approve','implement','reject','duplicate','reopen') then
    if not public.fm_idea_decider(i.region) then raise exception 'not allowed'; end if;
    if p_action = 'approve' then
      if i.status not in ('new','study') then raise exception 'invalid status'; end if;
      st := 'approved'; msg := '✅ اعتُمد مقترحك ' || i.code || ' للتطبيق';
      if not exists(select 1 from public.fm_idea_events where idea_id = p_id and kind = 'points' and status = 'approved') then pts := (cfg->>'pts_approve')::int; end if;
    elsif p_action = 'implement' then
      if i.status not in ('new','study','approved') then raise exception 'invalid status'; end if;
      st := 'implemented'; msg := '🎉 طُبِّق مقترحك ' || i.code || ' — شكراً لك';
      if not exists(select 1 from public.fm_idea_events where idea_id = p_id and kind = 'points' and status = 'approved') and i.status <> 'approved' then pts := (cfg->>'pts_approve')::int; end if;
      if not exists(select 1 from public.fm_idea_events where idea_id = p_id and kind = 'points' and status = 'implemented') then pts := pts + (cfg->>'pts_implement')::int; end if;
    elsif p_action = 'reject' then
      if i.status not in ('new','study','approved') then raise exception 'invalid status'; end if;
      if length(note) < 3 then raise exception 'note required'; end if;
      st := 'rejected'; msg := 'لم يُعتمد مقترحك ' || i.code || ': ' || note;
    elsif p_action = 'duplicate' then
      if i.status not in ('new','study') then raise exception 'invalid status'; end if;
      if not exists(select 1 from public.fm_ideas where code = btrim(coalesce(p->>'of','')) and id <> p_id) then raise exception 'unknown idea'; end if;
      st := 'duplicate'; msg := 'مقترحك ' || i.code || ' مكرر مع ' || btrim(p->>'of');
    else
      if i.status not in ('rejected','duplicate','approved') then raise exception 'invalid status'; end if;
      st := 'study'; msg := '🔄 أُعيد فتح مقترحك ' || i.code;
    end if;
    update public.fm_ideas set status = st, dup_of = case when st = 'duplicate' then btrim(p->>'of') else dup_of end,
      decided_by = nm, decided_at = now(), impl_at = case when st = 'implemented' then now() else impl_at end, updated_at = now(),
      points = points + pts where id = p_id;
    perform public.fm_idea_log(p_id, 'status', st, null, null, note);
    if pts > 0 then perform public.fm_idea_log(p_id, 'points', st, pts, null, case st when 'approved' then 'اعتماد المقترح' else 'تطبيق المقترح' end); end if;
    if st = 'implemented' and i.by_id is not null then
      begin perform public.fm_badge_put(i.by_id, 'initiative', null, false, pts, 'تطبيق المقترح ' || i.code || ': ' || left(i.title, 120), auth.uid(), nm);
      exception when others then null; end;
      begin perform public.fm_badge_news('💡 طُبِّق مقترح ' || i.by_name || ': ' || left(i.title, 200),
        i.code || E'\n' || left(i.body, 1000) || case when i.solution <> '' then E'\n\nالحل: ' || left(i.solution, 1000) else '' end || E'\n\nالتفاصيل في «💡 بنك المقترحات».');
      exception when others then null; end;
    end if;
  else raise exception 'invalid action'; end if;
  if msg is not null and i.by_id is not null then
    begin perform public.fm_push_add(i.by_id, 'idea', msg, case when pts > 0 then '+' || pts || ' نقطة — ' else '' end || i.title, 'ideas=' || i.id, 'idea-' || i.id, false);
    exception when others then null; end;
  end if;
  select status into st from public.fm_ideas where id = p_id;
  return jsonb_build_object('status', st, 'pts', pts);
end $$;

-- impact points while the idea keeps helping (approved / implemented)
create or replace function public.fm_idea_points(p_id uuid, p_pts int, p_note text) returns int
language plpgsql security definer set search_path = public as $$
declare i public.fm_ideas; cfg jsonb := public.fm_idea_cfg();
begin
  select * into i from public.fm_ideas where id = p_id for update;
  if not found or not public.fm_idea_sees(i) then raise exception 'not found'; end if;
  if i.by_id = auth.uid() then raise exception 'own idea'; end if;
  if not public.fm_idea_decider(i.region) then raise exception 'not allowed'; end if;
  if i.status not in ('approved','implemented') then raise exception 'invalid status'; end if;
  if p_pts is null or p_pts < 1 or p_pts > (cfg->>'pts_max')::int then raise exception 'invalid points'; end if;
  if length(btrim(coalesce(p_note,''))) < 5 then raise exception 'note required'; end if;
  update public.fm_ideas set points = points + p_pts, updated_at = now() where id = p_id returning points into i.points;
  perform public.fm_idea_log(p_id, 'points', 'impact', p_pts, null, btrim(p_note));
  begin perform public.fm_push_add(i.by_id, 'idea', '⭐ +' || p_pts || ' نقطة لأثر مقترحك ' || i.code, left(btrim(p_note), 200), 'ideas=' || i.id, 'idea-' || i.id, false);
  exception when others then null; end;
  return i.points;
end $$;

revoke all on function public.fm_idea_log(uuid,text,text,int,boolean,text) from public, anon, authenticated;
revoke all on function public.fm_idea_cfg(), public.fm_idea_decider(text), public.fm_idea_line(public.fm_ideas), public.fm_idea_sees(public.fm_ideas),
  public.fm_idea_new(jsonb), public.fm_idea_list(int), public.fm_idea_get(uuid), public.fm_idea_vote(uuid,boolean), public.fm_idea_comment(uuid,text),
  public.fm_idea_act(uuid,text,text,jsonb), public.fm_idea_points(uuid,int,text) from public, anon;
grant execute on function public.fm_idea_cfg(), public.fm_idea_decider(text), public.fm_idea_line(public.fm_ideas), public.fm_idea_sees(public.fm_ideas),
  public.fm_idea_new(jsonb), public.fm_idea_list(int), public.fm_idea_get(uuid), public.fm_idea_vote(uuid,boolean), public.fm_idea_comment(uuid,text),
  public.fm_idea_act(uuid,text,text,jsonb), public.fm_idea_points(uuid,int,text) to authenticated;
notify pgrst, 'reload schema';

-- =====================================================================
-- Section 55 (V250): assign a ticket to a real account when the primary person is unavailable
-- «↪️ إسناد بلاغ لحساب» from «🗂️ سجل البلاغات»: the manager picks an available person (leave, load and the
-- primary's deputy are shown), with a reason and an optional end date; the person gets a push and sees the
-- ticket in the field app («↪️ بلاغات مُسندة إليّ»), confirms receipt and reports it done. The primary person
-- is told. A work order with the same school and description may be created and linked. Idempotent.
-- =====================================================================
create table if not exists public.fm_tk_assign (
  region       text not null,
  ticket_id    text not null,
  assignee     uuid references public.profiles(id) on delete set null,
  assignee_name text not null default '',
  primary_name text not null default '',
  primary_id   uuid references public.profiles(id) on delete set null,
  reason       text not null default 'other' check (reason in ('leave','absent','busy','far','skill','other')),
  note         text not null default '' check (length(note) <= 1000),
  until        date,
  snap         jsonb not null default '{}'::jsonb,
  wo_id        uuid,
  wo_code      text,
  status       text not null default 'active' check (status in ('active','done','ended')),
  ack_at       timestamptz,
  done_at      timestamptz,
  done_note    text,
  by_id        uuid references public.profiles(id) on delete set null,
  by_name      text,
  at           timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  primary key (region, ticket_id)
);
create index if not exists fm_tk_assign_who on public.fm_tk_assign (assignee, status);
create table if not exists public.fm_tk_assign_log (
  id        uuid primary key default gen_random_uuid(),
  region    text not null,
  ticket_id text not null,
  action    text not null check (action in ('assign','unassign','ack','done','wo')),
  assignee_name text,
  reason    text,
  note      text not null default '',
  by_id     uuid references public.profiles(id) on delete set null,
  by_name   text,
  at        timestamptz not null default now()
);
create index if not exists fm_tk_assign_log_t on public.fm_tk_assign_log (region, ticket_id, at);
alter table public.fm_tk_assign enable row level security;
alter table public.fm_tk_assign_log enable row level security;
revoke all on public.fm_tk_assign, public.fm_tk_assign_log from public, anon, authenticated;

-- who may reassign tickets of a region: admin, system admin, project / ops manager, area manager / engineer and supervisor of the region
create or replace function public.fm_tk_can(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager')
    or (public.fm_my_pos() in ('area_manager','area_engineer','supervisor') and public.fm_region_ok(coalesce(p_region,''))), false) $$;
-- may the caller give a ticket to this person? (a supervisor only to the people under him)
create or replace function public.fm_tk_target_ok(p_region text, p_user uuid) returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles t where t.id = p_user and t.active and t.role <> 'pending' and t.id <> auth.uid()
    and public.fm_posx(t.role, t.job_title) in ('supervisor','contractor','area_engineer')
    and (cardinality(coalesce(t.regions,'{}')) = 0 or coalesce(p_region,'') = any(t.regions))
    and (public.fm_my_pos() <> 'supervisor' or public.fm_is_under(t.id, auth.uid()))) $$;
-- the account behind a name written in the tickets (full name or person_names)
create or replace function public.fm_tk_person(p_name text) returns uuid language sql stable security definer set search_path = public as $$
  select p.id from public.profiles p where p.active and coalesce(btrim(p_name),'') <> ''
     and (btrim(coalesce(p.full_name,'')) = btrim(p_name) or btrim(p_name) = any(coalesce(p.person_names,'{}')))
   order by p.created_at limit 1 $$;
-- the active leave of a person: {until, deputy, deputy_name}
create or replace function public.fm_tk_leave(p_user uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('until', d.to_at, 'deputy', d.deputy, 'deputy_name', coalesce(nullif(p.full_name,''), p.email))
    from public.fm_deputies d join public.profiles p on p.id = d.deputy
   where d.principal = p_user and d.active and now() >= d.from_at and now() < d.to_at order by d.to_at desc limit 1 $$;

-- people the caller may choose, with availability and load, and the primary person of each given name
create or replace function public.fm_tk_people(p_region text, p_names text[] default '{}') returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare ppl jsonb; pri jsonb;
begin
  if auth.uid() is null or not public.fm_tk_can(p_region) then raise exception 'not allowed'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'name', coalesce(nullif(t.full_name,''), t.email), 'title', public.fm_posx(t.role, t.job_title),
      'phone', t.phone, 'leave', public.fm_tk_leave(t.id),
      'wo', (select count(*) from public.work_orders w where w.assignee = t.id and w.status in ('assigned','accepted','in_progress','returned')),
      'tk', (select count(*) from public.fm_tk_assign a where a.assignee = t.id and a.status = 'active' and (a.until is null or a.until >= (now() at time zone 'Asia/Riyadh')::date)))
      order by coalesce(nullif(t.full_name,''), t.email)), '[]'::jsonb) into ppl
    from public.profiles t where public.fm_tk_target_ok(p_region, t.id);
  select coalesce(jsonb_agg(jsonb_build_object('name', n, 'id', u, 'leave', case when u is not null then public.fm_tk_leave(u) end,
      'active', (select active from public.profiles where id = u))), '[]'::jsonb) into pri
    from (select n, public.fm_tk_person(n) u from unnest(coalesce(p_names,'{}')) n where coalesce(btrim(n),'') <> '' group by n) x;
  return jsonb_build_object('people', ppl, 'primaries', pri);
end $$;

-- assign: p_rows [{id, school, cat, pri, desc, date, primary}] (≤ 200)
create or replace function public.fm_tk_assign(p_region text, p_rows jsonb, p_user uuid, p_reason text, p_note text, p_until date default null) returns int
language plpgsql security definer set search_path = public as $$
declare me text; tn text; x jsonb; n int := 0; pid uuid; tid text; sch text; prv uuid;
begin
  if auth.uid() is null or not public.fm_tk_can(p_region) then raise exception 'not allowed'; end if;
  if not public.fm_mod('tickets') then raise exception 'module disabled'; end if;
  if not public.fm_tk_target_ok(p_region, p_user) then raise exception 'invalid assignee'; end if;
  if coalesce(p_reason,'') not in ('leave','absent','busy','far','skill','other') then raise exception 'invalid reason'; end if;
  if p_reason = 'other' and length(btrim(coalesce(p_note,''))) < 3 then raise exception 'note required'; end if;
  if p_until is not null and p_until < (now() at time zone 'Asia/Riyadh')::date then raise exception 'invalid date'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 200 then raise exception 'invalid rows'; end if;
  select coalesce(nullif(full_name,''), email) into me from public.profiles where id = auth.uid();
  select coalesce(nullif(full_name,''), email) into tn from public.profiles where id = p_user;
  for x in select * from jsonb_array_elements(p_rows) loop
    tid := btrim(coalesce(x->>'id','')); if tid = '' or length(tid) > 80 then continue; end if;
    pid := public.fm_tk_person(x->>'primary');
    select assignee into prv from public.fm_tk_assign where region = p_region and ticket_id = tid and status = 'active';
    insert into public.fm_tk_assign(region, ticket_id, assignee, assignee_name, primary_name, primary_id, reason, note, until, snap, status, ack_at, done_at, done_note, by_id, by_name, at, updated_at)
    values (p_region, tid, p_user, tn, left(btrim(coalesce(x->>'primary','')),200), pid, p_reason, left(btrim(coalesce(p_note,'')),1000), p_until,
            jsonb_build_object('school', left(x->>'school',200), 'cat', left(x->>'cat',200), 'pri', left(x->>'pri',40), 'desc', left(x->>'desc',1500), 'date', left(x->>'date',40)),
            'active', null, null, null, auth.uid(), me, now(), now())
    on conflict (region, ticket_id) do update set assignee = excluded.assignee, assignee_name = excluded.assignee_name, primary_name = excluded.primary_name,
      primary_id = excluded.primary_id, reason = excluded.reason, note = excluded.note, until = excluded.until, snap = excluded.snap, status = 'active',
      ack_at = null, done_at = null, done_note = null, by_id = auth.uid(), by_name = me, at = now(), updated_at = now(),
      wo_id = case when public.fm_tk_assign.assignee = excluded.assignee then public.fm_tk_assign.wo_id end,
      wo_code = case when public.fm_tk_assign.assignee = excluded.assignee then public.fm_tk_assign.wo_code end;
    insert into public.fm_tk_assign_log(region, ticket_id, action, assignee_name, reason, note, by_id, by_name) values (p_region, tid, 'assign', tn, p_reason, left(btrim(coalesce(p_note,'')),1000), auth.uid(), me);
    n := n + 1; sch := coalesce(x->>'school','');
    begin
      if prv is not null and prv <> p_user then
        perform public.fm_push_add(prv, 'tk_assign', '↩️ سُحب منك البلاغ ' || tid, concat_ws(' — ', 'أُسند إلى ' || tn, nullif(sch,'')), 'tka', 'tka-' || tid, false); end if;
      if pid is not null and pid <> p_user and pid is distinct from prv then
        perform public.fm_push_add(pid, 'tk_assign', '↪️ أُسند بلاغك ' || tid || ' إلى ' || tn, sch || coalesce(' — حتى ' || p_until, ''), 'tka', 'tka-' || tid, false); end if;
    exception when others then null; end;
  end loop;
  begin
    perform public.fm_push_add(p_user, 'tk_assign', '↪️ ' || case when n = 1 then 'بلاغ مُسند إليك ' || tid else n || ' بلاغات مُسندة إليك' end,
      case when n = 1 and sch <> '' then sch || ' — ' else '' end || 'من ' || me || coalesce(' حتى ' || p_until, '') || coalesce(' — ' || nullif(btrim(p_note),''), ''), 'tka', 'tka-' || p_user, false);
  exception when others then null; end;
  return n;
end $$;

-- back to the primary person
create or replace function public.fm_tk_unassign(p_region text, p_ids text[], p_note text default '') returns int
language plpgsql security definer set search_path = public as $$
declare me text; r record; n int := 0;
begin
  if auth.uid() is null or not public.fm_tk_can(p_region) then raise exception 'not allowed'; end if;
  select coalesce(nullif(full_name,''), email) into me from public.profiles where id = auth.uid();
  for r in select * from public.fm_tk_assign where region = p_region and ticket_id = any(coalesce(p_ids,'{}')) and status = 'active' for update loop
    update public.fm_tk_assign set status = 'ended', updated_at = now() where region = r.region and ticket_id = r.ticket_id;
    insert into public.fm_tk_assign_log(region, ticket_id, action, assignee_name, note, by_id, by_name) values (r.region, r.ticket_id, 'unassign', r.assignee_name, left(coalesce(p_note,''),1000), auth.uid(), me);
    begin perform public.fm_push_add(r.assignee, 'tk_assign', '↩️ أُعيد البلاغ ' || r.ticket_id || ' للمسؤول الأساسي', coalesce(r.snap->>'school','') || ' — ' || me, 'tka', 'tka-' || r.ticket_id, false);
    exception when others then null; end;
    n := n + 1;
  end loop;
  return n;
end $$;

-- the current assignments of a region (for the register) — managers of the region, or rows the caller is part of
create or replace function public.fm_tk_list(p_region text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', a.ticket_id, 'assignee', a.assignee, 'name', a.assignee_name, 'primary', a.primary_name, 'reason', a.reason,
      'note', a.note, 'until', a.until, 'status', case when a.status = 'active' and a.until < (now() at time zone 'Asia/Riyadh')::date then 'expired' else a.status end,
      'ack_at', a.ack_at, 'done_at', a.done_at, 'done_note', a.done_note, 'wo_code', a.wo_code, 'by', a.by_name, 'at', a.at)), '[]'::jsonb)
    from public.fm_tk_assign a
   where a.region = p_region and a.status <> 'ended' and auth.uid() is not null
     and (public.fm_tk_can(p_region) or a.assignee = auth.uid() or a.primary_id = auth.uid() or public.fm_scope_all()) $$;

-- my assigned tickets (field app): active and not past the end date, plus those I finished in the last 7 days
create or replace function public.fm_tk_my() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('region', a.region, 'id', a.ticket_id, 'snap', a.snap, 'primary', a.primary_name, 'reason', a.reason, 'note', a.note,
      'until', a.until, 'status', a.status, 'ack_at', a.ack_at, 'done_at', a.done_at, 'wo_code', a.wo_code, 'wo_id', a.wo_id, 'by', a.by_name, 'at', a.at,
      'tstatus', t.status) order by a.status, a.at desc), '[]'::jsonb)
    from public.fm_tk_assign a left join public.tickets t on t.region = a.region and t.ticket_id = a.ticket_id
   where a.assignee = auth.uid() and ((a.status = 'active' and (a.until is null or a.until >= (now() at time zone 'Asia/Riyadh')::date))
      or (a.status = 'done' and a.done_at > now() - interval '7 days')) $$;

-- the assignee: ack (received) | done (with a note)
create or replace function public.fm_tk_act(p_region text, p_id text, p_action text, p_note text default '') returns jsonb
language plpgsql security definer set search_path = public as $$
declare a public.fm_tk_assign; me text;
begin
  select * into a from public.fm_tk_assign where region = p_region and ticket_id = p_id for update;
  if not found or a.assignee is distinct from auth.uid() or a.status <> 'active' then raise exception 'not allowed'; end if;
  select coalesce(nullif(full_name,''), email) into me from public.profiles where id = auth.uid();
  if p_action = 'ack' then
    update public.fm_tk_assign set ack_at = coalesce(ack_at, now()), updated_at = now() where region = p_region and ticket_id = p_id;
    begin perform public.fm_push_add(a.by_id, 'tk_assign', '✔️ ' || me || ' استلم البلاغ ' || p_id, coalesce(a.snap->>'school',''), 'tka', 'tka-' || p_id, false); exception when others then null; end;
  elsif p_action = 'done' then
    if length(btrim(coalesce(p_note,''))) < 3 then raise exception 'note required'; end if;
    update public.fm_tk_assign set status = 'done', done_at = now(), done_note = left(btrim(p_note),1000), ack_at = coalesce(ack_at, now()), updated_at = now()
     where region = p_region and ticket_id = p_id;
    begin perform public.fm_push_add(a.by_id, 'tk_assign', '✅ ' || me || ' نفّذ البلاغ ' || p_id, left(btrim(p_note),200), 'tka', 'tka-' || p_id, false);
      if a.primary_id is not null and a.primary_id <> a.by_id then perform public.fm_push_add(a.primary_id, 'tk_assign', '✅ نُفّذ بلاغك ' || p_id || ' بواسطة ' || me, left(btrim(p_note),200), 'tka', 'tka-' || p_id, false); end if;
    exception when others then null; end;
  else raise exception 'invalid action'; end if;
  insert into public.fm_tk_assign_log(region, ticket_id, action, assignee_name, note, by_id, by_name) values (p_region, p_id, p_action, me, left(coalesce(p_note,''),1000), auth.uid(), me);
  return jsonb_build_object('ok', true);
end $$;

-- link the work order created for the assigned ticket
create or replace function public.fm_tk_link_wo(p_region text, p_id text, p_wo uuid) returns boolean
language plpgsql security definer set search_path = public as $$
declare c text;
begin
  if auth.uid() is null or not public.fm_tk_can(p_region) then raise exception 'not allowed'; end if;
  select code into c from public.work_orders where id = p_wo;
  if not found then raise exception 'unknown order'; end if;
  update public.fm_tk_assign set wo_id = p_wo, wo_code = c, updated_at = now() where region = p_region and ticket_id = p_id and status = 'active';
  if not found then return false; end if;
  insert into public.fm_tk_assign_log(region, ticket_id, action, note, by_id, by_name)
  values (p_region, p_id, 'wo', c, auth.uid(), (select coalesce(nullif(full_name,''), email) from public.profiles where id = auth.uid()));
  return true;
end $$;

create or replace function public.fm_tk_history(p_region text, p_id text) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('action', l.action, 'name', l.assignee_name, 'reason', l.reason, 'note', l.note, 'by', l.by_name, 'at', l.at) order by l.at), '[]'::jsonb)
    from public.fm_tk_assign_log l
   where l.region = p_region and l.ticket_id = p_id and auth.uid() is not null
     and (public.fm_tk_can(p_region) or public.fm_scope_all()
          or exists (select 1 from public.fm_tk_assign a where a.region = p_region and a.ticket_id = p_id and (a.assignee = auth.uid() or a.primary_id = auth.uid()))) $$;

revoke all on function public.fm_tk_person(text), public.fm_tk_leave(uuid) from public, anon, authenticated;
revoke all on function public.fm_tk_can(text), public.fm_tk_target_ok(text,uuid), public.fm_tk_people(text,text[]), public.fm_tk_assign(text,jsonb,uuid,text,text,date),
  public.fm_tk_unassign(text,text[],text), public.fm_tk_list(text), public.fm_tk_my(), public.fm_tk_act(text,text,text,text), public.fm_tk_link_wo(text,text,uuid),
  public.fm_tk_history(text,text) from public, anon;
grant execute on function public.fm_tk_can(text), public.fm_tk_target_ok(text,uuid), public.fm_tk_people(text,text[]), public.fm_tk_assign(text,jsonb,uuid,text,text,date),
  public.fm_tk_unassign(text,text[],text), public.fm_tk_list(text), public.fm_tk_my(), public.fm_tk_act(text,text,text,text), public.fm_tk_link_wo(text,text,uuid),
  public.fm_tk_history(text,text) to authenticated;
notify pgrst, 'reload schema';

-- =====================================================================
-- Section 56 (V251): procurement governance — approval matrix, segregation of duties, split requests
-- fm_settings.po_gov {enabled (false), levels [{t: title, max: SAR, 0 = no limit}], owner_above (SAR, 0 = off),
-- split_days (7, 0 = off), sod (true)}. Disabled = the V158 spend_limits as levels (same behaviour as before),
-- while the split check and segregation of duties still apply. Exceptions (system admin acting on his own
-- request, a split approved at the higher level, owner co-approval) go to fm_gov_log. Idempotent.
-- =====================================================================
alter table public.wo_purchase_requests add column if not exists approved_by uuid references public.profiles(id) on delete set null;
alter table public.wo_purchase_requests add column if not exists eff_total numeric(14,2);
alter table public.wo_purchase_requests add column if not exists related text[];
alter table public.wo_purchase_requests add column if not exists need_owner boolean not null default false;
alter table public.wo_purchase_requests add column if not exists appr1_by uuid references public.profiles(id) on delete set null;
alter table public.wo_purchase_requests add column if not exists appr1_name text;
alter table public.wo_purchase_requests add column if not exists appr1_at timestamptz;

create table if not exists public.fm_gov_log (
  id      uuid primary key default gen_random_uuid(),
  kind    text not null check (kind in ('sod_approve','sod_receive','split','owner','owner_skip')),
  ref     text,
  region  text,
  amount  numeric(14,2),
  note    text not null default '',
  by_id   uuid references public.profiles(id) on delete set null,
  by_name text,
  at      timestamptz not null default now()
);
create index if not exists fm_gov_log_at on public.fm_gov_log (at desc);
alter table public.fm_gov_log enable row level security;
revoke all on public.fm_gov_log from public, anon, authenticated;

-- the rules in force
create or replace function public.fm_po_gov() returns jsonb language sql stable security definer set search_path = public as $$
  select case when coalesce((g->>'enabled')::boolean, false) and jsonb_typeof(g->'levels') = 'array' and jsonb_array_length(g->'levels') > 0 then
      jsonb_build_object('enabled', true, 'levels', g->'levels', 'owner_above', coalesce((g->>'owner_above')::numeric, 0),
        'split_days', coalesce((g->>'split_days')::int, 7), 'sod', coalesce((g->>'sod')::boolean, true))
    else jsonb_build_object('enabled', false,
      'levels', jsonb_build_array(jsonb_build_object('t','area_manager','max', coalesce(nullif(l->>'area_manager','')::numeric, 0)),
                                  jsonb_build_object('t','ops_manager','max', coalesce(nullif(l->>'ops_manager','')::numeric, 0)),
                                  jsonb_build_object('t','project_manager','max', 0), jsonb_build_object('t','dept_manager','max', 0)),
      'owner_above', 0, 'split_days', coalesce((g->>'split_days')::int, 7), 'sod', coalesce((g->>'sod')::boolean, true)) end
  from (select coalesce(public.fm_setting('po_gov'), '{}') g, coalesce(public.fm_setting('spend_limits'), '{}') l) x $$;

-- the caller's limit for a store region: -1 = no limit, 0 = may not approve, > 0 = up to this amount
create or replace function public.fm_po_limit(p_region text) returns numeric language plpgsql stable security definer set search_path = public as $$
declare pos text := public.fm_my_pos(); lv jsonb; m numeric;
begin
  if public.fm_role() = 'admin' or pos = 'sysadmin' then return -1; end if;
  for lv in select * from jsonb_array_elements(public.fm_po_gov()->'levels') loop
    if lv->>'t' = pos then
      if pos in ('area_manager','area_engineer') and not public.fm_region_ok(coalesce(p_region,'')) then return 0; end if;
      m := coalesce((lv->>'max')::numeric, 0);
      return case when m <= 0 then -1 else m end;
    end if;
  end loop;
  return 0;
end $$;

-- other live requests of the same store within split_days that share the supplier or an item
create or replace function public.fm_po_related(p_id uuid) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r public.wo_purchase_requests; d int := coalesce((public.fm_po_gov()->>'split_days')::int, 7); s numeric; c text[];
begin
  select * into r from public.wo_purchase_requests where id = p_id;
  if not found or d <= 0 then return jsonb_build_object('sum', 0, 'codes', '[]'::jsonb); end if;
  select coalesce(sum(o.total), 0), coalesce(array_agg(o.code order by o.at), '{}') into s, c
    from public.wo_purchase_requests o
   where o.id <> r.id and o.store_id = r.store_id and o.status in ('requested','approved','partial','received')
     and o.at between r.at - make_interval(days => d) and r.at + make_interval(days => d)
     and ((r.supplier_id is not null and o.supplier_id = r.supplier_id)
          or exists (select 1 from jsonb_array_elements(o.lines) a, jsonb_array_elements(r.lines) b where a->>'material_id' = b->>'material_id'));
  return jsonb_build_object('sum', s, 'codes', to_jsonb(c));
end $$;

create or replace function public.fm_gov_add(p_kind text, p_ref text, p_region text, p_amount numeric, p_note text) returns void
language sql security definer set search_path = public as $$
  insert into public.fm_gov_log(kind, ref, region, amount, note, by_id, by_name) values (p_kind, p_ref, p_region, p_amount, left(coalesce(p_note,''),500), auth.uid(), public.fm_me_name()) $$;

create or replace function public.fm_po_owner_ok() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_my_pos() = 'owner_rep', false) $$;

create or replace function public.fm_po_act(p_id uuid, p_action text, p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare r public.wo_purchase_requests; st public.wo_stores; g jsonb := public.fm_po_gov(); lim numeric; rel jsonb; eff numeric; sup boolean;
  x jsonb; gl jsonb; L jsonb := '[]'; q numeric; pr numeric; v numeric; all_done boolean := true; n int := 0; sr text; wm int; at_ timestamptz; u uuid; ownr boolean;
begin
  select * into r from public.wo_purchase_requests where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  select * into st from public.wo_stores where id = r.store_id;
  sup := public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin';
  if p_action in ('approve','reject') then
    if r.status <> 'requested' then raise exception 'invalid status'; end if;
    -- owner stage: a manager already approved, the owner's representative decides
    if r.need_owner and r.appr1_at is not null then
      if not (public.fm_po_owner_ok() or sup) then raise exception 'owner approval pending'; end if;
      if p_action = 'reject' and btrim(coalesce(p->>'note','')) = '' then raise exception 'note required'; end if;
      update public.wo_purchase_requests set status = case when p_action = 'approve' then 'approved' else 'rejected' end, approved_by = auth.uid(),
        approved_by_name = coalesce(appr1_name || ' + ', '') || public.fm_me_name(), approved_at = now(),
        response = left(nullif(btrim(coalesce(p->>'note','')),''),500) where id = p_id;
      if p_action = 'approve' then perform public.fm_gov_add('owner', r.code, st.region, r.eff_total, 'اعتماد الجهة المالكة'); end if;
      return p_action;
    end if;
    lim := public.fm_po_limit(st.region);
    if lim = 0 then raise exception 'not allowed'; end if;
    -- segregation of duties: the requester does not decide his own request (system admin: allowed and logged)
    if coalesce((g->>'sod')::boolean, true) and r.requested_by = auth.uid() then
      if not sup then raise exception 'self approval'; end if;
      perform public.fm_gov_add('sod_approve', r.code, st.region, r.total, p_action);
    end if;
    if p_action = 'reject' then
      if btrim(coalesce(p->>'note','')) = '' then raise exception 'note required'; end if;
      update public.wo_purchase_requests set status = 'rejected', approved_by = auth.uid(), approved_by_name = public.fm_me_name(), approved_at = now(),
        response = left(btrim(p->>'note'),500) where id = p_id;
      return 'reject';
    end if;
    rel := public.fm_po_related(p_id); eff := r.total + coalesce((rel->>'sum')::numeric, 0);
    if lim > 0 and eff > lim then
      raise exception 'spend approval required: %', case when eff > r.total then 'split ' || round(eff) || ' ' || array_to_string(array(select jsonb_array_elements_text(rel->'codes')), ',') else round(eff)::text end;
    end if;
    if eff > r.total then perform public.fm_gov_add('split', r.code, st.region, eff, 'مع ' || array_to_string(array(select jsonb_array_elements_text(rel->'codes')), '، ')); end if;
    ownr := coalesce((g->>'owner_above')::numeric, 0) > 0 and eff > (g->>'owner_above')::numeric;
    if ownr and not exists (select 1 from public.profiles where active and public.fm_posx(role, job_title) = 'owner_rep' and id <> coalesce(r.requested_by, '00000000-0000-0000-0000-000000000000'::uuid)) then
      ownr := false; perform public.fm_gov_add('owner_skip', r.code, st.region, eff, 'لا يوجد ممثل جهة مالكة نشط');
    end if;
    if ownr then
      update public.wo_purchase_requests set need_owner = true, appr1_by = auth.uid(), appr1_name = public.fm_me_name(), appr1_at = now(), eff_total = eff,
        related = array(select jsonb_array_elements_text(rel->'codes')), response = left(nullif(btrim(coalesce(p->>'note','')),''),500) where id = p_id;
      begin
        for u in select * from public.fm_push_people(array['owner_rep'], null) loop
          perform public.fm_push_add(u, 'appr', '🛒 طلب شراء بانتظار اعتماد الجهة المالكة ' || r.code, coalesce(st.name,'') || ' — ' || round(eff) || ' ر.س — اعتمده ' || public.fm_me_name(), 'wh=po', 'po-' || r.id);
        end loop;
      exception when others then null; end;
      return 'owner';
    end if;
    update public.wo_purchase_requests set status = 'approved', approved_by = auth.uid(), approved_by_name = public.fm_me_name(), approved_at = now(), eff_total = eff,
      related = array(select jsonb_array_elements_text(rel->'codes')), response = left(nullif(btrim(coalesce(p->>'note','')),''),500) where id = p_id;
    return 'approve';
  elsif p_action = 'cancel' then
    if r.requested_by <> auth.uid() or r.status not in ('requested','approved') then raise exception 'not allowed'; end if;
    update public.wo_purchase_requests set status = 'cancelled' where id = p_id; return 'cancelled';
  elsif p_action = 'receive' then
    perform public.fm_lines230(p);
    if not (public.fm_wh_keeper(st.id) or public.fm_stock_can(st.region)) then raise exception 'not allowed'; end if;
    if r.status not in ('approved','partial') then raise exception 'invalid status'; end if;
    -- segregation of duties: whoever approved does not receive (system admin: allowed and logged)
    if coalesce((g->>'sod')::boolean, true) and (r.approved_by = auth.uid() or r.appr1_by = auth.uid()) then
      if not sup then raise exception 'self receive'; end if;
      perform public.fm_gov_add('sod_receive', r.code, st.region, r.total, 'استلم ما اعتمده');
    end if;
    at_ := least(now(), coalesce(nullif(p->>'at','')::date + time '12:00', now()));
    for x in select * from jsonb_array_elements(r.lines) loop
      gl := (select e from jsonb_array_elements(coalesce(p->'lines','[]')) t(e) where e->>'material_id' = x->>'material_id' limit 1);
      q := coalesce(nullif(gl->>'qty','')::numeric, 0);
      if q < 0 then raise exception 'invalid qty'; end if;
      if q > 0 then
        pr := coalesce(nullif(gl->>'price','')::numeric, (x->>'price')::numeric);
        if pr<0 or pr::text in ('NaN','Infinity','-Infinity') then raise exception 'invalid price';end if;
        v := public.fm_wh_receive_line(st.id, (x->>'material_id')::uuid, q, pr, r.supplier_id, r.supplier_name, p->>'invoice_no', at_, r.code, null);
        x := x || jsonb_build_object('recv', coalesce((x->>'recv')::numeric,0) + q, 'paid', pr, 'variance', v);
        select warranty_months into wm from public.wo_materials where id = (x->>'material_id')::uuid;
        for sr in select btrim(e #>> '{}') from jsonb_array_elements(case when jsonb_typeof(gl->'serials') = 'array' then gl->'serials' else '[]' end) t(e) loop
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

-- what the platform shows on each open request: amount with related requests, who may decide, the level needed
create or replace function public.fm_po_checks() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare g jsonb := public.fm_po_gov(); r record; rel jsonb; eff numeric; lim numeric; out jsonb := '[]'::jsonb; lvl text; lv jsonb; sup boolean;
begin
  if auth.uid() is null or public.fm_role() not in ('admin','manager','staff','engineer','viewer') then raise exception 'not allowed'; end if;
  sup := public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin';
  for r in select p.*, s.region from public.wo_purchase_requests p join public.wo_stores s on s.id = p.store_id where p.status = 'requested' loop
    rel := public.fm_po_related(r.id); eff := r.total + coalesce((rel->>'sum')::numeric, 0); lim := public.fm_po_limit(r.region); lvl := null;
    for lv in select * from jsonb_array_elements(g->'levels') e order by case when coalesce((e->>'max')::numeric,0) <= 0 then 1e15 else (e->>'max')::numeric end loop
      if coalesce((lv->>'max')::numeric,0) <= 0 or (lv->>'max')::numeric >= eff then lvl := lv->>'t'; exit; end if;
    end loop;
    out := out || jsonb_build_array(jsonb_build_object('id', r.id, 'eff', eff, 'related', rel->'codes', 'level', lvl,
      'stage', case when r.need_owner and r.appr1_at is not null then 'owner' else 'manager' end, 'appr1', r.appr1_name,
      'owner', coalesce((g->>'owner_above')::numeric,0) > 0 and eff > (g->>'owner_above')::numeric,
      'self', r.requested_by = auth.uid(),
      'can', case when r.need_owner and r.appr1_at is not null then public.fm_po_owner_ok() or sup
                  else lim <> 0 and (lim < 0 or eff <= lim) and (r.requested_by is distinct from auth.uid() or sup or not coalesce((g->>'sod')::boolean, true)) end,
      'can_reject', case when r.need_owner and r.appr1_at is not null then public.fm_po_owner_ok() or sup
                  else lim <> 0 and (r.requested_by is distinct from auth.uid() or sup or not coalesce((g->>'sod')::boolean, true)) end));
  end loop;
  return jsonb_build_object('gov', g, 'rows', out, 'my_limit', public.fm_po_limit(null));
end $$;

-- the exceptions report and a segregation-of-duties scan of the last days
create or replace function public.fm_gov_report(p_days int default 90) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d int := least(greatest(coalesce(p_days, 90), 7), 400);
begin
  if auth.uid() is null or not (public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager','qa_manager','owner_rep','accountant')) then
    raise exception 'not allowed'; end if;
  return jsonb_build_object(
    'log', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'ref', ref, 'region', region, 'amount', amount, 'note', note, 'by', by_name, 'at', at) order by at desc)
                       from public.fm_gov_log where at > now() - make_interval(days => d)), '[]'::jsonb),
    -- requests approved by their requester, received by their approver (also from before V251)
    'self_approved', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'total', total, 'by', approved_by_name, 'at', approved_at))
                       from public.wo_purchase_requests where approved_at > now() - make_interval(days => d) and status in ('approved','partial','received')
                        and approved_by is not null and approved_by = requested_by), '[]'::jsonb),
    'adj_self', coalesce((select jsonb_agg(jsonb_build_object('code', code, 'value', value, 'by', decided_name, 'at', decided_at))
                       from public.wo_stock_adj a where a.at > now() - make_interval(days => d) and a.status = 'approved' and a.decided_by is not null and a.decided_by = a.by_id), '[]'::jsonb),
    'supplier_share', coalesce((select jsonb_agg(x order by x.share desc) from (
        select coalesce(supplier_name,'—') supplier, round(sum(total),2) total, round(100 * sum(total) / nullif(sum(sum(total)) over (), 0), 1) share, count(*) n
          from public.wo_purchase_requests where at > now() - make_interval(days => d) and status in ('approved','partial','received') group by 1) x), '[]'::jsonb),
    'days', d);
end $$;

revoke all on function public.fm_gov_add(text,text,text,numeric,text), public.fm_po_related(uuid) from public, anon, authenticated;
revoke all on function public.fm_po_gov(), public.fm_po_limit(text), public.fm_po_owner_ok(), public.fm_po_act(uuid,text,jsonb), public.fm_po_checks(), public.fm_gov_report(int) from public, anon;
grant execute on function public.fm_po_gov(), public.fm_po_limit(text), public.fm_po_owner_ok(), public.fm_po_act(uuid,text,jsonb), public.fm_po_checks(), public.fm_gov_report(int) to authenticated;
notify pgrst, 'reload schema';

-- =====================================================================
-- Section 57 (V252): governance red flags «🚩 إنذارات الحوكمة»
-- One server function gathers the warning signs of a period: purchases (self-approved, split, price above the
-- agreed price, one supplier taking most of the money, system-admin exceptions), warehouse (negative balances,
-- count adjustments decided by their author, the same item to the same school again, one person consuming far
-- more than the others), tickets closed without a photo or a solution, work orders returned again and again,
-- field visits far from the school. Each flag has a stable key; a reviewer marks it «ok» or «action» with a note.
-- Thresholds in fm_settings.red_flags. Idempotent.
-- =====================================================================
create table if not exists public.fm_flag_reviews (
  k       text primary key,
  status  text not null check (status in ('ok','action')),
  note    text not null default '' check (length(note) <= 1000),
  by_id   uuid references public.profiles(id) on delete set null,
  by_name text,
  at      timestamptz not null default now()
);
alter table public.fm_flag_reviews enable row level security;
revoke all on public.fm_flag_reviews from public, anon, authenticated;

create or replace function public.fm_flag_can() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','dept_manager','project_manager','ops_manager','qa_manager','owner_rep','accountant'), false) $$;

-- thresholds: {price_pct 10, share_pct 60, far_m 500, far_n 3, repeat_days 30, returns 2, outlier 3}
create or replace function public.fm_flag_cfg() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('price_pct', coalesce((s->>'price_pct')::numeric, 10), 'share_pct', coalesce((s->>'share_pct')::numeric, 60),
    'far_m', coalesce((s->>'far_m')::numeric, 500), 'far_n', coalesce((s->>'far_n')::int, 3), 'repeat_days', coalesce((s->>'repeat_days')::int, 30),
    'returns', coalesce((s->>'returns')::int, 2), 'outlier', coalesce((s->>'outlier')::numeric, 3))
  from (select coalesce(public.fm_setting('red_flags'), '{}') s) x $$;

create or replace function public.fm_red_flags(p_days int default 90) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare d int := least(greatest(coalesce(p_days, 90), 7), 400); c jsonb := public.fm_flag_cfg(); f jsonb := '[]'::jsonb; part jsonb; skipped text[] := '{}';
  since timestamptz; med numeric;
begin
  if auth.uid() is null or not public.fm_flag_can() then raise exception 'not allowed'; end if;
  since := now() - make_interval(days => d);
  -- 1) purchase requests approved by their requester
  begin
    select coalesce(jsonb_agg(jsonb_build_object('k', 'po_self:' || code, 'sev', 'high', 'area', 'po', 't', 'طلب شراء اعتمده مقدّمه',
      'd', concat_ws(' — ', code, nullif(approved_by_name,''), round(total) || ' ر.س'), 'ref', code, 'n', total, 'at', approved_at, 'go', 'wh=po')), '[]') into part
      from public.wo_purchase_requests where approved_at > since and approved_by is not null and approved_by = requested_by and status in ('approved','partial','received');
    f := f || part;
  exception when others then skipped := skipped || 'po_self'; end;
  -- 2) split requests: approved together (log) and still open with related requests
  begin
    select coalesce(jsonb_agg(jsonb_build_object('k', 'po_split:' || ref, 'sev', 'med', 'area', 'po', 't', 'طلبات شراء مرتبطة (تجزئة محتملة)',
      'd', ref || ' ' || note || ' — المجموع ' || round(amount) || ' ر.س — اعتمده ' || coalesce(by_name,''), 'ref', ref, 'n', amount, 'at', at, 'go', 'wh=po')), '[]') into part
      from public.fm_gov_log where kind = 'split' and at > since;
    f := f || part;
    select coalesce(jsonb_agg(x), '[]') into part from (
      select jsonb_build_object('k', 'po_open_split:' || p.code, 'sev', 'med', 'area', 'po', 't', 'طلب مفتوح له طلبات مرتبطة',
        'd', p.code || ' — ' || round(p.total) || ' ر.س، مع ' || array_to_string(array(select jsonb_array_elements_text(r->'codes')), '، ') || ' = ' || round(p.total + (r->>'sum')::numeric) || ' ر.س',
        'ref', p.code, 'n', p.total + (r->>'sum')::numeric, 'at', p.at, 'go', 'wh=po') x
        from public.wo_purchase_requests p, lateral (select public.fm_po_related(p.id) r) z
       where p.status = 'requested' and coalesce((r->>'sum')::numeric, 0) > 0) y;
    f := f || part;
  exception when others then skipped := skipped || 'po_split'; end;
  -- 3) received above the agreed price
  begin
    select coalesce(jsonb_agg(jsonb_build_object('k', 'po_price:' || p.code || ':' || (l->>'material_id'), 'sev', case when (l->>'variance')::numeric > 2 * (c->>'price_pct')::numeric then 'high' else 'med' end,
      'area', 'po', 't', 'سعر الفاتورة أعلى من المتفق عليه',
      'd', p.code || ' — ' || coalesce(m.name,'') || ' — +' || round((l->>'variance')::numeric, 1) || '% (' || coalesce(l->>'paid','') || ' بدل ' || coalesce(l->>'price','') || ') — ' || coalesce(p.supplier_name,''),
      'ref', p.code, 'n', (l->>'variance')::numeric, 'at', p.received_at, 'go', 'wh=po')), '[]') into part
      from public.wo_purchase_requests p cross join lateral jsonb_array_elements(p.lines) l left join public.wo_materials m on m.id::text = l->>'material_id'
     where p.received_at > since and (l->>'variance') is not null and (l->>'variance')::numeric > (c->>'price_pct')::numeric;
    f := f || part;
  exception when others then skipped := skipped || 'po_price'; end;
  -- 4) one supplier takes most of the approved money
  begin
    select coalesce(jsonb_agg(jsonb_build_object('k', 'po_share:' || x.supplier || ':' || d, 'sev', 'med', 'area', 'po', 't', 'تركّز المشتريات عند مورد واحد',
      'd', x.supplier || ' — ' || x.share || '% من المشتريات المعتمدة (' || round(x.total) || ' ر.س في ' || x.n || ' طلب)', 'ref', x.supplier, 'n', x.share, 'go', 'wh=po')), '[]') into part
      from (select coalesce(supplier_name,'—') supplier, sum(total) total, count(*) n, round(100 * sum(total) / nullif(sum(sum(total)) over (), 0), 1) share, count(*) over () ns
              from public.wo_purchase_requests where at > since and status in ('approved','partial','received') group by 1) x
     where x.ns > 1 and x.share > (c->>'share_pct')::numeric;
    f := f || part;
  exception when others then skipped := skipped || 'po_share'; end;
  -- 5) system-admin exceptions to the segregation of duties
  begin
    select coalesce(jsonb_agg(jsonb_build_object('k', 'gov:' || id, 'sev', 'low', 'area', 'po', 't', case kind when 'sod_approve' then 'مدير النظام قرّر في طلبه' else 'مدير النظام استلم ما اعتمده' end,
      'd', coalesce(ref,'') || ' — ' || coalesce(by_name,'') || coalesce(' — ' || round(amount) || ' ر.س', ''), 'ref', ref, 'n', amount, 'at', at, 'go', 'wh=po')), '[]') into part
      from public.fm_gov_log where kind in ('sod_approve','sod_receive') and at > since;
    f := f || part;
  exception when others then skipped := skipped || 'gov'; end;
  -- 6) negative balances
  begin
    select coalesce(jsonb_agg(jsonb_build_object('k', 'wh_neg:' || k.store_id || ':' || k.material_id, 'sev', 'high', 'area', 'wh', 't', 'رصيد سالب في المستودع',
      'd', coalesce(s.name,'') || ' — ' || coalesce(m.name,'') || ' — ' || (k.qty)::float8, 'ref', m.name, 'n', k.qty, 'go', 'wh=neg')), '[]') into part
      from public.wo_stock k join public.wo_stores s on s.id = k.store_id join public.wo_materials m on m.id = k.material_id where k.qty < 0 and s.active;
    f := f || part;
  exception when others then skipped := skipped || 'wh_neg'; end;
  -- 7) count adjustments decided by their author
  begin
    select coalesce(jsonb_agg(jsonb_build_object('k', 'wh_adj_self:' || code, 'sev', 'high', 'area', 'wh', 't', 'فرق جرد اعتمده من سجّله',
      'd', code || ' — ' || coalesce(decided_name,'') || ' — ' || round(value) || ' ر.س', 'ref', code, 'n', value, 'at', decided_at, 'go', 'wh=adj')), '[]') into part
      from public.wo_stock_adj where decided_at > since and status = 'approved' and decided_by is not null and decided_by = by_id;
    f := f || part;
  exception when others then skipped := skipped || 'wh_adj'; end;
  -- 8) the same item to the same school again within repeat_days
  begin
    select coalesce(jsonb_agg(jsonb_build_object('k', 'wh_rep:' || x.material_id || ':' || x.school || ':' || x.last::date, 'sev', case when x.n >= 3 then 'high' else 'med' end, 'area', 'wh',
      't', 'نفس القطعة لنفس المدرسة أكثر من مرة', 'd', x.mname || ' — ' || x.school || ' — ' || x.n || ' مرات (' || (x.q)::float8 || ' ' || coalesce(x.unit,'') || ') خلال ' || (c->>'repeat_days') || ' يوماً',
      'ref', x.school, 'n', x.n, 'at', x.last, 'go', 'wh=moves')), '[]') into part
      from (select mv.material_id, mv.school, max(m.name) mname, max(m.unit) unit, count(*) n, sum(abs(mv.qty)) q, max(mv.at) last
              from public.wo_stock_moves mv join public.wo_materials m on m.id = mv.material_id
             where mv.at > greatest(since, now() - make_interval(days => (c->>'repeat_days')::int)) and mv.kind in ('out','issue') and coalesce(btrim(mv.school),'') <> ''
             group by mv.material_id, mv.school having count(*) >= 2) x;
    f := f || part;
  exception when others then skipped := skipped || 'wh_rep'; end;
  -- 9) one person consuming far more than the others (custody use value)
  begin
    select percentile_cont(0.5) within group (order by v) into med from (
      select sum(abs(cm.qty) * coalesce(cm.unit_price, m.price, 0)) v from public.wo_custody_moves cm join public.wo_materials m on m.id = cm.material_id
       where cm.at > since and cm.kind = 'use' group by cm.holder) y;
    if med > 0 then
      select coalesce(jsonb_agg(jsonb_build_object('k', 'wh_out:' || x.holder || ':' || d, 'sev', 'med', 'area', 'wh', 't', 'استهلاك أعلى بكثير من الزملاء',
        'd', x.name || ' — ' || round(x.v) || ' ر.س (' || round(x.v / med, 1) || ' ضعف المتوسط)', 'ref', x.name, 'n', x.v, 'go', 'cus')), '[]') into part
        from (select cm.holder, max(cm.holder_name) name, sum(abs(cm.qty) * coalesce(cm.unit_price, m.price, 0)) v from public.wo_custody_moves cm join public.wo_materials m on m.id = cm.material_id
               where cm.at > since and cm.kind = 'use' group by cm.holder) x
       where x.v > med * (c->>'outlier')::numeric;
      f := f || part;
    end if;
  exception when others then skipped := skipped || 'wh_out'; end;
  -- 10) tickets closed in the platform without an after photo and without a solution text
  begin
    select coalesce(jsonb_agg(x), '[]') into part from (
      select jsonb_build_object('k', 'tk_doc:' || w.region || ':' || w.ticket_id, 'sev', 'med', 'area', 'tk', 't', 'بلاغ أُغلق بلا صورة ولا وصف حل',
        'd', concat_ws(' — ', w.ticket_id, nullif(t.school,''), nullif(w.updated_by_name,'')), 'ref', w.ticket_id, 'region', w.region, 'at', coalesce(w.resolved_at, w.updated_at), 'go', 'tk=' || w.region || ':' || w.ticket_id) x
        from public.ticket_work w left join public.tickets t on t.region = w.region and t.ticket_id = w.ticket_id
       where w.stage in ('resolved','closed') and coalesce(w.resolved_at, w.updated_at) > since
         and coalesce(btrim(w.rec->'resolution'->>'desc'),'') = ''
         and not exists (select 1 from public.ticket_photos ph where ph.region = w.region and ph.ticket_id = w.ticket_id and ph.kind = 'after')
       order by coalesce(w.resolved_at, w.updated_at) desc limit 300) y;
    f := f || part;
  exception when others then skipped := skipped || 'tk_doc'; end;
  -- 11) work orders returned again and again
  begin
    select coalesce(jsonb_agg(jsonb_build_object('k', 'wo_ret:' || w.id, 'sev', case when x.n >= 3 then 'high' else 'med' end, 'area', 'wo', 't', 'أمر عمل أُعيد للتصحيح أكثر من مرة',
      'd', concat_ws(' — ', nullif(w.code,''), nullif(w.school,''), nullif(w.assignee_name,''), x.n || ' مرات'), 'ref', w.code, 'n', x.n, 'at', x.last, 'go', 'wo=' || w.id)), '[]') into part
      from (select wo_id, count(*) n, max(at) last from public.wo_events where type = 'return' and at > since group by wo_id having count(*) >= (c->>'returns')::int) x
      join public.work_orders w on w.id = x.wo_id;
    f := f || part;
  exception when others then skipped := skipped || 'wo_ret'; end;
  -- 12) field visits recorded far from the school
  begin
    select coalesce(jsonb_agg(jsonb_build_object('k', 'att_far:' || x.user_id || ':' || d, 'sev', case when x.n >= 2 * (c->>'far_n')::int then 'high' else 'med' end, 'area', 'att',
      't', 'زيارات مسجّلة بعيداً عن المدرسة', 'd', x.name || ' — ' || x.n || ' زيارة على بعد أكثر من ' || (c->>'far_m') || ' م (أبعدها ' || round(x.mx) || ' م)', 'ref', x.name, 'n', x.n, 'at', x.last, 'go', 'att')), '[]') into part
      from (select a.user_id, max(coalesce(a.name, p.full_name)) name, count(*) n, max(a.dist_m) mx, max(a.at) last from public.fm_att a left join public.profiles p on p.id = a.user_id
             where a.at > since and a.kind = 'visit' and a.dist_m > (c->>'far_m')::numeric group by a.user_id having count(*) >= (c->>'far_n')::int) x;
    f := f || part;
  exception when others then skipped := skipped || 'att_far'; end;
  -- reviews
  select coalesce(jsonb_agg(e || coalesce((select jsonb_build_object('rv', jsonb_build_object('status', r.status, 'note', r.note, 'by', r.by_name, 'at', r.at))
                                             from public.fm_flag_reviews r where r.k = e->>'k'), '{}'::jsonb)), '[]') into f
    from jsonb_array_elements(f) e;
  return jsonb_build_object('days', d, 'cfg', c, 'flags', f, 'skipped', to_jsonb(skipped),
    'can_set', coalesce(public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin', false));
end $$;

create or replace function public.fm_flag_review(p_k text, p_status text, p_note text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.fm_flag_can() then raise exception 'not allowed'; end if;
  if coalesce(btrim(p_k),'') = '' or length(p_k) > 300 then raise exception 'invalid key'; end if;
  if p_status is null then delete from public.fm_flag_reviews where k = p_k; return true; end if;
  if p_status not in ('ok','action') then raise exception 'invalid status'; end if;
  if length(btrim(coalesce(p_note,''))) < 3 then raise exception 'note required'; end if;
  insert into public.fm_flag_reviews(k, status, note, by_id, by_name) values (p_k, p_status, left(btrim(p_note),1000), auth.uid(), public.fm_me_name())
  on conflict (k) do update set status = excluded.status, note = excluded.note, by_id = excluded.by_id, by_name = excluded.by_name, at = now();
  return true;
end $$;

revoke all on function public.fm_flag_can(), public.fm_flag_cfg(), public.fm_red_flags(int), public.fm_flag_review(text,text,text) from public, anon;
grant execute on function public.fm_flag_can(), public.fm_flag_cfg(), public.fm_red_flags(int), public.fm_flag_review(text,text,text) to authenticated;
notify pgrst, 'reload schema';

-- =====================================================================
-- Section 58 (V253): approved pause of a ticket's SLA clock «⏸️ إيقاف المهلة»
-- A supervisor / engineer asks to pause a ticket's clock for an accepted reason (waiting for a part, the
-- school closed, an official holiday, no access, the client's request, other); the area manager of the region
-- (or ops / project manager, system admin) approves or rejects; an approved pause runs from `from_at` until
-- `to_at` or until it is ended. The platform shows the adjusted SLA next to the original — the original
-- SLA calculation is never changed. Idempotent.
-- =====================================================================
create table if not exists public.fm_sla_pauses (
  id          uuid primary key default gen_random_uuid(),
  code        text unique,
  region      text not null,
  ticket_id   text not null,
  school      text,
  reason      text not null check (reason in ('parts','school_closed','holiday','access','client','other')),
  note        text not null default '' check (length(note) <= 1000),
  from_at     timestamptz not null,
  to_at       timestamptz,
  status      text not null default 'pending' check (status in ('pending','approved','rejected','ended','cancelled')),
  req_by      uuid references public.profiles(id) on delete set null,
  req_name    text,
  dec_by      uuid references public.profiles(id) on delete set null,
  dec_name    text,
  dec_at      timestamptz,
  dec_note    text,
  ended_at    timestamptz,
  created_at  timestamptz not null default now()
);
create index if not exists fm_sla_pauses_t on public.fm_sla_pauses (region, ticket_id);
create index if not exists fm_sla_pauses_st on public.fm_sla_pauses (status, created_at desc);
alter table public.fm_sla_pauses enable row level security;
revoke all on public.fm_sla_pauses from public, anon, authenticated;

create or replace function public.fm_slap_can_req(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() not in ('pending','viewer') and (public.fm_role() = 'admin' or public.fm_scope_all() or public.fm_region_ok(coalesce(p_region,''))), false) $$;
create or replace function public.fm_slap_can_dec(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager')
    or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(p_region,''))), false) $$;

create or replace function public.fm_sla_pause_request(p_region text, p_ticket text, p_reason text, p_note text, p_from timestamptz default null, p_to timestamptz default null, p_school text default null)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.fm_sla_pauses; u uuid; f timestamptz := coalesce(p_from, now());
begin
  if auth.uid() is null or not public.fm_slap_can_req(p_region) then raise exception 'not allowed'; end if;
  if not public.fm_mod('tickets') then raise exception 'module disabled'; end if;
  if coalesce(btrim(p_ticket),'') = '' or length(p_ticket) > 80 then raise exception 'invalid ticket'; end if;
  if coalesce(p_reason,'') not in ('parts','school_closed','holiday','access','client','other') then raise exception 'invalid reason'; end if;
  if length(btrim(coalesce(p_note,''))) < 3 then raise exception 'note required'; end if;
  if f > now() + interval '30 days' or f < now() - interval '30 days' then raise exception 'invalid date'; end if;
  if p_to is not null and p_to <= f then raise exception 'invalid date'; end if;
  if exists (select 1 from public.fm_sla_pauses where region = p_region and ticket_id = btrim(p_ticket) and status = 'pending') then raise exception 'already pending'; end if;
  if exists (select 1 from public.fm_sla_pauses where region = p_region and ticket_id = btrim(p_ticket) and status = 'approved' and (to_at is null or to_at > now()) and ended_at is null) then raise exception 'already paused'; end if;
  if (select count(*) from public.fm_sla_pauses where req_by = auth.uid() and created_at > now() - interval '1 day') >= 50 then raise exception 'too many today'; end if;
  insert into public.fm_sla_pauses(code, region, ticket_id, school, reason, note, from_at, to_at, req_by, req_name)
  values ('SP-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad((select count(*) + 1 from public.fm_sla_pauses where code like 'SP-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-%')::text, 4, '0'),
          p_region, btrim(p_ticket), left(nullif(btrim(coalesce(p_school,'')),''),200), p_reason, left(btrim(p_note),1000), f, p_to, auth.uid(), public.fm_me_name())
  returning * into r;
  begin
    for u in select distinct x from (select public.fm_push_people(array['area_manager'], p_region) x
               union select p.reports_to from public.profiles p where p.id = auth.uid()) y where x is not null and x <> auth.uid() loop
      perform public.fm_push_add(u, 'sla_pause', '⏸️ طلب إيقاف مهلة البلاغ ' || r.ticket_id, concat_ws(' — ', r.school, public.fm_me_name(), left(r.note, 120)), 'slap', 'slap-' || r.id, false);
    end loop;
  exception when others then null; end;
  return jsonb_build_object('id', r.id, 'code', r.code);
end $$;

-- approve | reject (note) | end (stop an approved pause now) | cancel (the requester, while pending)
create or replace function public.fm_sla_pause_act(p_id uuid, p_action text, p_note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare r public.fm_sla_pauses;
begin
  select * into r from public.fm_sla_pauses where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if p_action = 'cancel' then
    if r.req_by is distinct from auth.uid() or r.status <> 'pending' then raise exception 'not allowed'; end if;
    update public.fm_sla_pauses set status = 'cancelled' where id = p_id; return 'cancelled';
  end if;
  if p_action = 'end' then
    if r.status <> 'approved' or not (public.fm_slap_can_dec(r.region) or r.req_by = auth.uid()) then raise exception 'not allowed'; end if;
    update public.fm_sla_pauses set status = 'ended', ended_at = greatest(now(), from_at), to_at = least(coalesce(to_at, now()), greatest(now(), from_at)) where id = p_id; return 'ended';
  end if;
  if p_action not in ('approve','reject') then raise exception 'invalid action'; end if;
  if r.status <> 'pending' then raise exception 'invalid status'; end if;
  if not public.fm_slap_can_dec(r.region) then raise exception 'not allowed'; end if;
  if r.req_by = auth.uid() and not (public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin') then raise exception 'self approval'; end if;
  if p_action = 'reject' and length(btrim(coalesce(p_note,''))) < 3 then raise exception 'note required'; end if;
  update public.fm_sla_pauses set status = case when p_action = 'approve' then 'approved' else 'rejected' end, dec_by = auth.uid(), dec_name = public.fm_me_name(), dec_at = now(),
    dec_note = left(nullif(btrim(coalesce(p_note,'')),''),500) where id = p_id;
  begin perform public.fm_push_add(r.req_by, 'sla_pause', case when p_action = 'approve' then '✅ اعتُمد إيقاف مهلة البلاغ ' else '❌ رُفض إيقاف مهلة البلاغ ' end || r.ticket_id,
    concat_ws(' — ', r.school, public.fm_me_name(), nullif(btrim(p_note),'')), 'slap', 'slap-' || r.id, false); exception when others then null; end;
  return p_action;
end $$;

-- pauses of a region (or all the caller may see): pending first
create or replace function public.fm_sla_pauses_list(p_region text default null, p_days int default 365) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('can_dec', public.fm_slap_can_dec(p_region), 'can_req', public.fm_slap_can_req(p_region), 'rows', coalesce(jsonb_agg(jsonb_build_object(
      'id', id, 'code', code, 'region', region, 'ticket', ticket_id, 'school', school, 'reason', reason, 'note', note, 'from', from_at, 'to', to_at,
      'status', status, 'req', req_name, 'mine', req_by = auth.uid(), 'dec', dec_name, 'dec_at', dec_at, 'dec_note', dec_note, 'ended_at', ended_at, 'at', created_at,
      'can_dec', public.fm_slap_can_dec(region) and (req_by is distinct from auth.uid() or public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin'))
      order by (status = 'pending') desc, created_at desc), '[]'::jsonb))
    from public.fm_sla_pauses
   where auth.uid() is not null and public.fm_role() <> 'pending' and (p_region is null or region = p_region)
     and created_at > now() - make_interval(days => least(greatest(coalesce(p_days,365),7),800))
     and (public.fm_role() = 'admin' or public.fm_scope_all() or public.fm_region_ok(region) or req_by = auth.uid()) $$;

revoke all on function public.fm_slap_can_req(text), public.fm_slap_can_dec(text), public.fm_sla_pause_request(text,text,text,text,timestamptz,timestamptz,text),
  public.fm_sla_pause_act(uuid,text,text), public.fm_sla_pauses_list(text,int) from public, anon;
grant execute on function public.fm_slap_can_req(text), public.fm_slap_can_dec(text), public.fm_sla_pause_request(text,text,text,text,timestamptz,timestamptz,text),
  public.fm_sla_pause_act(uuid,text,text), public.fm_sla_pauses_list(text,int) to authenticated;
notify pgrst, 'reload schema';

-- =====================================================================
-- Section 59 (V254): urgent tickets closed in the platform or the field app wait for the area engineer's review
-- When the shared closing rules (app_kv fm_work_rules_v135) have `urgent: true`, a ticket whose priority is urgent
-- (طارئ / حرج / urgent) that reaches resolved / closed gets a review row; the area engineer / manager of the region
-- (or ops / project manager, system admin) approves it or returns it — a return puts the ticket back in «قيد التنفيذ»
-- with an event and tells whoever closed it. Nothing is blocked while the review waits. Idempotent.
-- =====================================================================
create table if not exists public.fm_tk_close_rev (
  id         uuid primary key default gen_random_uuid(),
  region     text not null,
  ticket_id  text not null,
  school     text,
  priority   text,
  sol        text,
  closed_by  uuid references public.profiles(id) on delete set null,
  closed_name text,
  closed_at  timestamptz not null default now(),
  status     text not null default 'pending' check (status in ('pending','approved','returned')),
  dec_by     uuid references public.profiles(id) on delete set null,
  dec_name   text,
  dec_at     timestamptz,
  note       text
);
create unique index if not exists fm_tk_close_rev_pending on public.fm_tk_close_rev (region, ticket_id) where status = 'pending';
alter table public.fm_tk_close_rev enable row level security;
revoke all on public.fm_tk_close_rev from public, anon, authenticated;

create or replace function public.fm_tkrev_can(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager')
    or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_region_ok(coalesce(p_region,''))), false) $$;

create or replace function public.fm_tk_close_trg() returns trigger language plpgsql security definer set search_path = public as $$
declare pr text; sch text; u uuid;
begin
  begin
    if new.stage not in ('resolved','closed') or (tg_op = 'UPDATE' and old.stage in ('resolved','closed')) then return null; end if;
    if not coalesce((select (value->>'urgent')::boolean from public.app_kv where key = 'fm_work_rules_v135'), false) then return null; end if;
    select coalesce(nullif(new.rec->'edits'->>'priority',''), t.priority), t.school into pr, sch from public.tickets t where t.region = new.region and t.ticket_id = new.ticket_id;
    pr := coalesce(pr, new.rec->'edits'->>'priority', '');
    if not (pr ~* 'طارئ|حرج|urgent|critical') then return null; end if;
    insert into public.fm_tk_close_rev(region, ticket_id, school, priority, sol, closed_by, closed_name)
    values (new.region, new.ticket_id, coalesce(sch, new.rec->>'school'), pr, left(coalesce(new.rec->'resolution'->>'desc',''),1000), new.updated_by, new.updated_by_name)
    on conflict do nothing;
    for u in select * from public.fm_push_people(array['area_engineer','area_manager'], new.region) loop
      perform public.fm_push_add(u, 'tk_review', '🟡 إغلاق بلاغ طارئ بانتظار اعتمادك ' || new.ticket_id, concat_ws(' — ', coalesce(sch, new.rec->>'school'), new.updated_by_name), 'tkrev', 'tkrev-' || new.ticket_id, false);
    end loop;
  exception when others then null; end;
  return null;
end $$;
drop trigger if exists fm_tk_close_trg on public.ticket_work;
create trigger fm_tk_close_trg after insert or update of stage on public.ticket_work for each row execute function public.fm_tk_close_trg();

create or replace function public.fm_tk_close_list(p_region text default null) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('can', public.fm_tkrev_can(p_region), 'rows', coalesce(jsonb_agg(jsonb_build_object('id', id, 'region', region, 'ticket', ticket_id, 'school', school, 'priority', priority,
      'sol', sol, 'by', closed_name, 'at', closed_at, 'status', status, 'dec', dec_name, 'dec_at', dec_at, 'note', note,
      'can', public.fm_tkrev_can(region) and closed_by is distinct from auth.uid()) order by (status = 'pending') desc, closed_at desc), '[]'::jsonb))
    from public.fm_tk_close_rev
   where auth.uid() is not null and (p_region is null or region = p_region) and closed_at > now() - interval '180 days'
     and (public.fm_tkrev_can(region) or closed_by = auth.uid() or public.fm_scope_all()) $$;

create or replace function public.fm_tk_close_act(p_id uuid, p_action text, p_note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare r public.fm_tk_close_rev; nm text := public.fm_me_name();
begin
  select * into r from public.fm_tk_close_rev where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if r.status <> 'pending' then raise exception 'invalid status'; end if;
  if not public.fm_tkrev_can(r.region) then raise exception 'not allowed'; end if;
  if r.closed_by = auth.uid() and not (public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin') then raise exception 'self approval'; end if;
  if p_action = 'return' and length(btrim(coalesce(p_note,''))) < 3 then raise exception 'note required'; end if;
  if p_action not in ('approve','return') then raise exception 'invalid action'; end if;
  update public.fm_tk_close_rev set status = case when p_action = 'approve' then 'approved' else 'returned' end, dec_by = auth.uid(), dec_name = nm, dec_at = now(),
    note = left(nullif(btrim(coalesce(p_note,'')),''),500) where id = p_id;
  if p_action = 'return' then
    update public.ticket_work set stage = 'progress', resolved_at = null, updated_at = now(), updated_by = auth.uid(), updated_by_name = nm,
      rec = rec || jsonb_build_object('stage','progress','reopened', coalesce((rec->>'reopened')::int,0) + 1, 'returnNote', left(btrim(p_note),500), 'updated', (extract(epoch from now()) * 1000)::bigint)
     where region = r.region and ticket_id = r.ticket_id;
    insert into public.ticket_events(region, ticket_id, by_name, type, stage, text) values (r.region, r.ticket_id, nm, 'stage', 'progress', '↩️ أُعيد من مراجعة إغلاق البلاغ الطارئ: ' || left(btrim(p_note),400));
  else
    insert into public.ticket_events(region, ticket_id, by_name, type, stage, text) values (r.region, r.ticket_id, nm, 'note', null, '✅ اعتُمد إغلاق البلاغ الطارئ' || coalesce(' — ' || nullif(btrim(p_note),''), ''));
  end if;
  begin perform public.fm_push_add(r.closed_by, 'tk_review', case when p_action = 'approve' then '✅ اعتُمد إغلاق البلاغ الطارئ ' else '↩️ أُعيد البلاغ الطارئ للتنفيذ ' end || r.ticket_id,
    concat_ws(' — ', r.school, nm, nullif(btrim(p_note),'')), 'tkrev', 'tkrev-' || r.ticket_id, false); exception when others then null; end;
  return p_action;
end $$;

revoke all on function public.fm_tk_close_trg() from public, anon, authenticated;
revoke all on function public.fm_tkrev_can(text), public.fm_tk_close_list(text), public.fm_tk_close_act(uuid,text,text) from public, anon;
grant execute on function public.fm_tkrev_can(text), public.fm_tk_close_list(text), public.fm_tk_close_act(uuid,text,text) to authenticated;
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════════
-- Section 60 (V256): random audit sample of closed tickets (QA manager)
-- The platform sends the tickets closed in a month; the server picks a random share (fm_settings.qa.sample_pct, V158),
-- the QA manager visits and rules pass / fail. A fail may send the ticket back to work (ticket_work stage progress).
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.fm_tk_audits (
  id         uuid primary key default gen_random_uuid(),
  code       text unique,
  region     text not null,
  ticket_id  text not null,
  month      text not null,
  school     text,
  priority   text,
  category   text,
  closed_at  timestamptz,
  executor   text,
  sol        text,
  status     text not null default 'pending' check (status in ('pending','pass','fail')),
  note       text,
  photo      text,
  reopened   boolean not null default false,
  sampled_by uuid references public.profiles(id) on delete set null,
  sampled_at timestamptz not null default now(),
  dec_by     uuid references public.profiles(id) on delete set null,
  dec_name   text,
  dec_at     timestamptz
);
create unique index if not exists fm_tk_audits_one on public.fm_tk_audits (region, ticket_id);
create index if not exists fm_tk_audits_month on public.fm_tk_audits (region, month);
alter table public.fm_tk_audits enable row level security;
revoke all on public.fm_tk_audits from public, anon, authenticated;

create or replace function public.fm_tka_can(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','qa_manager'), false) $$;
create or replace function public.fm_tka_sees(p_region text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_tka_can(p_region) or public.fm_scope_all()
    or (public.fm_my_pos() in ('area_manager','area_engineer') and public.fm_region_ok(coalesce(p_region,''))), false) $$;

-- p_rows: [{id, school, priority, cat, closed, exec, sol}] = the tickets closed in the month (≤ 5000)
create or replace function public.fm_tk_audit_sample(p_region text, p_month text, p_rows jsonb, p_pct numeric default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare pct numeric := coalesce(p_pct, (public.fm_setting('qa')->>'sample_pct')::numeric, 5); tot int; want int; have int; n int := 0; r jsonb; y text := left(p_month,4); seq int;
begin
  if auth.uid() is null or not public.fm_tka_can(p_region) then raise exception 'not allowed'; end if;
  if not public.fm_mod('tickets') then raise exception 'module disabled'; end if;
  if p_month !~ '^\d{4}-\d{2}$' then raise exception 'invalid month'; end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) > 5000 then raise exception 'invalid rows'; end if;
  if pct is null or pct <= 0 or pct > 100 then raise exception 'invalid pct'; end if;
  tot := jsonb_array_length(p_rows);
  if tot = 0 then return jsonb_build_object('total', 0, 'added', 0, 'have', 0); end if;
  want := greatest(1, ceil(tot * pct / 100.0)::int);
  perform pg_advisory_xact_lock(hashtext('fm_tka:' || p_region || ':' || p_month));
  select count(*) into have from public.fm_tk_audits where region = p_region and month = p_month;
  for r in select x from jsonb_array_elements(p_rows) x
            where nullif(btrim(x->>'id'),'') is not null
              and not exists (select 1 from public.fm_tk_audits a where a.region = p_region and a.ticket_id = btrim(x->>'id'))
            order by random() limit greatest(0, want - have) loop
    select coalesce(max(substring(code from '\d+$')::int), 0) + 1 into seq from public.fm_tk_audits where code like 'TA-' || y || '-%';
    insert into public.fm_tk_audits(code, region, ticket_id, month, school, priority, category, closed_at, executor, sol, sampled_by)
    values ('TA-' || y || '-' || lpad(seq::text, 4, '0'), p_region, btrim(r->>'id'), p_month, left(r->>'school',200), left(r->>'priority',40), left(r->>'cat',120),
      case when (r->>'closed') ~ '^\d{4}-\d{2}-\d{2}' then (r->>'closed')::timestamptz end, left(r->>'exec',120), left(r->>'sol',1000), auth.uid())
    on conflict do nothing;
    n := n + 1;
  end loop;
  return jsonb_build_object('total', tot, 'want', want, 'added', n, 'have', have + n, 'pct', pct);
end $$;

create or replace function public.fm_tk_audit_list(p_region text, p_month text default null) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('can', public.fm_tka_can(p_region), 'sees', public.fm_tka_sees(p_region),
    'pct', coalesce((public.fm_setting('qa')->>'sample_pct')::numeric, 5),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'code', code, 'ticket', ticket_id, 'month', month, 'school', school, 'priority', priority,
        'cat', category, 'closed', closed_at, 'exec', executor, 'sol', sol, 'status', status, 'note', note, 'photo', photo is not null, 'reopened', reopened,
        'dec', dec_name, 'dec_at', dec_at) order by (status = 'pending') desc, sampled_at desc)
      from public.fm_tk_audits where region = p_region and (p_month is null or month = p_month) and public.fm_tka_sees(p_region)), '[]'::jsonb))
  where auth.uid() is not null $$;

create or replace function public.fm_tk_audit_photo(p_id uuid) returns text language sql stable security definer set search_path = public as $$
  select photo from public.fm_tk_audits where id = p_id and auth.uid() is not null and public.fm_tka_sees(region) $$;

create or replace function public.fm_tk_audit_review(p_id uuid, p_result text, p_note text default '', p_reopen boolean default false, p_photo text default null) returns text
language plpgsql security definer set search_path = public as $$
declare a public.fm_tk_audits; nm text := public.fm_me_name(); u uuid;
begin
  select * into a from public.fm_tk_audits where id = p_id for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if not public.fm_tka_can(a.region) then raise exception 'not allowed'; end if;
  if p_result not in ('pass','fail') then raise exception 'invalid action'; end if;
  if a.status <> 'pending' then raise exception 'invalid status'; end if;
  if p_result = 'fail' and length(btrim(coalesce(p_note,''))) < 3 then raise exception 'note required'; end if;
  if p_photo is not null and (length(p_photo) > 420000 or p_photo !~ '^data:image/(jpeg|png|webp);base64,') then raise exception 'invalid photo'; end if;
  update public.fm_tk_audits set status = p_result, note = left(nullif(btrim(coalesce(p_note,'')),''),1000), photo = coalesce(p_photo, photo),
    reopened = (p_result = 'fail' and coalesce(p_reopen,false)), dec_by = auth.uid(), dec_name = nm, dec_at = now() where id = p_id;
  if p_result = 'fail' and coalesce(p_reopen,false) then
    insert into public.ticket_work(region, ticket_id, stage, rec, resolved_at, updated_by, updated_by_name)
    values (a.region, a.ticket_id, 'progress', jsonb_build_object('stage','progress','reopened',1,'returnNote', left(btrim(p_note),500), 'updated', (extract(epoch from now()) * 1000)::bigint), null, auth.uid(), nm)
    on conflict (region, ticket_id) do update set stage = 'progress', resolved_at = null, updated_at = now(), updated_by = auth.uid(), updated_by_name = nm,
      rec = public.ticket_work.rec || jsonb_build_object('stage','progress','reopened', coalesce((public.ticket_work.rec->>'reopened')::int,0) + 1, 'returnNote', left(btrim(p_note),500), 'updated', (extract(epoch from now()) * 1000)::bigint);
  end if;
  insert into public.ticket_events(region, ticket_id, by_name, type, stage, text) values (a.region, a.ticket_id, nm,
    case when p_result = 'fail' and coalesce(p_reopen,false) then 'stage' else 'note' end, case when p_result = 'fail' and coalesce(p_reopen,false) then 'progress' end,
    case when p_result = 'pass' then '✅ تدقيق الجودة ' || a.code || ': مطابق' else '❌ تدقيق الجودة ' || a.code || ': غير مطابق — ' || left(btrim(p_note),400)
      || case when coalesce(p_reopen,false) then ' (أُعيد للتنفيذ)' else '' end end || case when p_result = 'pass' and nullif(btrim(coalesce(p_note,'')),'') is not null then ' — ' || left(btrim(p_note),300) else '' end);
  if p_result = 'fail' then
    begin
      for u in select * from public.fm_push_people(array['area_engineer','area_manager'], a.region) loop
        perform public.fm_push_add(u, 'tk_audit', '❌ بلاغ غير مطابق في تدقيق الجودة ' || a.ticket_id, concat_ws(' — ', a.school, a.executor, left(btrim(p_note),120)), 'tkaudit', 'tka-' || a.ticket_id, false);
      end loop;
    exception when others then null; end;
  end if;
  return p_result;
end $$;

revoke all on function public.fm_tka_can(text), public.fm_tka_sees(text), public.fm_tk_audit_sample(text,text,jsonb,numeric), public.fm_tk_audit_list(text,text),
  public.fm_tk_audit_photo(uuid), public.fm_tk_audit_review(uuid,text,text,boolean,text) from public, anon;
grant execute on function public.fm_tka_can(text), public.fm_tka_sees(text), public.fm_tk_audit_sample(text,text,jsonb,numeric), public.fm_tk_audit_list(text,text),
  public.fm_tk_audit_photo(uuid), public.fm_tk_audit_review(uuid,text,text,boolean,text) to authenticated;
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════════
-- Section 61 (V258): abnormal parts consumption
-- fm_wh_abnormal(days): (1) the same item used for the same school again within repeat_days (fm_settings.red_flags,
-- V252) — store «out» moves with a school and custody «use» moves; (2) a person whose use value is above outlier × the
-- median of the people with the same job title (≥ 3 people with use). fm_v258_daily() (pg_cron fm-v258-daily 05:45 UTC)
-- sends push wh_abn once per repeat case to the keepers and area engineers / managers of the store's region.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.fm_wh_abn_sent (k text primary key, at timestamptz not null default now());
alter table public.fm_wh_abn_sent enable row level security;
revoke all on public.fm_wh_abn_sent from public, anon, authenticated;

create or replace function public.fm_wh_abn_can() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_flag_can() or public.fm_wh_edit() or public.fm_scope_all(), false) $$;

-- internal: uses in the period (all regions)
create or replace function public.fm_wh_uses(p_since timestamptz) returns table(at timestamptz, material_id uuid, school text, qty numeric, value numeric, wo_code text,
  who uuid, who_name text, region text, src text) language sql stable security definer set search_path = public as $$
  select mv.at, mv.material_id, btrim(mv.school), abs(mv.qty), abs(mv.qty) * coalesce(mv.unit_price, m.price, 0), mv.wo_code, mv.by_id, mv.by_name, s.region, 'store'
    from public.wo_stock_moves mv join public.wo_materials m on m.id = mv.material_id left join public.wo_stores s on s.id = mv.store_id
   where mv.at > p_since and mv.kind = 'out' and coalesce(btrim(mv.school),'') <> ''
  union all
  select cm.at, cm.material_id, btrim(cm.school), coalesce(nullif(cm.used,0), abs(cm.qty)), coalesce(nullif(cm.used,0), abs(cm.qty)) * coalesce(cm.unit_price, m.price, 0), cm.wo_code,
         cm.holder, cm.holder_name, coalesce(s.region, (select p.regions[1] from public.profiles p where p.id = cm.holder)), 'custody'
    from public.wo_custody_moves cm join public.wo_materials m on m.id = cm.material_id left join public.wo_stores s on s.id = cm.store_id
   where cm.at > p_since and cm.kind = 'use' $$;
revoke all on function public.fm_wh_uses(timestamptz) from public, anon, authenticated;

-- internal: repeat cases (consecutive uses of an item at a school with a gap ≤ repeat_days)
create or replace function public.fm_wh_rep_rows(p_since timestamptz) returns table(k text, material_id uuid, mname text, unit text, school text, region text, n int, q numeric, v numeric, first timestamptz, last timestamptz, uses jsonb)
language sql stable security definer set search_path = public as $$
  with c as (select coalesce((public.fm_flag_cfg()->>'repeat_days')::int, 30) d),
  u as (select x.*, lag(x.at) over (partition by x.material_id, x.school order by x.at) prev from public.fm_wh_uses(p_since) x where coalesce(x.school,'') <> ''),
  g as (select u.*, sum(case when u.prev is null or u.at - u.prev > make_interval(days => (select d from c)) then 1 else 0 end) over (partition by u.material_id, u.school order by u.at) grp from u)
  select g.material_id::text || ':' || g.school || ':' || min(g.at)::date, g.material_id, max(m.name), max(m.unit), g.school, max(g.region), count(*)::int, sum(g.qty), sum(g.value), min(g.at), max(g.at),
         jsonb_agg(jsonb_build_object('at', g.at, 'q', g.qty, 'wo', g.wo_code, 'by', g.who_name, 'src', g.src) order by g.at)
    from g join public.wo_materials m on m.id = g.material_id
   group by g.material_id, g.school, g.grp having count(*) >= 2 $$;
revoke all on function public.fm_wh_rep_rows(timestamptz) from public, anon, authenticated;

create or replace function public.fm_wh_abnormal(p_days int default 90) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare d int := least(greatest(coalesce(p_days,90),7),365); since timestamptz := now() - make_interval(days => d); c jsonb := public.fm_flag_cfg();
  allr boolean := public.fm_role() = 'admin' or public.fm_scope_all() or public.fm_my_pos() in ('accountant','owner_rep'); rep jsonb; peer jsonb; o numeric := coalesce((c->>'outlier')::numeric, 3);
begin
  if auth.uid() is null or not public.fm_wh_abn_can() then raise exception 'not allowed'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('k', r.k, 'material', r.mname, 'unit', r.unit, 'school', r.school, 'region', r.region, 'n', r.n, 'q', r.q, 'v', round(r.v,2),
      'first', r.first, 'last', r.last, 'uses', r.uses) order by r.n desc, r.last desc), '[]'::jsonb) into rep
    from public.fm_wh_rep_rows(since) r where allr or public.fm_region_ok(coalesce(r.region,''));
  with u as (select x.who, max(x.who_name) nm, max(x.region) region, sum(x.value) v, sum(x.qty) q, count(*) n from public.fm_wh_uses(since) x where x.who is not null group by x.who),
  t as (select u.*, public.fm_posx(p.role, p.job_title) title from u join public.profiles p on p.id = u.who),
  m as (select title, percentile_cont(0.5) within group (order by v) med, count(*) cnt from t where v > 0 group by title)
  select coalesce(jsonb_agg(jsonb_build_object('who', t.who, 'name', t.nm, 'title', t.title, 'region', t.region, 'v', round(t.v,2), 'n', t.n, 'med', round(m.med::numeric,2), 'peers', m.cnt,
      'ratio', round((t.v / m.med)::numeric, 1),
      'top', (select jsonb_agg(z) from (select jsonb_build_object('material', mm.name, 'q', sum(x.qty), 'v', round(sum(x.value),2)) z from public.fm_wh_uses(since) x join public.wo_materials mm on mm.id = x.material_id
               where x.who = t.who group by mm.name order by sum(x.value) desc limit 5) zz)) order by t.v / m.med desc), '[]'::jsonb) into peer
    from t join m on m.title = t.title
   where m.cnt >= 3 and m.med > 0 and t.v > m.med * o and (allr or public.fm_region_ok(coalesce(t.region,'')));
  return jsonb_build_object('days', d, 'repeat_days', coalesce((c->>'repeat_days')::int,30), 'outlier', o, 'rep', rep, 'peer', peer);
end $$;

create or replace function public.fm_v258_daily() returns int language plpgsql security definer set search_path = public as $$
declare r record; u uuid; n int := 0;
begin
  for r in select * from public.fm_wh_rep_rows(now() - interval '120 days') x where x.last > now() - interval '2 days'
             and not exists (select 1 from public.fm_wh_abn_sent s where s.k = x.k || ':' || x.n) loop
    insert into public.fm_wh_abn_sent(k) values (r.k || ':' || r.n) on conflict do nothing;
    for u in select * from public.fm_wh_keepers_of(r.region) union select * from public.fm_push_people(array['area_engineer','area_manager'], r.region) loop
      begin perform public.fm_push_add(u, 'wh_abn', '🚨 صرف متكرر لنفس القطعة ' || coalesce(r.mname,''), concat_ws(' — ', r.school, r.n || ' مرات', (r.q)::float8 || ' ' || coalesce(r.unit,'')), 'wh=abn', 'abn-' || left(md5(r.k),12), false);
      exception when others then null; end;
    end loop;
    n := n + 1;
  end loop;
  delete from public.fm_wh_abn_sent where at < now() - interval '400 days';
  return n;
end $$;
revoke all on function public.fm_v258_daily() from public, anon, authenticated;
revoke all on function public.fm_wh_abn_can(), public.fm_wh_abnormal(int) from public, anon;
grant execute on function public.fm_wh_abn_can(), public.fm_wh_abnormal(int) to authenticated;
do $do$ begin
  begin execute 'select cron.unschedule(''fm-v258-daily'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-v258-daily'', ''45 5 * * *'', ''select public.fm_v258_daily()'')';
  exception when others then raise notice 'pg_cron is not available: abnormal consumption alerts are not pushed (the page still shows them)'; end;
end $do$;
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════════
-- Section 62 (V259): monthly three-way reconciliation of custody parts
-- Per person × item × month: opening balance, issued to him (issue), used on work orders (use: from custody / total),
-- returned (return), written off, closing; scrap owed by the month's uses vs scrap returned; the month's count (V180
-- wo_custody_counts) against the closing balance. The engineer above him (or a manager) signs «مطابق» or records
-- the differences (wo_custody_recon, one per person and month, with the snapshot).
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.wo_custody_recon (
  id         uuid primary key default gen_random_uuid(),
  holder     uuid not null references public.profiles(id) on delete cascade,
  holder_name text,
  month      text not null,
  status     text not null check (status in ('ok','diff')),
  note       text,
  lines      jsonb not null default '[]',
  totals     jsonb not null default '{}',
  by_id      uuid references public.profiles(id) on delete set null,
  by_name    text,
  at         timestamptz not null default now(),
  unique (holder, month)
);
alter table public.wo_custody_recon enable row level security;
revoke all on public.wo_custody_recon from public, anon, authenticated;

create or replace function public.fm_recon_can_sign(h uuid) returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and h is distinct from auth.uid() and (public.fm_role() = 'admin' or public.fm_wh_admin()
    or (public.fm_my_pos() in ('area_engineer','area_manager','ops_manager','project_manager','sysadmin') and public.fm_wh_sees_holder(h))) $$;

-- internal: one person's lines for a month ('YYYY-MM', Riyadh time)
create or replace function public.fm_recon_lines(h uuid, p_month text) returns jsonb language sql stable security definer set search_path = public as $$
  with b as (select (p_month || '-01')::timestamp at time zone 'Asia/Riyadh' a, ((p_month || '-01')::date + interval '1 month')::timestamp at time zone 'Asia/Riyadh' z),
  mv as (select cm.* from public.wo_custody_moves cm, b where cm.holder = h and cm.at < b.z),
  agg as (select mv.material_id,
      sum(case when mv.at < b.a then mv.qty else 0 end) open_q,
      sum(case when mv.at >= b.a and mv.kind = 'issue' then mv.qty else 0 end) issued,
      -sum(case when mv.at >= b.a and mv.kind = 'use' then mv.qty else 0 end) used_cus,
      sum(case when mv.at >= b.a and mv.kind = 'use' then coalesce(mv.used,0) else 0 end) used_all,
      count(distinct case when mv.at >= b.a and mv.kind = 'use' then mv.wo_code end) wos,
      -sum(case when mv.at >= b.a and mv.kind = 'return' then mv.qty else 0 end) returned,
      -sum(case when mv.at >= b.a and mv.kind = 'writeoff' then mv.qty else 0 end) writeoff,
      sum(mv.qty) close_q,
      sum(case when mv.at >= b.a and mv.scrap > 0 then mv.scrap else 0 end) scrap_new,
      -sum(case when mv.at >= b.a and mv.scrap < 0 then mv.scrap else 0 end) scrap_back,
      sum(mv.scrap) scrap_end,
      max(mv.unit_price) price
    from mv, b group by mv.material_id),
  cnt as (select (l->>'material_id')::uuid mid, (l->>'counted')::numeric counted, c.status cst
            from public.wo_custody_counts c cross join lateral jsonb_array_elements(c.lines) l, b
           where c.holder = h and c.month = p_month and coalesce(l->>'material_id','') ~ '^[0-9a-fA-F-]{36}$' and l ? 'counted')
  select coalesce(jsonb_agg(jsonb_build_object('material_id', a.material_id, 'name', m.name, 'code', m.code, 'unit', m.unit,
      'open', a.open_q, 'issued', a.issued, 'used_cus', a.used_cus, 'used_all', a.used_all, 'wos', a.wos, 'returned', a.returned, 'writeoff', a.writeoff,
      'close', a.close_q, 'scrap_new', a.scrap_new, 'scrap_back', a.scrap_back, 'scrap_end', a.scrap_end,
      'price', coalesce(a.price, m.price, 0), 'counted', k.counted, 'count_st', k.cst,
      'cdiff', case when k.counted is not null then k.counted - a.close_q end,
      'now', case when p_month = to_char(now() at time zone 'Asia/Riyadh','YYYY-MM') then (select qty from public.wo_custody w where w.holder = h and w.material_id = a.material_id) end)
      order by m.name), '[]'::jsonb)
    from agg a join public.wo_materials m on m.id = a.material_id left join cnt k on k.mid = a.material_id
   where a.open_q <> 0 or a.issued <> 0 or a.used_cus <> 0 or a.used_all <> 0 or a.returned <> 0 or a.writeoff <> 0 or a.scrap_new <> 0 or a.scrap_back <> 0 or a.scrap_end <> 0 or k.counted is not null $$;
revoke all on function public.fm_recon_lines(uuid,text) from public, anon, authenticated;

-- people with custody activity in the month (or a balance), with totals and the sign status
create or replace function public.fm_custody_recon_list(p_month text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare r record; L jsonb; out jsonb := '[]'::jsonb; t jsonb; rc public.wo_custody_recon;
begin
  if auth.uid() is null or public.fm_role() = 'pending' then raise exception 'not allowed'; end if;
  if p_month !~ '^\d{4}-\d{2}$' then raise exception 'invalid month'; end if;
  if not public.fm_mod('wh') then raise exception 'module disabled'; end if;
  for r in select p.id, p.full_name, public.fm_posx(p.role, p.job_title) title, p.regions from public.profiles p
            where (exists (select 1 from public.wo_custody_moves cm where cm.holder = p.id and cm.at < ((p_month || '-01')::date + interval '1 month')::timestamp at time zone 'Asia/Riyadh'))
              and public.fm_wh_sees_holder(p.id) order by p.full_name loop
    L := public.fm_recon_lines(r.id, p_month);
    if jsonb_array_length(L) = 0 then continue; end if;
    select jsonb_build_object('lines', jsonb_array_length(L),
      'issued_v', round(coalesce(sum((x->>'issued')::numeric * (x->>'price')::numeric),0),2),
      'used_v', round(coalesce(sum((x->>'used_cus')::numeric * (x->>'price')::numeric),0),2),
      'returned_v', round(coalesce(sum((x->>'returned')::numeric * (x->>'price')::numeric),0),2),
      'close_v', round(coalesce(sum((x->>'close')::numeric * (x->>'price')::numeric),0),2),
      'scrap_open', coalesce(sum((x->>'scrap_end')::numeric),0),
      'cdiff_n', count(*) filter (where x->>'cdiff' is not null and (x->>'cdiff')::numeric <> 0),
      'now_diff', count(*) filter (where x->>'now' is not null and (x->>'now')::numeric <> (x->>'close')::numeric),
      'counted', bool_or(x->>'counted' is not null)) into t from jsonb_array_elements(L) x;
    select * into rc from public.wo_custody_recon where holder = r.id and month = p_month;
    out := out || jsonb_build_object('holder', r.id, 'name', r.full_name, 'title', r.title, 'regions', to_jsonb(r.regions), 't', t, 'can_sign', public.fm_recon_can_sign(r.id),
      'recon', case when rc.id is null then null else jsonb_build_object('status', rc.status, 'note', rc.note, 'by', rc.by_name, 'at', rc.at) end);
  end loop;
  return out;
end $$;

create or replace function public.fm_custody_recon_get(p_holder uuid, p_month text) returns jsonb language plpgsql stable security definer set search_path = public as $$
declare rc public.wo_custody_recon;
begin
  if auth.uid() is null or not public.fm_wh_sees_holder(p_holder) then raise exception 'not allowed'; end if;
  if p_month !~ '^\d{4}-\d{2}$' then raise exception 'invalid month'; end if;
  select * into rc from public.wo_custody_recon where holder = p_holder and month = p_month;
  return jsonb_build_object('name', (select full_name from public.profiles where id = p_holder), 'lines', public.fm_recon_lines(p_holder, p_month),
    'can_sign', public.fm_recon_can_sign(p_holder),
    'recon', case when rc.id is null then null else jsonb_build_object('status', rc.status, 'note', rc.note, 'by', rc.by_name, 'at', rc.at, 'lines', rc.lines) end);
end $$;

create or replace function public.fm_custody_recon_sign(p_holder uuid, p_month text, p_ok boolean, p_note text default '') returns text
language plpgsql security definer set search_path = public as $$
declare L jsonb; nm text := public.fm_me_name(); t jsonb;
begin
  if not public.fm_recon_can_sign(p_holder) then raise exception 'not allowed'; end if;
  if p_month !~ '^\d{4}-\d{2}$' or p_month > to_char(now() at time zone 'Asia/Riyadh','YYYY-MM') then raise exception 'invalid month'; end if;
  if not coalesce(p_ok,false) and length(btrim(coalesce(p_note,''))) < 3 then raise exception 'note required'; end if;
  L := public.fm_recon_lines(p_holder, p_month);
  select jsonb_build_object('issued', sum((x->>'issued')::numeric), 'used', sum((x->>'used_cus')::numeric), 'returned', sum((x->>'returned')::numeric), 'close', sum((x->>'close')::numeric)) into t from jsonb_array_elements(L) x;
  insert into public.wo_custody_recon(holder, holder_name, month, status, note, lines, totals, by_id, by_name)
  values (p_holder, (select full_name from public.profiles where id = p_holder), p_month, case when p_ok then 'ok' else 'diff' end, left(nullif(btrim(coalesce(p_note,'')),''),1000), L, coalesce(t,'{}'), auth.uid(), nm)
  on conflict (holder, month) do update set status = excluded.status, note = excluded.note, lines = excluded.lines, totals = excluded.totals, by_id = excluded.by_id, by_name = excluded.by_name, at = now();
  begin perform public.fm_push_add(p_holder, 'wh_issued', case when p_ok then '✅ اعتُمدت مطابقة عهدتك لشهر ' else '⚠️ فروقات في مطابقة عهدتك لشهر ' end || p_month,
    concat_ws(' — ', nm, nullif(btrim(coalesce(p_note,'')),'')), 'cus', 'recon-' || p_month, false); exception when others then null; end;
  return case when p_ok then 'ok' else 'diff' end;
end $$;

revoke all on function public.fm_recon_can_sign(uuid), public.fm_custody_recon_list(text), public.fm_custody_recon_get(uuid,text), public.fm_custody_recon_sign(uuid,text,boolean,text) from public, anon;
grant execute on function public.fm_recon_can_sign(uuid), public.fm_custody_recon_list(text), public.fm_custody_recon_get(uuid,text), public.fm_custody_recon_sign(uuid,text,boolean,text) to authenticated;
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════════
-- Section 63 (V260): framework agreements with suppliers
-- An agreement fixes prices for a period with an optional value cap and per-item quantity caps. A purchase request
-- raised from it (fm_fa_order → fm_po_save with the agreement prices, no quotations) carries framework_id and still goes
-- through the normal approval (fm_po_act). Used = requests approved / partial / received (and requested, as reserved).
-- fm_v260_daily() (pg_cron fm-v260-daily 05:55 UTC): push wh_fa to the managers at 30 / 7 / 0 days before the end and
-- once when 80 % of the cap is used.
-- ═══════════════════════════════════════════════════════════════════════════
create sequence if not exists public.wo_fa_seq;
create table if not exists public.wo_frameworks (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null default ('FA-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_fa_seq')::text, 3, '0')),
  supplier_id uuid not null references public.wo_suppliers(id) on delete restrict,
  title       text not null,
  ref         text,
  regions     text[] not null default '{}',
  start_date  date not null,
  end_date    date not null,
  cap_value   numeric(14,2) not null default 0,
  lines       jsonb not null default '[]',   -- [{material_id, price, cap_qty}]
  status      text not null default 'active' check (status in ('active','ended','cancelled')),
  note        text,
  alerts      jsonb not null default '{}',
  by_id       uuid references public.profiles(id) on delete set null,
  by_name     text,
  at          timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
alter table public.wo_frameworks enable row level security;
revoke all on public.wo_frameworks from public, anon, authenticated;
alter table public.wo_purchase_requests add column if not exists framework_id uuid references public.wo_frameworks(id) on delete set null;

create or replace function public.fm_fa_can_edit() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_wh_admin() or public.fm_my_pos() in ('dept_manager','accountant'), false) $$;

-- internal: usage of an agreement
create or replace function public.fm_fa_used(f uuid) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'value', coalesce(sum(r.total) filter (where r.status in ('approved','partial','received')), 0),
    'pending', coalesce(sum(r.total) filter (where r.status = 'requested'), 0),
    'n', count(*) filter (where r.status not in ('rejected','cancelled')),
    'qty', coalesce((select jsonb_object_agg(k, q) from (select l->>'material_id' k, sum((l->>'qty')::numeric) q
        from public.wo_purchase_requests r2 cross join lateral jsonb_array_elements(r2.lines) l
       where r2.framework_id = f and r2.status not in ('rejected','cancelled') group by 1) z), '{}'::jsonb))
    from public.wo_purchase_requests r where r.framework_id = f and r.status not in ('rejected','cancelled') $$;
revoke all on function public.fm_fa_used(uuid) from public, anon, authenticated;

create or replace function public.fm_fa_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare id_ uuid := nullif(p->>'id','')::uuid; x jsonb; L jsonb := '[]'; s uuid := nullif(p->>'supplier_id','')::uuid; d1 date; d2 date; r public.wo_frameworks; pr numeric; cq numeric; seen text[] := '{}';
begin
  if auth.uid() is null or not public.fm_fa_can_edit() then raise exception 'not allowed'; end if;
  if not public.fm_mod('wh') then raise exception 'module disabled'; end if;
  if not exists (select 1 from public.wo_suppliers where id = s) then raise exception 'unknown supplier'; end if;
  if length(btrim(coalesce(p->>'title',''))) < 3 then raise exception 'title required'; end if;
  d1 := (p->>'start_date')::date; d2 := (p->>'end_date')::date;
  if d1 is null or d2 is null or d2 < d1 then raise exception 'invalid dates'; end if;
  if coalesce(nullif(p->>'cap_value','')::numeric,0) < 0 then raise exception 'invalid cap'; end if;
  for x in select * from jsonb_array_elements(coalesce(p->'lines','[]')) loop
    if not exists (select 1 from public.wo_materials where id = nullif(x->>'material_id','')::uuid and active) then raise exception 'unknown material'; end if;
    if (x->>'material_id') = any(seen) then raise exception 'duplicate material'; end if; seen := seen || (x->>'material_id');
    pr := nullif(x->>'price','')::numeric; if pr is null or pr <= 0 then raise exception 'invalid price'; end if;
    cq := coalesce(nullif(x->>'cap_qty','')::numeric,0); if cq < 0 then raise exception 'invalid qty'; end if;
    L := L || jsonb_build_object('material_id', x->>'material_id', 'price', round(pr,2), 'cap_qty', cq);
  end loop;
  if jsonb_array_length(L) = 0 or jsonb_array_length(L) > 500 then raise exception 'no lines'; end if;
  if id_ is null then
    insert into public.wo_frameworks(supplier_id, title, ref, regions, start_date, end_date, cap_value, lines, note, by_id, by_name)
    values (s, left(btrim(p->>'title'),200), left(nullif(btrim(coalesce(p->>'ref','')),''),100),
      coalesce((select array_agg(v) from jsonb_array_elements_text(case when jsonb_typeof(p->'regions') = 'array' then p->'regions' else '[]' end) v), '{}'),
      d1, d2, coalesce(nullif(p->>'cap_value','')::numeric,0), L, left(nullif(btrim(coalesce(p->>'note','')),''),1000), auth.uid(), public.fm_me_name()) returning * into r;
  else
    update public.wo_frameworks set supplier_id = s, title = left(btrim(p->>'title'),200), ref = left(nullif(btrim(coalesce(p->>'ref','')),''),100),
      regions = coalesce((select array_agg(v) from jsonb_array_elements_text(case when jsonb_typeof(p->'regions') = 'array' then p->'regions' else '[]' end) v), '{}'),
      start_date = d1, end_date = d2, cap_value = coalesce(nullif(p->>'cap_value','')::numeric,0), lines = L, note = left(nullif(btrim(coalesce(p->>'note','')),''),1000), updated_at = now()
     where id = id_ and status = 'active' returning * into r;
    if not found then raise exception 'invalid status'; end if;
  end if;
  return jsonb_build_object('id', r.id, 'code', r.code);
end $$;

create or replace function public.fm_fa_end(p_id uuid, p_cancel boolean default false, p_note text default '') returns text language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not public.fm_fa_can_edit() then raise exception 'not allowed'; end if;
  update public.wo_frameworks set status = case when p_cancel then 'cancelled' else 'ended' end, note = concat_ws(' — ', note, nullif(btrim(coalesce(p_note,'')),'')), updated_at = now()
   where id = p_id and status = 'active';
  if not found then raise exception 'invalid status'; end if;
  return 'ok';
end $$;

create or replace function public.fm_fa_list() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare today date := (now() at time zone 'Asia/Riyadh')::date;
begin
  if auth.uid() is null or public.fm_role() in ('pending') or public.fm_my_pos() in ('supervisor','contractor') then raise exception 'not allowed'; end if;
  return jsonb_build_object('can_edit', public.fm_fa_can_edit(), 'rows', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'code', f.code, 'title', f.title, 'ref', f.ref,
      'supplier_id', f.supplier_id, 'supplier', s.name, 'regions', to_jsonb(f.regions), 'start', f.start_date, 'end', f.end_date, 'cap', f.cap_value, 'lines', f.lines,
      'status', case when f.status = 'active' and f.end_date < today then 'expired' else f.status end, 'note', f.note, 'by', f.by_name, 'at', f.at,
      'days_left', f.end_date - today, 'used', public.fm_fa_used(f.id)) order by (f.status = 'active') desc, f.end_date)
    from public.wo_frameworks f left join public.wo_suppliers s on s.id = f.supplier_id
   where cardinality(f.regions) = 0 or public.fm_role() = 'admin' or public.fm_scope_all() or f.regions && public.fm_regions() or public.fm_my_pos() in ('accountant','owner_rep')), '[]'::jsonb));
end $$;

-- p {fa_id, store_id, lines:[{material_id, qty}], note}
create or replace function public.fm_fa_order(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare f public.wo_frameworks; st public.wo_stores; x jsonb; ln jsonb; L jsonb := '[]'; u jsonb; t numeric := 0; q numeric; res jsonb; today date := (now() at time zone 'Asia/Riyadh')::date;
begin
  select * into f from public.wo_frameworks where id = nullif(p->>'fa_id','')::uuid for update;
  if auth.uid() is null or not found then raise exception 'not found'; end if;
  if f.status <> 'active' or today < f.start_date or today > f.end_date then raise exception 'agreement not active'; end if;
  select * into st from public.wo_stores where id = nullif(p->>'store_id','')::uuid and active;
  if not found then raise exception 'not allowed'; end if;
  if cardinality(f.regions) > 0 and not (st.region = any(f.regions)) then raise exception 'region not covered'; end if;
  u := public.fm_fa_used(f.id);
  if jsonb_typeof(p->'lines') <> 'array' or jsonb_array_length(p->'lines') = 0 then raise exception 'no lines'; end if;
  for x in select * from jsonb_array_elements(p->'lines') loop
    ln := null;
    select fl.e into ln from jsonb_array_elements(f.lines) fl(e) where fl.e->>'material_id' = x->>'material_id';
    if ln is null then raise exception 'item not in agreement'; end if;
    q := nullif(x->>'qty','')::numeric; if q is null or q <= 0 then raise exception 'invalid qty'; end if;
    if coalesce((ln->>'cap_qty')::numeric,0) > 0 and coalesce((u->'qty'->>(x->>'material_id'))::numeric,0) + q > (ln->>'cap_qty')::numeric then
      raise exception 'quantity cap exceeded %', x->>'material_id'; end if;
    L := L || jsonb_build_object('material_id', x->>'material_id', 'qty', q, 'price', (ln->>'price')::numeric); t := t + q * (ln->>'price')::numeric;
  end loop;
  if f.cap_value > 0 and (u->>'value')::numeric + (u->>'pending')::numeric + t > f.cap_value then raise exception 'value cap exceeded'; end if;
  res := public.fm_po_save(jsonb_build_object('store_id', st.id, 'supplier_id', f.supplier_id, 'lines', L,
    'note', concat_ws(' — ', f.code || ' — اتفاقية إطارية: ' || f.title, nullif(btrim(coalesce(p->>'note','')),''))));
  update public.wo_purchase_requests set framework_id = f.id where id = (res->>'id')::uuid;
  return res || jsonb_build_object('total', round(t,2));
end $$;

create or replace function public.fm_v260_daily() returns int language plpgsql security definer set search_path = public as $$
declare f record; u uuid; n int := 0; today date := (now() at time zone 'Asia/Riyadh')::date; k text; used numeric; msg text; ev jsonb;
begin
  for f in select * from public.wo_frameworks where status = 'active' loop
    ev := '[]'::jsonb;
    if f.end_date - today in (30, 7, 0) and not (f.alerts ? ('end' || (f.end_date - today) || ':' || f.end_date)) then
      ev := ev || jsonb_build_object('k', 'end' || (f.end_date - today) || ':' || f.end_date, 'm', case when f.end_date = today then 'تنتهي اليوم' else 'تنتهي خلال ' || (f.end_date - today) || ' يوم' end);
    end if;
    if f.cap_value > 0 and not (f.alerts ? 'cap80') then
      used := (public.fm_fa_used(f.id)->>'value')::numeric;
      if used >= f.cap_value * 0.8 then ev := ev || jsonb_build_object('k', 'cap80', 'm', 'استُهلك ' || round(used / f.cap_value * 100) || '% من سقفها'); end if;
    end if;
    for k, msg in select e->>'k', e->>'m' from jsonb_array_elements(ev) e loop
      update public.wo_frameworks set alerts = alerts || jsonb_build_object(k, now()) where id = f.id;
      for u in select p.id from public.profiles p where p.active and public.fm_posx(p.role, p.job_title) in ('sysadmin','project_manager','ops_manager','accountant') loop
        begin perform public.fm_push_add(u, 'wh_fa', '📑 اتفاقية إطارية ' || f.code || ': ' || msg, f.title, 'wh=fa', 'fa-' || f.code || '-' || k, false); exception when others then null; end;
      end loop;
      n := n + 1;
    end loop;
  end loop;
  update public.wo_frameworks set status = 'ended', updated_at = now() where status = 'active' and end_date < today - 30;
  return n;
end $$;
revoke all on function public.fm_v260_daily() from public, anon, authenticated;
revoke all on function public.fm_fa_can_edit(), public.fm_fa_save(jsonb), public.fm_fa_end(uuid,boolean,text), public.fm_fa_list(), public.fm_fa_order(jsonb) from public, anon;
grant execute on function public.fm_fa_can_edit(), public.fm_fa_save(jsonb), public.fm_fa_end(uuid,boolean,text), public.fm_fa_list(), public.fm_fa_order(jsonb) to authenticated;
do $do$ begin
  begin execute 'select cron.unschedule(''fm-v260-daily'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-v260-daily'', ''55 5 * * *'', ''select public.fm_v260_daily()'')';
  exception when others then raise notice 'pg_cron is not available: framework agreement reminders are not pushed'; end;
end $do$;
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════════
-- Section 64 (V262): supplier portal (supplier.html?k=<64 hex>, no account)
-- One active private link per supplier. Through anon RPCs the supplier sees open quotation requests (wo_rfqs; all, or only
-- those that list him in `invited`), sends / updates his quotation (wo_rfq_quotes, by_name «المورد عبر البوابة»), follows
-- his purchase requests and framework agreements, and uploads invoices (wo_supplier_invoices) that the accountant / warehouse
-- accepts, rejects or marks paid. Staff: fm_supplier_link_make / _revoke / _list, fm_supplier_inv_list / _act.
-- ═══════════════════════════════════════════════════════════════════════════
alter table public.wo_rfqs add column if not exists invited uuid[] not null default '{}';
create table if not exists public.wo_supplier_links (
  token        text primary key check (token ~ '^[0-9a-f]{64}$'),
  supplier_id  uuid not null references public.wo_suppliers(id) on delete cascade,
  active       boolean not null default true,
  created_by   uuid default auth.uid() references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  last_used_at timestamptz,
  revoked_at   timestamptz
);
create unique index if not exists wo_supplier_links_one on public.wo_supplier_links (supplier_id) where active;
create sequence if not exists public.wo_sinv_seq;
create table if not exists public.wo_supplier_invoices (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null default ('SI-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.wo_sinv_seq')::text, 4, '0')),
  supplier_id  uuid not null references public.wo_suppliers(id) on delete cascade,
  po_id        uuid references public.wo_purchase_requests(id) on delete set null,
  po_code      text,
  invoice_no   text not null,
  invoice_date date,
  amount       numeric(14,2) not null check (amount > 0),
  vat          numeric(14,2),
  photo        text check (photo is null or length(photo) <= 560000),
  note         text,
  status       text not null default 'new' check (status in ('new','accepted','rejected','paid')),
  response     text,
  pay_ref      text,
  at           timestamptz not null default now(),
  dec_by       uuid references public.profiles(id) on delete set null,
  dec_name     text,
  dec_at       timestamptz
);
alter table public.wo_supplier_links enable row level security;
alter table public.wo_supplier_invoices enable row level security;
revoke all on public.wo_supplier_links, public.wo_supplier_invoices from public, anon, authenticated;

create or replace function public.fm_sup_staff() returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_wh_edit() or public.fm_my_pos() in ('accountant','dept_manager'), false) $$;
-- internal: token → supplier id (active link, active supplier); touches last_used_at
create or replace function public.fm_sup_token(p_token text) returns uuid language plpgsql security definer set search_path = public as $$
declare s uuid;
begin
  select l.supplier_id into s from public.wo_supplier_links l join public.wo_suppliers w on w.id = l.supplier_id
   where l.token = lower(coalesce(p_token,'')) and l.active and coalesce(w.active, true);
  if s is null then raise exception 'invalid link'; end if;
  update public.wo_supplier_links set last_used_at = now() where token = lower(p_token) and (last_used_at is null or last_used_at < now() - interval '5 minutes');
  return s;
end $$;
revoke all on function public.fm_sup_token(text) from public, anon, authenticated;

create or replace function public.fm_supplier_link_make(p_supplier uuid, p_renew boolean default false) returns text language plpgsql security definer set search_path = public as $$
declare t text;
begin
  if auth.uid() is null or not public.fm_sup_staff() then raise exception 'not allowed'; end if;
  if not exists (select 1 from public.wo_suppliers where id = p_supplier) then raise exception 'unknown supplier'; end if;
  if p_renew then update public.wo_supplier_links set active = false, revoked_at = now() where supplier_id = p_supplier and active; end if;
  select token into t from public.wo_supplier_links where supplier_id = p_supplier and active;
  if t is null then
    t := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
    insert into public.wo_supplier_links(token, supplier_id) values (t, p_supplier);
  end if;
  return t;
end $$;
create or replace function public.fm_supplier_link_revoke(p_supplier uuid) returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if auth.uid() is null or not public.fm_sup_staff() then raise exception 'not allowed'; end if;
  update public.wo_supplier_links set active = false, revoked_at = now() where supplier_id = p_supplier and active;
  get diagnostics n = row_count; return n;
end $$;
create or replace function public.fm_supplier_links_list() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('supplier_id', s.id, 'name', s.name, 'phone', s.phone, 'token', l.token, 'last_used', l.last_used_at, 'created', l.created_at,
      'inv_new', (select count(*) from public.wo_supplier_invoices i where i.supplier_id = s.id and i.status = 'new')) order by s.name), '[]'::jsonb)
    from public.wo_suppliers s left join public.wo_supplier_links l on l.supplier_id = s.id and l.active
   where auth.uid() is not null and public.fm_sup_staff() $$;

-- anon: everything the supplier sees
create or replace function public.fm_supplier_portal(p_token text) returns jsonb language plpgsql security definer set search_path = public as $$
declare s uuid; sp public.wo_suppliers;
begin
  s := public.fm_sup_token(p_token);
  select * into sp from public.wo_suppliers where id = s;
  return jsonb_build_object('state', 'ok', 'supplier', sp.name,
    'rfqs', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'code', r.code, 'at', r.at, 'due', r.due_date, 'note', r.note, 'region', r.region,
        'lines', (select jsonb_agg(jsonb_build_object('material_id', l->>'material_id', 'qty', (l->>'qty')::numeric, 'name', m.name, 'unit', m.unit, 'code', m.code, 'specs', m.specs))
                    from jsonb_array_elements(r.lines) l left join public.wo_materials m on m.id = (l->>'material_id')::uuid),
        'quote', (select jsonb_build_object('prices', q.prices, 'total', q.total, 'delivery_days', q.delivery_days, 'valid_until', q.valid_until, 'note', q.note, 'at', q.at)
                    from public.wo_rfq_quotes q where q.rfq_id = r.id and q.supplier_id = s)) order by r.at desc)
      from public.wo_rfqs r where r.status = 'open' and (cardinality(r.invited) = 0 or s = any(r.invited)) and (r.due_date is null or r.due_date >= (now() at time zone 'Asia/Riyadh')::date - 1)), '[]'::jsonb),
    'won', coalesce((select jsonb_agg(jsonb_build_object('code', r.code, 'po', r.po_code, 'at', r.decided_at) order by r.decided_at desc)
      from (select * from public.wo_rfqs where award_supplier_id = s and status = 'awarded' order by decided_at desc limit 20) r), '[]'::jsonb),
    'pos', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'code', p.code, 'at', p.at, 'status', p.status, 'total', p.total, 'received_at', p.received_at,
        'lines', (select jsonb_agg(jsonb_build_object('name', m.name, 'unit', m.unit, 'qty', (l->>'qty')::numeric, 'price', (l->>'price')::numeric, 'recv', coalesce((l->>'recv')::numeric,0)))
                    from jsonb_array_elements(p.lines) l left join public.wo_materials m on m.id = (l->>'material_id')::uuid),
        'inv', (select jsonb_agg(jsonb_build_object('code', i.code, 'status', i.status)) from public.wo_supplier_invoices i where i.po_id = p.id)) order by p.at desc)
      from (select * from public.wo_purchase_requests where supplier_id = s and status in ('approved','partial','received') order by at desc limit 60) p), '[]'::jsonb),
    'fas', coalesce((select jsonb_agg(jsonb_build_object('code', f.code, 'title', f.title, 'start', f.start_date, 'end', f.end_date, 'status', f.status, 'cap', f.cap_value, 'used', (public.fm_fa_used(f.id)->>'value')::numeric))
      from public.wo_frameworks f where f.supplier_id = s and f.status = 'active'), '[]'::jsonb),
    'invoices', coalesce((select jsonb_agg(jsonb_build_object('code', i.code, 'po', i.po_code, 'no', i.invoice_no, 'date', i.invoice_date, 'amount', i.amount, 'status', i.status, 'response', i.response, 'pay_ref', i.pay_ref, 'at', i.at) order by i.at desc)
      from (select * from public.wo_supplier_invoices where supplier_id = s order by at desc limit 60) i), '[]'::jsonb));
end $$;

-- anon: quotation p {prices:[{material_id, price}], delivery_days, valid_until, note, photo}
create or replace function public.fm_supplier_quote(p_token text, p_rfq uuid, p jsonb) returns numeric language plpgsql security definer set search_path = public as $$
declare s uuid; sp public.wo_suppliers; r public.wo_rfqs; ln jsonb; pr numeric; PQ jsonb := '[]'; t numeric := 0;
begin
  s := public.fm_sup_token(p_token);
  select * into sp from public.wo_suppliers where id = s;
  select * into r from public.wo_rfqs where id = p_rfq for update;
  if not found or r.status <> 'open' or not (cardinality(r.invited) = 0 or s = any(r.invited)) then raise exception 'not open'; end if;
  if length(coalesce(p->>'photo','')) > 420000 then raise exception 'photo too large'; end if;
  if nullif(p->>'photo','') is not null and (p->>'photo') !~ '^data:(image/(jpeg|png|webp)|application/pdf);base64,' then raise exception 'invalid photo'; end if;
  for ln in select * from jsonb_array_elements(r.lines) loop
    pr := (select nullif(e->>'price','')::numeric from jsonb_array_elements(case when jsonb_typeof(p->'prices') = 'array' then p->'prices' else '[]' end) z(e) where e->>'material_id' = ln->>'material_id' limit 1);
    if pr is not null and (pr < 0 or pr > 10000000) then raise exception 'invalid price'; end if;
    PQ := PQ || jsonb_build_object('material_id', ln->>'material_id', 'price', pr);
    t := t + coalesce(pr, 0) * (ln->>'qty')::numeric;
  end loop;
  if not exists(select 1 from jsonb_array_elements(PQ) e where e->>'price' is not null) then raise exception 'no prices'; end if;
  insert into public.wo_rfq_quotes(rfq_id, supplier_id, supplier_name, prices, total, delivery_days, valid_until, note, photo, by_name)
  values (r.id, s, sp.name, PQ, round(t,2), least(greatest(nullif(p->>'delivery_days','')::int,0),365), nullif(p->>'valid_until','')::date, left(nullif(btrim(coalesce(p->>'note','')),''),500), nullif(p->>'photo',''), 'المورد عبر البوابة')
  on conflict (rfq_id, supplier_id) do update set prices = excluded.prices, total = excluded.total, delivery_days = excluded.delivery_days,
    valid_until = excluded.valid_until, note = excluded.note, photo = coalesce(excluded.photo, public.wo_rfq_quotes.photo), at = now(), by_name = excluded.by_name;
  return round(t,2);
end $$;

-- anon: invoice p {po_id?, invoice_no, invoice_date, amount, vat?, photo, note}
create or replace function public.fm_supplier_invoice(p_token text, p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare s uuid; po public.wo_purchase_requests; i public.wo_supplier_invoices; a numeric := nullif(p->>'amount','')::numeric; u uuid; reg text;
begin
  s := public.fm_sup_token(p_token);
  if (select count(*) from public.wo_supplier_invoices where supplier_id = s and at > now() - interval '1 day') >= 20 then raise exception 'too many'; end if;
  if length(btrim(coalesce(p->>'invoice_no',''))) < 1 then raise exception 'invoice no required'; end if;
  if a is null or a <= 0 or a > 100000000 then raise exception 'invalid amount'; end if;
  if nullif(p->>'photo','') is null then raise exception 'photo required'; end if;
  if length(p->>'photo') > 560000 or (p->>'photo') !~ '^data:(image/(jpeg|png|webp)|application/pdf);base64,' then raise exception 'invalid photo'; end if;
  if nullif(p->>'po_id','') is not null then
    select * into po from public.wo_purchase_requests where id = (p->>'po_id')::uuid and supplier_id = s;
    if not found then raise exception 'unknown po'; end if;
    select region into reg from public.wo_stores where id = po.store_id;
  end if;
  if exists (select 1 from public.wo_supplier_invoices where supplier_id = s and lower(btrim(invoice_no)) = lower(btrim(p->>'invoice_no')) and status <> 'rejected') then raise exception 'duplicate invoice'; end if;
  insert into public.wo_supplier_invoices(supplier_id, po_id, po_code, invoice_no, invoice_date, amount, vat, photo, note)
  values (s, po.id, po.code, left(btrim(p->>'invoice_no'),60), nullif(p->>'invoice_date','')::date, round(a,2), nullif(p->>'vat','')::numeric, p->>'photo', left(nullif(btrim(coalesce(p->>'note','')),''),500)) returning * into i;
  begin
    for u in select p2.id from public.profiles p2 where p2.active and public.fm_posx(p2.role, p2.job_title) in ('accountant','project_manager') union select * from public.fm_wh_keepers_of(reg) loop
      perform public.fm_push_add(u, 'wh_inv', '🧾 فاتورة مورد جديدة ' || i.code, concat_ws(' — ', (select name from public.wo_suppliers where id = s), i.invoice_no, round(i.amount) || ' ر.س', i.po_code), 'wh=inv', 'sinv-' || i.code, false);
    end loop;
  exception when others then null; end;
  return jsonb_build_object('code', i.code);
end $$;

create or replace function public.fm_supplier_inv_list(p_days int default 180) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', i.id, 'code', i.code, 'supplier', s.name, 'supplier_id', i.supplier_id, 'po', i.po_code, 'po_id', i.po_id, 'po_total', p.total, 'po_status', p.status,
      'no', i.invoice_no, 'date', i.invoice_date, 'amount', i.amount, 'vat', i.vat, 'note', i.note, 'status', i.status, 'response', i.response, 'pay_ref', i.pay_ref, 'at', i.at,
      'dec', i.dec_name, 'dec_at', i.dec_at) order by (i.status = 'new') desc, i.at desc), '[]'::jsonb)
    from public.wo_supplier_invoices i join public.wo_suppliers s on s.id = i.supplier_id left join public.wo_purchase_requests p on p.id = i.po_id
   where auth.uid() is not null and public.fm_sup_staff() and i.at > now() - make_interval(days => least(greatest(coalesce(p_days,180),7),1100)) $$;
create or replace function public.fm_supplier_inv_photo(p_id uuid) returns text language sql stable security definer set search_path = public as $$
  select photo from public.wo_supplier_invoices where id = p_id and auth.uid() is not null and public.fm_sup_staff() $$;
create or replace function public.fm_supplier_inv_act(p_id uuid, p_action text, p_note text default '', p_ref text default '') returns text language plpgsql security definer set search_path = public as $$
declare i public.wo_supplier_invoices;
begin
  select * into i from public.wo_supplier_invoices where id = p_id for update;
  if auth.uid() is null or not found or not public.fm_sup_staff() then raise exception 'not allowed'; end if;
  if p_action = 'accept' and i.status = 'new' then update public.wo_supplier_invoices set status = 'accepted', response = nullif(btrim(coalesce(p_note,'')),''), dec_by = auth.uid(), dec_name = public.fm_me_name(), dec_at = now() where id = p_id;
  elsif p_action = 'reject' and i.status = 'new' then
    if length(btrim(coalesce(p_note,''))) < 3 then raise exception 'note required'; end if;
    update public.wo_supplier_invoices set status = 'rejected', response = btrim(p_note), dec_by = auth.uid(), dec_name = public.fm_me_name(), dec_at = now() where id = p_id;
  elsif p_action = 'paid' and i.status in ('new','accepted') then
    if not (public.fm_role() = 'admin' or public.fm_my_pos() in ('accountant','sysadmin')) then raise exception 'not allowed'; end if;
    update public.wo_supplier_invoices set status = 'paid', pay_ref = left(nullif(btrim(coalesce(p_ref,'')),''),100), response = coalesce(nullif(btrim(coalesce(p_note,'')),''), response), dec_by = auth.uid(), dec_name = public.fm_me_name(), dec_at = now() where id = p_id;
  else raise exception 'invalid status'; end if;
  return p_action;
end $$;

create or replace function public.fm_rfq_invite(p_rfq uuid, p_suppliers uuid[]) returns int language plpgsql security definer set search_path = public as $$
declare r public.wo_rfqs;
begin
  select * into r from public.wo_rfqs where id = p_rfq;
  if auth.uid() is null or not found or not (public.fm_stock_can(r.region) or public.fm_wh_keeper(r.store_id)) then raise exception 'not allowed'; end if;
  update public.wo_rfqs set invited = coalesce(p_suppliers, '{}') where id = p_rfq;
  return coalesce(cardinality(p_suppliers),0);
end $$;

revoke all on function public.fm_sup_staff(), public.fm_supplier_link_make(uuid,boolean), public.fm_supplier_link_revoke(uuid), public.fm_supplier_links_list(),
  public.fm_supplier_inv_list(int), public.fm_supplier_inv_photo(uuid), public.fm_supplier_inv_act(uuid,text,text,text), public.fm_rfq_invite(uuid,uuid[]),
  public.fm_supplier_portal(text), public.fm_supplier_quote(text,uuid,jsonb), public.fm_supplier_invoice(text,jsonb) from public;
grant execute on function public.fm_sup_staff(), public.fm_supplier_link_make(uuid,boolean), public.fm_supplier_link_revoke(uuid), public.fm_supplier_links_list(),
  public.fm_supplier_inv_list(int), public.fm_supplier_inv_photo(uuid), public.fm_supplier_inv_act(uuid,text,text,text), public.fm_rfq_invite(uuid,uuid[]) to authenticated;
grant execute on function public.fm_supplier_portal(text), public.fm_supplier_quote(text,uuid,jsonb), public.fm_supplier_invoice(text,jsonb) to anon, authenticated;
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════════
-- Section 65 (V263): approved alternative items
-- wo_material_alts: pairs (material, alt) kept in both directions; set by the warehouse (fm_wh_edit) per item with
-- fm_mat_alt_set(material, alts[], note) (replaces that item's list; both items must be active). Read by every signed-in
-- non-pending account (fm_mat_alts()). The apps suggest an alternative that has balance when the item runs out.
-- ═══════════════════════════════════════════════════════════════════════════
create table if not exists public.wo_material_alts (
  material_id uuid not null references public.wo_materials(id) on delete cascade,
  alt_id      uuid not null references public.wo_materials(id) on delete cascade,
  note        text,
  by_name     text,
  at          timestamptz not null default now(),
  primary key (material_id, alt_id),
  check (material_id <> alt_id)
);
alter table public.wo_material_alts enable row level security;
revoke all on public.wo_material_alts from public, anon, authenticated;

create or replace function public.fm_mat_alt_set(p_material uuid, p_alts uuid[], p_note text default '') returns int language plpgsql security definer set search_path = public as $$
declare a uuid; n int := 0; nm text := public.fm_me_name();
begin
  if auth.uid() is null or not public.fm_wh_edit() then raise exception 'not allowed'; end if;
  if not exists (select 1 from public.wo_materials where id = p_material and active) then raise exception 'unknown material'; end if;
  if coalesce(cardinality(p_alts),0) > 20 then raise exception 'too many'; end if;
  delete from public.wo_material_alts where (material_id = p_material and not (alt_id = any(coalesce(p_alts,'{}')))) or (alt_id = p_material and not (material_id = any(coalesce(p_alts,'{}'))));
  foreach a in array coalesce(p_alts,'{}') loop
    if a = p_material then continue; end if;
    if not exists (select 1 from public.wo_materials where id = a and active) then raise exception 'unknown material'; end if;
    insert into public.wo_material_alts(material_id, alt_id, note, by_name) values (p_material, a, left(nullif(btrim(coalesce(p_note,'')),''),200), nm)
      on conflict (material_id, alt_id) do update set note = excluded.note, by_name = excluded.by_name, at = now();
    insert into public.wo_material_alts(material_id, alt_id, note, by_name) values (a, p_material, left(nullif(btrim(coalesce(p_note,'')),''),200), nm)
      on conflict (material_id, alt_id) do update set note = excluded.note, by_name = excluded.by_name, at = now();
    n := n + 1;
  end loop;
  return n;
end $$;
create or replace function public.fm_mat_alts() returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('m', a.material_id, 'a', a.alt_id, 'note', a.note)), '[]'::jsonb)
    from public.wo_material_alts a join public.wo_materials x on x.id = a.alt_id and x.active
   where auth.uid() is not null and public.fm_role() <> 'pending' $$;
revoke all on function public.fm_mat_alt_set(uuid,uuid[],text), public.fm_mat_alts() from public, anon;
grant execute on function public.fm_mat_alt_set(uuid,uuid[],text), public.fm_mat_alts() to authenticated;
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════════
-- Section 66 (V264): overtime and night emergencies
-- fm_overtime: one row per piece of work outside the shift. The field app starts it (fm_ot_start, location) and ends it
-- (fm_ot_end, location → hours), or the person records it afterwards within 7 days (fm_ot_add, flagged manual).
-- The managers above the person (fm_is_under), project / ops managers, the area manager of his region and the system
-- admin approve, reject or adjust the hours (fm_ot_act); never their own. fm_ot_list(month) → own rows + rows they may see
-- (+ accountant / scope_all); the platform sums approved hours per person and kind for payroll.
-- ═══════════════════════════════════════════════════════════════════════════
create sequence if not exists public.fm_ot_seq;
create table if not exists public.fm_overtime (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null default ('OT-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.fm_ot_seq')::text, 5, '0')),
  user_id     uuid not null references public.profiles(id) on delete cascade,
  user_name   text,
  region      text,
  kind        text not null default 'after_hours' check (kind in ('after_hours','emergency','weekend','holiday')),
  reason      text not null,
  ticket_ref  text,
  wo_code     text,
  school      text,
  start_at    timestamptz not null,
  end_at      timestamptz,
  hours       numeric(6,2),
  month       text,
  manual      boolean not null default false,
  lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision,
  status      text not null default 'open' check (status in ('open','pending','approved','rejected')),
  appr_hours  numeric(6,2),
  dec_by      uuid references public.profiles(id) on delete set null,
  dec_name    text,
  dec_at      timestamptz,
  dec_note    text,
  at          timestamptz not null default now()
);
create unique index if not exists fm_overtime_open on public.fm_overtime (user_id) where status = 'open';
create index if not exists fm_overtime_m on public.fm_overtime (month, user_id);
alter table public.fm_overtime enable row level security;
revoke all on public.fm_overtime from public, anon, authenticated;

create or replace function public.fm_ot_dec_can(u uuid, reg text) returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and u is distinct from auth.uid() and (public.fm_role() = 'admin' or public.fm_my_pos() in ('sysadmin','project_manager','ops_manager')
    or public.fm_is_under(u, auth.uid()) or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(reg,'')))) $$;
create or replace function public.fm_ot_sees(u uuid, reg text) returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (u = auth.uid() or public.fm_ot_dec_can(u, reg) or public.fm_scope_all() or public.fm_my_pos() = 'accountant') $$;

-- internal: close a row with its hours and notify the line manager
create or replace function public.fm_ot_close(p_id uuid, p_end timestamptz, p_lat double precision, p_lng double precision) returns jsonb language plpgsql security definer set search_path = public as $$
declare r public.fm_overtime; h numeric; boss uuid;
begin
  select * into r from public.fm_overtime where id = p_id for update;
  if p_end <= r.start_at then raise exception 'invalid time'; end if;
  h := round(extract(epoch from (p_end - r.start_at)) / 3600.0, 2);
  if h > 16 then raise exception 'too long'; end if;
  update public.fm_overtime set end_at = p_end, hours = h, status = 'pending', lat2 = p_lat, lng2 = p_lng,
    month = to_char(r.start_at at time zone 'Asia/Riyadh','YYYY-MM') where id = p_id returning * into r;
  select reports_to into boss from public.profiles where id = r.user_id;
  begin
    if boss is not null then perform public.fm_push_add(boss, 'ot', '⏱️ عمل إضافي بانتظار اعتمادك ' || r.code, concat_ws(' — ', r.user_name, h || ' ساعة', r.reason), 'ot', 'ot-' || r.code, false); end if;
  exception when others then null; end;
  return jsonb_build_object('id', r.id, 'code', r.code, 'hours', h);
end $$;
revoke all on function public.fm_ot_close(uuid,timestamptz,double precision,double precision) from public, anon, authenticated;

-- p {kind, reason, ticket_ref, wo_code, school, lat, lng}
create or replace function public.fm_ot_start(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; r public.fm_overtime;
begin
  select * into me from public.profiles where id = auth.uid();
  if auth.uid() is null or me.id is null or not coalesce(me.active,true) or public.fm_role() in ('pending','viewer') then raise exception 'not allowed'; end if;
  if length(btrim(coalesce(p->>'reason',''))) < 3 then raise exception 'reason required'; end if;
  if exists (select 1 from public.fm_overtime where user_id = auth.uid() and status = 'open') then raise exception 'already open'; end if;
  insert into public.fm_overtime(user_id, user_name, region, kind, reason, ticket_ref, wo_code, school, start_at, lat1, lng1, month)
  values (auth.uid(), me.full_name, (me.regions)[1], coalesce(nullif(p->>'kind',''),'after_hours'), left(btrim(p->>'reason'),300), left(nullif(btrim(coalesce(p->>'ticket_ref','')),''),60),
    left(nullif(btrim(coalesce(p->>'wo_code','')),''),60), left(nullif(btrim(coalesce(p->>'school','')),''),200), now(), nullif(p->>'lat','')::float8, nullif(p->>'lng','')::float8,
    to_char(now() at time zone 'Asia/Riyadh','YYYY-MM')) returning * into r;
  return jsonb_build_object('id', r.id, 'code', r.code, 'start', r.start_at);
end $$;
create or replace function public.fm_ot_end(p_id uuid, p jsonb default '{}') returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (select 1 from public.fm_overtime where id = p_id and user_id = auth.uid() and status = 'open') then raise exception 'not found'; end if;
  if nullif(btrim(coalesce(p->>'note','')),'') is not null then update public.fm_overtime set reason = left(reason || ' — ' || btrim(p->>'note'),600) where id = p_id; end if;
  return public.fm_ot_close(p_id, now(), nullif(p->>'lat','')::float8, nullif(p->>'lng','')::float8);
end $$;
-- p {from, to, kind, reason, ticket_ref, wo_code, school}
create or replace function public.fm_ot_add(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare me public.profiles; r public.fm_overtime; a timestamptz := (p->>'from')::timestamptz; b timestamptz := (p->>'to')::timestamptz;
begin
  select * into me from public.profiles where id = auth.uid();
  if auth.uid() is null or me.id is null or public.fm_role() in ('pending','viewer') then raise exception 'not allowed'; end if;
  if length(btrim(coalesce(p->>'reason',''))) < 3 then raise exception 'reason required'; end if;
  if a is null or b is null or b <= a or b > now() + interval '10 minutes' or a < now() - interval '7 days' then raise exception 'invalid time'; end if;
  if exists (select 1 from public.fm_overtime where user_id = auth.uid() and status in ('pending','approved') and end_at > start_at and tstzrange(start_at, end_at) && tstzrange(a, b)) then raise exception 'overlap'; end if;
  insert into public.fm_overtime(user_id, user_name, region, kind, reason, ticket_ref, wo_code, school, start_at, manual, status, month)
  values (auth.uid(), me.full_name, (me.regions)[1], coalesce(nullif(p->>'kind',''),'after_hours'), left(btrim(p->>'reason'),300), left(nullif(btrim(coalesce(p->>'ticket_ref','')),''),60),
    left(nullif(btrim(coalesce(p->>'wo_code','')),''),60), left(nullif(btrim(coalesce(p->>'school','')),''),200), a, true, 'pending', to_char(a at time zone 'Asia/Riyadh','YYYY-MM')) returning * into r;
  return public.fm_ot_close(r.id, b, null, null);
end $$;
create or replace function public.fm_ot_cancel(p_id uuid) returns text language plpgsql security definer set search_path = public as $$
begin
  delete from public.fm_overtime where id = p_id and user_id = auth.uid() and status in ('open','pending');
  if not found then raise exception 'not found'; end if;
  return 'ok';
end $$;
create or replace function public.fm_ot_act(p_id uuid, p_action text, p_hours numeric default null, p_note text default '') returns text language plpgsql security definer set search_path = public as $$
declare r public.fm_overtime; h numeric;
begin
  select * into r from public.fm_overtime where id = p_id for update;
  if not found then raise exception 'not found'; end if;
  if not public.fm_ot_dec_can(r.user_id, r.region) then raise exception 'not allowed'; end if;
  if r.status not in ('pending','approved','rejected') then raise exception 'invalid status'; end if;
  if p_action = 'reject' and length(btrim(coalesce(p_note,''))) < 3 then raise exception 'note required'; end if;
  h := case when p_action = 'approve' then coalesce(p_hours, r.hours) end;
  if p_action = 'approve' and (h < 0 or h > r.hours) then raise exception 'invalid hours'; end if;
  if p_action = 'approve' and h < r.hours and length(btrim(coalesce(p_note,''))) < 3 then raise exception 'note required'; end if;
  if p_action not in ('approve','reject') then raise exception 'invalid action'; end if;
  update public.fm_overtime set status = case when p_action = 'approve' then 'approved' else 'rejected' end, appr_hours = h, dec_by = auth.uid(), dec_name = public.fm_me_name(), dec_at = now(),
    dec_note = left(nullif(btrim(coalesce(p_note,'')),''),300) where id = p_id;
  begin perform public.fm_push_add(r.user_id, 'ot', case when p_action = 'approve' then '✅ اعتُمد عملك الإضافي ' || r.code || ' (' || h || ' ساعة)' else '❌ لم يُعتمد عملك الإضافي ' || r.code end,
    concat_ws(' — ', public.fm_me_name(), nullif(btrim(coalesce(p_note,'')),'')), 'ot', 'ot-' || r.code, false); exception when others then null; end;
  return p_action;
end $$;
create or replace function public.fm_ot_list(p_month text) returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('me', auth.uid(), 'open', (select jsonb_build_object('id', id, 'code', code, 'start', start_at, 'kind', kind, 'reason', reason) from public.fm_overtime where user_id = auth.uid() and status = 'open'),
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', o.id, 'code', o.code, 'user', o.user_id, 'name', o.user_name, 'region', o.region, 'kind', o.kind, 'reason', o.reason,
        'ticket', o.ticket_ref, 'wo', o.wo_code, 'school', o.school, 'start', o.start_at, 'end', o.end_at, 'hours', o.hours, 'manual', o.manual, 'geo', o.lat1 is not null and o.lat2 is not null,
        'status', o.status, 'appr', o.appr_hours, 'dec', o.dec_name, 'dec_at', o.dec_at, 'note', o.dec_note, 'can', public.fm_ot_dec_can(o.user_id, o.region), 'mine', o.user_id = auth.uid())
        order by (o.status = 'pending') desc, o.start_at desc)
      from public.fm_overtime o where o.month = p_month and o.status <> 'open' and public.fm_ot_sees(o.user_id, o.region)), '[]'::jsonb))
   where auth.uid() is not null $$;
revoke all on function public.fm_ot_dec_can(uuid,text), public.fm_ot_sees(uuid,text), public.fm_ot_start(jsonb), public.fm_ot_end(uuid,jsonb), public.fm_ot_add(jsonb),
  public.fm_ot_cancel(uuid), public.fm_ot_act(uuid,text,numeric,text), public.fm_ot_list(text) from public, anon;
grant execute on function public.fm_ot_dec_can(uuid,text), public.fm_ot_sees(uuid,text), public.fm_ot_start(jsonb), public.fm_ot_end(uuid,jsonb), public.fm_ot_add(jsonb),
  public.fm_ot_cancel(uuid), public.fm_ot_act(uuid,text,numeric,text), public.fm_ot_list(text) to authenticated;
notify pgrst, 'reload schema';

-- ═══════════════════════════════════════════════════════════════════════════
-- Section 67 (V267): fm_my_school_db without a statement timeout
-- The section-17 version re-ran the «people under me» lookup (fm_is_under over every profile) for each of the ~2 300
-- school rows, so engineers / supervisors / contractors hit «canceling statement due to statement timeout» on the real
-- project and got no schools. The names and school codes are now computed once, then matched with = any(array).
-- Same rows as before.
-- ═══════════════════════════════════════════════════════════════════════════
create or replace function public.fm_my_school_db() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb; me uuid := auth.uid(); nm text[]; sc text[];
begin
  if me is null or public.fm_role() not in ('admin','manager','staff','viewer','engineer','supervisor','contractor') then return '[]'::jsonb; end if;
  select value into v from public.app_kv where key = 'fm_school_master_db_v1';
  if v is null then return '[]'::jsonb; end if;
  if jsonb_typeof(v) = 'string' then v := (v #>> '{}')::jsonb; end if;
  if jsonb_typeof(v) <> 'array' then return '[]'::jsonb; end if;
  if public.fm_role() in ('admin','manager','staff','viewer') then return v; end if;
  select coalesce(array_agg(distinct lower(btrim(n))), '{}') into nm
    from public.profiles p, unnest(coalesce(p.person_names,'{}') || coalesce(p.full_name,'')) n
   where (p.id = me or public.fm_is_under(p.id, me)) and btrim(n) <> '';
  select coalesce(array_agg(distinct a.school_code), '{}') into sc
    from public.fm_eng_assignments a where a.active and (a.user_id = me or public.fm_is_under(a.user_id, me));
  return coalesce((select jsonb_agg(r) from jsonb_array_elements(v) r
     where lower(btrim(r->>'supervisor')) = any(nm) or lower(btrim(r->>'engineer')) = any(nm) or lower(btrim(r->>'lightSupervisor')) = any(nm)
        or lower(btrim(r->>'lightEngineer')) = any(nm) or lower(btrim(r->>'contractor')) = any(nm)
        or regexp_replace(regexp_replace(upper(coalesce(r->>'buildingId','')), '^S[[:space:]-]*', ''), '[^A-Z0-9]', '', 'g') = any(sc)), '[]'::jsonb);
end $$;
revoke all on function public.fm_my_school_db() from public, anon;
grant execute on function public.fm_my_school_db() to authenticated;
notify pgrst, 'reload schema';

-- ---------- 68) per-person permissions on top of the job title (V268, start S12, field F77) ----------
-- profiles.perms = {add:[keys], deny:[keys], route: index | field | choose | ''}. The job title still gives the defaults
-- (fm_settings.cost_perms / cc_perms, the upload rule); add grants a key to this person, deny removes it. The system
-- admin (role admin / title sysadmin) always keeps everything. Written only by the system admin (profiles admin policy);
-- the person cannot change it (p_profiles_self). route overrides fm_settings.routes for this person.
alter table public.profiles add column if not exists perms jsonb not null default '{}'::jsonb;
create or replace function public.fm_perm_keys() returns text[] language sql immutable as $$
  select array['upload','cost_view','cost_entry','cost_budget','cc_view','cc_entry','cc_budget','cc_salaries','cc_revenue'] $$;
create or replace function public.fm_perms_ok(p jsonb) returns boolean language sql immutable as $$
  select jsonb_typeof(coalesce(p,'{}'::jsonb)) = 'object'
    and (p->'add' is null or (jsonb_typeof(p->'add') = 'array'
         and not exists (select 1 from jsonb_array_elements_text(p->'add') k where k <> all(public.fm_perm_keys()))))
    and (p->'deny' is null or (jsonb_typeof(p->'deny') = 'array'
         and not exists (select 1 from jsonb_array_elements_text(p->'deny') k where k <> all(public.fm_perm_keys()))))
    and coalesce(p->>'route','') in ('','index','field','choose') $$;
do $do$ begin
  alter table public.profiles add constraint profiles_perms_ok check (public.fm_perms_ok(perms));
exception when duplicate_object then null; end $do$;
drop policy if exists p_profiles_self on public.profiles;
create policy p_profiles_self on public.profiles for update using (id = auth.uid())
  with check (id = auth.uid() and role = (select role from public.profiles where id = auth.uid())
              and job_title is not distinct from (select job_title from public.profiles where id = auth.uid())
              and person_names = (select person_names from public.profiles where id = auth.uid())
              and regions = (select regions from public.profiles where id = auth.uid())
              and active = (select active from public.profiles where id = auth.uid())
              and reports_to is not distinct from (select reports_to from public.profiles where id = auth.uid())
              and full_name is not distinct from (select full_name from public.profiles where id = auth.uid())
              and emp_no is not distinct from (select emp_no from public.profiles where id = auth.uid())
              and personal = (select personal from public.profiles where id = auth.uid())
              and perms = (select perms from public.profiles where id = auth.uid()));
-- true = added, false = denied, null = follow the job title (inactive / expired plan: no override)
create or replace function public.fm_perm_x(k text) returns boolean language sql stable security definer set search_path = public as $$
  select case when public.fm_my_pos() is null then null
              when p.perms->'deny' ? k then false when p.perms->'add' ? k then true end
    from public.profiles p where p.id = auth.uid() $$;
-- any added cost / cc key implies seeing that area unless view is denied
create or replace function public.fm_perm_any(pfx text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_my_pos() is not null and exists (select 1 from public.profiles p, jsonb_array_elements_text(coalesce(p.perms->'add','[]')) k
    where p.id = auth.uid() and k like pfx || '%'), false) $$;

create or replace function public.fm_can_upload(r text) returns boolean language sql stable security definer set search_path = public as $$
  select public.fm_role() = 'admin' or coalesce(
    case public.fm_perm_x('upload') when false then false when true then public.fm_region_ok(coalesce(r,'')) end,
    coalesce(public.fm_my_pos() in ('project_manager','ops_manager'), false)
      or (public.fm_my_pos() = 'area_manager' and public.fm_region_ok(coalesce(r,'')))) $$;

create or replace function public.fm_cost_can(p_what text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin'
    or coalesce(public.fm_perm_x('cost_' || p_what),
         case when p_what = 'view' and public.fm_perm_any('cost_') then true end,
         public.fm_my_pos() in (select jsonb_array_elements_text(case when p_what = 'view'
           then coalesce(s.value->'view','[]') || coalesce(s.value->'entry','[]') || coalesce(s.value->'budget','[]')
           else coalesce(s.value->p_what,'[]') end)
         from public.fm_settings s where s.key = 'cost_perms')), false)
    and (p_what = 'view' or public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin' or public.fm_perm_x('cost_view') is distinct from false) $$;

create or replace function public.fm_cc_title(k text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_my_pos() = any(array(select jsonb_array_elements_text(coalesce(public.fm_setting('cc_perms')->k, '[]')))), false) $$;
create or replace function public.fm_cc_eff(k text) returns boolean language sql stable security definer set search_path = public as $$
  select case when k = 'view' then coalesce(public.fm_perm_x('cc_view'), case when public.fm_perm_any('cc_') then true end, public.fm_cc_title('view'))
              else coalesce(public.fm_perm_x('cc_' || k), public.fm_cc_title(k)) end $$;
create or replace function public.fm_cc_can(k text) returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(public.fm_role() = 'admin' or public.fm_my_pos() = 'sysadmin'
    or (public.fm_cc_eff(k) and public.fm_cc_eff('view')), false) $$;

revoke all on function public.fm_perm_x(text), public.fm_perm_any(text), public.fm_cc_title(text), public.fm_cc_eff(text) from public, anon;
grant execute on function public.fm_perm_x(text), public.fm_perm_any(text), public.fm_cc_title(text), public.fm_cc_eff(text), public.fm_perm_keys(), public.fm_perms_ok(jsonb) to authenticated;
notify pgrst, 'reload schema';

-- ---------- 69) notifications for new tickets, news and school requests (V271, field F78) ----------
-- Before, a new ticket from the uploaded file, a news item and a school-portal request did not notify anyone. Each trigger
-- is wrapped so a notification can never block the write. fm_push_add still skips the author, people without a device,
-- kinds turned off for the company / the person, and does nothing while fm_settings.push is off.
-- (1) new tickets: one summary per person per upload, only open tickets created in the last 3 days (a full re-upload of
--     old tickets after a reset notifies nobody). People = the supervisor / engineer / contractor names of the ticket matched
--     to accounts (full name / person_names), as fm_sla_people does.
create or replace function public.fm_push_tk_new() returns trigger language plpgsql security definer set search_path = public as $$
declare r record; n int; u int; one record;
begin
  begin
    if not coalesce((public.fm_setting('push')->>'enabled')::boolean, false) then return null; end if;
    for r in
      with t as (
        select x.region, x.ticket_id, x.school, x.priority, x.sub_category, x.supervisor, x.engineer, x.contractor
          from nt x
         where coalesce(x.created_at, x.uploaded_at) > now() - interval '3 days'
           and coalesce(x.status,'') !~* '(مغلق|تم الحل|تم حل|محلول|ملغ|مكتمل|closed|resolved|cancel|done|complete)'),
      who as (
        select p.id as uid, t.* from t, public.profiles p
         where p.active and public.fm_posx(p.role, p.job_title) is not null
           and exists (select 1 from unnest(array[nullif(btrim(coalesce(t.supervisor,'')),''), nullif(btrim(coalesce(t.engineer,'')),''),
                                                   nullif(btrim(coalesce(t.contractor,'')),'')]) nm(v)
                        where nm.v is not null and (nm.v = any(coalesce(p.person_names,'{}')) or btrim(coalesce(p.full_name,'')) = nm.v)))
      select uid, region, count(distinct ticket_id) as n,
             count(distinct ticket_id) filter (where coalesce(priority,'') ~* '(طارئ|حرج|عاجل|urgent|critical|emergency)') as u,
             min(ticket_id) as t1, min(school) as s1, min(coalesce(sub_category,'')) as c1
        from who group by uid, region
    loop
      perform public.fm_push_add(r.uid, 'tk_new',
        case when r.n = 1 then case when r.u > 0 then '🚨 بلاغ طارئ جديد' else '🎫 بلاغ جديد' end
             else '🎫 ' || r.n || ' بلاغات جديدة' || case when r.u > 0 then ' (منها ' || r.u || ' طارئ)' else '' end end,
        case when r.n = 1 then coalesce(r.s1,'') || case when r.c1 <> '' then ' — ' || r.c1 else '' end || ' • رقم ' || r.t1
             else 'منها ' || coalesce(r.s1,'') || ' — افتح قائمة البلاغات' end,
        'tknew', 'tknew-' || coalesce(r.region,''), false);
    end loop;
  exception when others then null; end;
  return null;
end $$;
drop trigger if exists fm_push_tk_new on public.tickets;
create trigger fm_push_tk_new after insert on public.tickets referencing new table as nt for each statement execute function public.fm_push_tk_new();

-- (2) news: everyone the item is meant for (titles, regions, team — the same rules as fm_news_for_me), when it starts now
create or replace function public.fm_push_news() returns trigger language plpgsql security definer set search_path = public as $$
declare p record;
begin
  begin
    if not new.active or new.start_at > now() + interval '5 minutes' or (new.end_at is not null and new.end_at <= now()) then return new; end if;
    if not coalesce((public.fm_setting('push')->>'enabled')::boolean, false) then return new; end if;
    for p in select x.id from public.profiles x
              where x.active and x.id <> new.author and public.fm_posx(x.role, x.job_title) is not null
                and (cardinality(new.titles) = 0 or public.fm_posx(x.role, x.job_title) = any(new.titles))
                and (cardinality(new.regions) = 0 or cardinality(coalesce(x.regions,'{}')) = 0 or coalesce(x.regions,'{}') && new.regions)
                and (new.scope <> 'team' or public.fm_is_under(x.id, new.author))
    loop
      perform public.fm_push_add(p.id, 'news',
        case new.priority when 'urgent' then '🚨 خبر عاجل' when 'important' then '⚠️ خبر مهم' else '📢 خبر جديد' end
          || coalesce(' — ' || nullif(new.author_name,''), ''),
        left(new.text, 280), 'news', 'news-' || new.id, false);
    end loop;
  exception when others then null; end;
  return new;
end $$;
drop trigger if exists fm_push_news on public.fm_news;
create trigger fm_push_news after insert on public.fm_news for each row execute function public.fm_push_news();

-- (3) a new school-portal request: the school's supervisor / engineer / light-services staff from the school DB (by building
--     key, else the name) and the area managers / engineers of its region
create or replace function public.fm_school_staff_ids(p_bkey text, p_name text, p_region text) returns uuid[] language plpgsql stable security definer set search_path = public as $$
declare v jsonb; nm text[]; ids uuid[];
begin
  select value into v from public.app_kv where key = 'fm_school_master_db_v1';
  if jsonb_typeof(v) = 'string' then v := (v #>> '{}')::jsonb; end if;
  if v is not null and jsonb_typeof(v) = 'array' then
    select coalesce(array_agg(distinct btrim(n)), '{}') into nm
      from jsonb_array_elements(v) e, unnest(array[e->>'supervisor', e->>'engineer', e->>'lightSupervisor', e->>'lightEngineer']) n
     where jsonb_typeof(e) = 'object' and btrim(coalesce(n,'')) <> ''
       and (public.fm_bkey(e->>'buildingId', e->>'school') = p_bkey or btrim(coalesce(e->>'school','')) = btrim(coalesce(p_name,'')));
  end if;
  select coalesce(array_agg(distinct p.id), '{}') into ids from public.profiles p
   where p.active and public.fm_posx(p.role, p.job_title) is not null
     and ((cardinality(coalesce(nm,'{}')) > 0 and (coalesce(p.person_names,'{}') && nm or btrim(coalesce(p.full_name,'')) = any(nm)))
          or p.id in (select public.fm_push_people(array['area_manager','area_engineer'], p_region)));
  return ids;
end $$;
create or replace function public.fm_push_sr_new() returns trigger language plpgsql security definer set search_path = public as $$
declare u uuid;
begin
  begin
    if not coalesce((public.fm_setting('push')->>'enabled')::boolean, false) then return new; end if;
    foreach u in array public.fm_school_staff_ids(new.bkey, new.school_name, new.region) loop
      perform public.fm_push_add(u, 'sr_new',
        case when new.urgency = 'urgent' then '🚨 طلب عاجل من مدرسة' else '🏫 طلب جديد من مدرسة' end,
        coalesce(new.school_name,'') || ' — ' || coalesce(new.category,'') || ': ' || left(coalesce(new.description,''), 160),
        'sr', 'sr-' || new.id, false);
    end loop;
  exception when others then null; end;
  return new;
end $$;
drop trigger if exists fm_push_sr_new on public.fm_school_requests;
create trigger fm_push_sr_new after insert on public.fm_school_requests for each row execute function public.fm_push_sr_new();
revoke all on function public.fm_push_tk_new(), public.fm_push_news(), public.fm_push_sr_new(), public.fm_school_staff_ids(text, text, text) from public, anon, authenticated;
notify pgrst, 'reload schema';

-- ---------- 70) push setup in one click + connection check (V272) ----------
-- The fm-push function can now read its two secrets from the database (service role only), so the system admin no longer
-- adds them in Supabase ← Edge Functions ← Secrets: fm_push_autoset saves the keys, the hook secret, the function URL and
-- turns notifications on in one call. Secrets set in Supabase (FM_PUSH_HOOK / VAPID_PRIVATE) still take precedence.
-- The kick keeps the id of its last request so fm_push_status can show what the function answered (404 not deployed,
-- 401 JWT check on, 403 hook mismatch, 500 with the message).
alter table public.fm_push_cfg add column if not exists vapid_private text;
alter table public.fm_push_cfg add column if not exists last_req bigint;
create or replace function public.fm_push_kick() returns void language plpgsql security definer set search_path = public as $$
declare c public.fm_push_cfg; rid bigint;
begin
  update public.fm_push_cfg set kicked_at = now() where id = 1 and fn_url is not null and coalesce(kicked_at, 'epoch') < now() - interval '3 seconds' returning * into c;
  if not found then return; end if;
  begin
    execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 20000)' into rid
      using c.fn_url, jsonb_build_object('Content-Type','application/json','x-fm-hook', coalesce(c.hook_secret,''))
                     || case when c.anon_key is not null then jsonb_build_object('Authorization','Bearer ' || c.anon_key, 'apikey', c.anon_key) else '{}'::jsonb end;
    update public.fm_push_cfg set last_req = rid where id = 1;
  exception when others then null;
  end;
end $$;
-- the function's secrets (service role only)
create or replace function public.fm_push_secrets() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('hook', hook_secret, 'vapid', vapid_private) from public.fm_push_cfg where id = 1 $$;
-- one-click setup by the system admin: p {vapid_public, vapid_private, hook_secret, fn_url, anon_key, subject}
create or replace function public.fm_push_autoset(p jsonb) returns boolean language plpgsql security definer set search_path = public as $$
declare s jsonb := coalesce(public.fm_setting('push'), '{}');
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed'; end if;
  if coalesce(p->>'vapid_public','') !~ '^[A-Za-z0-9_-]{80,100}$' or coalesce(p->>'vapid_private','') !~ '^[A-Za-z0-9_-]{40,50}$' then raise exception 'invalid keys'; end if;
  if length(coalesce(p->>'hook_secret','')) < 24 then raise exception 'secret too short'; end if;
  if coalesce(p->>'fn_url','') !~ '^https://[^ ]+$' then raise exception 'invalid url'; end if;
  insert into public.fm_push_cfg(id) values (1) on conflict do nothing;
  update public.fm_push_cfg set fn_url = p->>'fn_url', hook_secret = p->>'hook_secret', vapid_private = p->>'vapid_private',
    anon_key = coalesce(nullif(btrim(p->>'anon_key'),''), anon_key), kicked_at = null where id = 1;
  insert into public.fm_settings(key, value) values ('push', s || jsonb_build_object('enabled', true, 'vapid_public', p->>'vapid_public',
      'subject', coalesce(nullif(p->>'subject',''), s->>'subject', 'mailto:admin@rakizora.com')))
  on conflict (key) do update set value = excluded.value;
  return true;
end $$;
-- call the function now (admin) and return the request id; read the answer with fm_push_status a few seconds later
create or replace function public.fm_push_check() returns bigint language plpgsql security definer set search_path = public as $$
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed'; end if;
  update public.fm_push_cfg set kicked_at = null, last_req = null where id = 1;
  perform public.fm_push_kick();
  return (select last_req from public.fm_push_cfg where id = 1);
end $$;
create or replace function public.fm_push_status() returns jsonb language plpgsql stable security definer set search_path = public as $$
declare hs int; hc text; rid bigint;
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed'; end if;
  select last_req into rid from public.fm_push_cfg where id = 1;
  if rid is not null then
    begin
      execute 'select status_code, left(coalesce(content::text, error_msg, ''''), 300) from net._http_response where id = $1' into hs, hc using rid;
    exception when others then null; end;
  end if;
  return jsonb_build_object(
    'fn_url', (select fn_url from public.fm_push_cfg where id = 1), 'has_secret', (select hook_secret is not null from public.fm_push_cfg where id = 1),
    'has_anon', (select anon_key is not null from public.fm_push_cfg where id = 1),
    'has_vapid', (select vapid_private is not null from public.fm_push_cfg where id = 1),
    'pg_net', exists(select 1 from pg_extension where extname = 'pg_net'), 'pg_cron', exists(select 1 from pg_extension where extname = 'pg_cron'),
    'devices', (select count(*) from public.fm_push_subs), 'people', (select count(distinct user_id) from public.fm_push_subs),
    'waiting', (select count(*) from public.fm_push_queue where sent_at is null and tries < 5 and created_at > now() - interval '1 day'),
    'sent24', (select count(*) from public.fm_push_queue where sent_at > now() - interval '1 day'),
    'failed24', (select count(*) from public.fm_push_queue where sent_at is null and err is not null and created_at > now() - interval '1 day'),
    'last_err', (select err from public.fm_push_queue where err is not null order by id desc limit 1),
    'last_sent', (select max(sent_at) from public.fm_push_queue),
    'last_req', rid, 'http_status', hs, 'http_body', hc,
    'by_kind', coalesce((select jsonb_object_agg(kind, n) from (select kind, count(*) n from public.fm_push_queue where created_at > now() - interval '30 days' group by kind) k), '{}'));
end $$;
revoke all on function public.fm_push_secrets(), public.fm_push_kick() from public, anon, authenticated;
revoke all on function public.fm_push_autoset(jsonb), public.fm_push_check() from public, anon;
grant execute on function public.fm_push_autoset(jsonb), public.fm_push_check(), public.fm_push_status() to authenticated;
do $do$ begin
  execute 'grant execute on function public.fm_push_secrets() to service_role';
exception when undefined_object then null; end $do$;
notify pgrst, 'reload schema';

-- ---------- 71) edit and delete users (V274) ----------
-- The system admin changes a user's e-mail / phone and deletes accounts. An account that never signed in and has no
-- records is removed; any other account is archived (deleted_at, inactive, sign-in blocked) so its history stays intact.
alter table public.profiles add column if not exists deleted_at timestamptz;

create or replace function public.fm_admin_update_user(p_user uuid, p_email text, p_phone text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions, auth as $$
declare v_email text := lower(trim(coalesce(p_email,''))); v_old text; v_phone text := nullif(regexp_replace(coalesce(p_phone,''), '[^0-9+]', '', 'g'), '');
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed' using errcode = '42501'; end if;
  select email into v_old from auth.users where id = p_user;
  if not found then raise exception 'user not found'; end if;
  if v_email <> '' and v_email is distinct from lower(v_old) then
    if v_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then raise exception 'invalid email'; end if;
    if exists (select 1 from auth.users where lower(email) = v_email and id <> p_user) then raise exception 'User already registered'; end if;
    update auth.users set email = v_email, updated_at = now() where id = p_user;
    update auth.identities set identity_data = coalesce(identity_data,'{}'::jsonb) || jsonb_build_object('email', v_email), updated_at = now()
     where user_id = p_user and provider = 'email';
    update public.profiles set email = v_email, updated_at = now() where id = p_user;
  end if;
  if p_phone is not null then
    if v_phone is not null and v_phone ~ '^0?5[0-9]{8}$' then v_phone := '0' || right(v_phone, 9); end if;
    update public.profiles set phone = v_phone, updated_at = now() where id = p_user;
  end if;
  return jsonb_build_object('email', coalesce(nullif(v_email,''), v_old), 'phone', v_phone);
end $$;

create or replace function public.fm_admin_delete_user(p_user uuid) returns text
language plpgsql security definer set search_path = public, extensions, auth as $$
declare v_seen timestamptz;
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed' using errcode = '42501'; end if;
  if p_user = auth.uid() then raise exception 'cannot delete yourself'; end if;
  select last_sign_in_at into v_seen from auth.users where id = p_user;
  if not found then raise exception 'user not found'; end if;
  if v_seen is null then
    begin
      delete from auth.users where id = p_user;
      return 'deleted';
    exception when foreign_key_violation then null;
    end;
  end if;
  update public.profiles set deleted_at = now(), active = false, reports_to = null, updated_at = now() where id = p_user;
  update public.profiles set reports_to = null, updated_at = now() where reports_to = p_user;
  update auth.users set banned_until = 'infinity', updated_at = now() where id = p_user;
  return 'archived';
end $$;

create or replace function public.fm_admin_restore_user(p_user uuid) returns void
language plpgsql security definer set search_path = public, extensions, auth as $$
begin
  if public.fm_role() is distinct from 'admin' then raise exception 'not allowed' using errcode = '42501'; end if;
  update public.profiles set deleted_at = null, active = true, updated_at = now() where id = p_user;
  if not found then raise exception 'user not found'; end if;
  update auth.users set banned_until = null, updated_at = now() where id = p_user;
end $$;

revoke all on function public.fm_admin_update_user(uuid,text,text), public.fm_admin_delete_user(uuid), public.fm_admin_restore_user(uuid) from public, anon;
grant execute on function public.fm_admin_update_user(uuid,text,text), public.fm_admin_delete_user(uuid), public.fm_admin_restore_user(uuid) to authenticated;
notify pgrst, 'reload schema';

-- ---------- 72) work orders: the school's engineer approves item by item; an uncorrected return becomes a ticket (V275) ----------
-- approver = the school's engineer (from the school DB, chosen when the order is made); he sees the order, may add review photos,
-- and approves item by item («review»): rejected items carry rv {ok:false, note} and the order goes back to the assignee.
-- A returned order not corrected within fm_settings.wo_return.days becomes a ticket (fm_wo_return_run, hourly).
alter table public.work_orders add column if not exists approver      uuid references public.profiles(id) on delete set null;
alter table public.work_orders add column if not exists approver_name text;
alter table public.work_orders add column if not exists rv_round      int not null default 0;
alter table public.work_orders add column if not exists ret_at        timestamptz;
alter table public.work_orders add column if not exists ret_ticket    text;
create index if not exists work_orders_approver_idx on public.work_orders (approver, status);
alter table public.wo_photos drop constraint if exists wo_photos_kind_check;
alter table public.wo_photos add constraint wo_photos_kind_check check (kind in ('before','after','attach','arrival','invoice','review'));
insert into public.fm_settings(key, value) values ('wo_return', '{"enabled": true, "days": 3}') on conflict (key) do nothing;

create or replace function public.fm_wo_can_see(p_wo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.fm_role() <> 'pending' and exists (select 1 from public.work_orders w where w.id = p_wo
    and (w.created_by = auth.uid() or w.assignee = auth.uid() or w.approver = auth.uid() or public.fm_role() = 'admin' or public.fm_scope_region(w.region)
         or public.fm_is_under(w.assignee, auth.uid()) or public.fm_is_under(w.created_by, auth.uid()))) $$;
create or replace function public.fm_wo_party(p_wo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.fm_role() <> 'pending' and exists (select 1 from public.work_orders w where w.id = p_wo
    and (w.created_by = auth.uid() or w.assignee = auth.uid() or w.approver = auth.uid()) and w.status not in ('closed','cancelled')) $$;

-- engineers / managers who may approve: listed for the create dialog (names matched to the school DB in the browser)
create or replace function public.fm_wo_approvers() returns table(id uuid, full_name text, email text, person_names text[], regions text[], job_title text)
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.full_name, p.email), p.email, p.person_names, p.regions, public.fm_posx(p.role, p.job_title)
    from public.profiles p
   where public.fm_role() not in ('pending') and p.active and p.role in ('admin','manager','engineer') and p.deleted_at is null
   order by p.full_name $$;

create or replace function public.fm_wo_create_as(p_me uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles; t public.profiles; ap public.profiles; v_id uuid := gen_random_uuid(); v_code text;
begin
  select * into me from public.profiles where id = p_me;
  if me.id is null or not me.active or me.role not in ('admin','manager','staff','engineer','supervisor') then
    raise exception 'not allowed' using errcode = '42501'; end if;
  if coalesce(trim(p->>'title'),'') = '' then raise exception 'title required'; end if;
  select * into t from public.profiles where id = public.fm_uuid_or_null(p->>'assignee');
  if t.id is null or not public.fm_can_assign_as(me.id, t.id) then raise exception 'cannot assign to this user'; end if;
  -- V275: the school's engineer who approves the order (optional; else the creator approves as before)
  if public.fm_uuid_or_null(p->>'approver') is not null then
    select * into ap from public.profiles where id = public.fm_uuid_or_null(p->>'approver');
    if ap.id is null or not ap.active or ap.role not in ('admin','manager','engineer') then raise exception 'invalid approver'; end if;
  end if;
  v_code := 'WO-' || to_char(now(),'YYYY') || '-' || lpad(nextval('public.wo_seq')::text, 4, '0');
  insert into public.work_orders (id, code, title, description, type, region, school, priority, due_at, checklist, ticket_refs,
                                  created_by, created_by_name, assignee, assignee_name, batch_id, batch_title, building_id, approver, approver_name)
  values (v_id, v_code, trim(p->>'title'), nullif(trim(p->>'description'),''), coalesce(nullif(p->>'type',''),'task'),
          nullif(p->>'region',''), nullif(trim(p->>'school'),''), coalesce(nullif(p->>'priority',''),'متوسط'),
          nullif(p->>'due_at','')::timestamptz,
          case when jsonb_typeof(p->'checklist') = 'array' then p->'checklist' else '[]'::jsonb end,
          case when jsonb_typeof(p->'ticket_refs') = 'array' then array(select jsonb_array_elements_text(p->'ticket_refs')) else '{}' end,
          me.id, coalesce(me.full_name, me.email), t.id, coalesce(t.full_name, t.email),
          public.fm_uuid_or_null(p->>'batch_id'), nullif(trim(p->>'batch_title'),''), nullif(trim(p->>'building_id'),''),
          ap.id, case when ap.id is not null then coalesce(ap.full_name, ap.email) end);
  insert into public.wo_events (wo_id, by_id, by_name, type, status, text)
  values (v_id, me.id, coalesce(me.full_name, me.email), 'create', 'assigned',
          case when p->>'schedule' is not null then '🔁 أُنشئ تلقائياً (حملة متكررة) وأُسند إلى ' else '📝 أُنشئ الأمر وأُسند إلى ' end || coalesce(t.full_name, t.email));
  return v_id;
end $$;

create or replace function public.fm_wo_act(p_id uuid, p_action text, p_note text default null, p_geo jsonb default null, p_data jsonb default null)
returns text language plpgsql security definer set search_path = public as $$
declare w public.work_orders; me public.profiles; t public.profiles; nm text; isA boolean; isC boolean; ns text; msg text; it jsonb; i int;
  rj jsonb; nrej int := 0; cl jsonb; rv jsonb; evt text; isR boolean;
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
  -- V275: the approver (the school's engineer) may review / close / return, nothing else
  isR := isC or w.approver = me.id;
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
  -- V275: item-by-item review. Every item is approved unless listed in p_data.items with ok = false (a note is required);
  -- any rejected item returns the order to the assignee, otherwise it closes like «close».
  elsif p_action = 'review' and isR and w.status = 'done' then
    rj := coalesce((select jsonb_object_agg(x->>'i', x) from jsonb_array_elements(case when jsonb_typeof(p_data->'items') = 'array' then p_data->'items' else '[]'::jsonb end) x
                    where coalesce((x->>'ok')::boolean, true) = false), '{}'::jsonb);
    cl := '[]'::jsonb;
    for it, i in select e, (o - 1)::int from jsonb_array_elements(coalesce(w.checklist,'[]'::jsonb)) with ordinality as t(e, o) loop
      if rj ? i::text then
        if length(trim(coalesce(rj->i::text->>'note',''))) < 3 then raise exception 'item note required: %', i + 1; end if;
        rv := jsonb_build_object('ok', false, 'note', trim(rj->i::text->>'note'), 'by', nm, 'at', now(), 'round', w.rv_round + 1);
        nrej := nrej + 1;
      else
        rv := jsonb_build_object('ok', true, 'by', nm, 'at', now(), 'round', w.rv_round + 1)
              || case when it->'rv'->>'ok' = 'false' then jsonb_build_object('prev', it->'rv'->>'note') else '{}'::jsonb end;
      end if;
      cl := cl || jsonb_build_array(it || jsonb_build_object('rv', rv));
    end loop;
    if nrej < (select count(*) from jsonb_object_keys(rj)) then raise exception 'unknown item'; end if;
    if nrej > 0 then
      update public.work_orders set checklist = cl, rv_round = w.rv_round + 1, ret_at = now() where id = w.id;
      ns := 'returned'; evt := 'return';
      msg := '↩️ لم يُعتمد ' || nrej || ' من ' || jsonb_array_length(cl) || ' بند — أُعيد للتصحيح';
    else
      if public.fm_wo_spend_rank(w.checklist) > greatest(public.fm_prank(public.fm_posx(me.role, me.job_title)),
           coalesce((select max(public.fm_prank(public.fm_posx(pr.role, pr.job_title))) from public.fm_deputies d join public.profiles pr on pr.id = d.principal
                      where d.deputy = me.id and d.active and now() between d.from_at and d.to_at), 0)) then
        raise exception 'spend approval required: %', case public.fm_wo_spend_rank(w.checklist) when 6 then 'ops_manager' else 'area_manager' end;
      end if;
      update public.work_orders set checklist = cl, rv_round = w.rv_round + 1 where id = w.id;
      ns := 'closed'; evt := 'close'; msg := '🔒 اعتُمدت كل البنود وأُغلق الأمر';
    end if;
  elsif p_action = 'close' and isR and w.status = 'done' then
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
  elsif p_action = 'return' and isR and w.status = 'done' then
    if note is null then raise exception 'reason required'; end if; update public.work_orders set ret_at = now() where id = w.id; ns := 'returned'; msg := '↩️ أعاد الأمر للتصحيح';
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
  values (w.id, me.id, nm, coalesce(evt, p_action), ns, msg || coalesce(' — ' || note, ''), p_geo);
  return ns;
end $$;

create or replace function public.fm_push_wo_ev() returns trigger language plpgsql security definer set search_path = public as $$
declare w public.work_orders; h text; t text; b text;
begin
  select * into w from public.work_orders where id = new.wo_id;
  if not found then return null; end if;
  h := 'wo=' || w.id; t := coalesce(w.code,'');
  b := w.title || coalesce(' — ' || w.school, '');
  if new.type in ('create','reassign','deputy') then
    if w.batch_id is not null and new.type = 'create' then
      perform public.fm_push_add(w.assignee, 'wo_new', '🛠️ أوامر عمل جديدة: ' || coalesce(w.batch_title, 'حملة'), 'أُسندت إليك أوامر في الحملة — افتح «الأوامر»', 'wo', 'batch-' || w.batch_id);
    else
      perform public.fm_push_add(w.assignee, 'wo_new', '🛠️ أمر عمل جديد ' || t, b, h, 'wo-' || w.id);
    end if;
  elsif new.type = 'done' then
    perform public.fm_push_add(coalesce(w.approver, w.created_by), 'wo_done', '✅ أمر بانتظار اعتمادك ' || t, b || ' — ' || coalesce(w.assignee_name,''), h, 'wo-' || w.id);
  elsif new.type = 'reject' then
    perform public.fm_push_add(w.created_by, 'wo_done', '❌ رُفض أمر العمل ' || t, coalesce(new.text, b), h, 'wo-' || w.id);
  elsif new.type = 'return' then
    perform public.fm_push_add(w.assignee, 'wo_return', '↩️ أُعيد إليك أمر العمل ' || t, coalesce(new.text, b), h, 'wo-' || w.id);
  elsif new.type = 'close' then
    perform public.fm_push_add(w.assignee, 'wo_closed', '🎉 اعتُمد أمر العمل ' || t, b, h, 'wo-' || w.id);
    -- V275: the creator gets the report of an order approved by someone else (the school's engineer)
    if new.by_id is distinct from w.created_by then
      perform public.fm_push_add(w.created_by, 'wo_closed', '📄 تقرير أمر العمل ' || t || ' — اعتمده ' || coalesce(new.by_name,''), b, h, 'wo-' || w.id);
    end if;
  elsif new.type = 'ticket' then
    perform public.fm_push_add(w.assignee, 'wo_return', '🎫 تحوّل أمر العمل ' || t || ' إلى بلاغ', coalesce(new.text, b), h, 'wo-' || w.id);
    perform public.fm_push_add(w.created_by, 'wo_return', '🎫 تحوّل أمر العمل ' || t || ' إلى بلاغ', coalesce(new.text, b), h, 'wo-' || w.id);
    if w.approver is not null and w.approver <> w.created_by then
      perform public.fm_push_add(w.approver, 'wo_return', '🎫 تحوّل أمر العمل ' || t || ' إلى بلاغ', coalesce(new.text, b), h, 'wo-' || w.id);
    end if;
  elsif new.type = 'escalate' then
    perform public.fm_push_add(w.esc_to, 'wo_esc', '⏫ تصعيد أمر متأخر ' || t, coalesce(new.text, b), h, 'esc-' || w.id);
  elsif new.type = 'stop' then
    perform public.fm_push_add(w.assignee, 'wo_stop', '⛔ إيقاف العمل في ' || t, coalesce(new.text, b), h, 'wo-' || w.id);
    perform public.fm_push_add(w.created_by, 'wo_stop', '⛔ إيقاف العمل في ' || t, coalesce(new.text, b), h, 'wo-' || w.id);
  end if;
  return null;
exception when others then return null;   -- a notification never blocks the work
end $$;

-- a returned order not corrected in time becomes a ticket of its region (the newest ticket's columns are the template)
create or replace function public.fm_wo_ticket_raw(tpl jsonb, v jsonb) returns jsonb
language plpgsql immutable as $$
declare k text; r jsonb := '{}'; used text[] := '{}'; f text;
begin
  if tpl is null or jsonb_typeof(tpl) <> 'object' or tpl = '{}'::jsonb then
    return jsonb_build_object('رقم البلاغ', v->>'id', 'اسم المدرسة', v->>'school', 'الرقم الوزاري', v->>'bid', 'الحالة', v->>'status',
      'الأولوية', v->>'priority', 'تاريخ البلاغ', v->>'created', 'الوصف', v->>'desc', 'التصنيف', v->>'cat', 'التصنيف الفرعي', v->>'sub',
      'المشرف', v->>'sup', 'المهندس', v->>'eng');
  end if;
  for k in select jsonb_object_keys(tpl) loop
    f := case
      when k ~* '(رقم|ر\.)\s*(ال)?(بلاغ|طلب)|ticket|^\s*id\s*$' and not ('id' = any(used)) then 'id'
      when k ~* 'وزار|رقم\s*المبن|كود\s*المبن|building' and not ('bid' = any(used)) then 'bid'
      when k ~* 'مدرس|اسم\s*المبن|school|الموقع' and not ('school' = any(used)) then 'school'
      when k ~* 'حال|status' and not ('status' = any(used)) then 'status'
      when k ~* '[أا]ولوي|priority' and not ('priority' = any(used)) then 'priority'
      when k ~* 'تاريخ|date|created' and k !~* 'إغلاق|اغلاق|حل|إنجاز|انجاز|close|resol' and not ('created' = any(used)) then 'created'
      when k ~* 'وصف|تفاصيل|description' and not ('desc' = any(used)) then 'desc'
      when k ~* 'فرعي|sub' and not ('sub' = any(used)) then 'sub'
      when k ~* 'تصنيف|فئة|category' and not ('cat' = any(used)) then 'cat'
      when k ~* 'مشرف|supervisor' and not ('sup' = any(used)) then 'sup'
      when k ~* 'مهندس|engineer' and not ('eng' = any(used)) then 'eng'
      when k ~* 'مقاول|contractor' and not ('con' = any(used)) then 'con'
      else null end;
    if f is not null then used := used || f; end if;
    r := r || jsonb_build_object(k, coalesce(v->>f, ''));
  end loop;
  if not ('id' = any(used)) then r := r || jsonb_build_object('رقم البلاغ', v->>'id'); end if;
  if not ('desc' = any(used)) then r := r || jsonb_build_object('الوصف', v->>'desc'); end if;
  return r;
end $$;

create or replace function public.fm_wo_return_run() returns int
language plpgsql security definer set search_path = public as $$
declare cfg jsonb := coalesce((select value from public.fm_settings where key = 'wo_return'), '{}');
  d numeric := greatest(coalesce(nullif(cfg->>'days','')::numeric, 3), 0.04); w public.work_orders; tid text; tpl jsonb; n int := 0;
  sup text; eng text; con text; v jsonb; dsc text;
begin
  if coalesce((cfg->>'enabled')::boolean, true) = false then return 0; end if;
  for w in select * from public.work_orders where status = 'returned' and ret_ticket is null and ret_at is not null
             and ret_at < now() - make_interval(secs => (d * 86400)::int) and region is not null
           order by ret_at limit 200 for update skip locked loop
    begin
      tid := 'WO-R-' || coalesce(regexp_replace(w.code, '^WO-', ''), left(w.id::text, 8));
      select raw into tpl from public.tickets where region = w.region order by uploaded_at desc limit 1;
      select t.supervisor, t.engineer, t.contractor into sup, eng, con from public.tickets t
       where t.region = w.region and ((w.building_id is not null and t.building_id = w.building_id) or t.school = w.school)
       order by t.uploaded_at desc limit 1;
      dsc := 'أمر العمل ' || coalesce(w.code,'') || ' (' || w.title || ') أُعيد للتصحيح ولم يُصحَّح خلال ' || d || ' يوم'
             || coalesce(': ' || (select string_agg((o)::text || ') ' || (e->>'t') || ' — ' || (e->'rv'->>'note'), ' • ')
                                  from jsonb_array_elements(w.checklist) with ordinality x(e, o) where e->'rv'->>'ok' = 'false'), '');
      v := jsonb_build_object('id', tid, 'school', w.school, 'bid', w.building_id, 'status', 'مفتوح', 'priority', w.priority,
             'created', to_char(now() at time zone 'Asia/Riyadh', 'YYYY-MM-DD HH24:MI'), 'desc', dsc,
             'cat', 'أوامر العمل', 'sub', 'أمر عمل مرتجع لم يُصحَّح', 'sup', coalesce(sup, w.assignee_name), 'eng', coalesce(eng, w.approver_name), 'con', con);
      insert into public.tickets (region, ticket_id, school, building_id, supervisor, engineer, contractor, priority, sub_category, status, created_at, raw, uploaded_by)
      values (w.region, tid, w.school, w.building_id, coalesce(sup, w.assignee_name), coalesce(eng, w.approver_name), con, w.priority,
              'أمر عمل مرتجع لم يُصحَّح', 'مفتوح', now(), public.fm_wo_ticket_raw(tpl, v), w.created_by)
      on conflict (region, ticket_id) do nothing;
      update public.work_orders set ret_ticket = tid, ticket_refs = case when tid = any(ticket_refs) then ticket_refs else ticket_refs || tid end,
             updated_at = now() where id = w.id;
      insert into public.wo_events (wo_id, by_id, by_name, type, status, text)
      values (w.id, null, 'النظام', 'ticket', w.status, '🎫 لم يُصحَّح خلال ' || d || ' يوم — أُنشئ البلاغ ' || tid);
      n := n + 1;
    exception when others then
      raise notice 'fm_wo_return_run %: %', w.code, sqlerrm;
    end;
  end loop;
  return n;
end $$;
-- the platform calls this once when it opens (any signed-in account; it only acts on overdue returned orders)
create or replace function public.fm_wo_return_check() returns int
language sql security definer set search_path = public as $$
  select case when public.fm_role() in ('admin','manager','engineer','staff') then public.fm_wo_return_run() else 0 end $$;
revoke all on function public.fm_wo_return_run(), public.fm_wo_ticket_raw(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.fm_wo_approvers(), public.fm_wo_return_check() from public, anon;
grant execute on function public.fm_wo_approvers(), public.fm_wo_return_check() to authenticated;
do $do$ begin
  begin execute 'select cron.unschedule(''fm-wo-return'')'; exception when others then null; end;
  begin execute 'select cron.schedule(''fm-wo-return'', ''17 * * * *'', ''select public.fm_wo_return_run()'')';
  exception when others then raise notice 'pg_cron is not available: returned orders become tickets when the platform opens'; end;
end $do$;
notify pgrst, 'reload schema';

-- ---------- 73) work-order photos: «before» required, «after» optional, only the school sign on arrival (V276) ----------
-- fm_settings.wo_photos {before: all (every item with a result) | issues (only items that need / had a repair), defer: true}
-- «defer» only tells the field app to keep item photos on the phone until «تم الإجراء».
insert into public.fm_settings(key, value) values ('wo_photos', '{"before": "all", "defer": true}') on conflict (key) do nothing;

create or replace function public.fm_wo_act(p_id uuid, p_action text, p_note text default null, p_geo jsonb default null, p_data jsonb default null)
returns text language plpgsql security definer set search_path = public as $$
declare w public.work_orders; me public.profiles; t public.profiles; nm text; isA boolean; isC boolean; ns text; msg text; it jsonb; i int;
  rj jsonb; nrej int := 0; cl jsonb; rv jsonb; evt text; isR boolean;
  ball boolean := coalesce((select value->>'before' from public.fm_settings where key = 'wo_photos'), 'all') <> 'issues';
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
  -- V275: the approver (the school's engineer) may review / close / return, nothing else
  isR := isC or w.approver = me.id;
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
    -- V276: «after» photos are optional; «before» photos are required (every item with a result, or one for an order without items)
    if ball and jsonb_array_length(case when jsonb_typeof(p_data) = 'array' then p_data else coalesce(w.checklist,'[]'::jsonb) end) = 0
       and not exists (select 1 from public.wo_photos where wo_id = w.id and kind = 'before') then raise exception 'before photo required'; end if;
    -- V148: a school order needs the three arrival photos; a repaired item needs materials and before / after photos,
    -- an item that still needs repair needs a before photo
    -- V276: only the school sign is required on arrival (entrance / fence / extra photos are optional)
    if w.school is not null and not exists (select 1 from public.wo_photos where wo_id = w.id and kind = 'arrival' and tag = 'sign') then
      raise exception 'arrival photos required'; end if;
    for it, i in select e, (o - 1)::int from jsonb_array_elements(case when jsonb_typeof(p_data) = 'array' then p_data else w.checklist end) with ordinality as t(e, o) loop
      if it->>'res' = 'fixed' and (jsonb_typeof(it->'materials') is distinct from 'array' or jsonb_array_length(it->'materials') = 0
          or not exists (select 1 from public.wo_photos where wo_id = w.id and item = i and kind = 'before')) then
        raise exception 'item documentation required: %', i + 1; end if;
      -- V149: a purchased material needs its unit price and an invoice photo on the item
      if it->>'res' = 'fixed' and exists (select 1 from jsonb_array_elements(it->'materials') m where m->>'src' = 'buy') and (
          exists (select 1 from jsonb_array_elements(it->'materials') m where m->>'src' = 'buy'
                    and coalesce(nullif(regexp_replace(m->>'price', '[^0-9.]', '', 'g'), '')::numeric, 0) <= 0)
          or not exists (select 1 from public.wo_photos where wo_id = w.id and item = i and kind = 'invoice')) then
        raise exception 'invoice required: %', i + 1; end if;
      if (it->>'res' = 'fix' or (ball and it->>'res' = 'ok' and coalesce(it->>'k','grade') = 'grade'))
         and not exists (select 1 from public.wo_photos where wo_id = w.id and item = i and kind = 'before') then
        raise exception 'item documentation required: %', i + 1; end if;
    end loop;
    if jsonb_typeof(p_data) = 'array' then update public.work_orders set checklist = p_data where id = w.id; end if;
    ns := 'done'; msg := '📨 أبلغ: تم الإجراء — بانتظار الاعتماد';
  -- V275: item-by-item review. Every item is approved unless listed in p_data.items with ok = false (a note is required);
  -- any rejected item returns the order to the assignee, otherwise it closes like «close».
  elsif p_action = 'review' and isR and w.status = 'done' then
    rj := coalesce((select jsonb_object_agg(x->>'i', x) from jsonb_array_elements(case when jsonb_typeof(p_data->'items') = 'array' then p_data->'items' else '[]'::jsonb end) x
                    where coalesce((x->>'ok')::boolean, true) = false), '{}'::jsonb);
    cl := '[]'::jsonb;
    for it, i in select e, (o - 1)::int from jsonb_array_elements(coalesce(w.checklist,'[]'::jsonb)) with ordinality as t(e, o) loop
      if rj ? i::text then
        if length(trim(coalesce(rj->i::text->>'note',''))) < 3 then raise exception 'item note required: %', i + 1; end if;
        rv := jsonb_build_object('ok', false, 'note', trim(rj->i::text->>'note'), 'by', nm, 'at', now(), 'round', w.rv_round + 1);
        nrej := nrej + 1;
      else
        rv := jsonb_build_object('ok', true, 'by', nm, 'at', now(), 'round', w.rv_round + 1)
              || case when it->'rv'->>'ok' = 'false' then jsonb_build_object('prev', it->'rv'->>'note') else '{}'::jsonb end;
      end if;
      cl := cl || jsonb_build_array(it || jsonb_build_object('rv', rv));
    end loop;
    if nrej < (select count(*) from jsonb_object_keys(rj)) then raise exception 'unknown item'; end if;
    if nrej > 0 then
      update public.work_orders set checklist = cl, rv_round = w.rv_round + 1, ret_at = now() where id = w.id;
      ns := 'returned'; evt := 'return';
      msg := '↩️ لم يُعتمد ' || nrej || ' من ' || jsonb_array_length(cl) || ' بند — أُعيد للتصحيح';
    else
      if public.fm_wo_spend_rank(w.checklist) > greatest(public.fm_prank(public.fm_posx(me.role, me.job_title)),
           coalesce((select max(public.fm_prank(public.fm_posx(pr.role, pr.job_title))) from public.fm_deputies d join public.profiles pr on pr.id = d.principal
                      where d.deputy = me.id and d.active and now() between d.from_at and d.to_at), 0)) then
        raise exception 'spend approval required: %', case public.fm_wo_spend_rank(w.checklist) when 6 then 'ops_manager' else 'area_manager' end;
      end if;
      update public.work_orders set checklist = cl, rv_round = w.rv_round + 1 where id = w.id;
      ns := 'closed'; evt := 'close'; msg := '🔒 اعتُمدت كل البنود وأُغلق الأمر';
    end if;
  elsif p_action = 'close' and isR and w.status = 'done' then
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
  elsif p_action = 'return' and isR and w.status = 'done' then
    if note is null then raise exception 'reason required'; end if; update public.work_orders set ret_at = now() where id = w.id; ns := 'returned'; msg := '↩️ أعاد الأمر للتصحيح';
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
  values (w.id, me.id, nm, coalesce(evt, p_action), ns, msg || coalesce(' — ' || note, ''), p_geo);
  return ns;
end $$;
notify pgrst, 'reload schema';
