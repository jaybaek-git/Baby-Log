-- Baby-Log v1.16 : 메모 메뉴 (주사·병원·약·기타) + 알림 문구 + 음성 "메모 ..."
update app_config set data = jsonb_set(data, '{types}', (data->'types') ||
  '[{"id":"memo","name":"메모","emoji":"📝","color":"#B39DDB","kind":"point","enabled":true,"marker":true,"small":true,"daily":false}]'::jsonb)
 where not exists (select 1 from jsonb_array_elements(data->'types') x where x->>'id' = 'memo');
update app_config set data = data || '{"memoCats":[{"e":"💉","n":"주사·접종"},{"e":"🏥","n":"병원"},{"e":"💊","n":"약"},{"e":"📝","n":"기타"}]}'::jsonb
 where not (data ? 'memoCats');

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
    when e.type = 'memo' then '📝 ' || v_call || ' 메모: ' || left(n, 60)
    when e.type = 'vitamin' then '💊 ' || v_call || ' 비타민 먹었어요'
    when e.type = 'tummy' and p_kind = 'end' then v_emoji || ' ' || v_call || ' 터미타임 끝' || coalesce(' (' || v_dur || ')', '')
    when t->>'kind' = 'duration' and p_kind = 'end' then v_emoji || ' ' || v_call || ' ' || v_name || ' 끝'
    when t->>'kind' = 'duration' then v_emoji || ' ' || v_call || ' ' || v_name || ' 시작'
    else v_emoji || ' ' || v_call || ' ' || v_name || coalesce(' ' || v_val, '') end;
  body := coalesce(nullif(e.created_by, ''), '누군가') || ' 기록 · '
          || to_char((case when p_kind = 'end' then e.end_at else e.start_at end) at time zone 'Asia/Seoul', 'HH24:MI')
          || case when e.type not in ('diaper','memo') and n <> '' and n !~ '때 함께' then ' · ' || n else '' end;
end $$;



-- 음성: "메모 ..." 로 시작하면 메모로 저장, 나머지는 기존 해석(_voice_core)으로
do $$ begin
  if not exists (select 1 from pg_proc where proname = '_voice_core') then
    alter function public.voice_log(text, text, text) rename to _voice_core;
  end if;
end $$;
revoke execute on function public._voice_core(text, text, text) from public, anon, authenticated;

create or replace function public.voice_log(p_code text, p_text text, p_by text default null)
returns text language plpgsql security definer set search_path = public as $$
declare m text[]; tt record; s text; v_note text;
begin
  perform _chk(p_code);
  m := regexp_match(coalesce(p_text, ''), '^\s*(메모|노트)\s*[,.:]?\s*(.*)$');
  if m is null then return _voice_core(p_code, p_text, p_by); end if;
  select * into tt from _voice_time(m[2]);
  s := trim(regexp_replace(tt.rest, '^\s*에\s*', ''));
  if s = '' then return '📝 메모 내용도 같이 말해 주세요 (예: 메모 소아과 다녀옴)'; end if;
  v_note := case when s ~ '(주사|접종|백신)' then '💉 ' when s ~ '(병원|소아과|검진|진료)' then '🏥 '
                 when s ~ '(약|시럽|해열제)' then '💊 ' else '📝 ' end || s;
  insert into events(type, start_at, note, created_by) values ('memo', tt.t, v_note, p_by);
  return '📝 메모 저장했어요: ' || s;
end $$;
grant execute on function public.voice_log(text, text, text) to anon, authenticated;
