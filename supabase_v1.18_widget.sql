-- Baby-Log v1.18 : 잠금화면/홈화면 위젯용 요약 (Scriptable)
create or replace function public.widget_status(p_code text) returns json
language plpgsql security definer set search_path = public as $$
declare cfg jsonb; feeds text[]; lf events; ld events; sl events; a json; d0 timestamptz;
begin
  perform _chk(p_code);
  select data into cfg from app_config limit 1;
  select coalesce(array_agg(x->>'id'), array['formula','breast']) into feeds
    from jsonb_array_elements(coalesce(cfg->'types','[]'::jsonb)) x where (x->>'feed')::boolean is true;
  select * into lf from events where type = any(feeds) order by start_at desc limit 1;
  select * into ld from events where type = 'diaper' order by start_at desc limit 1;
  select * into sl from events where type = 'sleep' and end_at is null and start_at > now() - interval '24 hours' order by start_at desc limit 1;
  a := alarm_status(p_code);
  d0 := date_trunc('day', now() at time zone 'Asia/Seoul') at time zone 'Asia/Seoul';
  return json_build_object(
    'name', coalesce(nullif(cfg->>'babyName',''), cfg->'remind'->>'call', '아기'),
    'last_feed', case when lf.id is null then null else json_build_object('at', lf.start_at, 'type', lf.type, 'value', lf.value, 'open', lf.end_at is null and lf.type <> 'formula') end,
    'due_at', a->>'due_at',
    'last_diaper', case when ld.id is null then null else json_build_object('at', ld.start_at, 'note', ld.note) end,
    'sleep_since', sl.start_at,
    'today', json_build_object(
      'ml', (select coalesce(sum(value),0) from events where type = any(feeds) and start_at >= d0),
      'feeds', (select count(*) from events where type = any(feeds) and start_at >= d0),
      'diapers', (select count(*) from events where type = 'diaper' and start_at >= d0)));
end $$;
grant execute on function public.widget_status(text) to anon, authenticated;
