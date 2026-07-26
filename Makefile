# A-mon 루트 Makefile — 맥(macos/)·윈도우(windows/) 공통 진입점.
#
#   make build              # macOS + Windows .NET 빌드
#   make dist               # 두 플랫폼 배포 아티팩트 (mac universal zip + windows zip)
#   make run                # 맥 앱 번들 조립 후 실행 (윈도우 exe 는 맥에서 실행 불가)
#   make scan               # 두 스캐너를 이 머신에서 실행 — 파싱 패리티 비교용
#   make version            # 두 플랫폼 현재 버전 표시
#   make set-version V=x.y.z  # 두 플랫폼 버전 동시 변경 (정책: 항상 함께 올린다)
#
# 개별 플랫폼: make mac-build / mac-dist / mac-run · win-build / win-dist

.PHONY: build dist installer run scan version set-version \
        mac-build mac-dist mac-installer mac-run mac-scan win-build win-dist win-installer win-scan

version:
	@printf "macOS   : "; $(MAKE) -s -C macos version
	@printf "Windows : A-mon %s\n" "$$(sed -n 's/^VERSION := //p' windows/Makefile)"

## 두 플랫폼 버전 동시 변경 — mac 은 Info.plist, Windows 는 Makefile VERSION.
set-version:
	@if [ -z "$(V)" ]; then echo "❌ 사용법: make set-version V=0.3.3"; exit 1; fi
	@$(MAKE) -s -C macos set-version V=$(V)
	@sed -i '' -E 's/^VERSION := .*/VERSION := $(V)/' windows/Makefile
	@echo "✅ Windows 버전 변경: $(V)"

build: mac-build win-build
dist: mac-dist win-dist
installer: mac-installer win-installer
run: mac-run

## 두 스캐너를 나란히 실행 — 결과 숫자가 같아야 한다 (같은 로그, 같은 규칙)
scan: mac-scan win-scan

# ── macOS (Swift) ─────────────────────────────────────────────
mac-build:
	$(MAKE) -C macos build

mac-dist:
	$(MAKE) -C macos dist

mac-installer:
	$(MAKE) -C macos installer

mac-run:
	$(MAKE) -C macos run

mac-scan:
	@echo "── macOS 스캐너 (Swift) ──"
	@$(MAKE) -C macos build >/dev/null
	@cd macos && ./.build/release/AIMonitor --scan

# ── Windows (.NET 10 / WPF) ──────────────────────────────────
win-build:
	$(MAKE) -C windows restore build

win-dist:
	$(MAKE) -C windows dist

win-installer:
	@echo "Windows installer is produced by the Windows CI packaging job."

win-scan:
	@echo "── Windows 스캐너 (.NET) ──"
	@$(MAKE) -C windows scan
