-- =====================================================================
--  아기 기록 v1.1 — 수유 알림(웹 푸시) 추가 SQL
--  v1.0 SQL을 이미 실행한 프로젝트에 이어서 실행하세요. (SQL Editor → 붙여넣기 → Run)
--  ★ 아래 edge_url의 <PROJECT_ID> 를 내 프로젝트 ID로 바꾸세요.
-- =====================================================================
create extension if not exists pg_cron with schema pg_catalog;
create extension if not exists pg_net with schema extensions;

create table if not exists public.push_subs (
  endpoint text primary key, sub jsonb not null, who text, created_at timestamptz not null default now());
create table if not exists public.push_queue (
  id bigserial primary key, title text not null, body text, tag text,
  created_at timestamptz not null default now(), sent_at timestamptz);
create table if not exists public.app_state (
  id int primary key default 1 check (id = 1), alarm_sent_for timestamptz, edge_url text);
alter table public.app_secret add column if not exists vapid_public text;
alter table public.app_secret add column if not exists vapid_private text;

alter table public.push_subs  enable row level security;
alter table public.push_queue enable row level security;
alter table public.app_state  enable row level security;
revoke all on public.push_subs, public.push_queue, public.app_state from anon, authenticated;
grant all on public.push_subs, public.push_queue, public.app_state, public.app_secret to service_role;
grant usage, select on sequence public.push_queue_id_seq to service_role;

-- ★ 알림을 보내는 Edge Function 주소
insert into public.app_state (id, edge_url) values (1, 'https://<PROJECT_ID>.supabase.co/functions/v1/push')
on conflict (id) do update set edge_url = excluded.edge_url;

-- 수유 간격 계산 (서버/앱 공용)
create or replace function public._alarm_calc() returns json
language plpgsql security definer set search_path = public as $$
declare
  cfg jsonb; al jsonb;
  feed_types text[]; dur_types text[];
  v_enabled bool; v_mode text; v_fixed numeric; v_lead numeric; v_days int;
  v_last_end timestamptz; v_open bool; v_first timestamptz;
  v_auto numeric; v_samples int; v_interval numeric; v_source text; v_due timestamptz;
begin
  select data into cfg from app_config where id = 1;
  al := coalesce(cfg->'alarm', '{}'::jsonb);
  v_enabled := coalesce((al->>'enabled')::bool, false);
  v_mode    := coalesce(al->>'mode', 'auto');
  v_fixed   := coalesce((al->>'fixedMin')::numeric, 120);
  v_lead    := coalesce((al->>'leadMin')::numeric, 0);
  v_days    := greatest(1, least(30, coalesce((al->>'statsDays')::int, 3)));

  select array_agg(t->>'id') into feed_types
    from jsonb_array_elements(coalesce(cfg->'types', '[]'::jsonb)) t where (t->>'feed')::bool is true;
  feed_types := coalesce(feed_types, array['breast','formula']);
  select array_agg(t->>'id') into dur_types
    from jsonb_array_elements(coalesce(cfg->'types', '[]'::jsonb)) t where t->>'kind' = 'duration';
  dur_types := coalesce(dur_types, array['breast','sleep','tummy']);

  v_open := exists (select 1 from events where type = any(feed_types) and type = any(dur_types)
                     and end_at is null and start_at > now() - interval '24 hours');
  select max(case when type = any(dur_types) then end_at else start_at end) into v_last_end
    from events where type = any(feed_types) and start_at > now() - interval '7 days';
  select min(start_at) into v_first from events where type = any(feed_types);

  -- 최근 N일: 30분 안에 이어진 수유(모유→분유 보충 등)는 한 번으로 묶고, '끝 → 다음 시작' 간격의 중앙값
  with f as (
    select start_at s, case when type = any(dur_types) then coalesce(end_at, start_at) else start_at end e
      from events
     where type = any(feed_types) and start_at > now() - make_interval(days => v_days)
       and not (type = any(dur_types) and end_at is null)
  ), m as (
    select s, e, max(e) over (order by s rows between unbounded preceding and 1 preceding) pe from f
  ), g as (
    select s, e, sum(case when pe is null or s > pe + interval '30 minutes' then 1 else 0 end) over (order by s) grp from m
  ), ss as (
    select min(s) s, max(e) e from g group by grp
  ), gaps as (
    select extract(epoch from (lead(s) over (order by s) - e)) / 60 gap from ss
  )
  select percentile_cont(0.5) within group (order by gap), count(*) into v_auto, v_samples
    from gaps where gap > 0;

  if v_mode = 'auto' and v_first <= now() - interval '24 hours' and v_samples >= 3 then
    v_interval := greatest(45, least(300, round(v_auto))); v_source := 'auto';
  else
    v_interval := v_fixed; v_source := 'fixed';
  end if;
  if v_last_end is not null then v_due := v_last_end + make_interval(mins => (v_interval - v_lead)::int); end if;

  return json_build_object('enabled', v_enabled, 'mode', v_mode, 'source', v_source,
    'interval_min', v_interval, 'auto_min', round(v_auto), 'samples', coalesce(v_samples, 0),
    'stats_days', v_days, 'lead_min', v_lead, 'last_end', v_last_end, 'open_feed', v_open,
    'due_at', v_due, 'first_feed', v_first);
end $$;
revoke execute on function public._alarm_calc() from public, anon, authenticated;

create or replace function public.alarm_status(p_code text) returns json
language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); return _alarm_calc(); end $$;

create or replace function public._fmt_min(m numeric) returns text language sql immutable as $$
  select case when m >= 60 then (floor(m/60))::int || '시간 ' || (round(m)::int % 60) || '분' else round(m)::int || '분' end $$;

-- 1분마다 실행: 알림 시각이 되면 큐에 넣고 Edge Function 호출
create or replace function public.check_alarm() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare a json; v_last timestamptz; v_sent timestamptz; v_url text; v_since numeric;
begin
  a := _alarm_calc();
  if not (a->>'enabled')::bool or (a->>'open_feed')::bool or a->>'due_at' is null then return; end if;
  if now() < (a->>'due_at')::timestamptz then return; end if;
  v_last := (a->>'last_end')::timestamptz;
  if v_last < now() - interval '12 hours' then return; end if;
  select alarm_sent_for, edge_url into v_sent, v_url from app_state where id = 1;
  if v_sent is not distinct from v_last then return; end if;
  update app_state set alarm_sent_for = v_last where id = 1;
  v_since := extract(epoch from now() - v_last) / 60;
  insert into push_queue (title, body, tag) values (
    '🍼 수유할 시간이에요',
    format('마지막 수유 끝 %s · %s 지났어요 (%s %s)',
      to_char(v_last at time zone 'Asia/Seoul', 'HH24:MI'), _fmt_min(v_since),
      case when a->>'source' = 'auto' then '최근 ' || (a->>'stats_days') || '일 보통 간격' else '설정 간격' end,
      _fmt_min((a->>'interval_min')::numeric)),
    'feed');
  perform net.http_post(url := v_url, body := '{}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;
revoke execute on function public.check_alarm() from public, anon, authenticated;

create or replace function public.test_push(p_code text, p_by text default null) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_url text;
begin
  perform _chk(p_code);
  select edge_url into v_url from app_state where id = 1;
  insert into push_queue (title, body, tag) values ('🔔 테스트 알림', coalesce(p_by, '') || ' 알림이 잘 와요!', 'test');
  perform net.http_post(url := v_url, body := '{}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;

create or replace function public.save_push_sub(p_code text, p_sub jsonb, p_who text default null) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _chk(p_code);
  insert into push_subs (endpoint, sub, who) values (p_sub->>'endpoint', p_sub, p_who)
  on conflict (endpoint) do update set sub = excluded.sub, who = excluded.who;
end $$;

create or replace function public.delete_push_sub(p_code text, p_endpoint text) returns void
language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); delete from push_subs where endpoint = p_endpoint; end $$;

create or replace function public.get_vapid_public(p_code text) returns text
language plpgsql security definer set search_path = public as $$
begin perform _chk(p_code); return (select vapid_public from app_secret where id = 1); end $$;

grant execute on function public.alarm_status(text), public.test_push(text, text),
  public.save_push_sub(text, jsonb, text), public.delete_push_sub(text, text),
  public.get_vapid_public(text) to anon, authenticated;

-- 1분마다 알림 확인
select cron.unschedule(jobid) from cron.job where jobname = 'baby-log-alarm';
select cron.schedule('baby-log-alarm', '* * * * *', 'select public.check_alarm()');

notify pgrst, 'reload schema';
