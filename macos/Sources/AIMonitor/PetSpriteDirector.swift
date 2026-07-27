import CoreGraphics
import Foundation

/// 펫이 향하는 좌우 방향.
enum PetLocomotion: String, Equatable {
    case left
    case right
}

/// 지금 재생할 애니메이션과 재생 방식.
struct PetPlayback: Equatable {
    let animation: CodexPetSpriteLayout.Animation
    /// 1회 재생 연출의 경과 시간. 반복 재생이면 nil.
    let oneShotElapsed: TimeInterval?

    static func loop(_ animation: CodexPetSpriteLayout.Animation) -> PetPlayback {
        PetPlayback(animation: animation, oneShotElapsed: nil)
    }
}

/// 스프라이트 11행을 실제 상황에 배정하는 순수 판정.
///
/// 활동 상태(idle/running/reviewing/needsInput/ready/blocked)만으로는 6행밖에
/// 쓰지 못한다. 남은 행은 상태가 아니라 사건에 붙는다.
/// - 주행(Run right/left): 사용자가 펫을 끌고 가는 방향
/// - 점프(Jumping): 작업이 막 끝난 순간 한 번
/// - 둘러보기(Look around): 할 일이 없을 때 마우스가 움직인 쪽 — v2 시트 전용
///
/// 시각과 좌표를 인자로만 받아 테스트할 수 있게 두고, 화면·이벤트 접근은
/// 호출하는 뷰가 맡는다.
struct PetSpriteDirector: Equatable {
    /// 이만큼(pt) 넘게 움직여야 "마우스가 움직였다"고 본다 — 미세한 떨림 무시.
    static let cursorMoveThreshold: CGFloat = 2
    /// 마지막 움직임 이후 이 시간이 지나면 둘러보기를 멈추고 idle 로 돌아간다.
    static let lookLinger: TimeInterval = 1.5
    /// 펫 중심에서 이만큼 안쪽은 좌우를 가르지 않는다 — 정중앙에서 방향이 튀는 것 방지.
    static let sideDeadzone: CGFloat = 12
    /// 완료를 알리는 몸짓(점프 → 손 흔들기)을 이 시간까지만 하고 쉬는 자세로 돌아간다.
    ///
    /// 완료 상태 자체는 세션이 목록에서 빠질 때까지(최대 15분) 남지만, Waving 은
    /// 명세상 "greeting or attention gesture" 라 쉬는 루프로 쓸 수 없다. 말풍선을
    /// 접은 뒤에도 펫이 계속 손을 흔들면 새 알림처럼 보인다.
    static let readyGestureDuration: TimeInterval = 4

    private var lastCursor: CGPoint?
    private var lastCursorMovedAt: Date?
    private var lookSide: PetLocomotion?
    private var lastStatus: PetActivityStatus?
    private var oneShot: OneShot?
    /// 완료로 넘어온 시각 — 몸짓을 언제 멈출지 잰다.
    private var readyEnteredAt: Date?

    init() {}

    private struct OneShot: Equatable {
        let animation: CodexPetSpriteLayout.Animation
        let startedAt: Date
    }

    mutating func playback(
        status: PetActivityStatus,
        version: CodexPetSpriteVersion,
        locomotion: PetLocomotion?,
        cursor: CGPoint?,
        petCenter: CGPoint?,
        now: Date,
        reduceMotion: Bool
    ) -> PetPlayback {
        let base = CodexPetSpriteLayout.animation(for: status)

        if enteredStatus(status) {
            oneShot = nil
            readyEnteredAt = nil
            if status == .ready {
                readyEnteredAt = now
                // 완료로 막 넘어온 순간엔 한 번 뛴다. 뛰고 나면 waving 으로 이어진다.
                if !reduceMotion {
                    oneShot = OneShot(animation: .jumping, startedAt: now)
                }
            }
        }

        trackCursor(cursor, now: now, petCenter: petCenter)

        // 직접 끌고 있으면 그게 가장 강한 신호다 — 다른 연출을 덮는다.
        if let locomotion {
            oneShot = nil
            return .loop(CodexPetSpriteLayout.locomotion(locomotion))
        }

        if !reduceMotion, let oneShot {
            let elapsed = now.timeIntervalSince(oneShot.startedAt)
            if elapsed >= 0,
               elapsed < CodexPetSpriteLayout.cycleDuration(for: oneShot.animation) {
                return PetPlayback(animation: oneShot.animation, oneShotElapsed: elapsed)
            }
            self.oneShot = nil
        }

        // 완료 몸짓이 끝났으면 할 일이 없는 것과 같다 — 쉬는 자세로 돌아간다.
        let rests = isResting(status: status, now: now)

        if !reduceMotion,
           rests,
           let side = activeLookSide(now: now),
           CodexPetSpriteLayout.isAvailable(
               CodexPetSpriteLayout.lookAround(side),
               in: version
           ) {
            return .loop(CodexPetSpriteLayout.lookAround(side))
        }

        return .loop(rests ? .idle : base)
    }

    /// 지금 쉬는 중인지. 완료는 몸짓을 마친 뒤부터 쉬는 것으로 본다.
    private func isResting(status: PetActivityStatus, now: Date) -> Bool {
        switch status {
        case .idle:
            return true
        case .ready:
            // 언제 끝났는지 모르면(앱을 새로 켰다면) 지난 일이므로 흔들지 않는다.
            guard let readyEnteredAt else { return true }
            let elapsed = now.timeIntervalSince(readyEnteredAt)
            return elapsed < 0 || elapsed >= Self.readyGestureDuration
        case .running, .reviewing, .needsInput, .blocked:
            return false
        }
    }

    /// 상태가 방금 바뀌었는지. 첫 관찰은 전환으로 보지 않는다 — 앱을 켜자마자
    /// 완료 상태였다는 이유로 뛰어오르면 안 된다.
    private mutating func enteredStatus(_ status: PetActivityStatus) -> Bool {
        defer { lastStatus = status }
        guard let lastStatus else { return false }
        return lastStatus != status
    }

    /// 마우스가 움직였는지 보고, 움직였다면 펫 기준 어느 쪽인지 기억한다.
    private mutating func trackCursor(
        _ cursor: CGPoint?,
        now: Date,
        petCenter: CGPoint?
    ) {
        guard let cursor else { return }
        defer { lastCursor = cursor }
        guard let previous = lastCursor else { return }
        let moved = hypot(cursor.x - previous.x, cursor.y - previous.y)
        guard moved > Self.cursorMoveThreshold else { return }
        lastCursorMovedAt = now
        guard let petCenter else { return }
        let dx = cursor.x - petCenter.x
        // 데드존 안이면 직전에 보던 쪽을 유지한다.
        guard abs(dx) > Self.sideDeadzone else { return }
        lookSide = dx > 0 ? .right : .left
    }

    private func activeLookSide(now: Date) -> PetLocomotion? {
        guard let lookSide, let lastCursorMovedAt else { return nil }
        let since = now.timeIntervalSince(lastCursorMovedAt)
        guard since >= 0, since < Self.lookLinger else { return nil }
        return lookSide
    }
}
