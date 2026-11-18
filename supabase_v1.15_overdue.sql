-- =====================================================================
--  아기 기록 v1.15 — 수유가 오래 끊기면 반복 알림
--  마지막 수유 끝에서 afterMin(기본 240분) 지나면 everyMin(기본 5분)마다 두 폰에 알림
--  설정: app_config.data.overdue {enabled, afterMin, everyMin}
-- =====================================================================
alter table public.app_state add column if not exists overdue_key text;

create or replace function public.check_overdue() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare cfg jsonb; o jsonb; a json; v_last timestamptz; v_after int; v_every int; v_since numeric; v_over int;
        v_key text; v_url text; v_call text;
begin
  select data into cfg from app_config where id = 1;
  o := coalesce(cfg->'overdue', '{}'::jsonb);
  if not coalesce((o->>'enabled')::bool, true) then return; end if;
  v_after := greatest(30, coalesce((o->>'afterMin')::int, 240));
  v_every := greatest(1, coalesce((o->>'everyMin')::int, 5));
  a := _alarm_calc();
  if (a->>'open_feed')::bool or a->>'last_end' is null then return; end if;
  v_last := (a->>'last_end')::timestamptz;
  if v_last < now() - interval '12 hours' then return; end if;
  v_since := extract(epoch from now() - v_last) / 60;
  if v_since < v_after then return; end if;
  v_over := floor(v_since - v_after)::int;
  if v_over % v_every <> 0 then return; end if;
  v_key := to_char(v_last, 'YYYYMMDDHH24MISS') || ':' || floor(v_since)::int;
  if exists (select 1 from app_state where id = 1 and overdue_key = v_key) then return; end if;
  update app_state set overdue_key = v_key where id = 1;
  v_call := coalesce(nullif(cfg->'remind'->>'call', ''), '아기');
  select edge_url into v_url from app_state where id = 1;
  insert into push_queue (title, body, tag) values (
    format('🚨 %s 수유한 지 %s 지났어요', v_call, _fmt_min(v_since)),
    format('마지막 수유 끝 %s · 기록을 깜빡했다면 앱에서 넣어 주세요', to_char(v_last at time zone 'Asia/Seoul', 'HH24:MI')),
    'overdue');
  perform net.http_post(url := v_url, body := '{}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;
revoke execute on function public.check_overdue() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'baby-log-overdue';
select cron.schedule('baby-log-overdue', '* * * * *', 'select public.check_overdue()');

update public.app_config set data = data || '{"overdue":{"enabled":true,"afterMin":240,"everyMin":5}}'::jsonb
 where id = 1 and not (data ? 'overdue');
notify pgrst, 'reload schema';
