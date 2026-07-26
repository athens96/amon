import Foundation

struct CodexPetImportPayload {
    let data: Data
    let metadata: CodexPetAssetMetadata
    let displayName: String?
}

enum CodexPetPackageImportError: Error, Equatable, LocalizedError {
    case archiveTooLarge(actualBytes: Int, maximumBytes: Int)
    case invalidArchive
    case tooManyEntries(maximumCount: Int)
    case unsafeEntryPath(String)
    case duplicateEntry(String)
    case ambiguousManifest
    case invalidManifest
    case missingSprite
    case ambiguousSprite
    case spriteEntryNotFound(String)
    case extractedFileTooLarge(maximumBytes: Int)
    case unzipUnavailable

    var errorDescription: String? {
        switch self {
        case let .archiveTooLarge(actualBytes, maximumBytes):
            return "펫 ZIP이 너무 큽니다 (\(actualBytes) bytes, 최대 \(maximumBytes) bytes)."
        case .invalidArchive:
            return "펫 ZIP을 읽을 수 없습니다."
        case let .tooManyEntries(maximumCount):
            return "펫 ZIP의 파일 수가 너무 많습니다 (최대 \(maximumCount)개)."
        case let .unsafeEntryPath(path):
            return "펫 ZIP에 안전하지 않은 경로가 있습니다: \(path)"
        case let .duplicateEntry(path):
            return "펫 ZIP에 중복된 파일 경로가 있습니다: \(path)"
        case .ambiguousManifest:
            return "펫 ZIP에 pet.json이 둘 이상 있어 적용할 펫을 정할 수 없습니다."
        case .invalidManifest:
            return "pet.json의 spritesheetPath를 읽을 수 없습니다."
        case .missingSprite:
            return "펫 ZIP에서 spritesheet.png 또는 spritesheet.webp를 찾을 수 없습니다."
        case .ambiguousSprite:
            return "펫 ZIP에 스프라이트시트가 둘 이상 있습니다. pet.json에 spritesheetPath를 지정해 주세요."
        case let .spriteEntryNotFound(path):
            return "pet.json이 지정한 스프라이트시트를 찾을 수 없습니다: \(path)"
        case let .extractedFileTooLarge(maximumBytes):
            return "펫 ZIP 내부 파일이 너무 큽니다 (최대 \(maximumBytes) bytes)."
        case .unzipUnavailable:
            return "이 Mac에서 ZIP 압축 해제 도구를 실행할 수 없습니다."
        }
    }
}

/// codex-pets.net 패키지와 단일 PNG/WebP를 동일한 설치 데이터로 변환한다.
///
/// ZIP은 디스크에 통째로 풀지 않는다. 안전한 내부 경로만 허용하고, 매니페스트와
/// 그 매니페스트가 가리키는 스프라이트시트만 제한된 크기로 읽는다.
enum CodexPetPackageImporter {
    static let maximumArchiveByteCount = 40 * 1024 * 1024
    static let maximumEntryCount = 256
    static let maximumManifestByteCount = 64 * 1024
    static let maximumListingByteCount = 512 * 1024
    static let unzipTimeout: TimeInterval = 10

    static func load(
        fileURL: URL,
        spriteVersion: CodexPetSpriteVersion? = nil
    ) throws -> CodexPetImportPayload {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        let isArchive = try hasZIPSignature(fileURL: fileURL)
        if !isArchive {
            if let size = values?.fileSize,
               size > CodexPetAssetValidator.maximumByteCount {
                throw CodexPetAssetValidationError.fileTooLarge(
                    actualBytes: size,
                    maximumBytes: CodexPetAssetValidator.maximumByteCount
                )
            }
            let data: Data
            do {
                data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            } catch {
                throw CodexPetAssetValidationError.unreadableImage
            }
            let metadata = try CodexPetAssetValidator.validate(
                data: data,
                spriteVersion: spriteVersion
            )
            return CodexPetImportPayload(
                data: data,
                metadata: metadata,
                displayName: nil
            )
        }

        if let size = values?.fileSize, size > maximumArchiveByteCount {
            throw CodexPetPackageImportError.archiveTooLarge(
                actualBytes: size,
                maximumBytes: maximumArchiveByteCount
            )
        }

        let entries = try archiveEntries(fileURL: fileURL)
        let manifestEntries = entries.filter {
            !$0.isDirectory
                && !$0.isMetadata
                && $0.basename.lowercased() == "pet.json"
        }
        guard manifestEntries.count <= 1 else {
            throw CodexPetPackageImportError.ambiguousManifest
        }

        let selectedEntry: ArchiveEntry
        var displayName: String?
        var resolvedSpriteVersion = spriteVersion
        if let manifestEntry = manifestEntries.first {
            let manifestData = try unzip(
                arguments: ["-p", fileURL.path, manifestEntry.originalPath],
                outputLimit: maximumManifestByteCount
            )
            let manifest: PetManifest
            do {
                manifest = try JSONDecoder().decode(PetManifest.self, from: manifestData)
            } catch {
                throw CodexPetPackageImportError.invalidManifest
            }

            let spritePath = try resolvedSpritePath(
                manifestPath: manifestEntry.normalizedPath,
                relativeSpritePath: manifest.spritesheetPath
            )
            guard let entry = entries.first(where: {
                !$0.isDirectory && $0.normalizedPath == spritePath
            }) else {
                throw CodexPetPackageImportError.spriteEntryNotFound(spritePath)
            }
            selectedEntry = entry
            displayName = sanitizedDisplayName(manifest.displayName)
            if let rawVersion = manifest.spriteVersionNumber {
                guard let manifestVersion = CodexPetSpriteVersion(
                    rawValue: rawVersion
                ) else {
                    throw CodexPetPackageImportError.invalidManifest
                }
                resolvedSpriteVersion = manifestVersion
            }
        } else {
            let candidates = entries.filter {
                guard !$0.isDirectory, !$0.isMetadata else { return false }
                let name = $0.basename.lowercased()
                return name == "spritesheet.png" || name == "spritesheet.webp"
            }
            guard !candidates.isEmpty else {
                throw CodexPetPackageImportError.missingSprite
            }
            guard candidates.count == 1 else {
                throw CodexPetPackageImportError.ambiguousSprite
            }
            selectedEntry = candidates[0]
        }

        let spriteData = try unzip(
            arguments: ["-p", fileURL.path, selectedEntry.originalPath],
            outputLimit: CodexPetAssetValidator.maximumByteCount
        )
        let metadata = try CodexPetAssetValidator.validate(
            data: spriteData,
            spriteVersion: resolvedSpriteVersion
        )
        return CodexPetImportPayload(
            data: spriteData,
            metadata: metadata,
            displayName: displayName
        )
    }

    private static func hasZIPSignature(fileURL: URL) throws -> Bool {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: fileURL)
        } catch {
            if fileURL.pathExtension.lowercased() == "zip" {
                throw CodexPetPackageImportError.invalidArchive
            }
            throw CodexPetAssetValidationError.unreadableImage
        }
        defer { try? handle.close() }
        let signature = try handle.read(upToCount: 4) ?? Data()
        let bytes = [UInt8](signature)
        let signatures: [[UInt8]] = [
            [0x50, 0x4b, 0x03, 0x04],
            [0x50, 0x4b, 0x05, 0x06],
            [0x50, 0x4b, 0x07, 0x08]
        ]
        if signatures.contains(bytes) {
            return true
        }
        if fileURL.pathExtension.lowercased() == "zip" {
            throw CodexPetPackageImportError.invalidArchive
        }
        return false
    }

    private static func archiveEntries(fileURL: URL) throws -> [ArchiveEntry] {
        let listing = try unzip(
            arguments: ["-Z1", fileURL.path],
            outputLimit: maximumListingByteCount
        )
        guard let text = String(data: listing, encoding: .utf8) else {
            throw CodexPetPackageImportError.invalidArchive
        }

        let paths = text.split(whereSeparator: \.isNewline).map(String.init)
        guard paths.count <= maximumEntryCount else {
            throw CodexPetPackageImportError.tooManyEntries(
                maximumCount: maximumEntryCount
            )
        }

        var normalizedPaths = Set<String>()
        return try paths.map { originalPath in
            let isDirectory = originalPath.hasSuffix("/")
            let normalized = try normalizedArchivePath(
                originalPath,
                allowTrailingSlash: isDirectory
            )
            let duplicateKey = normalized
                .precomposedStringWithCanonicalMapping
                .folding(
                    options: [.caseInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )
            guard normalizedPaths.insert(duplicateKey).inserted else {
                throw CodexPetPackageImportError.duplicateEntry(normalized)
            }
            return ArchiveEntry(
                originalPath: originalPath,
                normalizedPath: normalized,
                isDirectory: isDirectory
            )
        }
    }

    private static func resolvedSpritePath(
        manifestPath: String,
        relativeSpritePath: String
    ) throws -> String {
        let trimmed = relativeSpritePath.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !trimmed.isEmpty else {
            throw CodexPetPackageImportError.invalidManifest
        }
        let sprite = try normalizedArchivePath(trimmed, allowTrailingSlash: false)
        let parent = manifestPath.split(separator: "/").dropLast()
        return (parent.map(String.init) + [sprite]).joined(separator: "/")
    }

    private static func normalizedArchivePath(
        _ path: String,
        allowTrailingSlash: Bool
    ) throws -> String {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.hasPrefix("\\"),
              !path.hasPrefix("-"),
              !path.contains("\\"),
              !path.contains("\0"),
              !path.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }),
              !path.contains("*"),
              !path.contains("?"),
              !path.contains("["),
              !path.contains("]")
        else {
            throw CodexPetPackageImportError.unsafeEntryPath(path)
        }

        let rawComponents = path.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        var components: [String] = []
        for (index, component) in rawComponents.enumerated() {
            if component.isEmpty {
                if allowTrailingSlash && index == rawComponents.count - 1 {
                    continue
                }
                throw CodexPetPackageImportError.unsafeEntryPath(path)
            }
            if component == "." {
                continue
            }
            guard component != ".." else {
                throw CodexPetPackageImportError.unsafeEntryPath(path)
            }
            components.append(String(component))
        }
        guard !components.isEmpty else {
            throw CodexPetPackageImportError.unsafeEntryPath(path)
        }
        return components.joined(separator: "/")
    }

    private static func sanitizedDisplayName(_ displayName: String?) -> String? {
        guard let displayName else { return nil }
        let oneLine = displayName
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return nil }
        return String(oneLine.prefix(80))
    }

    private static func unzip(
        arguments: [String],
        outputLimit: Int
    ) throws -> Data {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CodexPetPackageImportError.unzipUnavailable
        }

        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + unzipTimeout,
            execute: timeout
        )
        defer { timeout.cancel() }

        var output = Data()
        while true {
            let chunk = outputPipe.fileHandleForReading.availableData
            if chunk.isEmpty { break }
            guard chunk.count <= outputLimit - output.count else {
                process.terminate()
                process.waitUntilExit()
                throw CodexPetPackageImportError.extractedFileTooLarge(
                    maximumBytes: outputLimit
                )
            }
            output.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CodexPetPackageImportError.invalidArchive
        }
        return output
    }
}

private struct ArchiveEntry {
    let originalPath: String
    let normalizedPath: String
    let isDirectory: Bool

    var basename: String {
        normalizedPath.split(separator: "/").last.map(String.init) ?? ""
    }

    var isMetadata: Bool {
        normalizedPath.split(separator: "/").contains("__MACOSX")
            || basename.hasPrefix("._")
    }
}

private struct PetManifest: Decodable {
    let displayName: String?
    let spritesheetPath: String
    let spriteVersionNumber: Int?
}
