# A-mon Windows

macOS 메뉴바 앱(`../macos`)의 Windows 대응 — **하단 트레이 상주 앱**(Go).

## 기능 (버전은 macOS 앱과 정책 공유 — 저장소 루트에서 `make version` 으로 확인)

- 10분 주기로 로컬 AI 도구 로그를 스캔해 트레이 메뉴에 표시 (경로는 2026-07
  공식 문서 기준 검증, 환경변수 오버라이드 지원)
  - Claude Code `%USERPROFILE%\.claude\projects` (`CLAUDE_CONFIG_DIR` 지원) —
    (message.id, requestId) dedup
  - Codex CLI `%USERPROFILE%\.codex\sessions` (`CODEX_HOME` 지원) —
    세션 누적 스냅샷 + 턴별 일자 귀속
  - OpenCode — 후보 자동 탐색: `%LOCALAPPDATA%\opencode\data`(데스크톱 앱) →
    `%APPDATA%\opencode` → `%USERPROFILE%\.local\share\opencode`.
    `OPENCODE_DB`(파일)/`OPENCODE_DATA_DIR` 우선. opencode.db(SQLite) 우선,
    파일 storage 폴백
  - Cursor `%APPDATA%\Cursor\User\globalStorage\state.vscdb`
- 서버 자동 보고: `POST {server}/api/v1/ai-agents/report` — `meta`와
  `usage_daily` 집계만 담은 새 SQLite 파일을 전송합니다. 로컬 세션 기록과
  프롬프트·응답·프로젝트 정보는 전송하지 않습니다.
- Codex 펫 호환 데스크톱 오버레이
  - Codex 작업 시작/완료를 5초 주기로 감지해 상태 애니메이션, 입력·출력 요약,
    입력/출력 토큰을 로컬에서 표시
  - 동시에 실행 중인 세션은 `1/N`과 좌우 버튼으로 전환
  - 펫 클릭으로 대시보드를 열고 닫으며, 드래그한 위치를 저장
  - `codex-pets` ZIP 또는 1536×1872 투명 PNG를 가져오고
    [codex-pets.net](https://codex-pets.net/)을 바로 열 수 있음
- 트레이 메뉴: 오늘/누적 합계 · 도구별 상세(hover 툴팁) · 새로고침 · 지금 보고 ·
  펫 설정/가져오기 · 설정 파일 열기 · 웹 대시보드 열기

파싱 규칙은 macOS `UsageScanner.swift` 와 1:1 동일하다 (2026-07 dedup 수정 반영).
프로바이더 라이브 쿼터(9종)는 후속 버전에서 이식 예정.

## 설정

첫 실행 시 `%APPDATA%\A-mon\config.json` 이 생성된다. 트레이 메뉴 →
"설정 파일 열기" 로 편집:

```json
{
  "server_url": "https://monitor.example.com",
  "user_key": "웹 내정보 설정에서 발급한 키",
  "paths": { "claude": "", "codex": "", "opencode": "", "cursor": "" },
  "pet": {
    "enabled": true,
    "local_activity_enabled": false,
    "shows_current_task": true
  }
}
```

`paths` 의 빈 항목은 OS 기본 경로를 쓴다. `local_activity_enabled`는
명시적으로 켜기 전까지 꺼져 있으며, 작업·응답·펫 위치는 서버에 전송되지 않는다.
현재 Windows 임포터는 ZIP 안의 PNG 또는 단독 PNG를 지원하며 WebP는 지원하지 않는다.

## 빌드 (macOS/리눅스에서 크로스컴파일)

```bash
cd windows
make build          # dist/A-mon-amd64.exe
make build-arm64    # dist/A-mon-arm64.exe
make dist           # 두 exe 를 zip 으로
make scan           # (개발용) 이 머신 로그로 스캐너 패리티 확인
```

순수 Go(cgo 없음: fyne.io/systray + modernc.org/sqlite)라 별도 툴체인 없이
크로스컴파일된다. `-H windowsgui` 로 콘솔 창 없이 실행된다.

## 자동 업데이트

macOS 앱과 같은 서버 릴리즈 채널을 쓴다 (`platform=windows`):

- 10분 주기(스캔 사이클)로 `GET {server}/api/v1/app/latest?platform=windows` 확인
- 새 버전이 있으면 트레이 메뉴에 "⬇ 새 버전 vX.Y.Z 설치" 항목이 나타난다
- 클릭 시: 다운로드 → SHA256 검증 → zip 이면 현재 아키텍처(amd64/arm64)에
  맞는 exe 선택 → 실행 중 exe 는 덮어쓸 수 없으므로 교체 배치가 앱 종료를
  기다렸다가 exe 를 바꿔치기하고 재실행한다

### 릴리즈 업로드 (admin)

`make dist` 산출물(zip, amd64+arm64 exe 동봉)을 그대로 올리면 된다:

```bash
VER=$(sed -n 's/^VERSION := //p' Makefile)
curl -X POST "{server}/api/v1/app/releases" \
  -H "Authorization: Bearer $ADMIN_JWT" \
  -F platform=windows -F version=$VER \
  -F notes="변경 요약" \
  -F file=@dist/A-mon-windows-$VER.zip
```

버전 단일 출처는 `windows/Makefile` 의 `VERSION` (빌드 시 ldflags 로
`main.appVersion` 에 주입). 변경은 저장소 루트에서 `make set-version V=x.y.z`
— macOS 와 동시에 올라간다.

## 시작 시 자동 실행

`Win+R` → `shell:startup` → 열린 폴더에 `A-mon-amd64.exe` 바로가기를 넣는다.
