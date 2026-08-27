import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Codex custom pet 파일 또는 codex-pets.net ZIP을 검증하고 amon 로컬 사본으로 설치한다.
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
                    Label("Codex 스프라이트 호환 amon 펫", systemImage: "pawprint.fill")
                        .font(.amonSection)
                        .foregroundStyle(MenuBarContentView.accent)
                    Text("작업 상태를 플로팅 펫과 말풍선으로 표시합니다. 표시에 쓰는 현재 작업은 이 Mac 안에서만 읽으며, 펫 때문에 서버로 나가는 데이터는 없습니다.")
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

            HStack(spacing: 8) {
                Text("완료 후 말풍선 접기")
                    .font(.amonCaption)
                Picker("", selection: $settings.petReadyAutoHideSeconds) {
                    ForEach(PetBubbleVisibility.readyAutoHideChoices, id: \.self) { seconds in
                        Text(PetBubbleVisibility.autoHideLabel(forSeconds: seconds))
                            .tag(seconds)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
                Spacer()
            }
            .disabled(
                !settings.petEnabled
                    || !settings.petShowsCurrentTask
                    || !settings.localActivityEnabled
            )
            .help("입력 필요·문제 발생은 손이 필요한 상태라 시간이 지나도 접지 않습니다.")

            if !settings.localActivityEnabled {
                Label(
                    "현재 작업을 보려면 감지를 켜세요. 세션·프롬프트·응답·프로젝트 정보는 서버로 전송하지 않습니다.",
                    systemImage: "lock.shield"
                )
                .font(.amonCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            BundledPetPicker(
                selectedID: settings.petBundledID,
                usesCustomSprite: !settings.petSpritePath.isEmpty,
                onSelect: use(bundled:)
            )
            .disabled(!settings.petEnabled)

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

            Text("호환 파일: codex-pets.net ZIP 또는 투명 PNG/WebP · 스프라이트시트는 1536×1872(v1), 1536×2288(v2) 또는 1536×2496(v3) px, 최대 20 MiB. ZIP은 pet.json의 spritesheetPath와 spriteVersionNumber를 읽습니다. v2 이상은 대기 중 마우스가 움직이면 그쪽을 둘러보고, v3는 완료 시 점프 뒤 뒷모습으로 앞으로 달립니다.")
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

    /// 번들 펫을 고르면 커스텀 펫보다 우선하도록 커스텀 지정을 함께 해제한다.
    private func use(bundled pet: BundledPet) {
        settings.petBundledID = pet.id
        settings.petSpritePath = ""
        settings.petSpriteVersion = pet.spriteVersion.rawValue
        settings.petSpriteRevision = 0
        validationFailed = false
        validationMessage = "기본 펫 \(pet.displayName) 을(를) 사용합니다."
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
        panel.message = "Codex 펫 ZIP 또는 호환 스프라이트 시트(v1 1536×1872, v2 1536×2288, v3 1536×2496)를 선택하세요."

        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }

        do {
            // 버전은 패키지(pet.json spriteVersionNumber)와 실제 시트 크기가 정한다.
            let payload = try CodexPetPackageImporter.load(fileURL: sourceURL)
            let installedURL = try installLocalCopy(
                data: payload.data,
                format: payload.metadata.format
            )
            settings.petSpritePath = installedURL.path
            settings.petSpriteVersion = (payload.metadata.spriteVersion ?? .v1).rawValue
            // 경로가 같고 같은 초 안에 연속 교체돼도 반드시 새 시트를 읽는다.
            settings.petSpriteRevision &+= 1
            settings.petEnabled = true
            validationFailed = false
            let name = payload.displayName.map { "\($0) · " } ?? ""
            let version = payload.metadata.spriteVersion ?? .v1
            validationMessage = "\(name)v\(version.rawValue) \(payload.metadata.pixelWidth)×\(payload.metadata.pixelHeight) \(payload.metadata.format.displayName) 펫을 적용했습니다."
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
        // 기존 커스텀 펫을 그대로 찾기 위한 레거시 지원 경로다.
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
        // 디스크에 쓴 사본도 같은 계약을 만족하는지 한 번 더 본다(버전은 크기로 재판별).
        _ = try CodexPetAssetValidator.validate(fileURL: temporary)

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

/// 함께 들어 있는 펫 중 하나를 고른다. 각 카드에는 그 펫의 idle 첫 프레임을 보여준다.
private struct BundledPetPicker: View {
    let selectedID: String
    /// 커스텀 펫이 지정돼 있으면 번들 펫은 그려지지 않는다 — 그 사실을 알려준다.
    let usesCustomSprite: Bool
    let onSelect: (BundledPet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("기본 펫")
                .font(.amonCaption.weight(.semibold))
                .foregroundStyle(.secondary)

            // 펫이 늘어나도 설정 창(420pt) 밖으로 나가지 않도록 줄바꿈한다.
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 168), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(BundledPet.all) { pet in
                    card(for: pet)
                }
            }

            if usesCustomSprite {
                Text("지금은 커스텀 펫을 쓰는 중입니다. 위에서 고르면 커스텀 펫 대신 그 펫으로 돌아갑니다.")
                    .font(.amonCaption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func card(for pet: BundledPet) -> some View {
        let isSelected = !usesCustomSprite && pet.id == selectedID
        return Button {
            onSelect(pet)
        } label: {
            HStack(spacing: 7) {
                BundledPetThumbnail(pet: pet)
                    .frame(width: 30, height: 32)
                Text(pet.displayName)
                    .font(.amonCaption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? MenuBarContentView.accent : .primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? MenuBarContentView.accent.opacity(0.12)
                            : Color.primary.opacity(0.04)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? MenuBarContentView.accent.opacity(0.85)
                            : Color.primary.opacity(0.12),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(pet.displayName) 펫으로 바꿉니다.")
        .accessibilityLabel(pet.displayName)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 번들 펫의 idle 첫 프레임. 시트를 못 읽으면 발자국 아이콘으로 자리만 지킨다.
private struct BundledPetThumbnail: View {
    let pet: BundledPet

    @State private var frame: CGImage?

    var body: some View {
        Group {
            if let frame {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "pawprint.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
        }
        .task(id: pet.id) {
            guard let path = pet.path else { return }
            frame = PetSpriteFrames
                .load(path: path, version: pet.spriteVersion)
                .frames(for: .idle)?
                .first
        }
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
