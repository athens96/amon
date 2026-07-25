# A-mon Windows 트레이 앱 — macOS 개발 머신에서 크로스컴파일한다.
#
#   make build        # windows/amd64 단일 exe (콘솔 창 없이 GUI 모드)
#   make build-arm64  # windows/arm64
#   make scan         # (개발용) 이 머신에서 스캐너만 실행 — 맥 앱과 패리티 검증
#   make dist         # amd64+arm64 exe 를 dist/ 에 zip 으로

APP     := A-mon
VERSION := 0.3.38
LDFLAGS := -H windowsgui -s -w -X main.appVersion=$(VERSION)

.PHONY: build build-arm64 scan tidy dist installer clean

tidy:
	go mod tidy

build: tidy
	GOOS=windows GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/$(APP)-amd64.exe .

build-arm64: tidy
	GOOS=windows GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/$(APP)-arm64.exe .

scan:
	go run ./cmd/scan

dist: build build-arm64
	cd dist && zip -q $(APP)-windows-$(VERSION).zip $(APP)-amd64.exe $(APP)-arm64.exe
	@ls -la dist/*.zip

installer: build
	mkdir -p cmd/installer/payload
	cp dist/$(APP)-amd64.exe cmd/installer/payload/A-mon.exe
	GOOS=windows GOARCH=amd64 go build -tags installer -ldflags "-H windowsgui -s -w -X main.version=$(VERSION)" -o dist/$(APP)-Setup-$(VERSION).exe ./cmd/installer
	rm -rf cmd/installer/payload
	@ls -la dist/$(APP)-Setup-$(VERSION).exe

clean:
	rm -rf dist
