-- RakizoraFM SaaS — control project (run ONLY in the platform owner's Supabase project, once; it is idempotent).
-- It keeps the companies (each with its own Supabase project that runs supabase_setup.sql), their public connection
-- (Project URL + anon / publishable key — never a service_role key), branding, plan and subscription, the secret used to
-- sign activation codes, the price list and the invoices. Only the platform owners (saas_owners) read or change them;
-- the start page asks for one company's public connection through saas_tenant(code) without an account.
--
-- After running it, make yourself an owner (replace the e-mail):
--   insert into public.saas_owners(user_id) select id from auth.users where email = 'owner@example.com' on conflict do nothing;

create table if not exists public.saas_owners (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create or replace function public.saas_is_owner() returns boolean language sql stable security definer set search_path = public as $$
  select exists(select 1 from public.saas_owners where user_id = auth.uid()) $$;

create table if not exists public.saas_tenants (
  code          text primary key check (code ~ '^[a-z0-9][a-z0-9-]{1,29}$'),
  name          text not null,
  logo          text check (logo is null or (logo ~ '^data:image/(png|jpeg|webp);base64,' and length(logo) <= 200000)),
  color         text check (color is null or color ~ '^#[0-9a-fA-F]{6}$'),
  url           text not null check (url ~ '^https://[a-z0-9-]+\.supabase\.co$'),
  anon_key      text not null check (length(anon_key) >= 30 and anon_key !~ '^sb_secret_'),
  plan          text not null default 'basic',
  schools_limit int  not null default 50,
  status        text not null default 'trial' check (status in ('trial','active','suspended')),
  active_until  date,
  secret        text not null default (replace(gen_random_uuid()::text,'-','') || replace(gen_random_uuid()::text,'-','')),
  vat_no        text,
  contact_name  text,
  contact_phone text,
  contact_email text,
  notes         text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create table if not exists public.saas_settings (key text primary key, value jsonb not null, updated_at timestamptz not null default now());
insert into public.saas_settings(key, value) values
  ('plans', '[{"k":"basic","name":"البلاغات","max":50,"price":1500,"modules":["tickets"]},{"k":"pro","name":"التشغيل","max":300,"price":5000,"modules":["tickets","wo","eng","portal"]},{"k":"enterprise","name":"الشاملة","max":0,"price":12000,"modules":["tickets","wo","wh","eng","portal","costs","bill"]}]'),
  ('addons', '[{"k":"tickets","base":800,"per_school":0},{"k":"wo","base":1500,"per_school":0},{"k":"wh","base":1500,"per_school":0},{"k":"eng","base":500,"per_school":0},{"k":"portal","base":500,"per_school":0},{"k":"costs","base":500,"per_school":0},{"k":"bill","base":1000,"per_school":0}]'),
  ('seller', '{"name":"RakizoraFM","vat_no":"","address":"","iban":"","vat_pct":15}')
on conflict (key) do nothing;
create sequence if not exists public.saas_invoice_seq;
create table if not exists public.saas_invoices (
  id              uuid primary key default gen_random_uuid(),
  number          text unique not null default ('INV-' || to_char(now() at time zone 'Asia/Riyadh','YYYY') || '-' || lpad(nextval('public.saas_invoice_seq')::text, 4, '0')),
  tenant          text not null references public.saas_tenants(code) on update cascade,
  issued_at       date not null default current_date,
  period_from     date not null,
  period_to       date not null check (period_to >= period_from),
  plan            text not null,
  schools_limit   int  not null,
  months          int  not null check (months between 1 and 36),
  amount          numeric(12,2) not null check (amount >= 0),
  vat_pct         numeric(5,2) not null default 15,
  total           numeric(12,2) not null,
  status          text not null default 'unpaid' check (status in ('unpaid','paid','cancelled')),
  paid_at         timestamptz,
  activation_code text,
  note            text,
  created_at      timestamptz not null default now()
);
grant usage, select on sequence public.saas_invoice_seq to authenticated;
-- V181: the parts of the platform a company bought {key: until-date | null} (null = every part), and the invoice lines
alter table public.saas_tenants  add column if not exists modules jsonb;
alter table public.saas_invoices add column if not exists modules jsonb;
alter table public.saas_invoices add column if not exists lines   jsonb;
-- V182: a demo company (fake data, demo_seed.sql in its own project): start.html lists its demo accounts with this password
alter table public.saas_tenants add column if not exists demo      boolean not null default false;
alter table public.saas_tenants add column if not exists demo_pass text;
insert into public.saas_settings(key, value) values
  ('addons', '[{"k":"tickets","base":800,"per_school":0},{"k":"wo","base":1500,"per_school":0},{"k":"wh","base":1500,"per_school":0},{"k":"eng","base":500,"per_school":0},{"k":"portal","base":500,"per_school":0},{"k":"costs","base":500,"per_school":0},{"k":"bill","base":1000,"per_school":0}]')
on conflict (key) do nothing;
create index if not exists saas_invoices_tenant_idx on public.saas_invoices (tenant, issued_at desc);

alter table public.saas_owners   enable row level security;
alter table public.saas_tenants  enable row level security;
alter table public.saas_settings enable row level security;
alter table public.saas_invoices enable row level security;
drop policy if exists p_saas_owners on public.saas_owners;
create policy p_saas_owners on public.saas_owners for select using (public.saas_is_owner());
drop policy if exists p_saas_tenants on public.saas_tenants;
create policy p_saas_tenants on public.saas_tenants for all using (public.saas_is_owner()) with check (public.saas_is_owner());
drop policy if exists p_saas_settings on public.saas_settings;
create policy p_saas_settings on public.saas_settings for all using (public.saas_is_owner()) with check (public.saas_is_owner());
drop policy if exists p_saas_invoices on public.saas_invoices;
create policy p_saas_invoices on public.saas_invoices for all using (public.saas_is_owner()) with check (public.saas_is_owner());
revoke all on public.saas_owners, public.saas_tenants, public.saas_settings, public.saas_invoices from anon;

-- public (no account): one company's connection and branding for the start page, school portal and rating page
create or replace function public.saas_tenant(p_code text) returns jsonb language sql stable security definer set search_path = public as $$
  select coalesce((select jsonb_build_object('code', t.code, 'name', t.name, 'logo', t.logo, 'color', t.color, 'url', t.url, 'key', t.anon_key,
      'status', t.status, 'active_until', t.active_until, 'demo', t.demo, 'demo_pass', case when t.demo then t.demo_pass end)
    from public.saas_tenants t where t.code = lower(btrim(coalesce(p_code,'')))), jsonb_build_object('status','unknown')) $$;
revoke all on function public.saas_tenant(text), public.saas_is_owner() from public;
grant execute on function public.saas_tenant(text) to anon, authenticated;
grant execute on function public.saas_is_owner() to authenticated;

-- ---------- V185: trial requests from try.html, daily usage of each company, renewal reminders ----------
do $$ begin execute 'create extension if not exists pgcrypto with schema extensions'; exception when others then null; end $$;
insert into public.saas_settings(key, value) values ('site', '{"demo_code":"","whatsapp":"","show_prices":true,"email":""}') on conflict (key) do nothing;
alter table public.saas_tenants add column if not exists reminders jsonb not null default '{}';   -- {"2026-12-31:30": "2026-12-01", …} renewal reminders sent
create table if not exists public.saas_leads (
  id         uuid primary key default gen_random_uuid(),
  at         timestamptz not null default now(),
  name       text not null,
  company    text not null,
  phone      text not null,
  email      text,
  city       text,
  schools    int,
  modules    text[] not null default '{}',
  message    text,
  status     text not null default 'new' check (status in ('new','contacted','demo','trial','won','lost')),
  note       text,
  tenant     text,
  updated_at timestamptz not null default now()
);
create index if not exists saas_leads_at_idx on public.saas_leads (at desc);
create table if not exists public.saas_usage (
  tenant text not null references public.saas_tenants(code) on update cascade on delete cascade,
  day    date not null,
  stats  jsonb not null,
  at     timestamptz not null default now(),
  primary key (tenant, day)
);
alter table public.saas_leads enable row level security;
alter table public.saas_usage enable row level security;
drop policy if exists p_saas_leads on public.saas_leads;
create policy p_saas_leads on public.saas_leads for all using (public.saas_is_owner()) with check (public.saas_is_owner());
drop policy if exists p_saas_usage on public.saas_usage;
create policy p_saas_usage on public.saas_usage for select using (public.saas_is_owner());
revoke all on public.saas_leads, public.saas_usage from anon;
-- public (no account): what try.html shows — plans and add-ons with their parts (prices only when show_prices), the demo code
create or replace function public.saas_public() returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('seller', (select value->>'name' from public.saas_settings where key = 'seller'),
    'site', (select value - 'email' from public.saas_settings where key = 'site'),
    'plans', (select case when coalesce((select (value->>'show_prices')::boolean from public.saas_settings where key = 'site'), true) then value
                          else (select coalesce(jsonb_agg(x - 'price'), '[]') from jsonb_array_elements(value) x) end from public.saas_settings where key = 'plans'),
    'addons', (select case when coalesce((select (value->>'show_prices')::boolean from public.saas_settings where key = 'site'), true) then value else '[]'::jsonb end
               from public.saas_settings where key = 'addons')) $$;
-- public (no account): a trial request. hp is a hidden field that people leave empty; limits: 3 a day per phone, 300 a day in all
create or replace function public.saas_lead_new(p jsonb) returns text language plpgsql security definer set search_path = public as $$
declare ph text := regexp_replace(coalesce(p->>'phone',''), '[^0-9+]', '', 'g');
begin
  if coalesce(p->>'hp','') <> '' then return 'ok'; end if;
  if length(btrim(coalesce(p->>'name',''))) < 2 or length(btrim(coalesce(p->>'company',''))) < 2 then raise exception 'name required'; end if;
  if ph !~ '^\+?[0-9]{9,15}$' then raise exception 'invalid phone'; end if;
  if (select count(*) from public.saas_leads where phone = ph and at > now() - interval '1 day') >= 3
     or (select count(*) from public.saas_leads where at > now() - interval '1 day') >= 300 then raise exception 'too many requests'; end if;
  insert into public.saas_leads(name, company, phone, email, city, schools, modules, message)
  values (left(btrim(p->>'name'),120), left(btrim(p->>'company'),200), ph, left(nullif(btrim(coalesce(p->>'email','')),''),120), left(nullif(btrim(coalesce(p->>'city','')),''),80),
          least(greatest(coalesce(nullif(regexp_replace(coalesce(p->>'schools',''),'[^0-9]','','g'),'')::int, 0), 0), 100000),
          coalesce((select array_agg(left(x,20)) from jsonb_array_elements_text(case when jsonb_typeof(p->'modules') = 'array' then p->'modules' else '[]' end) x limit 10), '{}'),
          left(nullif(btrim(coalesce(p->>'message','')),''),1000));
  return 'ok';
end $$;
-- a company's platform reports its daily numbers, signed in its own database with the company secret (fm_plan_usage)
create or replace function public.saas_hmac(p_data text, p_key text) returns text language plpgsql immutable set search_path = public as $$
begin
  begin return encode(extensions.hmac(convert_to(p_data,'utf8'), convert_to(p_key,'utf8'), 'sha256'), 'hex');
  exception when undefined_function or invalid_schema_name then return encode(public.hmac(convert_to(p_data,'utf8'), convert_to(p_key,'utf8'), 'sha256'), 'hex'); end;
end $$;
create or replace function public.saas_ping(p_code text, p_payload text, p_sig text) returns text language plpgsql security definer set search_path = public as $$
declare t public.saas_tenants; j jsonb;
begin
  select * into t from public.saas_tenants where code = lower(btrim(coalesce(p_code,'')));
  if not found or length(coalesce(p_payload,'')) > 4000 or public.saas_hmac(p_payload, t.secret) <> coalesce(p_sig,'') then raise exception 'invalid'; end if;
  j := p_payload::jsonb;
  if j->>'c' is distinct from t.code or abs((j->>'d')::date - current_date) > 2 then raise exception 'invalid'; end if;
  insert into public.saas_usage(tenant, day, stats) values (t.code, (j->>'d')::date, j - 'c' - 'd')
    on conflict (tenant, day) do update set stats = excluded.stats, at = now();
  return 'ok';
end $$;
revoke all on function public.saas_hmac(text, text) from public, anon, authenticated;
revoke all on function public.saas_public(), public.saas_lead_new(jsonb), public.saas_ping(text, text, text) from public;
grant execute on function public.saas_public(), public.saas_lead_new(jsonb), public.saas_ping(text, text, text) to anon, authenticated;
