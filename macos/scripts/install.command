#!/bin/bash
# A-mon 설치 — /Applications(또는 ~/Applications)로 복사 + Gatekeeper
# quarantine 해제 + 실행. Finder 에서 더블클릭하거나 `bash install.command` 로 실행.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SRC="$DIR/AIMonitor.app"

if [ ! -d "$APP_SRC" ]; then
  echo "❌ AIMonitor.app 을 찾을 수 없습니다 ($APP_SRC)"
  echo "   이 스크립트는 AIMonitor.app 과 같은 폴더에서 실행해야 합니다."
  read -n 1 -s -r -p "엔터를 누르면 닫힙니다..."
  exit 1
fi

# 설치 위치: /Applications 우선, 쓰기 불가 시 ~/Applications
DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
  DEST_DIR="$HOME/Applications"
  mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/AIMonitor.app"

echo "→ 설치 위치: $DEST"

# 실행 중이면 종료
pkill -x AIMonitor 2>/dev/null || true
sleep 1

rm -rf "$DEST"
cp -R "$APP_SRC" "$DEST"

# Gatekeeper quarantine 플래그 제거 (다운로드/전송 시 붙는 차단)
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "✅ 설치 완료: $DEST"
open "$DEST"
echo ""
echo "메뉴바(화면 오른쪽 위)에 게이지 아이콘이 뜹니다."
echo "설정(⚙️)에서:"
echo "  1) '로그인 시 자동 실행' 켜기"
echo "  2) 서버 URL·유저 키 입력 (웹 AI 모니터 > 내정보 설정에서 발급)"
echo ""
read -n 1 -s -r -p "엔터를 누르면 닫힙니다..."
