APP := amon
VERSION := 0.4.1
CONFIGURATION := Release

.PHONY: restore build test scan publish publish-x64 publish-arm64 dist clean

restore:
	dotnet restore AMon.Windows.slnx

build:
	dotnet build AMon.Windows.slnx -c $(CONFIGURATION) --no-restore

test:
	dotnet test AMon.Windows.slnx -c $(CONFIGURATION) --no-build

scan:
	dotnet run --project src/AMon.Scanner/AMon.Scanner.csproj -c $(CONFIGURATION)

publish: publish-x64 publish-arm64

publish-x64:
	dotnet publish src/AMon.App/AMon.App.csproj -c $(CONFIGURATION) -r win-x64 \
		--self-contained true -p:PublishSingleFile=true -p:Version=$(VERSION) \
		-o dist/win-x64
	dotnet publish src/AMon.Updater/AMon.Updater.csproj -c $(CONFIGURATION) -r win-x64 \
		--self-contained true -p:PublishSingleFile=true -p:Version=$(VERSION) \
		-o dist/win-x64

publish-arm64:
	dotnet publish src/AMon.App/AMon.App.csproj -c $(CONFIGURATION) -r win-arm64 \
		--self-contained true -p:PublishSingleFile=true -p:Version=$(VERSION) \
		-o dist/win-arm64
	dotnet publish src/AMon.Updater/AMon.Updater.csproj -c $(CONFIGURATION) -r win-arm64 \
		--self-contained true -p:PublishSingleFile=true -p:Version=$(VERSION) \
		-o dist/win-arm64

dist: publish
	mkdir -p dist/releases/windows-x64 dist/releases/windows-arm64
	cd dist/win-x64 && zip -qr ../releases/windows-x64/$(APP)-windows-x64-$(VERSION).zip .
	cd dist/win-arm64 && zip -qr ../releases/windows-arm64/$(APP)-windows-arm64-$(VERSION).zip .
	node scripts/write-release-manifest.mjs \
		dist/releases/windows-x64/$(APP)-windows-x64-$(VERSION).zip x64 $(VERSION) \
		dist/releases/windows-x64/latest.json
	node scripts/write-release-manifest.mjs \
		dist/releases/windows-arm64/$(APP)-windows-arm64-$(VERSION).zip arm64 $(VERSION) \
		dist/releases/windows-arm64/latest.json

clean:
	dotnet clean AMon.Windows.slnx
	rm -rf dist artifacts TestResults
