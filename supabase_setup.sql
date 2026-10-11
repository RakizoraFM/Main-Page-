-- =====================================================================
--  FM Platform — Supabase setup (V136, user management V141, profile V142, work orders V145–V148)
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
              and active = (select active from public.profiles where id = auth.uid())
              and reports_to is not distinct from (select reports_to from public.profiles where id = auth.uid()));

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

-- ---------- 10) work orders (V145) ----------
-- Hierarchy: admin > engineer > supervisor > contractor. An order goes from a person to someone below him
-- in his own line (profiles.reports_to); the admin may assign to anyone below him.
-- All writes go through the functions below, which check the hierarchy and the allowed status changes.
create or replace function public.fm_rank(r text) returns int language sql immutable as $$
  select case r when 'admin' then 4 when 'engineer' then 3 when 'supervisor' then 2 when 'contractor' then 1 else 0 end $$;

-- true when p_user reports to p_boss, directly or through other managers
create or replace function public.fm_is_under(p_user uuid, p_boss uuid) returns boolean
language sql stable security definer set search_path = public as $$
  with recursive up(id, boss, depth) as (
    select id, reports_to, 1 from public.profiles where id = p_user
    union all
    select p.id, p.reports_to, u.depth + 1 from public.profiles p join up u on p.id = u.boss where u.depth < 8)
  select p_boss is not null and exists (select 1 from up where boss = p_boss) $$;

-- may p_me assign work to p_user? (V147: the scheduled campaigns check it for the schedule's owner)
create or replace function public.fm_can_assign_as(p_me uuid, p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.profiles t, public.profiles me
    where t.id = p_user and me.id = p_me and me.active and t.active and t.id <> me.id
      and public.fm_rank(t.role) between 1 and public.fm_rank(me.role) - 1
      and (me.role = 'admin' or public.fm_is_under(t.id, me.id))) $$;
-- may the signed-in user assign work to p_user?
create or replace function public.fm_can_assign_to(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.fm_can_assign_as(auth.uid(), p_user) $$;

-- the people the signed-in user may assign to (for the assignee list; V146 adds email and
-- person_names so a group of schools can be matched to each school's own supervisor)
drop function if exists public.fm_wo_assignable();
create or replace function public.fm_wo_assignable() returns table(id uuid, full_name text, role text, regions text[], phone text, email text, person_names text[])
language sql stable security definer set search_path = public as $$
  select p.id, coalesce(p.full_name, p.email), p.role, p.regions, p.phone, p.email, p.person_names from public.profiles p
   where public.fm_can_assign_to(p.id) order by public.fm_rank(p.role) desc, p.full_name $$;

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
alter table public.wo_photos add constraint wo_photos_kind_check check (kind in ('before','after','attach','arrival'));

-- who sees an order: its creator, its assignee, the admin, and the managers above either of them
create or replace function public.fm_wo_can_see(p_wo uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select public.fm_role() <> 'pending' and exists (select 1 from public.work_orders w where w.id = p_wo
    and (w.created_by = auth.uid() or w.assignee = auth.uid() or public.fm_role() = 'admin'
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
drop policy if exists p_woobj_read   on storage.objects;
drop policy if exists p_woobj_insert on storage.objects;
create policy p_woobj_read   on storage.objects for select using (bucket_id = 'wo-photos'
  and public.fm_wo_can_see(public.fm_uuid_or_null(split_part(name,'/',1))));
create policy p_woobj_insert on storage.objects for insert with check (bucket_id = 'wo-photos'
  and public.fm_wo_party(public.fm_uuid_or_null(split_part(name,'/',1))));

-- create an order (admin / engineer / supervisor) for someone below in the line.
-- fm_wo_create_as is internal (also used by the scheduled campaigns for the schedule's owner).
create or replace function public.fm_wo_create_as(p_me uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare me public.profiles; t public.profiles; v_id uuid := gen_random_uuid(); v_code text;
begin
  select * into me from public.profiles where id = p_me;
  if me.id is null or not me.active or me.role not in ('admin','engineer','supervisor') then
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
  isC := w.created_by = me.id or me.role = 'admin';
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
      if it->>'res' = 'fix' and not exists (select 1 from public.wo_photos where wo_id = w.id and item = i and kind = 'before') then
        raise exception 'item documentation required: %', i + 1; end if;
    end loop;
    if jsonb_typeof(p_data) = 'array' then update public.work_orders set checklist = p_data where id = w.id; end if;
    ns := 'done'; msg := '📨 أبلغ: تم الإجراء — بانتظار الاعتماد';
  elsif p_action = 'close' and isC and w.status = 'done' then ns := 'closed'; msg := '🔒 اعتمد الإنجاز وأغلق الأمر';
  elsif p_action = 'return' and isC and w.status = 'done' then
    if note is null then raise exception 'reason required'; end if; ns := 'returned'; msg := '↩️ أعاد الأمر للتصحيح';
  elsif p_action = 'cancel' and isC and w.status not in ('closed','cancelled') then ns := 'cancelled'; msg := '🚫 ألغى الأمر';
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
create policy p_wot_read on public.wo_templates for select using (public.fm_role() in ('admin','engineer','supervisor') and (shared or created_by = auth.uid()));
create policy p_wot_ins  on public.wo_templates for insert with check (created_by = auth.uid() and public.fm_role() in ('admin','engineer','supervisor'));
create policy p_wot_upd  on public.wo_templates for update using (created_by = auth.uid() or public.fm_role() = 'admin') with check (created_by = auth.uid() or public.fm_role() = 'admin');
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
  and (created_by = auth.uid() or public.fm_role() = 'admin' or public.fm_is_under(created_by, auth.uid())));

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
  if me.id is null or not me.active or me.role not in ('admin','engineer','supervisor') then
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
  if auth.uid() is not null and public.fm_role() not in ('admin','engineer','supervisor') then return 0; end if;
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
  if me.id is null or not me.active or me.role not in ('admin','engineer','supervisor') then
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

-- done. Next: in the platform → الإعدادات → «السحابة والمستخدمين», paste the Project URL and the anon key.
