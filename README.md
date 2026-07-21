# A-mon

A-mon은 로컬 AI 코딩 도구의 사용량과 세션을 수집하는 데스크톱 앱입니다.
macOS에서는 메뉴바 앱으로, Windows에서는 시스템 트레이 앱으로 실행됩니다.

현재 버전은 `0.3.30`이며 다음 도구의 로컬 데이터를 수집합니다.

- Claude Code
- Codex CLI
- OpenCode
- Cursor
- Gemini CLI, GitHub Copilot, Qwen Code 등 플랫폼별 지원 도구

수집 결과는 로컬에서 확인할 수 있고, 서비스 모니터의 AI Monitoring API에
연결하면 사용자별 대시보드와 세션 기록을 업로드할 수 있습니다. 서버 URL과
사용자 키는 앱 설정에서 지정합니다.

## 저장소 구조

```text
.
|-- macos/       Swift 5.9, SwiftUI 메뉴바 앱
|-- windows/     Go 1.24 시스템 트레이 앱
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

Go 1.24 이상이 필요합니다. Windows에서 직접 테스트하고 빌드하려면:

```powershell
cd windows
go test ./...
go build -o dist/A-mon.exe .
```

macOS 또는 Linux에서 Windows 배포 파일을 만들려면:

```bash
make win-build
make win-dist
```

상세 내용은 [windows/README.md](windows/README.md)를 참고하세요.

## 공통 명령

```bash
make version
make set-version V=0.3.31
make scan
make build
make dist
```

`make build`와 `make dist`는 macOS와 Windows 산출물을 모두 만들기 때문에
macOS 개발 환경에서 실행하는 것을 전제로 합니다.
