import {PGlite} from '@electric-sql/pglite';
import fs from 'node:fs';
fs.mkdirSync(new URL('../results/',import.meta.url),{recursive:true});
export const db=new PGlite();
await db.exec(`
create role anon nologin;create role authenticated nologin;create role service_role nologin bypassrls;
create schema auth;create schema storage;create schema extensions;
alter default privileges in schema public grant select,insert,update,delete on tables to anon,authenticated,service_role;
alter default privileges in schema public grant usage,select on sequences to anon,authenticated,service_role;
create table auth.users(id uuid primary key,instance_id uuid,aud text,role text,email text unique,encrypted_password text,email_confirmed_at timestamptz,raw_app_meta_data jsonb default '{}',raw_user_meta_data jsonb default '{}',created_at timestamptz default now(),updated_at timestamptz default now(),confirmation_token text,recovery_token text,email_change_token_new text,email_change text,last_sign_in_at timestamptz);
create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid$$;
create function auth.role() returns text language sql stable as $$select nullif(current_setting('request.jwt.claim.role',true),'')$$;
create function auth.jwt() returns jsonb language sql stable as $$select coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb$$;
create table storage.buckets(id text primary key,name text,public boolean default false,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid default gen_random_uuid() primary key,bucket_id text references storage.buckets(id),name text,owner uuid,metadata jsonb default '{}',created_at timestamptz default now(),updated_at timestamptz default now(),unique(bucket_id,name));
create function storage.foldername(name text) returns text[] language sql immutable as $$select string_to_array(name,'/')$$;
alter table storage.objects enable row level security;
grant usage on schema public,auth,storage to anon,authenticated,service_role;
grant all on all tables in schema storage to authenticated,service_role;
`);
const sql=fs.readFileSync(new URL('../../supabase_setup.sql',import.meta.url),'utf8');
try{await db.exec(sql);console.log('FULL_SETUP_OK')}catch(e){console.error('FULL_SETUP_ERROR',e.message,'position',e.position,'hint',e.hint);fs.writeFileSync(new URL('../results/sql_install_error.json',import.meta.url),JSON.stringify({message:e.message,position:e.position,hint:e.hint,where:e.where},null,2));throw e}
console.log((await db.query(`select count(*) as functions from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'`)).rows);
