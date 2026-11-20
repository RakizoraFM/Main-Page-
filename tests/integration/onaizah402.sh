#!/bin/bash
# V402 — Onaizah trial (140 schools): permissions, deadlines, alerts and the engineer's closure review on a LOCAL Postgres.
# usage: PGHOST=/tmp PGPORT=5433 PGUSER=postgres bash tests/integration/onaizah402.sh [dbname] [test.sql]
# Builds a fresh database with a Supabase-like bootstrap (auth.users / auth.uid() / roles), runs supabase_setup.sql, then onaizah402.sql.
# Never point it at a real project: it writes the school DB (app_kv) and test accounts.
set -e
DB=${1:-tonz402}; cd "$(dirname "$0")/../.."
P="psql -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "drop database if exists $DB" -c "create database $DB" >/dev/null 2>&1
$P -d $DB >/dev/null 2>&1 <<'SQL'
do $$begin create role anon nologin;exception when others then null;end$$;
do $$begin create role authenticated nologin;exception when others then null;end$$;
do $$begin create role service_role nologin bypassrls;exception when others then null;end$$;
create schema if not exists auth; create schema if not exists extensions; create schema if not exists storage;
create extension if not exists pgcrypto with schema extensions;
create table if not exists auth.users (instance_id uuid, id uuid primary key, aud text, role text, email text, encrypted_password text, email_confirmed_at timestamptz,
  raw_app_meta_data jsonb default '{}', raw_user_meta_data jsonb default '{}', created_at timestamptz default now(), updated_at timestamptz default now(),
  last_sign_in_at timestamptz, banned_until timestamptz, confirmation_token text, recovery_token text, email_change_token_new text, email_change text, phone text);
create table if not exists auth.identities (id uuid primary key, user_id uuid, provider_id text, identity_data jsonb, provider text, last_sign_in_at timestamptz, created_at timestamptz, updated_at timestamptz);
create or replace function auth.uid() returns uuid language sql stable as $f$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $f$;
create or replace function auth.role() returns text language sql stable as $f$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), 'authenticated') $f$;
create or replace function auth.jwt() returns jsonb language sql stable as $f$ select jsonb_build_object('sub', auth.uid()) $f$;
create table if not exists storage.buckets (id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table if not exists storage.objects (id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid, created_at timestamptz default now(), metadata jsonb);
alter table storage.objects enable row level security;
create or replace function storage.foldername(name text) returns text[] language sql immutable as $f$ select string_to_array(name, '/') $f$;
grant usage on schema auth, extensions, storage, public to anon, authenticated, service_role;
grant select on auth.users to authenticated;
-- as on Supabase: new public tables / functions / sequences are granted to the API roles; supabase_setup.sql revokes where it must
alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
SQL
$P -d $DB -f supabase_setup.sql >/dev/null 2>&1 || { echo "supabase_setup.sql failed"; $P -d $DB -f supabase_setup.sql 2>&1 | grep -m3 ERROR; exit 1; }
$P -d $DB -f ${2:-tests/integration/onaizah402.sql} 2>&1 | grep -v NOTICE
