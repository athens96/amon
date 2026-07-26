# A-mon

A-mon은 로컬 AI 코딩 도구의 사용량과 세션을 수집하는 데스크톱 앱입니다.
macOS에서는 메뉴바 앱으로, Windows에서는 시스템 트레이 앱으로 실행됩니다.

현재 버전은 `0.3.38`이며 다음 도구의 로컬 데이터를 수집합니다.

- Claude Code
- Codex CLI
- OpenCode
- Cursor
- Gemini CLI, GitHub Copilot, Qwen Code 등 플랫폼별 지원 도구

수집 결과와 세션 기록·대화·현재 활동은 이 기기에서만 확인합니다. 서버를 연결하면
새로 만든 SQLite 파일의 `meta`와 `usage_daily` 집계만 대시보드에 업로드하며,
세션·프롬프트·응답·프로젝트 정보는 전송하지 않습니다. 서버 URL과 사용자 키는
앱 설정에서 지정합니다.

## 저장소 구조

```text
.
|-- macos/       Swift 5.9, SwiftUI 메뉴바 앱
|-- windows/     .NET 10 WPF 시스템 트레이 앱
|-- artwork/     공통 앱 아이콘 원본
|-- Makefile     공통 빌드 및 버전 관리 진입점
`-- LICENSE
```

## macOS

macOS 13 이상과 Xcode 15 또는 Swift 5.9 이상이 필요합니다.

```bash
make mac-build
make mac-run
make mac-dist
```

상세 내용은 [macos/README.md](macos/README.md)를 참고하세요.

## Windows

.NET 10 SDK가 필요합니다. Windows에서 직접 테스트하고 빌드하려면:

```powershell
cd windows
dotnet restore AMon.Windows.slnx
dotnet build AMon.Windows.slnx -c Release
dotnet test AMon.Windows.slnx -c Release
```

서명된 x64·Arm64 배포 파일은 Windows CI에서 생성합니다:

```bash
make win-build
make win-dist
```

상세 내용은 [windows/README.md](windows/README.md)를 참고하세요.

## 공통 명령

```bash
make version
make set-version V=0.3.39
make scan
make build
make dist
```

`make build`와 `make dist`는 macOS와 Windows 산출물을 모두 만들기 때문에
macOS 개발 환경에서 실행하는 것을 전제로 합니다.
