-- =====================================================================
--  아기 기록 v1.3 — "함께 기록" (예: 목욕하면 기저귀도 자동 기록)
--  SQL Editor → 붙여넣기 → Run (한 번만)
--  앱 · 잠금화면 단축어 어디서 기록해도 서버에서 같이 기록돼요.
-- =====================================================================
create or replace function public._also_log() returns trigger
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; v_links jsonb; v_name text; l text;
begin
  if pg_trigger_depth() > 1 then return new; end if;
  if coalesce(current_setting('babylog.skip_also', true), '') = '1' then return new; end if;
  select data into cfg from app_config where id = 1;
  select t->'alsoLog', t->>'name' into v_links, v_name
    from jsonb_array_elements(coalesce(cfg->'types', '[]'::jsonb)) t where t->>'id' = new.type limit 1;
  if v_links is null or jsonb_typeof(v_links) <> 'array' then return new; end if;
  for l in select jsonb_array_elements_text(v_links) loop
    if l <> new.type then
      insert into events (type, start_at, note, created_by)
      values (l, new.start_at, coalesce(v_name, new.type) || ' 때 함께', new.created_by);
    end if;
  end loop;
  return new;
end $$;
revoke execute on function public._also_log() from public, anon, authenticated;

drop trigger if exists trg_also_log on public.events;
create trigger trg_also_log after insert on public.events
  for each row execute function public._also_log();

-- 백업 불러오기·메모 가져오기(대량 입력) 때는 중복이 생기지 않도록 함께 기록을 끔
create or replace function public.import_events(p_code text, p_rows jsonb)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _chk(p_code);
  perform set_config('babylog.skip_also', '1', true);
  insert into events (type, start_at, end_at, value, note, created_by)
  select r->>'type', (r->>'start_at')::timestamptz, nullif(r->>'end_at', '')::timestamptz,
         nullif(r->>'value', '')::numeric, r->>'note', r->>'created_by'
    from jsonb_array_elements(p_rows) r;
  get diagnostics n = row_count;
  perform set_config('babylog.skip_also', '', true);
  return n;
end $$;

notify pgrst, 'reload schema';
