-- =====================================================================
--  아기 기록 v1.9 — 비타민·체온·체중 챙기기 알림
--  오늘 아직 기록이 없으면, 설정한 시간대 안에서 N시간마다 두 폰에 알림
--  설정(app_config.data.remind): enabled, start "09:00", end "21:00", every 2, items [...], call "예린이"
-- =====================================================================
alter table public.app_state add column if not exists remind_key text;

create or replace function public.check_reminders() returns void
language plpgsql security definer set search_path = public, extensions as $$
declare
  cfg jsonb; r jsonb; v_now timestamp; v_today timestamptz; v_start time; v_end time; v_every int;
  v_mins int; v_key text; v_items text[]; v_pending text[] := '{}'; v_call text; it text;
  v_title text; v_body text; v_url text; v_names text[] := '{}';
begin
  select data into cfg from app_config where id = 1;
  r := coalesce(cfg->'remind', '{}'::jsonb);
  if not coalesce((r->>'enabled')::bool, false) then return; end if;
  v_now   := now() at time zone 'Asia/Seoul';
  v_start := coalesce(r->>'start', '09:00')::time;
  v_end   := coalesce(r->>'end', '21:00')::time;
  v_every := greatest(1, coalesce((r->>'every')::int, 2));
  if v_now::time < v_start or v_now::time > v_end then return; end if;
  v_mins := (extract(epoch from (v_now::time - v_start)) / 60)::int;
  if v_mins % (v_every * 60) <> 0 then return; end if;
  v_key := to_char(v_now, 'YYYY-MM-DD HH24:MI');
  if exists (select 1 from app_state where id = 1 and remind_key = v_key) then return; end if;

  v_today := date_trunc('day', v_now) at time zone 'Asia/Seoul';
  select array_agg(x) into v_items from jsonb_array_elements_text(coalesce(r->'items', '["vitamin","temp","weight"]'::jsonb)) x;
  foreach it in array coalesce(v_items, '{}') loop
    if not exists (select 1 from events where type = it and start_at >= v_today) then
      v_pending := v_pending || it;
    end if;
  end loop;
  update app_state set remind_key = v_key where id = 1;
  if cardinality(v_pending) = 0 then return; end if;

  v_call := coalesce(nullif(r->>'call', ''), '아기');
  foreach it in array v_pending loop
    v_names := v_names || (case it when 'vitamin' then '💊 비타민' when 'temp' then '🌡️ 체온' when 'weight' then '⚖️ 체중'
      else coalesce((select t->>'emoji' || ' ' || (t->>'name') from jsonb_array_elements(cfg->'types') t where t->>'id' = it limit 1), it) end);
  end loop;
  if cardinality(v_pending) = 1 then
    v_title := case v_pending[1]
      when 'vitamin' then '엄마·아빠, ' || v_call || ' 비타민 주세요! 💊'
      when 'temp'    then '엄마·아빠, ' || v_call || ' 체온 재 주세요! 🌡️'
      when 'weight'  then '엄마·아빠, ' || v_call || ' 체중 재 주세요! ⚖️'
      else '엄마·아빠, ' || v_call || ' ' || v_names[1] || ' 챙겨 주세요!' end;
    v_body := '오늘 아직 기록이 없어요.';
  else
    v_title := '엄마·아빠, ' || v_call || ' 챙길 게 있어요!';
    v_body := array_to_string(v_names, ' · ') || ' — 오늘 아직이에요.';
  end if;

  select edge_url into v_url from app_state where id = 1;
  insert into push_queue (title, body, tag) values (v_title, v_body, 'remind');
  perform net.http_post(url := v_url, body := '{}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb);
end $$;
revoke execute on function public.check_reminders() from public, anon, authenticated;

select cron.unschedule(jobid) from cron.job where jobname = 'baby-log-remind';
select cron.schedule('baby-log-remind', '* * * * *', 'select public.check_reminders()');

notify pgrst, 'reload schema';
