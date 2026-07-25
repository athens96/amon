import XCTest

@testable import AIMonitor

final class PetActivityTests: XCTestCase {
    func testCodexPrioritySelectsNeedsInputFirst() {
        let sessions = [
            makeSession(id: "running", status: "active", updatedAt: Date(timeIntervalSince1970: 50)),
            makeSession(id: "ready", status: "ready", updatedAt: Date(timeIntervalSince1970: 40)),
            makeSession(id: "blocked", status: "blocked", updatedAt: Date(timeIntervalSince1970: 30)),
            makeSession(
                id: "input",
                status: "awaiting_approval",
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
        ]

        let presentations = PetStateAdapter.presentations(
            for: sessions,
            localActivityEnabled: true
        )
        let presentation = try! XCTUnwrap(presentations.first)

        XCTAssertEqual(presentation.status, .needsInput)
        XCTAssertEqual(presentation.sessionID, "input")
        XCTAssertEqual(presentation.activeCount, 1)
        XCTAssertEqual(presentations.count, 1)
    }

    func testSameStatusUsesStableNewestSessionOrder() {
        let older = makeSession(
            id: "older",
            status: "active",
            startedAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 30)
        )
        let newer = makeSession(
            id: "newer",
            status: "running",
            startedAt: Date(timeIntervalSince1970: 20),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        let presentation = PetStateAdapter.presentation(for: [older, newer])

        XCTAssertEqual(presentation.status, .running)
        XCTAssertEqual(presentation.sessionID, "newer")
    }

    func testMultipleSessionsExposeInputOutputAndTokensForCarousel() {
        let first = makeSession(
            id: "first",
            status: "active",
            startedAt: Date(timeIntervalSince1970: 20),
            task: "첫 번째 입력",
            output: "첫 번째 출력",
            inputTokens: 1200,
            outputTokens: 340,
            totalTokens: 1540
        )
        let second = makeSession(
            id: "second",
            status: "active",
            startedAt: Date(timeIntervalSince1970: 10),
            task: "두 번째 입력",
            output: "두 번째 출력",
            inputTokens: 80,
            outputTokens: 20,
            totalTokens: 100
        )

        let presentations = PetStateAdapter.presentations(
            for: [second, first],
            localActivityEnabled: true
        )

        XCTAssertEqual(presentations.map(\.sessionID), ["first", "second"])
        XCTAssertEqual(presentations.first?.detail, "첫 번째 입력")
        XCTAssertEqual(presentations.first?.output, "첫 번째 출력")
        XCTAssertEqual(presentations.first?.inputTokens, 1200)
        XCTAssertEqual(presentations.first?.outputTokens, 340)
        XCTAssertEqual(presentations.first?.totalTokens, 1540)
        XCTAssertEqual(presentations.first?.activeCount, 2)
    }

    func testCarouselIncludesOnlyCurrentlyActiveSessions() {
        let sessions = [
            makeSession(
                id: "active-new",
                status: "active",
                startedAt: Date(timeIntervalSince1970: 30)
            ),
            makeSession(
                id: "active-old",
                status: "active",
                startedAt: Date(timeIntervalSince1970: 20)
            ),
            makeSession(
                id: "history-new",
                status: "idle",
                updatedAt: Date(timeIntervalSince1970: 40),
                output: "완료 출력"
            ),
            makeSession(
                id: "history-old",
                status: "idle",
                updatedAt: Date(timeIntervalSince1970: 10),
                output: "과거 출력"
            ),
            makeSession(
                id: "explicit-ready",
                status: "completed",
                updatedAt: Date(timeIntervalSince1970: 50),
                output: "명시적 완료 출력"
            ),
        ]

        let presentations = PetStateAdapter.presentations(
            for: sessions,
            localActivityEnabled: true
        )

        XCTAssertEqual(
            presentations.map(\.sessionID),
            ["active-new", "active-old"]
        )
        XCTAssertTrue(presentations.allSatisfy { $0.status == .running })
        XCTAssertTrue(presentations.allSatisfy { $0.activeCount == 2 })
    }

    func testOnlyNewestCompletedSessionIsShownWhenNothingIsActive() {
        let sessions = [
            makeSession(
                id: "history-old",
                status: "idle",
                updatedAt: Date(timeIntervalSince1970: 10),
                output: "과거 출력"
            ),
            makeSession(
                id: "history-new",
                status: "idle",
                updatedAt: Date(timeIntervalSince1970: 20),
                output: "최근 출력"
            ),
            makeSession(
                id: "idle-without-output",
                status: "idle",
                updatedAt: Date(timeIntervalSince1970: 30)
            ),
        ]

        let presentations = PetStateAdapter.presentations(
            for: sessions,
            localActivityEnabled: true
        )

        XCTAssertEqual(presentations.count, 1)
        XCTAssertEqual(presentations.first?.sessionID, "history-new")
        XCTAssertEqual(presentations.first?.status, .ready)
        XCTAssertEqual(presentations.first?.activeCount, 0)
    }

    func testCarouselWrapsAndPreservesSelectedSession() {
        let presentations = PetStateAdapter.presentations(
            for: [
                makeSession(
                    id: "first",
                    status: "active",
                    startedAt: Date(timeIntervalSince1970: 20)
                ),
                makeSession(
                    id: "second",
                    status: "active",
                    startedAt: Date(timeIntervalSince1970: 10)
                ),
            ],
            localActivityEnabled: true
        )
        let first = presentations[0].sessionIdentity
        let second = presentations[1].sessionIdentity

        XCTAssertEqual(
            PetCarousel.movedIdentity(
                selectedIdentity: first,
                offset: -1,
                in: presentations
            ),
            second
        )
        XCTAssertEqual(
            PetCarousel.movedIdentity(
                selectedIdentity: second,
                offset: 1,
                in: presentations
            ),
            first
        )
        XCTAssertEqual(
            PetCarousel.preservedIdentity(
                selectedIdentity: second,
                previousIndex: 1,
                in: presentations
            ),
            second
        )
        XCTAssertEqual(
            PetCarousel.preservedIdentity(
                selectedIdentity: "missing",
                previousIndex: 9,
                in: presentations
            ),
            second
        )
    }

    func testCurrentStatusesAndUnknownValueMapSafely() {
        XCTAssertEqual(PetStateAdapter.status(from: "active"), .running)
        XCTAssertEqual(PetStateAdapter.status(from: "idle"), .idle)
        XCTAssertEqual(PetStateAdapter.status(from: "Needs Input"), .needsInput)
        XCTAssertEqual(PetStateAdapter.status(from: "unexpected-new-state"), .idle)
    }

    func testOverrideAddsPreciseLifecycleWithoutChangingLiveSession() {
        let session = makeSession(id: "s1", status: "idle", task: "local fallback")
        let overrides = [
            session.identity: PetActivityOverride(
                status: .blocked,
                title: "Codex App Server",
                detail: "승인이 거절되었습니다"
            ),
        ]

        let presentation = PetStateAdapter.presentation(for: [session], overrides: overrides)

        XCTAssertEqual(presentation.status, .blocked)
        XCTAssertEqual(presentation.title, "Codex App Server")
        XCTAssertEqual(presentation.detail, "승인이 거절되었습니다")
        XCTAssertEqual(presentation.activeCount, 1)
    }

    func testDisplayTextIsSingleLineAndBounded() {
        let session = makeSession(
            id: "s1",
            status: "active",
            project: String(repeating: "p", count: 100),
            task: String(repeating: "t", count: 140) + "\n원문 두 번째 줄"
        )

        let presentation = PetStateAdapter.presentation(for: [session])

        XCTAssertEqual(presentation.title.count, 80)
        XCTAssertEqual(presentation.detail?.count, 120)
        XCTAssertFalse(presentation.detail?.contains("\n") ?? true)
    }

    func testNoSessionsProducesIdlePet() {
        XCTAssertEqual(PetStateAdapter.presentation(for: []), .idle)
    }

    func testDisabledLocalActivityHidesCachedSessionImmediately() {
        let cached = makeSession(id: "cached", status: "active")

        XCTAssertEqual(
            PetStateAdapter.presentation(
                for: [cached],
                localActivityEnabled: false
            ),
            .idle
        )
    }

    func testStoppedLocalTurnWithResultBecomesReady() {
        let session = LiveSession(
            provider: "claude",
            sessionId: "done",
            projectLabel: "amon-dev",
            gitBranch: nil,
            status: "idle",
            agents: [],
            currentTask: "펫 구현",
            lastResult: "구현을 완료했습니다.",
            model: "claude",
            totalTokens: 42,
            startedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        XCTAssertEqual(
            PetStateAdapter.presentation(for: [session]).status,
            .ready
        )
        XCTAssertEqual(
            PetStateAdapter.presentation(for: [session]).activeCount,
            0
        )
    }

    func testPetStatusesMapToCompatibleAnimationRows() {
        XCTAssertEqual(CodexPetSpriteLayout.animation(for: .idle), .idle)
        XCTAssertEqual(CodexPetSpriteLayout.animation(for: .running), .running)
        XCTAssertEqual(CodexPetSpriteLayout.animation(for: .needsInput), .waiting)
        XCTAssertEqual(CodexPetSpriteLayout.animation(for: .ready), .waving)
        XCTAssertEqual(CodexPetSpriteLayout.animation(for: .blocked), .failed)

        XCTAssertEqual(
            CodexPetSpriteLayout.strips[.waiting],
            .init(row: 6, frameCount: 6)
        )
        XCTAssertEqual(CodexPetSpriteLayout.framePixelWidth, 192)
        XCTAssertEqual(CodexPetSpriteLayout.framePixelHeight, 208)
    }

    func testPetBubbleExpandsRightAtLeftScreenEdge() {
        let result = PetOverlayGeometry.expanded(
            from: CGRect(x: 8, y: 40, width: 148, height: 166),
            expandedSize: CGSize(width: 382, height: 166),
            visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800)
        )

        XCTAssertEqual(result.bubblePlacement, .right)
        XCTAssertEqual(result.frame.minX, 8)
        XCTAssertLessThanOrEqual(result.frame.maxX, 1192)
    }

    func testPetBubbleExpandsLeftAtRightScreenEdgeAndCollapsesToPet() {
        let compact = CGRect(x: 1044, y: 40, width: 148, height: 166)
        let visible = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let result = PetOverlayGeometry.expanded(
            from: compact,
            expandedSize: CGSize(width: 382, height: 166),
            visibleFrame: visible
        )

        XCTAssertEqual(result.bubblePlacement, .left)
        XCTAssertEqual(result.frame.maxX, compact.maxX)
        XCTAssertEqual(
            PetOverlayGeometry.collapsed(
                from: result.frame,
                compactSize: compact.size,
                bubblePlacement: result.bubblePlacement,
                visibleFrame: visible
            ),
            compact
        )
    }

    func testAvatarHitFrameTracksBubblePlacementAndCompactLayout() {
        let expanded = CGSize(width: 382, height: 166)
        let compact = CGSize(width: 148, height: 166)

        XCTAssertEqual(
            PetOverlayGeometry.avatarFrame(
                in: expanded,
                bubblePlacement: .left
            ),
            CGRect(x: 248, y: 8, width: 126, height: 148)
        )
        XCTAssertEqual(
            PetOverlayGeometry.avatarFrame(
                in: expanded,
                bubblePlacement: .right
            ),
            CGRect(x: 14, y: 8, width: 126, height: 148)
        )
        XCTAssertEqual(
            PetOverlayGeometry.avatarFrame(
                in: compact,
                bubblePlacement: .left
            ),
            CGRect(x: 14, y: 8, width: 126, height: 148)
        )
    }

    func testCarouselControlFrameStaysOnBubbleSide() {
        let size = CGSize(width: 382, height: 166)

        XCTAssertEqual(
            PetOverlayGeometry.carouselControlFrame(
                in: size,
                bubblePlacement: .left
            ),
            CGRect(x: 150, y: 116, width: 94, height: 46)
        )
        XCTAssertEqual(
            PetOverlayGeometry.carouselControlFrame(
                in: size,
                bubblePlacement: .right
            ),
            CGRect(x: 284, y: 116, width: 94, height: 46)
        )
    }

    func testEveryCompatibleSpriteFrameStaysInsideSheet() throws {
        let sheet = CGRect(
            x: 0,
            y: 0,
            width: CodexPetSpriteLayout.sheetPixelWidth,
            height: CodexPetSpriteLayout.sheetPixelHeight
        )
        for animation in CodexPetSpriteLayout.Animation.allCases {
            let strip = try XCTUnwrap(CodexPetSpriteLayout.strips[animation])
            for column in 0..<strip.frameCount {
                let frame = try XCTUnwrap(
                    CodexPetSpriteLayout.frameRect(
                        column: column,
                        animation: animation
                    )
                )
                XCTAssertTrue(sheet.contains(frame), "\(animation) \(column)")
            }
            XCTAssertNil(
                CodexPetSpriteLayout.frameRect(
                    column: strip.frameCount,
                    animation: animation
                )
            )
        }
    }

    func testReduceMotionAlwaysUsesFirstCompatibleFrame() {
        for animation in CodexPetSpriteLayout.Animation.allCases {
            XCTAssertEqual(
                CodexPetSpriteLayout.frameIndex(
                    at: 1234.5,
                    animation: animation,
                    reduceMotion: true
                ),
                0
            )
        }
    }

    func testFallbackRunningMotionIsDistinctFromIdle() {
        let idle = AmonPetMotion.sample(
            status: .idle,
            time: 0.1,
            reduceMotion: false
        )
        let running = AmonPetMotion.sample(
            status: .running,
            time: 0.1,
            reduceMotion: false
        )

        XCTAssertNotEqual(idle, running)
        XCTAssertGreaterThan(abs(running.offsetY), abs(idle.offsetY))
        XCTAssertNotEqual(running.rotationDegrees, 0)
        XCTAssertNotEqual(running.statusDotScale, 1)
    }

    func testFallbackMotionStopsForReduceMotion() {
        for status in PetActivityStatus.allCases {
            XCTAssertEqual(
                AmonPetMotion.sample(
                    status: status,
                    time: 42,
                    reduceMotion: true
                ),
                .still
            )
        }
    }

    private func makeSession(
        id: String,
        status: String,
        startedAt: Date = Date(timeIntervalSince1970: 1),
        updatedAt: Date = Date(timeIntervalSince1970: 20),
        project: String = "amon-dev",
        task: String? = "펫 UI 구현",
        output: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        totalTokens: Int? = 42
    ) -> LiveSession {
        LiveSession(
            provider: "codex",
            sessionId: id,
            projectLabel: project,
            gitBranch: nil,
            status: status,
            agents: [],
            currentTask: task,
            lastResult: output,
            model: "gpt-5",
            totalTokens: totalTokens,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            startedAt: startedAt,
            updatedAt: updatedAt
        )
    }
}
