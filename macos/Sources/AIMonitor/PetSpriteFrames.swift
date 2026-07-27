import CoreGraphics
import Foundation
import ImageIO

/// 스프라이트 시트에서 애니메이션별 프레임을 잘라 담아둔다.
///
/// `CGImage.cropping` 은 원본을 참조만 하므로 11행 전체를 미리 잘라둬도
/// 픽셀이 복사되지 않는다. 상태·연출이 프레임마다 바뀔 수 있어 필요한 행만
/// 그때그때 읽는 대신 한 번에 준비해둔다.
struct PetSpriteFrames {
    private let strips: [CodexPetSpriteLayout.Animation: [CGImage]]

    init(strips: [CodexPetSpriteLayout.Animation: [CGImage]]) {
        self.strips = strips
    }

    static let empty = PetSpriteFrames(strips: [:])

    var isEmpty: Bool { strips.isEmpty }

    func frames(for animation: CodexPetSpriteLayout.Animation) -> [CGImage]? {
        guard let strip = strips[animation], !strip.isEmpty else { return nil }
        return strip
    }

    static func load(path: String, version: CodexPetSpriteVersion) -> PetSpriteFrames {
        guard !path.isEmpty, let sheet = loadSheet(path: path) else { return .empty }
        var strips: [CodexPetSpriteLayout.Animation: [CGImage]] = [:]
        for animation in CodexPetSpriteLayout.animations(in: version) {
            let frames = crop(sheet: sheet, animation: animation)
            guard !frames.isEmpty else { continue }
            strips[animation] = frames
        }
        return PetSpriteFrames(strips: strips)
    }

    private static func crop(
        sheet: CGImage,
        animation: CodexPetSpriteLayout.Animation
    ) -> [CGImage] {
        guard let strip = CodexPetSpriteLayout.strips[animation] else { return [] }
        let frames = (0..<strip.frameCount).compactMap { column in
            CodexPetSpriteLayout.frameRect(column: column, animation: animation)
                .flatMap(sheet.cropping(to:))
        }
        // 공개 표가 프레임 수를 못 박은 행(0~8)은 그대로 믿는다. 둘러보기 두 행은
        // 실제 사용 열이 몇 개인지 알 수 없으므로, 뒤쪽 빈 셀을 잘라내지 않으면
        // 재생 중 펫이 사라져 보인다 — 명세상 미사용 셀은 완전히 투명하다.
        guard CodexPetSpriteLayout.requiredVersion(for: animation) == .v2 else {
            return frames
        }
        return trimmingTrailingTransparent(frames)
    }

    static func trimmingTrailingTransparent(_ frames: [CGImage]) -> [CGImage] {
        var used = frames.count
        while used > 1, isFullyTransparent(frames[used - 1]) {
            used -= 1
        }
        // 첫 프레임까지 비어 있으면 그 행 자체가 없는 셈이다.
        if used == 1, let first = frames.first, isFullyTransparent(first) {
            return []
        }
        return Array(frames.prefix(used))
    }

    /// 알파 채널만 남긴 축소본을 그려 전부 0인지 본다. 축소는 평균이라
    /// 완전히 투명한 셀은 그대로 0으로 남는다.
    private static func isFullyTransparent(_ image: CGImage) -> Bool {
        let side = 16
        var buffer = [UInt8](repeating: 0, count: side * side)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue
            ) else {
                return false
            }
            context.draw(
                image,
                in: CGRect(x: 0, y: 0, width: side, height: side)
            )
            return true
        }
        // 알파를 읽지 못했으면 비었다고 단정하지 않는다 — 프레임을 살려둔다.
        guard drawn else { return false }
        return buffer.allSatisfy { $0 == 0 }
    }

    private static func loadSheet(path: String) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(
            URL(fileURLWithPath: path) as CFURL, nil
        ) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
