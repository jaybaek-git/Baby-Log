-- =====================================================================
--  아기 기록 v1.11 — 체온이 정상 범위를 벗어나면 두 폰에 바로 알림
--  범위: app_config.data.tempRange {min, max} (기본 36.5 ~ 37.5)
-- =====================================================================
create or replace function public._temp_alert() returns trigger
language plpgsql security definer set search_path = public, extensions as $$
declare cfg jsonb; v_min numeric; v_max numeric; v_url text; v_call text; v_body text;
begin
  if new.type <> 'temp' or new.value is null then return new; end if;
  if coalesce(current_setting('babylog.skip_also', true), '') = '1' then return new; end if;
  if tg_op = 'UPDATE' and old.value is not distinct from new.value then return new; end if;
  select data into cfg from app_config where id = 1;
  v_min := coalesce((cfg->'tempRange'->>'min')::numeric, 36.5);
  v_max := coalesce((cfg->'tempRange'->>'max')::numeric, 37.5);
  if new.value >= v_min and new.value <= v_max then return new; end if;
  v_call := coalesce(nullif(cfg->'remind'->>'call', ''), '아기');
  v_body := format('정상 범위 %s~%s℃ %s · %s 기록', v_min, v_max,
                   case when new.value > v_max then '보다 높아요' else '보다 낮아요' end, coalesce(new.created_by, ''));
  if new.value >= 38.0 then
    v_body := v_body || ' · 생후 3개월 미만 아기가 38℃ 이상이면 바로 병원에 연락하세요.';
  end if;
  select edge_url into v_url from app_state where id = 1;
  insert into push_queue (title, body, tag)
  values (format('🌡️ %s 체온 %s℃ — 확인이 필요해요', v_call, new.value), v_body, 'temp');
  perform net.http_post(url := v_url, body := '{}'::jsonb, headers := '{"Content-Type":"application/json"}'::jsonb);
  return new;
end $$;
revoke execute on function public._temp_alert() from public, anon, authenticated;

drop trigger if exists trg_temp_alert on public.events;
create trigger trg_temp_alert after insert or update of value on public.events
  for each row execute function public._temp_alert();

notify pgrst, 'reload schema';
