-- =====================================================================
--  FM Platform — Supabase setup (V136, user management V141, profile V142)
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
    when 'engineer'   then exists(select 1 from public.tickets k where k.region=r and k.ticket_id=t and public.fm_region_ok(r) and (k.engineer   = any(public.fm_names()) or k.supervisor = any(public.fm_names())))
    when 'supervisor' then exists(select 1 from public.tickets k where k.region=r and k.ticket_id=t and public.fm_region_ok(r) and  k.supervisor = any(public.fm_names()))
    when 'contractor' then exists(select 1 from public.tickets k where k.region=r and k.ticket_id=t and public.fm_region_ok(r) and  k.contractor = any(public.fm_names()))
    else false end $$;
create or replace function public.fm_can_edit(r text, t text) returns boolean language sql stable as $$
  select public.fm_role() in ('admin','engineer','supervisor','contractor') and public.fm_can_see(r,t) $$;

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
              and person_names = (select person_names from public.profiles where id = auth.uid())
              and regions = (select regions from public.profiles where id = auth.uid())
              and active = (select active from public.profiles where id = auth.uid()));

drop policy if exists p_tickets_read  on public.tickets;
drop policy if exists p_tickets_write on public.tickets;
create policy p_tickets_read  on public.tickets for select using (public.fm_can_see(region, ticket_id));
create policy p_tickets_write on public.tickets for all using (public.fm_role() = 'admin') with check (public.fm_role() = 'admin');

drop policy if exists p_kv_read  on public.app_kv;
drop policy if exists p_kv_write on public.app_kv;
create policy p_kv_read  on public.app_kv for select using (public.fm_role() in ('admin','engineer','supervisor','contractor','viewer'));
create policy p_kv_write on public.app_kv for all using (public.fm_role() = 'admin') with check (public.fm_role() = 'admin');

-- only admin / engineer may verify-and-close or cancel
drop policy if exists p_work_read   on public.ticket_work;
drop policy if exists p_work_insert on public.ticket_work;
drop policy if exists p_work_update on public.ticket_work;
drop policy if exists p_work_delete on public.ticket_work;
create policy p_work_read   on public.ticket_work for select using (public.fm_can_see(region, ticket_id));
create policy p_work_insert on public.ticket_work for insert with check (public.fm_can_edit(region, ticket_id)
  and (public.fm_role() in ('admin','engineer') or stage not in ('closed','cancelled')));
create policy p_work_update on public.ticket_work for update using (public.fm_can_edit(region, ticket_id))
  with check (public.fm_can_edit(region, ticket_id) and (public.fm_role() in ('admin','engineer') or stage not in ('closed','cancelled')));
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
create policy p_ph_delete on public.ticket_photos for delete using (public.fm_role() in ('admin','engineer') or by_id = auth.uid());

-- ---------- 6) photo storage (private bucket; path = region/ticket_id/file.jpg) ----------
insert into storage.buckets (id, name, public) values ('ticket-photos','ticket-photos', false)
  on conflict (id) do nothing;
drop policy if exists p_obj_read   on storage.objects;
drop policy if exists p_obj_insert on storage.objects;
drop policy if exists p_obj_delete on storage.objects;
create policy p_obj_read   on storage.objects for select using (bucket_id = 'ticket-photos'
  and public.fm_can_see(split_part(name,'/',1), split_part(name,'/',2)));
create policy p_obj_insert on storage.objects for insert with check (bucket_id = 'ticket-photos'
  and public.fm_can_edit(split_part(name,'/',1), split_part(name,'/',2)));
create policy p_obj_delete on storage.objects for delete using (bucket_id = 'ticket-photos'
  and (public.fm_role() in ('admin','engineer') or owner = auth.uid()));

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
  if p_role not in ('admin','engineer','supervisor','contractor','viewer','pending') then raise exception 'invalid role'; end if;
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

-- done. Next: in the platform → الإعدادات → «السحابة والمستخدمين», paste the Project URL and the anon key.
