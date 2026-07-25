import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Codex custom pet 파일 또는 codex-pets.net ZIP을 검증하고 A-mon 로컬 사본으로 설치한다.
/// 파일은 로컬에만 복사되며 서버 업로드 경로와 연결되지 않는다.
struct PetSettingsRow: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @State private var validationMessage: String?
    @State private var validationFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Codex 스프라이트 호환 A-mon 펫", systemImage: "pawprint.fill")
                        .font(.amonSection)
                        .foregroundStyle(MenuBarContentView.accent)
                    Text("작업 상태를 플로팅 펫과 말풍선으로 표시합니다. 현재 작업 문구는 이 Mac에서만 읽고 서버로 보내지 않습니다.")
                        .font(.amonCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Toggle("", isOn: $settings.petEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
            }

            Toggle("현재 작업 감지 (이 Mac에서만)", isOn: localActivityBinding)
                .toggleStyle(.checkbox)
                .font(.amonCaption)

            Toggle("작업 중 프로젝트와 현재 작업 표시", isOn: $settings.petShowsCurrentTask)
                .toggleStyle(.checkbox)
                .font(.amonCaption)
                .disabled(!settings.petEnabled || !settings.localActivityEnabled)

            if !settings.localActivityEnabled {
                Label(
                    "현재 작업을 보려면 로컬 감지를 켜세요. 세션·프롬프트·응답·프로젝트 정보는 서버로 전송하지 않습니다.",
                    systemImage: "lock.shield"
                )
                .font(.amonCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    pickCompatibleSprite()
                } label: {
                    Label(
                        settings.petSpritePath.isEmpty ? "커스텀 펫 가져오기" : "커스텀 펫 변경",
                        systemImage: "archivebox"
                    )
                }
                .buttonStyle(.bordered)

                if !settings.petSpritePath.isEmpty {
                    Button("기본 펫") {
                        settings.petSpritePath = ""
                        validationFailed = false
                        validationMessage = "A-mon 기본 펫을 사용합니다."
                    }
                    .buttonStyle(.borderless)
                }

                Button {
                    openCodexPetGallery()
                } label: {
                    Label("Codex 펫 다운로드", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help("codex-pets.net에서 Codex 호환 펫을 찾아 다운로드합니다.")

                Button {
                    openCodexPetSettings()
                } label: {
                    Label("Codex 펫 설정", systemImage: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Codex 설정을 열어 같은 스프라이트 파일을 직접 업로드합니다.")

                Spacer()
            }

            Text("호환 파일: codex-pets.net ZIP 또는 투명 PNG/WebP · 스프라이트시트는 정확히 1536×1872 px, 최대 20 MiB. ZIP은 pet.json의 spritesheetPath를 읽습니다.")
                .font(.amonCaption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            Text("현재 로컬 로그가 구분하는 작업 중·완료 상태를 표시하며, 입력 필요·문제 발생 lifecycle 이벤트가 제공되면 같은 Codex 우선순위로 표시합니다.")
                .font(.amonCaption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let validationMessage {
                Label(
                    validationMessage,
                    systemImage: validationFailed
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.amonCaption)
                .foregroundStyle(validationFailed ? Color.orange : Color.green)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func pickCompatibleSprite() {
        let panel = NSOpenPanel()
        var allowedTypes: [UTType] = [.zip, .png]
        if let webP = UTType(filenameExtension: "webp") {
            allowedTypes.append(webP)
        }
        panel.allowedContentTypes = allowedTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Codex 펫 ZIP 또는 호환 스프라이트 시트(1536×1872)를 선택하세요."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        do {
            let version = CodexPetSpriteVersion(
                rawValue: settings.petSpriteVersion == 2 ? 2 : 1
            )
            let payload = try CodexPetPackageImporter.load(
                fileURL: sourceURL,
                spriteVersion: version
            )
            let installedURL = try installLocalCopy(
                data: payload.data,
                format: payload.metadata.format
            )
            settings.petSpritePath = installedURL.path
            settings.petEnabled = true
            validationFailed = false
            let name = payload.displayName.map { "\($0) · " } ?? ""
            validationMessage = "\(name)\(payload.metadata.pixelWidth)×\(payload.metadata.pixelHeight) \(payload.metadata.format.displayName) 펫을 적용했습니다."
        } catch {
            validationFailed = true
            validationMessage =
                (error as? LocalizedError)?.errorDescription
                ?? "펫 파일을 적용할 수 없습니다: \(error.localizedDescription)"
        }
    }

    private var localActivityBinding: Binding<Bool> {
        Binding(
            get: { settings.localActivityEnabled },
            set: { enabled in
                settings.localActivityEnabled = enabled
                state.setLiveActivity(enabled: enabled)
            }
        )
    }

    private func openCodexPetSettings() {
        guard let url = URL(string: "codex://settings") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openCodexPetGallery() {
        guard let url = URL(string: "https://codex-pets.net/") else { return }
        NSWorkspace.shared.open(url)
    }

    private func installLocalCopy(
        data: Data,
        format: CodexPetAssetFormat
    ) throws -> URL {
        let fm = FileManager.default
        let support = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = support
            .appendingPathComponent("A-mon", isDirectory: true)
            .appendingPathComponent("pets", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = directory.appendingPathComponent(
            format == .png ? "spritesheet.png" : "spritesheet.webp"
        )
        let temporary = directory.appendingPathComponent(
            ".spritesheet-\(UUID().uuidString).\(format == .png ? "png" : "webp")"
        )
        defer { try? fm.removeItem(at: temporary) }
        try data.write(to: temporary, options: [.atomic])
        _ = try CodexPetAssetValidator.validate(
            fileURL: temporary,
            spriteVersion: CodexPetSpriteVersion(
                rawValue: settings.petSpriteVersion == 2 ? 2 : 1
            )
        )

        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: temporary)
        } else {
            try fm.moveItem(at: temporary, to: destination)
        }

        let obsolete = directory.appendingPathComponent(
            format == .png ? "spritesheet.webp" : "spritesheet.png"
        )
        if fm.fileExists(atPath: obsolete.path) {
            try? fm.removeItem(at: obsolete)
        }
        return destination
    }
}

private extension CodexPetAssetFormat {
    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .webP: return "WebP"
        }
    }
}
