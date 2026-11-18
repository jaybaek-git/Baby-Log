-- =====================================================================
--  아기 기록 v1.14 — 상대방 알림을 N분 뒤에 (기본 3분), 친근한 문구로
--  · 그 사이 지우면 알림 취소, 메모(소변/대변)·양을 바꾸면 바뀐 내용으로 발송
--  · 지연 시간: app_config.data.liveDelay (분)
-- =====================================================================
create table if not exists public.live_pending (
  id bigserial primary key, event_id uuid not null, kind text not null, due_at timestamptz not null,
  created_at timestamptz not null default now(), unique (event_id, kind));
alter table public.live_pending enable row level security;
revoke all on public.live_pending from anon, authenticated;

create or replace function public._live_notify() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; v_delay int;
begin
  if pg_trigger_depth() > 1 then return new; end if;
  if coalesce(current_setting('babylog.skip_also', true), '') = '1' then return new; end if;
  select data into cfg from app_config where id = 1;
  if coalesce((cfg->>'liveNotify')::bool, true) = false then return new; end if;
  v_delay := greatest(0, least(30, coalesce((cfg->>'liveDelay')::int, 3)));
  if tg_op = 'INSERT' then
    if new.start_at < now() - interval '30 minutes' or new.start_at > now() + interval '10 minutes' then return new; end if;
    insert into live_pending (event_id, kind, due_at) values (new.id, 'new', now() + make_interval(mins => v_delay))
    on conflict (event_id, kind) do nothing;
  elsif tg_op = 'UPDATE' and old.end_at is null and new.end_at is not null and new.end_at >= now() - interval '30 minutes' then
    insert into live_pending (event_id, kind, due_at) values (new.id, 'end', now() + make_interval(mins => v_delay))
    on conflict (event_id, kind) do update set due_at = excluded.due_at;
  end if;
  return new;
end $$;
revoke execute on function public._live_notify() from public, anon, authenticated;

create or replace function public._live_text(e events, p_kind text, cfg jsonb, out title text, out body text)
language plpgsql stable set search_path = public as $$
declare t jsonb; v_call text; v_emoji text; v_name text; v_unit text; n text; v_val text; v_dur text;
begin
  select x into t from jsonb_array_elements(coalesce(cfg->'types','[]'::jsonb)) x where x->>'id' = e.type limit 1;
  v_call := coalesce(nullif(cfg->'remind'->>'call', ''), '아기');
  v_emoji := coalesce(t->>'emoji', ''); v_name := coalesce(t->>'name', e.type); v_unit := coalesce(t->>'unit', '');
  n := coalesce(e.note, '');
  v_val := case when e.value is not null then trim(to_char(e.value, 'FM9999990.##')) || v_unit end;
  v_dur := case when e.end_at is not null then _fmt_min(extract(epoch from e.end_at - e.start_at) / 60) end;
  title := case
    when e.type = 'diaper' and n ~ '(대변|둘다|응가)' then '💩 ' || v_call || ' 응가했어요'
    when e.type = 'diaper' and n ~ '(소변|쉬)' then '💧 ' || v_call || ' 쉬야했어요'
    when e.type = 'diaper' then v_emoji || ' ' || v_call || ' 기저귀 갈았어요'
    when e.type = 'formula' then '🍼 ' || v_call || ' 분유 먹었어요' || coalesce(' (' || v_val || ')', '')
    when e.type = 'breast' and p_kind = 'end' then '🤱 ' || v_call || ' 모유 다 먹었어요' || coalesce(' (' || v_dur || coalesce(', ' || v_val, '') || ')', '')
    when e.type = 'breast' then '🤱 ' || v_call || ' 모유 먹기 시작했어요'
    when e.type = 'sleep' and p_kind = 'end' then '🌞 ' || v_call || ' 깼어요' || coalesce(' (' || v_dur || ' 잤어요)', '')
    when e.type = 'sleep' then '😴 ' || v_call || ' 잠들었어요'
    when e.type = 'bath' then '🛁 ' || v_call || ' 목욕했어요'
    when e.type = 'temp' then '🌡️ ' || v_call || ' 체온 ' || coalesce(trim(to_char(e.value, 'FM990.0')) || '℃', '쟀어요')
    when e.type = 'weight' then '⚖️ ' || v_call || ' 체중 ' || coalesce(v_val, '쟀어요')
    when e.type = 'vitamin' then '💊 ' || v_call || ' 비타민 먹었어요'
    when e.type = 'tummy' and p_kind = 'end' then v_emoji || ' ' || v_call || ' 터미타임 끝' || coalesce(' (' || v_dur || ')', '')
    when t->>'kind' = 'duration' and p_kind = 'end' then v_emoji || ' ' || v_call || ' ' || v_name || ' 끝'
    when t->>'kind' = 'duration' then v_emoji || ' ' || v_call || ' ' || v_name || ' 시작'
    else v_emoji || ' ' || v_call || ' ' || v_name || coalesce(' ' || v_val, '') end;
  body := coalesce(nullif(e.created_by, ''), '누군가') || ' 기록 · '
          || to_char((case when p_kind = 'end' then e.end_at else e.start_at end) at time zone 'Asia/Seoul', 'HH24:MI')
          || case when e.type <> 'diaper' and n <> '' and n !~ '때 함께' then ' · ' || n else '' end;
end $$;

create or replace function public.process_live_pending() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare cfg jsonb; r record; e events; v_url text; n int := 0; tt record;
begin
  select data into cfg from app_config where id = 1;
  for r in select * from live_pending where due_at <= now() order by id loop
    delete from live_pending where id = r.id;
    select * into e from events where id = r.event_id;
    if not found then continue; end if;
    if r.kind = 'end' and e.end_at is null then continue; end if;
    if r.kind = 'new' and e.start_at < now() - interval '45 minutes' then continue; end if;
    select * into tt from _live_text(e, r.kind, cfg);
    insert into push_queue (title, body, tag, exclude_who) values (tt.title, tt.body, 'live-' || e.type, nullif(e.created_by, ''));
    n := n + 1;
  end loop;
  if n > 0 then
    select edge_url into v_url from app_state where id = 1;
    perform net.http_post(url := v_url, body := '{}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb);
  end if;
end $$;
revoke execute on function public.process_live_pending() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'baby-log-live';
select cron.schedule('baby-log-live', '* * * * *', 'select public.process_live_pending()');

notify pgrst, 'reload schema';
