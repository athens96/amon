# amon

amon의 **macOS 메뉴바(상태바) 앱**. 화면 최상단 상태바에
아이콘이 뜨고, 클릭하면 패널이 나타난다. 로컬 AI 코딩 도구
(**Claude Code · Codex CLI · OpenCode · Cursor · Gemini · Qwen · Copilot**)의
로그를 읽어 **토큰 사용량**을 집계한다.

- **오늘 사용량**을 크게, **전체 누적**을 하단에 작게 표시
- 도구별 카드: 오늘 입력/출력/캐시 브레이크다운 + 누적·세션 수·마지막 활동일
- **설정** 화면에서 3개 도구의 로그 폴더 경로를 직접 지정 (UserDefaults 영속)
- 세션 상세의 Markdown·표·체크리스트, 턴별 사용량과 로컬 정적 감사(명령·파일·스킬·MCP)
- 현재 활동과 세션 전문은 로컬 전용. 서버에는 `meta`와 `usage_daily` 집계만 업로드

> 실행 파일/번들명은 ASCII `AIMonitor` 로 두고, Finder·메뉴바에 보이는 이름은
> `Info.plist` 의 `CFBundleDisplayName`("amon")로 지정한다.

## 프레임워크 선택 — 네이티브 SwiftUI (`MenuBarExtra`)

맥 전용 메뉴바 유틸리티라 **네이티브 Swift + SwiftUI** 를 택했다.

| 후보 | 장점 | 단점 | 판정 |
|------|------|------|------|
| **SwiftUI `MenuBarExtra`** | 네이티브·초경량, 메뉴바 앱이 Scene 한 줄, 런타임 의존성 0, 성능/배터리 최적 | Swift 필요, macOS 13+ | ✅ 채택 |
| Tauri | 기존 React 프론트 재사용 가능, Rust 백엔드 | 트레이 UI는 결국 네이티브, 웹뷰 오버헤드 | 웹 UI 재사용이 목표가 되면 대안 |
| Electron | 웹 100% 재사용, 크로스플랫폼 | 번들 100MB+, 메뉴바 앱엔 과함 | ❌ 부적합 |

`MenuBarExtra` 는 macOS 13(Ventura)+ 에서 제공되는 SwiftUI Scene 으로,
상태바 아이템 앱을 별도 `NSStatusItem` 보일러플레이트 없이 만든다.
`.menuBarExtraStyle(.window)` 로 아이콘 클릭 시 팝오버 형태의 화면을 띄운다.

## 구조

```
macos/
├── Package.swift                 SwiftPM 매니페스트 (executable AIMonitor, macOS 13+)
├── Makefile                      빌드/번들/실행
├── Resources/
│   └── Info.plist                LSUIElement=true, CFBundleDisplayName="amon"
├── Sources/AIMonitor/
│   ├── AIMonitorApp.swift        @main 진입점(--scan CLI 포함) + MenuBarExtra + AppDelegate
│   ├── AppState.swift            전역 상태 — 스캔 결과·오늘/전체 총합
│   ├── AppSettings.swift         3개 도구 폴더 경로 저장(UserDefaults)
│   ├── Model.swift               AITool·TokenUsage·요약 모델·숫자 포맷
│   ├── UsageScanner.swift        도구별 로그 파서(오늘/전체 집계)
│   ├── UsageView.swift           사용량 화면(오늘 크게, 누적 작게)
│   ├── SettingsView.swift        설정 화면(경로 편집·폴더 선택·기본값)
│   ├── MenuBarContentView.swift  헤더/본문/푸터 컨테이너
│   └── HeadlessScan.swift        --scan: GUI 없이 사용량 출력(스크립트/검증)
└── .gitignore
```

### 도구별 파서

| 도구 | 기본 경로 | 파싱 방식 |
|------|-----------|-----------|
| Claude Code | `~/.claude/projects` | 세션 `.jsonl` 의 `message.usage` 합산, `timestamp` 로 오늘 판별 |
| Codex CLI | `~/.codex/sessions` | rollout 파일의 **마지막** `token_count`(세션 누적)만 합산 |
| OpenCode | `~/.local/share/opencode` | `storage/message/**/*.json` 의 assistant `tokens` 합산 (구버전 `.db` 는 미지원) |

## 요구 사항

- macOS 13 이상
- Xcode 15+ 또는 Swift 5.9+ 툴체인 (`swift --version` 확인)

## 빌드 · 실행

```bash
cd macos
make run      # 빌드 + .app 번들 조립 + 실행 → 상태바에 아이콘 표시
```

개별 단계:

```bash
make build    # SPM 바이너리만 빌드
make app      # AIMonitor.app 번들 조립 (Finder 표시명 "amon")
make clean    # 산출물 삭제

# GUI 없이 현재 설정 경로로 사용량 출력 (검증/스크립트용)
./.build/release/AIMonitor --scan
```

실행하면 Dock 에는 뜨지 않고(메뉴바 전용, `LSUIElement`) 상태바에
게이지 아이콘이 나타난다. 아이콘을 클릭하면 패널이 열리고, "종료"(⌘Q)로
끝낼 수 있다.

## 데스크톱 펫

`Sources/AIMonitor/PetSprites/Amon.webp`는 기본 번들 펫 `amon`의 Codex Pet
v3 스프라이트시트다. 시트는 1536×2496 WebP이며 표준 9개 애니메이션에
좌우 둘러보기와 뒷모습 앞으로 달리기를 더한 12개 행을 사용한다.
`amon`은 번들 카탈로그의 첫 항목이자 미선택 사용자의 기본값이다. 사용자가
명시적으로 고른 Dozy Boo 또는 가져온 커스텀 펫은 변경하지 않는다.

## 다음 단계

- 모델별 단가 테이블 → 토큰을 **비용(원/$)** 으로 환산
- OpenCode 구버전 **SQLite(`opencode.db`)** 파서 지원
- 날짜별·모델별 사용 추이 차트
- 메뉴바 라벨에 오늘 토큰 수 직접 표시 / 백엔드 AI Monitoring 탭 연동
