import CoreGraphics
import XCTest

@testable import AIMonitor

/// 명세 11행이 실제 상황에 어떻게 배정되는지 — 상태 6행 + 사건 5행.
final class PetSpriteDirectorTests: XCTestCase {
    private let center = CGPoint(x: 500, y: 500)
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)

    // MARK: - 상태 → 행

    func testEveryStatusMapsToItsRow() {
        XCTAssertEqual(CodexPetSpriteLayout.animation(for: .idle), .idle)
        XCTAssertEqual(CodexPetSpriteLayout.animation(for: .running), .running)
        XCTAssertEqual(CodexPetSpriteLayout.animation(for: .reviewing), .review)
        XCTAssertEqual(CodexPetSpriteLayout.animation(for: .needsInput), .waiting)
        XCTAssertEqual(CodexPetSpriteLayout.animation(for: .ready), .waving)
        XCTAssertEqual(CodexPetSpriteLayout.animation(for: .blocked), .failed)
    }

    /// 명세의 11행이 모두 실제로 재생될 수 있어야 한다 — 죽은 행이 없어야 한다.
    func testAllElevenRowsAreReachable() {
        var reached = Set<CodexPetSpriteLayout.Animation>()

        for status in PetActivityStatus.allCases {
            reached.insert(CodexPetSpriteLayout.animation(for: status))
        }
        for side in [PetLocomotion.left, .right] {
            reached.insert(CodexPetSpriteLayout.locomotion(side))
            reached.insert(CodexPetSpriteLayout.lookAround(side))
        }
        // 점프는 완료 진입 순간의 1회 연출로만 나온다.
        var director = PetSpriteDirector()
        _ = playback(&director, status: .running, at: start)
        reached.insert(
            playback(&director, status: .ready, at: start.addingTimeInterval(1)).animation
        )

        XCTAssertEqual(reached, Set(CodexPetSpriteLayout.Animation.allCases))
    }

    // MARK: - 끌기 → 주행

    func testDraggingPlaysDirectionalRunRows() {
        var director = PetSpriteDirector()

        XCTAssertEqual(
            playback(&director, status: .idle, locomotion: .right, at: start).animation,
            .runningRight
        )
        XCTAssertEqual(
            playback(&director, status: .idle, locomotion: .left, at: start).animation,
            .runningLeft
        )
        // 놓으면 원래 상태로 돌아온다.
        XCTAssertEqual(
            playback(&director, status: .idle, at: start).animation,
            .idle
        )
    }

    /// 끌기는 어떤 상태에서도 주행이 우선이다 — 직접 만지는 행동이 가장 강한 신호다.
    func testDragOverridesStatusAnimation() {
        var director = PetSpriteDirector()
        for status in PetActivityStatus.allCases {
            XCTAssertEqual(
                playback(&director, status: status, locomotion: .right, at: start).animation,
                .runningRight,
                "\(status) 를 끌 때도 주행이어야 한다"
            )
        }
    }

    // MARK: - 완료 진입 → 점프 1회

    func testReadyEntryJumpsOnceThenWaves() {
        var director = PetSpriteDirector()
        _ = playback(&director, status: .running, at: start)

        let entering = playback(&director, status: .ready, at: start.addingTimeInterval(1))
        XCTAssertEqual(entering.animation, .jumping)
        XCTAssertEqual(entering.oneShotElapsed, 0)

        let cycle = CodexPetSpriteLayout.cycleDuration(for: .jumping)
        let midway = playback(
            &director,
            status: .ready,
            at: start.addingTimeInterval(1 + cycle / 2)
        )
        XCTAssertEqual(midway.animation, .jumping)

        // 한 바퀴가 끝나면 완료 상태의 기본 행(waving)으로 넘어간다.
        let after = playback(
            &director,
            status: .ready,
            at: start.addingTimeInterval(1 + cycle + 0.01)
        )
        XCTAssertEqual(after.animation, .waving)
        XCTAssertNil(after.oneShotElapsed)
    }

    /// 완료 몸짓은 유한하다 — 말풍선을 접은 뒤에도 계속 손을 흔들면 새 알림처럼 보인다.
    /// 완료 상태는 세션이 목록에서 빠질 때까지(최대 15분) 남으므로 여기서 끊어야 한다.
    func testWavingStopsAndRestsAfterTheReadyGesture() {
        var director = PetSpriteDirector()
        _ = playback(&director, status: .running, at: start)
        let done = start.addingTimeInterval(1)
        _ = playback(&director, status: .ready, at: done)

        let waving = done.addingTimeInterval(
            CodexPetSpriteLayout.cycleDuration(for: .jumping) + 0.01
        )
        XCTAssertEqual(playback(&director, status: .ready, at: waving).animation, .waving)

        let stillWaving = done.addingTimeInterval(
            PetSpriteDirector.readyGestureDuration - 0.01
        )
        XCTAssertEqual(playback(&director, status: .ready, at: stillWaving).animation, .waving)

        let rested = done.addingTimeInterval(PetSpriteDirector.readyGestureDuration)
        XCTAssertEqual(playback(&director, status: .ready, at: rested).animation, .idle)

        // 한참 뒤에도 계속 쉰다.
        XCTAssertEqual(
            playback(&director, status: .ready, at: done.addingTimeInterval(600)).animation,
            .idle
        )
    }

    /// 다음 작업이 끝나면 다시 처음부터 알린다.
    func testNextCompletionGesturesAgain() {
        var director = PetSpriteDirector()
        _ = playback(&director, status: .running, at: start)
        _ = playback(&director, status: .ready, at: start.addingTimeInterval(1))
        XCTAssertEqual(
            playback(&director, status: .ready, at: start.addingTimeInterval(60)).animation,
            .idle
        )

        _ = playback(&director, status: .running, at: start.addingTimeInterval(70))
        let again = playback(&director, status: .ready, at: start.addingTimeInterval(80))
        XCTAssertEqual(again.animation, .jumping)
        XCTAssertEqual(again.oneShotElapsed, 0)
    }

    /// 완료 몸짓이 끝난 뒤에는 대기 중과 똑같이 마우스를 따라 둘러본다.
    func testRestingAfterCompletionStillLooksAround() {
        var director = PetSpriteDirector()
        _ = playback(&director, status: .running, at: start)
        let done = start.addingTimeInterval(1)
        _ = playback(&director, status: .ready, cursor: center, at: done)

        let rested = done.addingTimeInterval(PetSpriteDirector.readyGestureDuration)
        XCTAssertEqual(
            playback(
                &director,
                status: .ready,
                cursor: CGPoint(x: center.x + 200, y: center.y),
                at: rested
            ).animation,
            .lookAroundRight
        )
    }

    /// 앱을 켰을 때 이미 완료 상태였다면 지난 일이므로 뛰지도 흔들지도 않는다.
    func testFirstObservationNeitherJumpsNorWaves() {
        var director = PetSpriteDirector()
        XCTAssertEqual(playback(&director, status: .ready, at: start).animation, .idle)
    }

    func testJumpIsSkippedWhenReduceMotionIsOn() {
        var director = PetSpriteDirector()
        _ = playback(&director, status: .running, at: start, reduceMotion: true)
        XCTAssertEqual(
            playback(
                &director,
                status: .ready,
                at: start.addingTimeInterval(1),
                reduceMotion: true
            ).animation,
            .waving
        )
    }

    // MARK: - 대기 중 마우스 움직임 → 둘러보기

    func testIdleLooksTowardTheSideTheMouseMovedTo() {
        var director = PetSpriteDirector()
        // 첫 표본은 기준점만 잡는다 — 움직였는지 알 수 없다.
        XCTAssertEqual(
            playback(&director, status: .idle, cursor: center, at: start).animation,
            .idle
        )

        let right = CGPoint(x: center.x + 200, y: center.y)
        XCTAssertEqual(
            playback(
                &director,
                status: .idle,
                cursor: right,
                at: start.addingTimeInterval(0.1)
            ).animation,
            .lookAroundRight
        )

        let left = CGPoint(x: center.x - 200, y: center.y)
        XCTAssertEqual(
            playback(
                &director,
                status: .idle,
                cursor: left,
                at: start.addingTimeInterval(0.2)
            ).animation,
            .lookAroundLeft
        )
    }

    /// 마우스가 멈추면 잠시 뒤 다시 idle 루프로 돌아온다.
    func testLookAroundStopsAfterTheMouseRests() {
        var director = PetSpriteDirector()
        _ = playback(&director, status: .idle, cursor: center, at: start)
        let moved = start.addingTimeInterval(0.1)
        XCTAssertEqual(
            playback(
                &director,
                status: .idle,
                cursor: CGPoint(x: center.x + 200, y: center.y),
                at: moved
            ).animation,
            .lookAroundRight
        )

        let resting = moved.addingTimeInterval(PetSpriteDirector.lookLinger - 0.01)
        XCTAssertEqual(
            playback(
                &director,
                status: .idle,
                cursor: CGPoint(x: center.x + 200, y: center.y),
                at: resting
            ).animation,
            .lookAroundRight
        )

        let rested = moved.addingTimeInterval(PetSpriteDirector.lookLinger + 0.01)
        XCTAssertEqual(
            playback(
                &director,
                status: .idle,
                cursor: CGPoint(x: center.x + 200, y: center.y),
                at: rested
            ).animation,
            .idle
        )
    }

    /// 손떨림 수준의 이동은 둘러보기를 깨우지 않는다.
    func testTinyCursorJitterIsIgnored() {
        var director = PetSpriteDirector()
        _ = playback(&director, status: .idle, cursor: center, at: start)
        let jittered = CGPoint(
            x: center.x + PetSpriteDirector.cursorMoveThreshold / 2,
            y: center.y
        )
        XCTAssertEqual(
            playback(
                &director,
                status: .idle,
                cursor: jittered,
                at: start.addingTimeInterval(0.1)
            ).animation,
            .idle
        )
    }

    /// 펫 바로 위에서 움직이면 좌우가 튀지 않도록 직전에 보던 쪽을 유지한다.
    func testCenterDeadzoneKeepsThePreviousSide() {
        var director = PetSpriteDirector()
        _ = playback(&director, status: .idle, cursor: center, at: start)
        _ = playback(
            &director,
            status: .idle,
            cursor: CGPoint(x: center.x + 200, y: center.y),
            at: start.addingTimeInterval(0.1)
        )

        let inDeadzone = CGPoint(
            x: center.x + PetSpriteDirector.sideDeadzone / 2,
            y: center.y
        )
        XCTAssertEqual(
            playback(
                &director,
                status: .idle,
                cursor: inDeadzone,
                at: start.addingTimeInterval(0.2)
            ).animation,
            .lookAroundRight
        )
    }

    /// 일하는 중에는 둘러보지 않는다 — 작업 애니메이션을 덮으면 안 된다.
    /// 완료는 몸짓을 마치면 쉬는 상태라 예외다(testRestingAfterCompletionStillLooksAround).
    func testLookAroundNeverInterruptsWork() {
        for status in [PetActivityStatus.running, .reviewing, .needsInput, .blocked] {
            var director = PetSpriteDirector()
            _ = playback(&director, status: status, cursor: center, at: start)
            XCTAssertEqual(
                playback(
                    &director,
                    status: status,
                    cursor: CGPoint(x: center.x + 200, y: center.y),
                    at: start.addingTimeInterval(0.1)
                ).animation,
                CodexPetSpriteLayout.animation(for: status),
                "\(status) 중에는 둘러보면 안 된다"
            )
        }
    }

    /// v1 시트에는 둘러보기 행이 없으므로 idle 루프를 유지한다.
    func testV1SheetNeverPlaysLookAround() {
        var director = PetSpriteDirector()
        _ = playback(&director, status: .idle, version: .v1, cursor: center, at: start)
        XCTAssertEqual(
            playback(
                &director,
                status: .idle,
                version: .v1,
                cursor: CGPoint(x: center.x + 200, y: center.y),
                at: start.addingTimeInterval(0.1)
            ).animation,
            .idle
        )
    }

    func testLookAroundIsSkippedWhenReduceMotionIsOn() {
        var director = PetSpriteDirector()
        _ = playback(&director, status: .idle, cursor: center, at: start, reduceMotion: true)
        XCTAssertEqual(
            playback(
                &director,
                status: .idle,
                cursor: CGPoint(x: center.x + 200, y: center.y),
                at: start.addingTimeInterval(0.1),
                reduceMotion: true
            ).animation,
            .idle
        )
    }

    // MARK: -

    private func playback(
        _ director: inout PetSpriteDirector,
        status: PetActivityStatus,
        version: CodexPetSpriteVersion = .v2,
        locomotion: PetLocomotion? = nil,
        cursor: CGPoint? = nil,
        at now: Date,
        reduceMotion: Bool = false
    ) -> PetPlayback {
        director.playback(
            status: status,
            version: version,
            locomotion: locomotion,
            cursor: cursor,
            petCenter: center,
            now: now,
            reduceMotion: reduceMotion
        )
    }
}
