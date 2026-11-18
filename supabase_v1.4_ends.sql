-- =====================================================================
--  아기 기록 v1.4 — "누르면 끝내기" (예: 수유·분유·목욕·기저귀 → 진행 중인 수면 종료)
--  + v1.3 "함께 기록" 포함. 앱·잠금화면 단축어 어디서 기록해도 서버에서 처리돼요.
-- =====================================================================
create or replace function public._also_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; v_links jsonb; v_ends jsonb; v_name text; l text;
begin
  if pg_trigger_depth() > 1 then return new; end if;
  if coalesce(current_setting('babylog.skip_also', true), '') = '1' then return new; end if;
  select data into cfg from app_config where id = 1;
  select t->'alsoLog', t->'ends', t->>'name' into v_links, v_ends, v_name
    from jsonb_array_elements(coalesce(cfg->'types', '[]'::jsonb)) t where t->>'id' = new.type limit 1;

  -- 끝내기: 24시간 안에 시작해 아직 안 끝난 기록을 이 기록 시각으로 종료
  if v_ends is not null and jsonb_typeof(v_ends) = 'array' then
    update events set end_at = new.start_at
     where type in (select jsonb_array_elements_text(v_ends)) and type <> new.type
       and end_at is null and start_at > now() - interval '24 hours' and start_at <= new.start_at;
  end if;

  -- 함께 기록
  if v_links is not null and jsonb_typeof(v_links) = 'array' then
    for l in select jsonb_array_elements_text(v_links) loop
      if l <> new.type then
        insert into events (type, start_at, note, created_by)
        values (l, new.start_at, coalesce(v_name, new.type) || ' 때 함께', new.created_by);
      end if;
    end loop;
  end if;
  return new;
end $$;
revoke execute on function public._also_log() from public, anon, authenticated;

drop trigger if exists trg_also_log on public.events;
create trigger trg_also_log after insert on public.events
  for each row execute function public._also_log();

-- 기본값: 모유수유·분유·목욕·기저귀를 누르면 수면 종료 (이미 설정이 있으면 그대로 둠)
update public.app_config
set data = jsonb_set(data, '{types}', (
  select jsonb_agg(case when t->>'id' in ('breast','formula','bath','diaper') and not (t ? 'ends')
                        then t || '{"ends":["sleep"]}'::jsonb else t end order by ord)
  from jsonb_array_elements(data->'types') with ordinality as x(t, ord)))
where id = 1 and data ? 'types';

notify pgrst, 'reload schema';
