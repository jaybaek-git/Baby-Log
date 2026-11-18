# 아기 기록 v1.0 — 사용설명서

## 구성
- `index.html` : 웹앱 (기록 버튼 · 24시간×7일 차트 · 목록 · 설정)
- `supabase_setup.sql` : 두 폰 동기화용 데이터베이스 설정
- `manifest.json`, `icon-180.png`, `icon-512.png` : 홈 화면 아이콘

## 1. Supabase 만들기 (5분)
1. supabase.com → Start your project → GitHub/Google로 가입
2. New project → Region: **Northeast Asia (Seoul)** → 생성
3. 왼쪽 **SQL Editor** → `supabase_setup.sql` 내용을 붙여넣기
4. `CHANGE-ME-우리가족-비밀코드-2026` 부분을 **우리만 아는 긴 코드**로 바꾸기 → **Run**
5. **Project Settings → API**(또는 Data API / API Keys)에서 확인
   - Project URL (예: `https://abcd.supabase.co`)
   - anon public key 또는 publishable key

> 무료 프로젝트는 7일 동안 사용이 없으면 일시정지돼요. 매일 쓰면 문제 없어요.

## 2. 웹에 올리기 (GitHub Pages)
1. GitHub 저장소에 `BabyLog` 폴더째 업로드 (index.html 등 4개 파일)
2. 저장소 **Settings → Pages** → Source: Deploy from a branch → `main` / `(root)` → Save
3. 1~2분 뒤 주소: `https://<아이디>.github.io/<저장소>/BabyLog/`

> 무료 GitHub Pages는 공개 저장소에서만 켜져요. 코드에는 키나 코드가 들어 있지 않아요(폰의 설정 탭에만 저장).

## 3. 아이폰에 설치 (두 분 모두)
1. 사파리로 위 주소 열기 → 공유 버튼 → **홈 화면에 추가**
2. 앱 열기 → **설정** 탭 → Project URL / API Key / 가족 코드 / 내 이름(아빠·엄마) 입력 → **저장 & 연결 테스트**
3. 오른쪽 위 점이 초록색 "동기화"면 완료

## 4. 잠금화면 버튼 (단축어)
설정 탭 아래 **잠금화면 단축어 설정값**에 값이 정리되어 있어요(복사 버튼).

1. 단축어 앱 → + → **URL 내용 가져오기**
   - URL: 설정 탭의 URL (한 번 탭 항목은 `add_event`, 시작/끝 항목은 `toggle_event`)
   - 방법: **POST**
   - 헤더: `apikey` = API Key  *(오류가 나면 `Authorization` = `Bearer <API Key>`도 추가)*
   - 요청 본문: **JSON** → `p_code` = 가족 코드, `p_type` = 항목 ID(예: `diaper`), (선택) `p_by` = 아빠
2. 이어서 **알림 보기** 동작 추가 → "기록됨"
3. 이름·아이콘 정하고 저장 → 잠금화면 하단 2칸 / 제어센터에 단축어 컨트롤로 추가

| 항목 | p_type | URL 끝 |
|---|---|---|
| 모유수유 (시작/끝) | breast | toggle_event |
| 분유 | formula | add_event (+ `p_value` = ml) |
| 기저귀 | diaper | add_event |
| 수면 (시작/끝) | sleep | toggle_event |
| 목욕 | bath | add_event |
| 체온 | temp | add_event (+ `p_value`) |
| 비타민 | vitamin | add_event |
| 터미타임 (시작/끝) | tummy | toggle_event |
| 기타 | etc | add_event |
| 기록A / 기록B | recA / recB | add_event |

> 대안: 단축어에서 **URL 열기**로 `.../BabyLog/?add=diaper` 를 열어도 앱이 열리면서 바로 기록돼요(앱 화면이 뜸).

## 5. 사용법
- **버튼 탭**: 바로 기록 → 아래 알림에서 메모(소변/대변, 왼쪽/오른쪽)·수정·취소
- **시작/끝 항목**(모유수유·수면·터미타임): 한 번 누르면 시작, 다시 누르면 끝
- **차트**: 세로 0~24시, 가로 7일. 좌우로 밀면 지난주. 표시를 탭하면 수정, 빈 곳을 탭하면 그 시각에 기록 추가. 범례를 탭하면 숨기기
- **설정 → 기록 버튼(메뉴)**: 목욕·체온·비타민·터미타임·기타·기록A·기록B 켜기/끄기, 이름·이모지·색·순서 변경, 새 항목 추가 → **메뉴 저장** (두 폰에 같이 적용)
- **데이터**: JSON 백업/불러오기, 엑셀용 CSV, 메모 앱 기록 가져오기
