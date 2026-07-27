import Foundation

struct AmonPetMotionSample: Equatable {
    let offsetX: Double
    let offsetY: Double
    let rotationDegrees: Double
    let scale: Double
    let statusDotScale: Double
    let sparkleScale: Double

    static let still = AmonPetMotionSample(
        offsetX: 0,
        offsetY: 0,
        rotationDegrees: 0,
        scale: 1,
        statusDotScale: 1,
        sparkleScale: 1
    )
}

/// 기본 A-mon 펫의 상태별 모션을 시간 기반으로 계산한다.
/// TimelineView가 이 값을 읽으므로 상태 전환 직후에도 새 모션이 확실히 적용된다.
enum AmonPetMotion {
    static func sample(
        status: PetActivityStatus,
        time: TimeInterval,
        reduceMotion: Bool
    ) -> AmonPetMotionSample {
        guard !reduceMotion else { return .still }

        switch status {
        case .idle:
            let wave = sine(time: time, period: 1.8)
            return .init(
                offsetX: 0,
                offsetY: wave * 2,
                rotationDegrees: 0,
                scale: 1,
                statusDotScale: 1,
                sparkleScale: 1
            )
        case .running:
            let wave = sine(time: time, period: 0.42)
            let bounce = abs(wave)
            return .init(
                offsetX: wave * 1.5,
                offsetY: -2 - bounce * 8,
                rotationDegrees: wave * 3.5,
                scale: 1 + bounce * 0.025,
                statusDotScale: 0.9 + bounce * 0.28,
                sparkleScale: 1
            )
        case .reviewing:
            // 좌우로 천천히 훑어보듯 — 작업 중보다 느리고 위아래 움직임은 없다.
            let wave = sine(time: time, period: 1.1)
            return .init(
                offsetX: wave * 4,
                offsetY: 0,
                rotationDegrees: wave * 2,
                scale: 1,
                statusDotScale: 1,
                sparkleScale: 1
            )
        case .needsInput:
            let wave = sine(time: time, period: 0.55)
            return .init(
                offsetX: wave * 2,
                offsetY: -1,
                rotationDegrees: wave * 6,
                scale: 1,
                statusDotScale: 1,
                sparkleScale: 1
            )
        case .ready:
            let bounce = abs(sine(time: time, period: 0.7))
            return .init(
                offsetX: 0,
                offsetY: -bounce * 9,
                rotationDegrees: 0,
                scale: 1 + bounce * 0.04,
                statusDotScale: 1,
                sparkleScale: 0.8 + bounce * 0.4
            )
        case .blocked:
            let wave = sine(time: time, period: 0.24)
            return .init(
                offsetX: wave * 5,
                offsetY: 0,
                rotationDegrees: wave * -2,
                scale: 1,
                statusDotScale: 1,
                sparkleScale: 1
            )
        }
    }

    private static func sine(time: TimeInterval, period: TimeInterval) -> Double {
        sin(time * 2 * .pi / period)
    }
}

/// 말풍선 헤더의 "작업 중" 표시에 쓰는 3점 웨이브.
///
/// 점마다 위상을 어긋나게 해서 왼쪽에서 오른쪽으로 훑고 지나가듯 보인다.
/// 값은 0~1 이며 크기와 불투명도에 함께 쓴다.
enum PetWorkingDots {
    static let dotCount = 3
    /// 한 바퀴 도는 데 걸리는 시간 — 과하지 않게 느슨히 잡는다.
    static let period: TimeInterval = 1.2

    static func intensity(
        index: Int,
        time: TimeInterval,
        reduceMotion: Bool
    ) -> Double {
        guard !reduceMotion else { return 1 }
        guard dotCount > 0, index >= 0, index < dotCount else { return 1 }
        let offset = Double(index) / Double(dotCount)
        let wave = sin((time / period - offset) * 2 * .pi)
        // sin 을 0~1 로 옮긴 뒤 완전히 꺼지지 않도록 바닥을 남긴다.
        return 0.3 + 0.7 * (wave + 1) / 2
    }
}
