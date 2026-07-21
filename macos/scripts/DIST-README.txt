A-mon (macOS 메뉴바 앱)
================================

로컬 AI 코딩 도구(Claude Code · Codex · OpenCode · Cursor)의 토큰 사용량을
집계해 메뉴바에 보여주고, 서버(웹 AI 모니터)로 전송합니다.

요구 사항
---------
- macOS 13 (Ventura) 이상
- Apple Silicon 또는 Intel Mac (universal 빌드)


설치 (간편)
-----------
1. 이 폴더의 "install.command" 를 더블클릭.
   - "확인되지 않은 개발자" 경고가 뜨면:
     install.command 를 우클릭 → 열기 → 열기.
2. 자동으로 /Applications 에 설치되고 실행됩니다.


설치 (수동 / 위 방법이 막힐 때)
--------------------------------
터미널에서 이 폴더로 이동 후:

    xattr -dr com.apple.quarantine AIMonitor.app
    cp -R AIMonitor.app /Applications/
    open /Applications/AIMonitor.app

(/Applications 에 권한이 없으면 ~/Applications 로 대체)


첫 실행 후
----------
메뉴바(오른쪽 위)에 게이지 아이콘이 뜹니다. 클릭 → 설정(⚙️):
- "로그인 시 자동 실행" 켜기 (설치 후 켜야 경로가 고정됩니다)
- 서버 URL·유저 키 입력
  (웹 AI 모니터 → 내정보 설정에서 유저 키 발급)

종료: 패널 하단 "종료"(⌘Q)


참고
----
- 이 빌드는 ad-hoc 서명입니다(정식 공증 아님). 사내 배포용.
- 앱은 로컬 로그 파일만 읽고, 설정한 서버로만 사용량을 전송합니다.
