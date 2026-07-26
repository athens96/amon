import Foundation
import ImageIO

/// Codex custom pet 설치 링크가 받는 sprite version 메타데이터.
///
/// V1/V2가 선언하는 시트 높이와 행 수를 함께 보존한다.
enum CodexPetSpriteVersion: Int, Codable, CaseIterable {
    case v1 = 1
    case v2 = 2

    var requiredPixelHeight: Int {
        switch self {
        case .v1: return 1872
        case .v2: return 2288
        }
    }

    var rowCount: Int {
        switch self {
        case .v1: return 9
        case .v2: return 11
        }
    }

    static func infer(width: Int, height: Int) -> CodexPetSpriteVersion? {
        guard width == CodexPetAssetValidator.requiredPixelWidth else {
            return nil
        }
        return allCases.first { $0.requiredPixelHeight == height }
    }
}

enum CodexPetAssetFormat: String, Codable {
    case png
    case webP
}

struct CodexPetAssetMetadata: Equatable {
    let format: CodexPetAssetFormat
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
    let spriteVersion: CodexPetSpriteVersion?
}

enum CodexPetAssetValidationError: Error, Equatable, LocalizedError {
    case fileTooLarge(actualBytes: Int, maximumBytes: Int)
    case unsupportedFormat
    case unreadableImage
    case invalidDimensions(width: Int, height: Int)
    case missingTransparency

    var errorDescription: String? {
        switch self {
        case let .fileTooLarge(actualBytes, maximumBytes):
            return "펫 파일이 너무 큽니다 (\(actualBytes) bytes, 최대 \(maximumBytes) bytes)."
        case .unsupportedFormat:
            return "펫 파일은 PNG 또는 WebP 형식이어야 합니다."
        case .unreadableImage:
            return "펫 이미지의 픽셀 정보를 읽을 수 없습니다."
        case let .invalidDimensions(width, height):
            return "Codex Pet V1은 1536×1872 px, V2는 1536×2288 px이어야 합니다 (현재 \(width)×\(height) px)."
        case .missingTransparency:
            return "펫 이미지는 투명도를 지원하는 PNG 또는 WebP여야 합니다."
        }
    }
}

/// 공식 custom pet 파일 계약만 검증한다.
///
/// 애니메이션 프레임 위치나 의미는 추측하지 않으며, 파일을 네트워크로 전송하지 않는다.
enum CodexPetAssetValidator {
    static let requiredPixelWidth = 1536
    static let requiredPixelHeightV1 = 1872
    static let requiredPixelHeightV2 = 2288
    static let maximumByteCount = 20 * 1024 * 1024

    static func validate(
        fileURL: URL,
        spriteVersion: CodexPetSpriteVersion? = nil
    ) throws -> CodexPetAssetMetadata {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize, size > maximumByteCount {
            throw CodexPetAssetValidationError.fileTooLarge(
                actualBytes: size,
                maximumBytes: maximumByteCount
            )
        }
        guard let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            throw CodexPetAssetValidationError.unreadableImage
        }
        return try validate(data: data, spriteVersion: spriteVersion)
    }

    static func validate(
        data: Data,
        spriteVersion: CodexPetSpriteVersion? = nil
    ) throws -> CodexPetAssetMetadata {
        guard data.count <= maximumByteCount else {
            throw CodexPetAssetValidationError.fileTooLarge(
                actualBytes: data.count,
                maximumBytes: maximumByteCount
            )
        }
        guard let format = format(of: data) else {
            throw CodexPetAssetValidationError.unsupportedFormat
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        else {
            throw CodexPetAssetValidationError.unreadableImage
        }
        let resolvedVersion: CodexPetSpriteVersion
        if let spriteVersion {
            guard width == requiredPixelWidth,
                  height == spriteVersion.requiredPixelHeight
            else {
                throw CodexPetAssetValidationError.invalidDimensions(
                    width: width,
                    height: height
                )
            }
            resolvedVersion = spriteVersion
        } else if let inferred = CodexPetSpriteVersion.infer(
            width: width,
            height: height
        ) {
            resolvedVersion = inferred
        } else {
            throw CodexPetAssetValidationError.invalidDimensions(width: width, height: height)
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CodexPetAssetValidationError.unreadableImage
        }
        guard hasAlphaChannel(image) else {
            throw CodexPetAssetValidationError.missingTransparency
        }
        return CodexPetAssetMetadata(
            format: format,
            pixelWidth: width,
            pixelHeight: height,
            byteCount: data.count,
            spriteVersion: resolvedVersion
        )
    }

    /// 확장자가 아니라 실제 파일 signature 로 PNG/WebP 를 판별한다.
    static func format(of data: Data) -> CodexPetAssetFormat? {
        let bytes = [UInt8](data.prefix(12))
        let pngSignature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        if bytes.count >= pngSignature.count,
           Array(bytes.prefix(pngSignature.count)) == pngSignature {
            return .png
        }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) {
            return .webP
        }
        return nil
    }

    private static func hasAlphaChannel(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .premultipliedLast, .premultipliedFirst, .last, .first, .alphaOnly:
            return true
        case .none, .noneSkipLast, .noneSkipFirst:
            return false
        @unknown default:
            return false
        }
    }
}
