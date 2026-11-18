-- =====================================================================
--  아기 기록 v1.13 — 최근 시간대에 새로 기록되면 "다른 폰"에 알림
--  · 지금 기준 30분 이내 시각의 새 기록 / 모유수유·수면 종료만 알림 (과거 기록·수정은 알림 없음)
--  · 기록한 사람(created_by) 폰은 제외 (push_subs.who 기준)
--  · 끄기: app_config.data.liveNotify = false
-- =====================================================================
alter table public.push_queue add column if not exists exclude_who text;

create or replace function public._live_notify() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare cfg jsonb; t jsonb; v_name text; v_emoji text; v_unit text; v_title text; v_body text; v_url text; v_who text;
begin
  if pg_trigger_depth() > 1 then return new; end if;
  if coalesce(current_setting('babylog.skip_also', true), '') = '1' then return new; end if;
  select data into cfg from app_config where id = 1;
  if coalesce((cfg->>'liveNotify')::bool, true) = false then return new; end if;
  select x into t from jsonb_array_elements(coalesce(cfg->'types','[]'::jsonb)) x where x->>'id' = new.type limit 1;
  v_name := coalesce(t->>'name', new.type); v_emoji := coalesce(t->>'emoji', ''); v_unit := coalesce(t->>'unit', '');
  v_who := coalesce(nullif(new.created_by, ''), '누군가');

  if tg_op = 'INSERT' then
    if new.start_at < now() - interval '30 minutes' or new.start_at > now() + interval '10 minutes' then return new; end if;
    v_title := format('%s %s · %s %s', v_emoji, v_who, v_name,
                      case when t->>'kind' = 'duration' and new.end_at is null then '시작' else '기록' end);
    v_body := to_char(new.start_at at time zone 'Asia/Seoul', 'HH24:MI')
              || coalesce(' · ' || new.value::text || v_unit, '') || coalesce(' · ' || new.note, '');
  elsif tg_op = 'UPDATE' then
    if not (old.end_at is null and new.end_at is not null) then return new; end if;
    if new.end_at < now() - interval '30 minutes' then return new; end if;
    v_title := format('%s %s 끝', v_emoji, v_name);
    v_body := to_char(new.start_at at time zone 'Asia/Seoul', 'HH24:MI') || '–' || to_char(new.end_at at time zone 'Asia/Seoul', 'HH24:MI')
              || ' · ' || _fmt_min(extract(epoch from new.end_at - new.start_at) / 60);
  else return new; end if;

  select edge_url into v_url from app_state where id = 1;
  insert into push_queue (title, body, tag, exclude_who) values (v_title, v_body, 'live-' || new.type, nullif(new.created_by, ''));
  perform net.http_post(url := v_url, body := '{}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb);
  return new;
end $$;
revoke execute on function public._live_notify() from public, anon, authenticated;

drop trigger if exists trg_live_notify on public.events;
create trigger trg_live_notify after insert or update of end_at on public.events
  for each row execute function public._live_notify();

notify pgrst, 'reload schema';
