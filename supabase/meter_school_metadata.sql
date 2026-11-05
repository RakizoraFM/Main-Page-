-- Run once in Supabase SQL Editor before using the new meter form.
begin;
alter table public.fm_meters add column if not exists office text;
alter table public.fm_meters add column if not exists school_code text;
create or replace function public.fm_meter_save(p jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
declare k text[] := public.fm_meter_keys(true); m public.fm_meters; b text := coalesce(nullif(p->>'bkey',''), '');
begin
  if public.fm_role() not in ('admin','manager','engineer','supervisor') then raise exception 'not allowed'; end if;
  if nullif(p->>'id','') is not null then select * into m from public.fm_meters where id = (p->>'id')::uuid for update; if not found then raise exception 'not found'; end if; b := m.bkey; end if;
  if b = '' or (k is not null and not b = any(k)) then raise exception 'not allowed'; end if;
  if m.id is null then
    if p->>'kind' not in ('elec','water') or btrim(coalesce(p->>'school_name','')) = '' then raise exception 'invalid meter'; end if;
    insert into public.fm_meters (bkey, school_name, region, kind, number, account_no, notes, office, school_code)
    values (b, left(btrim(p->>'school_name'),200), nullif(p->>'region',''), p->>'kind', left(nullif(p->>'number',''),60), left(nullif(p->>'account_no',''),60), left(nullif(p->>'notes',''),300), left(nullif(p->>'office',''),200), left(nullif(p->>'school_code',''),80))
    returning * into m;
  else
    update public.fm_meters set number = left(nullif(p->>'number',''),60), account_no = left(nullif(p->>'account_no',''),60), notes = left(nullif(p->>'notes',''),300),
      office = case when p ? 'office' then left(nullif(p->>'office',''),200) else office end, school_code = case when p ? 'school_code' then left(nullif(p->>'school_code',''),80) else school_code end,
      active = coalesce((p->>'active')::boolean, active) where id = m.id returning * into m;
  end if;
  return jsonb_build_object('id', m.id);
end $$;

commit;
