-- =====================================================================
--  아기 기록 v1.8 — 시간 기록 단위 (1분 그대로 / 5분 반올림 / 10분 반올림)
--  앱·잠금화면 단축어 어디서 기록해도 서버에서 같은 규칙으로 맞춰요.
--  (백업 복구·가져오기 때는 원래 시간을 그대로 둬요)
-- =====================================================================
create or replace function public._round_ts(ts timestamptz, n int) returns timestamptz
language sql immutable as $$
  select case when ts is null or n is null or n <= 1 then ts
              else to_timestamp(round(extract(epoch from ts) / (n * 60)) * (n * 60)) end $$;

create or replace function public._time_round() returns trigger
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if coalesce(current_setting('babylog.skip_also', true), '') = '1' then return new; end if;
  select coalesce((data->>'timeRound')::int, 1) into n from app_config where id = 1;
  if n is null or n <= 1 then return new; end if;
  new.start_at := _round_ts(new.start_at, n);
  new.end_at := _round_ts(new.end_at, n);
  if new.end_at is not null and new.end_at < new.start_at then new.end_at := new.start_at; end if;
  return new;
end $$;
revoke execute on function public._time_round() from public, anon, authenticated;

drop trigger if exists trg_time_round on public.events;
create trigger trg_time_round before insert or update of start_at, end_at on public.events
  for each row execute function public._time_round();

notify pgrst, 'reload schema';
