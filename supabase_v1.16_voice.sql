-- Baby-Log v1.16 : 음성(Siri 받아쓰기) 기록
-- voice_log(가족코드, 말한 문장, 누가) → Siri가 읽어 줄 답장 문자열
-- 예) "맘마 80 먹었어" "똥 쌌어" "기저귀 갈았어" "쉬야했어" "10분 전에 재웠어" "깼어" "체온 36.9" "3시 반에 목욕했어"

create or replace function public._voice_time(p text, out t timestamptz, out dur int, out rest text)
language plpgsql as $$
declare
  s text := p; m text[]; h int; mi int; nowl timestamp := now() at time zone 'Asia/Seoul';
  c timestamp; best timestamp; d int; hs int[]; hh int; mark text;
begin
  t := now(); dur := null;
  -- 한/두/세 → 숫자 (시간 앞에서만)
  s := regexp_replace(s, '(^|\s)한\s*시간', '\1 1시간', 'g');
  s := regexp_replace(s, '(^|\s)두\s*시간', '\1 2시간', 'g');
  s := regexp_replace(s, '(^|\s)세\s*시간', '\1 3시간', 'g');
  s := regexp_replace(s, '(^|\s)네\s*시간', '\1 4시간', 'g');
  -- N분 동안 / N분간 → 길이
  m := regexp_match(s, '(\d+)\s*분\s*(동안|간)');
  if m is not null then dur := m[1]::int; s := regexp_replace(s, '(\d+)\s*분\s*(동안|간)', ' '); end if;
  -- N시간 (반) 전
  m := regexp_match(s, '(\d+)\s*시간\s*(반)?\s*(쯤|정도)?\s*전');
  if m is not null then
    t := now() - make_interval(mins => m[1]::int*60 + case when m[2] is not null then 30 else 0 end);
    s := regexp_replace(s, '(\d+)\s*시간\s*(반)?\s*(쯤|정도)?\s*전', ' ');
  end if;
  -- N분 전
  m := regexp_match(s, '(\d+)\s*분\s*(쯤|정도)?\s*전');
  if m is not null then
    t := t - make_interval(mins => m[1]::int);
    s := regexp_replace(s, '(\d+)\s*분\s*(쯤|정도)?\s*전', ' ');
  end if;
  -- 오후 3시 반 / 3시 20분 / 15:20
  m := regexp_match(s, '(오전|오후|새벽|아침|저녁|밤|낮)?\s*(\d{1,2})\s*시(?!간)\s*(반|(\d{1,2})\s*분)?');
  if m is null then
    m := regexp_match(s, '(오전|오후|새벽|아침|저녁|밤|낮)?\s*(\d{1,2}):(\d{2})()');
    if m is not null then m := array[m[1], m[2], m[3], m[3]]; end if;
    if m is not null then s := regexp_replace(s, '(오전|오후|새벽|아침|저녁|밤|낮)?\s*(\d{1,2}):(\d{2})', ' '); end if;
  else
    s := regexp_replace(s, '(오전|오후|새벽|아침|저녁|밤|낮)?\s*(\d{1,2})\s*시(?!간)\s*(반|(\d{1,2})\s*분)?', ' ');
  end if;
  if m is not null then
    mark := m[1]; h := m[2]::int;
    mi := case when m[3] = '반' then 30 when m[4] is not null and m[4] <> '' then m[4]::int else 0 end;
    if h <= 24 and mi < 60 then
      if mark in ('오후','저녁','밤') and h < 12 then hs := array[h+12];
      elsif mark in ('오전','새벽','아침') then hs := array[h % 12];
      elsif mark = '낮' then hs := array[case when h < 7 then h+12 else h end];
      elsif h >= 13 then hs := array[h % 24];
      else hs := array[h % 12, h % 12 + 12]; end if;
      best := null;
      foreach hh in array hs loop
        for d in 0..1 loop
          c := date_trunc('day', nowl) - make_interval(days => d) + make_interval(hours => hh, mins => mi);
          if c <= nowl + interval '2 minutes' and (best is null or c > best) then best := c; end if;
        end loop;
      end loop;
      if best is not null then t := best at time zone 'Asia/Seoul'; end if;
    end if;
  end if;
  rest := s;
end $$;
revoke execute on function public._voice_time(text) from public, anon, authenticated;

create or replace function public.voice_log(p_code text, p_text text, p_by text default null)
returns text language plpgsql security definer set search_path = public as $$
declare
  raw text := coalesce(p_text, '');
  s text; tt record; t timestamptz; r events; cfg jsonb; dv numeric;
  num numeric; m text[]; msgs text[] := '{}'; v_note text; done boolean := false;
  d int; is_breast boolean; is_formula boolean; is_end boolean; is_start boolean;
begin
  perform _chk(p_code);
  s := lower(regexp_replace(raw, '[.,!?~]+(\s|$)', ' \1', 'g'));
  s := regexp_replace(s, '(\d)\s*(점|\.)\s*(\d)', '\1.\3', 'g');
  select * into tt from _voice_time(s);
  t := tt.t; s := ' ' || tt.rest || ' ';
  select data into cfg from app_config limit 1;
  m := regexp_match(s, '(\d+(\.\d+)?)');
  num := case when m is null then null else m[1]::numeric end;
  is_end := s ~ '(끝|다\s*먹|그만|멈|종료|깼|깨어|일어났|기상)';
  is_start := s ~ '시작';

  -- 체온
  if s ~ '(체온|열\s|열이|온도)' then
    if num is null or num < 30 or num > 43 then return '🌡 체온 숫자를 같이 말해 주세요 (예: 체온 36.9)'; end if;
    insert into events(type,start_at,value,created_by) values('temp',t,num,p_by);
    msgs := msgs || format('🌡 체온 %s℃', num); num := null; done := true;
  end if;
  -- 체중
  if s ~ '(체중|몸무게|킬로|kg)' then
    if num is null then return '⚖️ 몸무게 숫자를 같이 말해 주세요 (예: 체중 4.5)'; end if;
    if num > 100 then num := round(num/1000, 2); end if;
    insert into events(type,start_at,value,created_by) values('weight',t,num,p_by);
    msgs := msgs || format('⚖️ 체중 %skg', num); num := null; done := true;
  end if;
  -- 기저귀 (똥/쉬)
  if s ~ '(기저귀|똥|응가|대변|큰\s*거|쉬|소변|오줌|작은\s*거)' then
    v_note := case
      when s ~ '(똥|응가|대변|큰\s*거)' and s ~ '(쉬|소변|오줌|작은\s*거)' then '둘다'
      when s ~ '(똥|응가|대변|큰\s*거)' then '대변'
      when s ~ '(쉬|소변|오줌|작은\s*거)' then '소변' end;
    insert into events(type,start_at,note,created_by) values('diaper',t,v_note,p_by);
    msgs := msgs || case v_note when '대변' then '💩 응가' when '소변' then '💧 쉬야' when '둘다' then '💩💧 응가+쉬야' else '🩲 기저귀' end;
    done := true;
  end if;
  -- 목욕
  if s ~ '(목욕|씻)' then
    insert into events(type,start_at,created_by) values('bath',t,p_by);
    msgs := msgs || '🛁 목욕'::text; done := true;
  end if;
  -- 비타민
  if s ~ '(비타민|영양제)' then
    insert into events(type,start_at,created_by) values('vitamin',t,p_by);
    msgs := msgs || '💊 비타민'::text; done := true;
  end if;
  -- 수유
  is_breast := s ~ '(모유|젖\s|젖을|젖\s*먹|직수)';
  is_formula := s ~ '(분유|맘마|우유|젖병)' or (not is_breast and s ~ '수유');
  if is_breast then
    v_note := case when s ~ '(양쪽|양\s*쪽)' then '양쪽' when s ~ '왼' then '왼쪽' when s ~ '오른' then '오른쪽' end;
    select * into r from events where type='breast' and end_at is null and start_at > now() - interval '24 hours' order by start_at desc limit 1;
    if tt.dur is not null then
      insert into events(type,start_at,end_at,value,note,created_by) values('breast',t - make_interval(mins=>tt.dur),t,num,v_note,p_by);
      msgs := msgs || format('🤱 모유 %s분%s', tt.dur, coalesce(' '||num||'ml',''));
    elsif r.id is not null and not is_start then
      update events set end_at = greatest(t, start_at), value = coalesce(num, value), note = coalesce(v_note, events.note) where id = r.id;
      msgs := msgs || format('🤱 모유 끝 (%s분)', greatest(0, round(extract(epoch from (greatest(t, r.start_at) - r.start_at))/60)::int));
    else
      insert into events(type,start_at,value,note,created_by) values('breast',t,num,v_note,p_by);
      msgs := msgs || '🤱 모유 시작'::text;
    end if;
    num := null; done := true;
  end if;
  if is_formula and not (is_breast and s !~ '분유') then
    select nullif(x->>'defaultValue','')::numeric into dv from jsonb_array_elements(cfg->'types') x where x->>'id'='formula';
    if num is null or num < 5 or num > 400 then num := coalesce(dv, 90); end if;
    insert into events(type,start_at,value,created_by) values('formula',t,num,p_by);
    msgs := msgs || format('🍼 분유 %sml', num); done := true;
  end if;
  -- 수면
  if s ~ '(깼|깨어|일어났|기상|잠\s*끝|수면\s*끝)' then
    select * into r from events where type='sleep' and end_at is null and start_at > now() - interval '24 hours' order by start_at desc limit 1;
    if r.id is null then
      if not done then return '😴 지금 자는 중인 기록이 없어요'; end if;
    else
      update events set end_at = greatest(t, start_at) where id = r.id;
      d := (extract(epoch from (greatest(t, r.start_at) - r.start_at))/60)::int;
      msgs := msgs || format('🌞 기상 (%s 잤어요)', case when d >= 60 then (d/60) || '시간 ' else '' end || (d % 60) || '분');
      done := true;
    end if;
  elsif s ~ '(재웠|잠들|잠\s*들|잤|자요|자기|자고|자는|잔다|낮잠|수면|꿈나라|코\s*자)' then
    if tt.dur is not null then
      insert into events(type,start_at,end_at,created_by) values('sleep',t - make_interval(mins=>tt.dur),t,p_by);
      msgs := msgs || format('😴 수면 %s분', tt.dur);
    else
      insert into events(type,start_at,created_by) values('sleep',t,p_by);
      msgs := msgs || '😴 수면 시작'::text;
    end if;
    done := true;
  end if;

  if not done then
    return format('잘 못 알아들었어요: "%s" — 예) 맘마 80 먹었어, 응가했어, 재웠어', trim(raw));
  end if;
  return array_to_string(msgs, ', ') || ' 기록했어요'
    || case when t < now() - interval '2 minutes' then ' (' || to_char(t at time zone 'Asia/Seoul', 'HH24:MI') || ')' else '' end;
end $$;
grant execute on function public.voice_log(text, text, text) to anon, authenticated;
