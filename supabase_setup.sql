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

-- done. Next: in the platform → الإعدادات → «السحابة والمستخدمين», paste the Project URL and the anon key.


-- V192: shared team readiness (also shipped as migration_v192.sql).
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
-- Prerequisites: current supabase_setup.sql through V192 (or migration_v192.sql).
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
