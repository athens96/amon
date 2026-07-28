import CoreGraphics
import Foundation

/// Codex custom pet sprite sheet 와 호환되는 프레임 배치.
///
/// 공개된 세 스프라이트 버전을 모두 지원한다.
/// - v1: 1536×1872 = 8열 × 9행. 표준 애니메이션 9종.
/// - v2: 1536×2288 = 8열 × 11행. 같은 9종 + 행 9~10 의 둘러보기 2종.
/// - v3: 1536×2496 = 8열 × 12행. v2 + 행 11의 뒷모습 앞으로 달리기.
///
/// 행 순서는 Codex 펫 명세를 그대로 따른다 —
/// idle · Run right · Run left · Waving · Jumping · Failed · Waiting ·
/// Running · Review · Look around(Right) · Look around(Left) · Running away.
/// 프레임 셀 크기(192×208)와 앞쪽 9행의 의미는 두 버전이 같다.
enum CodexPetSpriteLayout {
    static let sheetPixelWidth = 1536
    static let framePixelWidth = 192
    static let framePixelHeight = 208
    static let columnCount = 8

    /// 표준 애니메이션 행 수 — 모든 버전이 공유한다.
    static let standardRowCount = 9
    /// v2 가 추가하는 둘러보기 행 수(행 9~10).
    static let lookRowCount = 2
    /// v3가 추가하는 뒷모습 앞으로 달리기 행(행 11).
    static let runningAwayRowCount = 1
    static let v1SheetPixelHeight = standardRowCount * framePixelHeight
    static let v2SheetPixelHeight =
        (standardRowCount + lookRowCount) * framePixelHeight
    static let v3SheetPixelHeight =
        (standardRowCount + lookRowCount + runningAwayRowCount) * framePixelHeight
    static let v1RowCount = standardRowCount
    static let v2RowCount = standardRowCount + lookRowCount
    static let v3RowCount = standardRowCount + lookRowCount + runningAwayRowCount

    static func rowCount(for version: CodexPetSpriteVersion) -> Int {
        switch version {
        case .v1: return standardRowCount
        case .v2: return standardRowCount + lookRowCount
        case .v3: return standardRowCount + lookRowCount + runningAwayRowCount
        }
    }

    static func sheetPixelHeight(for version: CodexPetSpriteVersion) -> Int {
        rowCount(for: version) * framePixelHeight
    }

    /// 시트 픽셀 크기로 버전을 판별한다. 매니페스트가 버전을 선언하지 않는
    /// 단일 이미지 임포트 경로에서 쓴다.
    static func version(
        forPixelWidth width: Int,
        pixelHeight height: Int
    ) -> CodexPetSpriteVersion? {
        guard width == sheetPixelWidth else { return nil }
        return CodexPetSpriteVersion.allCases.first {
            sheetPixelHeight(for: $0) == height
        }
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
        case lookAroundRight
        case lookAroundLeft
        case runningAway
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
        // 공개 표는 행 8까지만 프레임 수를 못 박는다. 둘러보기 두 행은 열 전체를
        // 후보로 잡고, 실제 사용 프레임 수는 로더가 시트에서 읽어 좁힌다
        // (명세: 마지막 사용 열 뒤의 셀은 완전히 투명하다).
        .lookAroundRight: Strip(row: 9, frameCount: columnCount),
        .lookAroundLeft: Strip(row: 10, frameCount: columnCount),
        .runningAway: Strip(row: 11, frameCount: 8),
    ]

    /// 이 애니메이션을 담고 있는 최소 시트 버전.
    static func requiredVersion(for animation: Animation) -> CodexPetSpriteVersion {
        switch animation {
        case .lookAroundRight, .lookAroundLeft:
            return .v2
        case .runningAway:
            return .v3
        default:
            return .v1
        }
    }

    static func isAvailable(_ animation: Animation, in version: CodexPetSpriteVersion) -> Bool {
        requiredVersion(for: animation).rawValue <= version.rawValue
    }

    static func animations(in version: CodexPetSpriteVersion) -> [Animation] {
        Animation.allCases.filter { isAvailable($0, in: version) }
    }

    /// 대기 중 마우스가 움직인 쪽을 바라보는 둘러보기 행. v2 이상에 있다.
    static func lookAround(_ side: PetLocomotion) -> Animation {
        switch side {
        case .right: return .lookAroundRight
        case .left: return .lookAroundLeft
        }
    }

    /// 펫을 끌고 갈 때 쓰는 주행 행.
    static func locomotion(_ side: PetLocomotion) -> Animation {
        switch side {
        case .right: return .runningRight
        case .left: return .runningLeft
        }
    }

    static func animation(for status: PetActivityStatus) -> Animation {
        switch status {
        case .idle:
            return .idle
        case .running:
            return .running
        case .reviewing:
            return .review
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
        return frameRect(column: column, row: strip.row)
    }

    private static func frameRect(column: Int, row: Int) -> CGRect {
        CGRect(
            x: column * framePixelWidth,
            y: row * framePixelHeight,
            width: framePixelWidth,
            height: framePixelHeight
        )
    }

    // MARK: - 프레임 타이밍

    /// 공개 표(행 0~8)의 프레임 지속시간. 둘러보기 두 행은 표에 없으므로 같은
    /// "훑어보는" 동작인 review 행의 박자를 그대로 쓴다.
    ///
    /// `frameCount` 를 주면 그 개수만큼만 잘라 쓴다 — 시트에서 실제로 사용된
    /// 프레임이 선언값보다 적은 둘러보기 행에서 필요하다.
    static func frameDurations(
        for animation: Animation,
        frameCount: Int? = nil
    ) -> [TimeInterval] {
        guard let declared = strips[animation]?.frameCount else { return [] }
        let count = min(frameCount ?? declared, declared)
        guard count > 0 else { return [] }
        let full: [TimeInterval]
        switch animation {
        case .idle:
            full = [1.68, 0.66, 0.66, 0.84, 0.84, 1.92]
        case .runningRight, .runningLeft, .running, .runningAway:
            full = repeatedDurations(count: declared, regular: 0.12, final: 0.22)
        case .waving, .jumping:
            full = repeatedDurations(count: declared, regular: 0.14, final: 0.28)
        case .failed:
            full = repeatedDurations(count: declared, regular: 0.14, final: 0.24)
        case .waiting:
            full = repeatedDurations(count: declared, regular: 0.15, final: 0.26)
        case .review, .lookAroundRight, .lookAroundLeft:
            full = repeatedDurations(count: declared, regular: 0.15, final: 0.28)
        }
        guard count < declared else { return full }
        // 마지막 프레임은 한 박자 길게 머무는 마무리 프레임이므로, 잘라낼 때도
        // 새 마지막 프레임이 그 역할을 이어받도록 길이를 옮겨준다.
        var trimmed = Array(full.prefix(count))
        trimmed[count - 1] = full[full.count - 1]
        return trimmed
    }

    /// 반복 재생 중 지금 보여줄 프레임.
    static func frameIndex(
        at time: TimeInterval,
        animation: Animation,
        frameCount: Int? = nil,
        reduceMotion: Bool
    ) -> Int? {
        let durations = frameDurations(for: animation, frameCount: frameCount)
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

    /// 한 번만 재생하는 연출(예: 완료 순간의 점프)의 현재 프레임.
    /// 재생이 끝났거나 "동작 줄이기"가 켜져 있으면 nil — 부르는 쪽이 기본
    /// 애니메이션으로 돌아가면 된다.
    static func oneShotFrameIndex(
        elapsed: TimeInterval,
        animation: Animation,
        frameCount: Int? = nil,
        reduceMotion: Bool
    ) -> Int? {
        guard !reduceMotion, elapsed >= 0 else { return nil }
        let durations = frameDurations(for: animation, frameCount: frameCount)
        guard !durations.isEmpty else { return nil }
        var cursor = elapsed
        for (index, duration) in durations.enumerated() {
            if cursor < duration { return index }
            cursor -= duration
        }
        return nil
    }

    /// 한 바퀴 도는 데 걸리는 시간.
    static func cycleDuration(
        for animation: Animation,
        frameCount: Int? = nil
    ) -> TimeInterval {
        frameDurations(for: animation, frameCount: frameCount).reduce(0, +)
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
