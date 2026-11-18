-- =====================================================================
--  아기 기록 v1.0 — Supabase 설정 SQL
--  Supabase → SQL Editor → 이 내용을 통째로 붙여넣고 → Run
--  ★ 아래 'CHANGE-ME...' 가족 코드를 길고 추측하기 어려운 값으로 바꾸세요.
--    (이 코드를 아는 폰만 기록을 읽고 쓸 수 있어요)
-- =====================================================================
create extension if not exists pgcrypto;

create table if not exists public.events (
  id          uuid primary key default gen_random_uuid(),
  type        text not null,
  start_at    timestamptz not null default now(),
  end_at      timestamptz,
  value       numeric,
  note        text,
  created_by  text,
  created_at  timestamptz not null default now()
);
create index if not exists events_start_idx on public.events (start_at);

create table if not exists public.app_config (id int primary key default 1 check (id = 1), data jsonb);
create table if not exists public.app_secret (id int primary key default 1 check (id = 1), code text not null);

-- 테이블은 직접 접근 금지 (아래 함수로만 접근)
alter table public.events     enable row level security;
alter table public.app_config enable row level security;
alter table public.app_secret enable row level security;
revoke all on public.events, public.app_config, public.app_secret from anon, authenticated;

-- ★ 가족 코드 (여기를 바꾸세요)
insert into public.app_secret (id, code) values (1, 'CHANGE-ME-우리가족-비밀코드-2026')
on conflict (id) do update set code = excluded.code;

create or replace function public._chk(p_code text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_code is null or not exists (select 1 from app_secret where code = p_code) then
    raise exception 'invalid family code';
  end if;
end $$;
revoke execute on function public._chk(text) from public, anon, authenticated;

-- 한 번 기록 (단축어: add_event)
create or replace function public.add_event(
  p_code text, p_type text,
  p_start timestamptz default null, p_end timestamptz default null,
  p_value numeric default null, p_note text default null, p_by text default null)
returns public.events language plpgsql security definer set search_path = public as $$
declare r events;
begin
  perform _chk(p_code);
  insert into events (type, start_at, end_at, value, note, created_by)
  values (p_type, coalesce(p_start, now()), p_end, p_value, p_note, p_by)
  returning * into r;
  return r;
end $$;

-- 시작/끝 토글 (단축어: toggle_event) — 24시간 안에 시작한 미종료 기록이 있으면 종료, 없으면 시작
create or replace function public.toggle_event(p_code text, p_type text, p_by text default null)
returns json language plpgsql security definer set search_path = public as $$
declare r events;
begin
  perform _chk(p_code);
  select * into r from events
   where type = p_type and end_at is null and start_at > now() - interval '24 hours'
   order by start_at desc limit 1;
  if found then
    update events set end_at = now() where id = r.id returning * into r;
    return json_build_object('action', 'stop', 'event', row_to_json(r));
  end if;
  insert into events (type, start_at, created_by) values (p_type, now(), p_by) returning * into r;
  return json_build_object('action', 'start', 'event', row_to_json(r));
end $$;

create or replace function public.list_events(p_code text, p_from timestamptz, p_to timestamptz)
returns setof public.events language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  return query
    select * from events
     where start_at < p_to
       and (coalesce(end_at, start_at) >= p_from
            or (end_at is null and start_at >= p_from - interval '1 day'))
     order by start_at;
end $$;

create or replace function public.update_event(
  p_code text, p_id uuid, p_type text, p_start timestamptz,
  p_end timestamptz default null, p_value numeric default null, p_note text default null)
returns public.events language plpgsql security definer set search_path = public as $$
declare r events;
begin
  perform _chk(p_code);
  update events set type = p_type, start_at = p_start, end_at = p_end, value = p_value, note = p_note
   where id = p_id returning * into r;
  return r;
end $$;

create or replace function public.delete_event(p_code text, p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  delete from events where id = p_id;
end $$;

create or replace function public.import_events(p_code text, p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _chk(p_code);
  insert into events (type, start_at, end_at, value, note, created_by)
  select r->>'type', (r->>'start_at')::timestamptz, nullif(r->>'end_at', '')::timestamptz,
         nullif(r->>'value', '')::numeric, r->>'note', r->>'created_by'
    from jsonb_array_elements(p_rows) r;
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.get_config(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  return (select data from app_config where id = 1);
end $$;

create or replace function public.set_config(p_code text, p_data jsonb)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  insert into app_config (id, data) values (1, p_data)
  on conflict (id) do update set data = excluded.data;
end $$;

grant execute on function
  public.add_event(text, text, timestamptz, timestamptz, numeric, text, text),
  public.toggle_event(text, text, text),
  public.list_events(text, timestamptz, timestamptz),
  public.update_event(text, uuid, text, timestamptz, timestamptz, numeric, text),
  public.delete_event(text, uuid),
  public.import_events(text, jsonb),
  public.get_config(text),
  public.set_config(text, jsonb)
to anon, authenticated;

notify pgrst, 'reload schema';
