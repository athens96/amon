import CoreGraphics
import Foundation

/// 현재 Codex custom pet sprite sheet 와 호환되는 프레임 배치.
///
/// V1의 9개 표준 행과 V2의 같은 표준 행을 재생하며, V2의 추가 시선 방향
/// 2개 행은 시트에 그대로 보존한다.
enum CodexPetSpriteLayout {
    static let sheetPixelWidth = 1536
    static let v1SheetPixelHeight = 1872
    static let v2SheetPixelHeight = 2288
    static let framePixelWidth = 192
    static let framePixelHeight = 208
    static let columnCount = 8
    static let v1RowCount = 9
    static let v2RowCount = 11

    static func sheetPixelHeight(for version: CodexPetSpriteVersion) -> Int {
        version.requiredPixelHeight
    }

    static func rowCount(for version: CodexPetSpriteVersion) -> Int {
        version.rowCount
    }

    enum Animation: String, CaseIterable {
        case idle
        case runningRight
        case runningLeft
        case waving
        case jumping
        case failed
        case waiting
        case running
        case review
    }

    struct Strip: Equatable {
        let row: Int
        let frameCount: Int
    }

    static let strips: [Animation: Strip] = [
        .idle: Strip(row: 0, frameCount: 6),
        .runningRight: Strip(row: 1, frameCount: 8),
        .runningLeft: Strip(row: 2, frameCount: 8),
        .waving: Strip(row: 3, frameCount: 4),
        .jumping: Strip(row: 4, frameCount: 5),
        .failed: Strip(row: 5, frameCount: 8),
        .waiting: Strip(row: 6, frameCount: 6),
        .running: Strip(row: 7, frameCount: 6),
        .review: Strip(row: 8, frameCount: 6),
    ]

    static func animation(for status: PetActivityStatus) -> Animation {
        switch status {
        case .idle:
            return .idle
        case .running:
            return .running
        case .needsInput:
            return .waiting
        case .ready:
            return .waving
        case .blocked:
            return .failed
        }
    }

    static func frameRect(column: Int, animation: Animation) -> CGRect? {
        guard let strip = strips[animation],
              column >= 0,
              column < strip.frameCount
        else {
            return nil
        }
        return CGRect(
            x: column * framePixelWidth,
            y: strip.row * framePixelHeight,
            width: framePixelWidth,
            height: framePixelHeight
        )
    }

    static func frameDurations(for animation: Animation) -> [TimeInterval] {
        guard let count = strips[animation]?.frameCount else { return [] }
        switch animation {
        case .idle:
            return [1.68, 0.66, 0.66, 0.84, 0.84, 1.92]
        case .runningRight, .runningLeft, .running:
            return repeatedDurations(count: count, regular: 0.12, final: 0.22)
        case .waving, .jumping:
            return repeatedDurations(count: count, regular: 0.14, final: 0.28)
        case .failed:
            return repeatedDurations(count: count, regular: 0.14, final: 0.24)
        case .waiting:
            return repeatedDurations(count: count, regular: 0.15, final: 0.26)
        case .review:
            return repeatedDurations(count: count, regular: 0.15, final: 0.28)
        }
    }

    static func frameIndex(
        at time: TimeInterval,
        animation: Animation,
        reduceMotion: Bool
    ) -> Int? {
        let durations = frameDurations(for: animation)
        guard !durations.isEmpty else { return nil }
        if reduceMotion { return 0 }
        let cycle = durations.reduce(0, +)
        guard cycle > 0 else { return 0 }
        var cursor = time.truncatingRemainder(dividingBy: cycle)
        if cursor < 0 { cursor += cycle }
        for (index, duration) in durations.enumerated() {
            if cursor < duration { return index }
            cursor -= duration
        }
        return durations.indices.last
    }

    private static func repeatedDurations(
        count: Int,
        regular: TimeInterval,
        final: TimeInterval
    ) -> [TimeInterval] {
        guard count > 0 else { return [] }
        return (0..<count).map { $0 == count - 1 ? final : regular }
    }
}
