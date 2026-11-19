# Baby-Log 인수인계 메모 (새 대화 / 비슷한 프로젝트용)

> 새 대화에서: "jaybaek-git/Baby-Log 의 HANDOFF.md 먼저 읽고 시작해 줘" 라고 하면 됩니다.
> 마지막 버전: **v1.17** (2026-11-19)

## 1. 무엇을 만들었나
- 신생아 기록 웹앱. 아빠·엄마 두 iPhone에서 같이 기록 (홈 화면에 추가한 PWA)
- 주소: https://jaybaek-git.github.io/Baby-Log/ (GitHub Pages, `main` 브랜치 루트)
- 기록 종류: 모유수유(시간+ml), 분유(ml), 기저귀(소변/대변/둘다), 수면, 목욕, 체온, 비타민, 체중, 메모(💉주사·🏥병원·💊약·📝기타)
- 화면: 위 상태 카드 3개(마지막 수유 / 다음 수유 타이머 / 마지막 기저귀) → 기록 버튼 → 차트(24시간 × 날짜) → 일별 요약 → 통계 그래프

## 2. 작업 방식 (사용자 선호)
- 작은 수정은 버전 뒤에 숫자 하나씩 (v1.16 → v1.16.1, v1.16.2 …), 큰 기능은 v1.17처럼
- 매 버전마다 `releases/Baby-Log_vX.zip` 업로드 + `index.html` 안의 `APP_VERSION` 올리기 + 커밋/푸시
- UI 변경은 **목업 먼저** 보여 달라고 할 때가 많음. 더 좋은 방안이 있으면 선택지(A/B/C)로 먼저 물어보기
- 서버(Supabase) SQL은 Claude가 MCP로 직접 적용. 적용한 SQL은 `supabase_vX_*.sql` 로 저장소에도 남김
- 보안 점검(get_advisors)은 요청할 때만
- 답변은 한국어, 모바일로 보므로 짧게

## 3. 구조
### 프런트 (`index.html` 한 파일)
- 바닐라 JS, `h()` DOM 헬퍼, 차트는 SVG 문자열로 그림
- 폰별 설정(localStorage): `bl_dev`(연결정보: url/key/code/who), `bl_theme`, `bl_order`(버튼 순서), `bl_size`(버튼 크기), `bl_compact`, `bl_zoom`, `bl_hidden`(범례 숨김), `bl_readmode`(차트 읽기 모드), `bl_stats`(통계 그래프), `bl_listMemo`
- 공통 설정(서버 `app_config.data`): `types[]`(id, name, emoji, color, kind=point/duration, feed, unit, presets, defaultValue, tags, marker, small, daily, noChart, alsoLog, ends), `title`, `babyName`, `birthDate`(D+는 태어난 날=D+1), `alarm`, `remind`, `tempRange`, `timeRound`, `liveNotify`, `liveDelay`, `overdue`, `memoCats`
- 주요 함수: `renderChart`, `renderButtons`, `renderSettings`, `openEdit`, `openMemo`, `viewRecords`, `sheet/closeSheet`, `toast`, `statValues`, 실행취소/다시실행 히스토리

### 서버 (Supabase)
- 테이블: `events`(type, start_at, end_at, value, note, created_by), `app_config`, `app_secret`(가족 코드), `push_subs`, `push_queue`, `backups`, `live_pending`
- RLS 켜고 직접 접근 막음 → 전부 `SECURITY DEFINER` RPC + `_chk(가족코드)` 로 확인
- RPC: add_event, toggle_event, list_events, update_event, delete_event, import_events, get_config, set_config, alarm_status, test_push, save_push_sub, get_vapid_public, list_backups, backup_now, restore_backup, **voice_log**(음성 문장 해석)
- 트리거: 함께 기록(alsoLog), 수면 자동 종료(ends), 시간 반올림, 체온 경고, 상대방 기록 알림
- pg_cron(매 분): 수유 알림, 챙기기 알림, 상대방 알림, 수유 지연 경고 / 30분마다 백업
- 알림: pg_net → Edge Function `push`(`edge_function_push.ts`, web-push, VAPID 키는 DB에) / 기록한 사람 폰은 제외
- SQL 적용 순서: `supabase_setup.sql` → v1.1 → v1.3 → v1.4 → v1.6 → v1.8 → v1.9 → v1.11 → v1.13 → v1.14 → v1.15 → v1.16_voice → v1.16_memo

## 4. 꼭 알아야 할 함정
- **iOS 18 홈 화면 앱에서 키보드가 안 뜸** (Safari에서는 뜸). 앱 버그 아님 → 숫자는 화면 숫자패드(`numPad`), 글자는 ✏️ `prompt()`·연결 코드 붙여넣기로 우회. 아이콘 삭제 후 다시 추가하면 고쳐질 수 있음
- 웹 푸시는 **홈 화면 앱에서만** 동작 (iOS 16.4+). Safari 탭에서는 안 됨
- GitHub Pages 반영까지 몇 분 + 홈 화면 앱은 옛 화면을 붙잡고 있음 → 앱 완전히 종료 후 재실행, 설정 맨 아래 버전 확인
- 버튼 3칸 그리드는 `minmax(0,1fr)` 필수 (긴 글자가 칸을 밀어 화면 밖으로 나감)
- 가족 코드·Supabase 키는 **저장소에 올리지 않음** (저장소 공개). 사용자가 앱에 직접 입력

## 5. Siri 음성 기록 (진행 중)
- 서버 `voice_log(p_code, p_text, p_by)` 준비 완료: "맘마 80 먹었어", "똥 쌌어", "기저귀 갈았어", "쉬야했어", "10분 전에 재웠어", "깼어", "체온 36.9", "메모 소아과 다녀옴" 등 해석 ("맘마"는 항상 분유)
- 남은 일: iPhone 단축어 만들기 안내 (받아쓰기 → URL 내용 가져오기 POST `rpc/voice_log` → 결과 표시). 사용법은 README "v1.16 — 음성 기록"

## 6. 앞으로 하고 싶다고 한 것
- 네이티브 iOS 앱 (잠금화면 라이브 액티비티 버튼) — 웹앱을 더 다듬은 뒤
- 통계 막대 누르면 그날 상세 보기
- 예방접종 일정 알림 (생일 기준)
- 메모 자주 쓰는 문구 버튼

## 7. 비슷한 새 프로젝트로 복제할 때
1. 새 GitHub 저장소 만들기 → 이 저장소의 `index.html`, `sw.js`, `manifest.json`, 아이콘, SQL 파일 복사
2. **새 Supabase 프로젝트** 만들기 (데이터 섞이지 않게) → SQL을 위 순서대로 적용, VAPID 키 생성, Edge Function `push` 배포, cron 등록
3. `DEFAULT_TYPES`(기록 종류)와 문구(아기 이름, 알림 말투)를 새 용도에 맞게 수정
4. GitHub Pages 켜기 → Safari에서 열고 홈 화면에 추가 → 연결 정보 입력
