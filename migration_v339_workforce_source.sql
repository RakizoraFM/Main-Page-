-- Preserve the 23-column uploaded workforce model privately, without collapsing rows.
begin;
create table if not exists public.fm_workforce339_source (
 region text primary key check(region in ('riyadh','qassim')),
 rows jsonb not null default '[]'::jsonb check(jsonb_typeof(rows)='array' and jsonb_array_length(rows)<=5000),
 revision integer not null default 1,
 updated_at timestamptz not null default now(),
 updated_by uuid references auth.users(id)
);
alter table public.fm_workforce339_source enable row level security;
revoke all on public.fm_workforce339_source from public,anon,authenticated;
create or replace function public.fm_workforce339_source_get(r text) returns jsonb
language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or not public.fm233_read(r) then raise exception 'not allowed'; end if;
 return coalesce((select jsonb_build_object('rows',s.rows,'revision',s.revision) from public.fm_workforce339_source s where s.region=r),jsonb_build_object('rows','[]'::jsonb,'revision',0));
end $$;
create or replace function public.fm_workforce339_source_save(p jsonb) returns jsonb
language plpgsql security definer set search_path=public as $$
declare r text; v jsonb; oldrev int; expected int; outv jsonb:='{}'::jsonb;
begin
 if auth.uid() is null or jsonb_typeof(p->'regions') is distinct from 'object' then raise exception 'invalid source'; end if;
 -- Serialize imports before checking revisions, preventing concurrent overwrites.
 perform pg_advisory_xact_lock(hashtext('fm_workforce339_source'));
 for r,v in select key,value from jsonb_each(p->'regions') order by key loop
  if not public.fm233_manage(r) then raise exception 'not allowed'; end if;
  if jsonb_typeof(v->'rows') is distinct from 'array' or jsonb_array_length(v->'rows')>5000 then raise exception 'invalid rows'; end if;
  if exists(select 1 from jsonb_array_elements(v->'rows') x where jsonb_typeof(x) is distinct from 'array' or jsonb_array_length(x)<>23) then raise exception 'expected 23 columns'; end if;
  select revision into oldrev from public.fm_workforce339_source where region=r for update;
  expected:=coalesce((v->>'revision')::int,0);
  if coalesce(oldrev,0)<>expected then raise exception 'تغير النموذج منذ تحميله؛ حدّث الصفحة وأعد المحاولة'; end if;
  insert into public.fm_workforce339_source(region,rows,revision,updated_at,updated_by)
  values(r,v->'rows',coalesce(oldrev,0)+1,now(),auth.uid())
  on conflict(region) do update set rows=excluded.rows,revision=excluded.revision,updated_at=excluded.updated_at,updated_by=excluded.updated_by;
  outv:=outv||jsonb_build_object(r,jsonb_build_object('saved',jsonb_array_length(v->'rows'),'revision',coalesce(oldrev,0)+1));
 end loop;
 return outv;
end $$;
revoke all on function public.fm_workforce339_source_get(text),public.fm_workforce339_source_save(jsonb) from public,anon;
grant execute on function public.fm_workforce339_source_get(text),public.fm_workforce339_source_save(jsonb) to authenticated;
commit;
