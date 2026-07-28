# amon — macOS 메뉴바 앱 빌드/실행/배포
#
#   make version          현재 앱 버전 출력
#   make set-version V=x  앱 버전 변경(예: make set-version V=0.2.0, build 번호 자동 +1)
#   make run              빌드 + .app 번들 조립 + 실행
#   make app              .app 번들만 조립 (현재 아키텍처)
#   make build            SPM 바이너리만 빌드
#   make dist             universal(arm64+x86_64) 빌드 + ad-hoc 서명 + zip 패키징
#   make publish TOKEN=…  dist + 백엔드 릴리즈 업로드
#   make clean            빌드 산출물 삭제
#
# 실행 파일/번들 파일명은 ASCII(AIMonitor)로 두고, Finder·메뉴바에 보이는
# 이름은 Info.plist 의 CFBundleDisplayName("amon")로 지정한다.

APP_NAME   := AIMonitor
CONFIG     := release
BUILD_DIR  := .build/$(CONFIG)
APP_BUNDLE := $(APP_NAME).app
CONTENTS   := $(APP_BUNDLE)/Contents
PET_BUNDLE := $(APP_NAME)_$(APP_NAME).bundle

# 배포 패키징
VERSION    := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist 2>/dev/null)
DIST_DIR   := dist
STAGE      := $(DIST_DIR)/amon-$(VERSION)
ZIP        := $(DIST_DIR)/amon-$(VERSION).zip
PKG        := $(DIST_DIR)/amon-$(VERSION).pkg

SERVER ?=
NOTES  ?=

PLIST := Resources/Info.plist

.PHONY: build app run clean universal dist pkg installer publish version set-version

## 현재 앱 버전 출력 (CFBundleShortVersionString + build 번호)
version:
	@echo "amon $(VERSION) (build $$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $(PLIST) 2>/dev/null))"

## 앱 버전 변경 — make set-version V=0.2.0 (build 번호 자동 +1)
set-version:
	@if [ -z "$(V)" ]; then echo "❌ 사용법: make set-version V=0.2.0"; exit 1; fi
	@echo "$(V)" | grep -qE '^[0-9]+(\.[0-9]+){0,3}$$' || { echo "❌ 버전 형식 오류 (예: 0.2.0)"; exit 1; }
	@/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(V)" $(PLIST)
	@BUILD=$$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" $(PLIST)); \
	 NEXT=$$((BUILD + 1)); \
	 /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$NEXT" $(PLIST); \
	 echo "✅ 버전 변경: $(V) (build $$NEXT)"

## SPM 실행 바이너리 빌드 (현재 아키텍처)
build:
	swift build -c $(CONFIG)

## 실행 파일 + Info.plist 로 .app 번들 조립 (현재 아키텍처)
app: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp $(BUILD_DIR)/$(APP_NAME) $(CONTENTS)/MacOS/$(APP_NAME)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	cp -R $(BUILD_DIR)/$(PET_BUNDLE) $(CONTENTS)/Resources/$(PET_BUNDLE)
	@echo "✅ $(APP_BUNDLE) 생성됨"

## 번들을 만들고 실행 (상태바에 아이콘이 뜬다)
run: app
	open $(APP_BUNDLE)

## universal(arm64 + x86_64) 번들 조립 — Apple Silicon·Intel 모두 실행
universal:
	swift build -c $(CONFIG) --arch arm64 --arch x86_64
	@BIN=$$(swift build -c $(CONFIG) --arch arm64 --arch x86_64 --show-bin-path); \
	 rm -rf $(APP_BUNDLE); \
	 mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources; \
	 cp $$BIN/$(APP_NAME) $(CONTENTS)/MacOS/$(APP_NAME); \
	 cp Resources/Info.plist $(CONTENTS)/Info.plist; \
	 cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns; \
	 cp -R $$BIN/$(PET_BUNDLE) $(CONTENTS)/Resources/$(PET_BUNDLE); \
	 echo "✅ universal $(APP_BUNDLE):"; \
	 lipo -info $(CONTENTS)/MacOS/$(APP_NAME)

## 배포 zip 생성 — universal + ad-hoc 서명 + install.command 동봉
dist: universal
	@echo "→ ad-hoc 서명"
	codesign --force --deep --sign - $(APP_BUNDLE)
	@codesign -dv $(APP_BUNDLE) 2>&1 | grep -E 'Signature|Identifier' || true
	rm -rf $(STAGE) $(ZIP)
	mkdir -p $(STAGE)
	cp -R $(APP_BUNDLE) $(STAGE)/
	cp scripts/install.command $(STAGE)/install.command
	chmod +x $(STAGE)/install.command
	cp scripts/DIST-README.txt $(STAGE)/README.txt
	ditto -c -k --keepParent $(STAGE) $(ZIP)
	@echo ""
	@echo "📦 배포 패키지: $(ZIP)"
	@echo "   내용: AIMonitor.app(universal) + install.command + README.txt"

## 릴리즈 업로드 — 백엔드에 zip 등록 (자동 업데이트 배포)
##   make publish TOKEN=<admin JWT> [SERVER=https://...] [NOTES="설명"]
pkg: universal
	codesign --force --deep --sign - $(APP_BUNDLE)
	chmod +x scripts/pkg/postinstall
	rm -f $(PKG)
	pkgbuild --component $(APP_BUNDLE) --install-location /Applications \
	  --identifier com.athens96.amon --version $(VERSION) \
	  --scripts scripts/pkg $(PKG)
	@echo "PKG installer: $(PKG)"

installer: pkg

publish: dist
	@if [ -z "$(TOKEN)" ]; then echo "❌ TOKEN=<admin JWT> 가 필요합니다"; exit 1; fi
	@if [ -z "$(SERVER)" ]; then echo "❌ SERVER=https://... 가 필요합니다"; exit 1; fi
	@echo "→ 업로드: v$(VERSION) → $(SERVER)"
	curl -fsS -X POST "$(SERVER)/api/v1/app/releases" \
	  -H "Authorization: Bearer $(TOKEN)" \
	  -F "version=$(VERSION)" \
	  -F "notes=$(NOTES)" \
	  -F "file=@$(ZIP)"
	@echo ""
	@echo "📤 업로드 완료: v$(VERSION)"

## 빌드 산출물 정리
clean:
	rm -rf .build $(APP_BUNDLE) $(DIST_DIR)
