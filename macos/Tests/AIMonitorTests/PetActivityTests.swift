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

    /// 펫 클릭 판정에 쓰는 아바타 영역 — 말풍선 반대쪽 끝에 붙는다.
    func testAvatarFrameTracksBubblePlacement() {
        let expanded = PetOverlayGeometry.panelSize(
            bubble: PetOverlayGeometry.defaultBubbleSize
        )

        XCTAssertEqual(
            PetOverlayGeometry.avatarFrame(in: expanded, bubblePlacement: .left),
            CGRect(x: 242, y: 8, width: 126, height: 148)
        )
        XCTAssertEqual(
            PetOverlayGeometry.avatarFrame(in: expanded, bubblePlacement: .right),
            CGRect(x: 8, y: 8, width: 126, height: 148)
        )
        // 접힌 상태에선 말풍선이 없으니 어느 쪽이든 왼쪽 여백에 붙는다.
        XCTAssertEqual(
            PetOverlayGeometry.avatarFrame(
                in: PetOverlayGeometry.compactSize,
                bubblePlacement: .left
            ),
            CGRect(x: 8, y: 8, width: 126, height: 148)
        )
    }

    func testPanelSizesMatchAvatarAndBubbleLayout() {
        XCTAssertEqual(
            PetOverlayGeometry.panelSize(bubble: PetOverlayGeometry.defaultBubbleSize),
            CGSize(width: 376, height: 166)
        )
        XCTAssertEqual(PetOverlayGeometry.compactSize, CGSize(width: 142, height: 164))
    }

    func testCarouselControlFrameStaysOnBubbleSide() {
        let size = PetOverlayGeometry.panelSize(
            bubble: PetOverlayGeometry.defaultBubbleSize
        )

        XCTAssertEqual(
            PetOverlayGeometry.carouselControlFrame(in: size, bubblePlacement: .left),
            CGRect(x: 144, y: 118, width: 82, height: 34)
        )
        XCTAssertEqual(
            PetOverlayGeometry.carouselControlFrame(in: size, bubblePlacement: .right),
            CGRect(x: 278, y: 118, width: 82, height: 34)
        )
    }

    // MARK: - 말풍선 크기 조절

    func testPanelSizeAndBubbleSizeAreInverses() {
        for bubble in [
            PetOverlayGeometry.minimumBubbleSize,
            CGSize(width: 400, height: 320),
            PetOverlayGeometry.maximumBubbleSize,
        ] {
            let panel = PetOverlayGeometry.panelSize(bubble: bubble)
            XCTAssertEqual(PetOverlayGeometry.bubbleSize(in: panel), bubble)
            XCTAssertTrue(PetOverlayGeometry.hasBubble(in: panel))
        }
        XCTAssertFalse(
            PetOverlayGeometry.hasBubble(in: PetOverlayGeometry.compactSize)
        )
    }

    func testBubbleSizeIsClampedToAllowedRange() {
        XCTAssertEqual(
            PetOverlayGeometry.clampedBubbleSize(CGSize(width: 10, height: 10)),
            PetOverlayGeometry.minimumBubbleSize
        )
        XCTAssertEqual(
            PetOverlayGeometry.clampedBubbleSize(CGSize(width: 9999, height: 9999)),
            PetOverlayGeometry.maximumBubbleSize
        )
    }

    func testBubbleMaximumAlsoFitsTheVisibleScreen() {
        let visible = CGRect(x: 0, y: 0, width: 640, height: 480)
        let bubble = PetOverlayGeometry.bubbleSize(
            PetOverlayGeometry.maximumBubbleSize,
            fitting: visible
        )
        let panel = PetOverlayGeometry.panelSize(bubble: bubble)

        XCTAssertLessThanOrEqual(panel.width, visible.width - 16)
        XCTAssertLessThanOrEqual(panel.height, visible.height - 16)
        XCTAssertGreaterThanOrEqual(bubble.width, PetOverlayGeometry.minimumBubbleSize.width)
        XCTAssertGreaterThanOrEqual(bubble.height, PetOverlayGeometry.minimumBubbleSize.height)
    }

    /// 그립은 말풍선의 아바타 반대쪽 위 모서리에 있다.
    func testResizeGripSitsOnOuterTopCornerOfBubble() {
        let size = PetOverlayGeometry.panelSize(
            bubble: PetOverlayGeometry.defaultBubbleSize
        )
        let length = PetOverlayGeometry.resizeGripLength

        XCTAssertEqual(
            PetOverlayGeometry.resizeGripFrame(in: size, bubblePlacement: .left),
            CGRect(x: 8, y: 158 - length, width: length, height: length)
        )
        XCTAssertEqual(
            PetOverlayGeometry.resizeGripFrame(in: size, bubblePlacement: .right),
            CGRect(x: 368 - length, y: 158 - length, width: length, height: length)
        )
    }

    /// 바깥쪽·위쪽으로 끌면 커지고, 반대로 끌면 최소 크기에서 멈춘다.
    func testDraggingGripOutwardGrowsBubbleForBothPlacements() {
        let start = PetOverlayGeometry.defaultBubbleSize

        XCTAssertEqual(
            PetOverlayGeometry.resizedBubbleSize(
                from: start,
                translation: CGSize(width: -60, height: 40),
                bubblePlacement: .left
            ),
            CGSize(width: start.width + 60, height: start.height + 40)
        )
        XCTAssertEqual(
            PetOverlayGeometry.resizedBubbleSize(
                from: start,
                translation: CGSize(width: 60, height: 40),
                bubblePlacement: .right
            ),
            CGSize(width: start.width + 60, height: start.height + 40)
        )
        XCTAssertEqual(
            PetOverlayGeometry.resizedBubbleSize(
                from: start,
                translation: CGSize(width: 200, height: -200),
                bubblePlacement: .left
            ),
            PetOverlayGeometry.minimumBubbleSize
        )
    }

    // MARK: - 완료 후 말풍선 접기

    /// 완료는 지정한 시간이 지나면 접히고, 그 전까지는 남는다.
    func testReadyBubbleHidesAfterConfiguredDelay() {
        let completedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let presentation = makePresentation(status: .ready, updatedAt: completedAt)

        XCTAssertTrue(
            showsBubble(presentation, now: completedAt.addingTimeInterval(29), delay: 30)
        )
        XCTAssertFalse(
            showsBubble(presentation, now: completedAt.addingTimeInterval(31), delay: 30)
        )
        // 설정을 늘리면 같은 시각에도 계속 보인다.
        XCTAssertTrue(
            showsBubble(presentation, now: completedAt.addingTimeInterval(31), delay: 60)
        )
    }

    /// 0 은 "숨기지 않음" — 아무리 지나도 남는다.
    func testZeroDelayKeepsReadyBubbleOpen() {
        let completedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let presentation = makePresentation(status: .ready, updatedAt: completedAt)

        XCTAssertTrue(
            showsBubble(presentation, now: completedAt.addingTimeInterval(9_999), delay: 0)
        )
        XCTAssertTrue(PetBubbleVisibility.readyAutoHideChoices.contains(0))
    }

    /// 손이 필요한 상태는 시간이 지나도 접지 않는다.
    func testAttentionStatesNeverAutoHide() {
        let long = Date(timeIntervalSinceReferenceDate: 1_000)
        for status in [PetActivityStatus.needsInput, .blocked, .running] {
            XCTAssertTrue(
                showsBubble(
                    makePresentation(status: status, updatedAt: long),
                    now: long.addingTimeInterval(3_600),
                    delay: 30
                ),
                "\(status) 는 자동으로 접히면 안 된다"
            )
        }
    }

    func testIdleHidesAndDisabledDetectionShowsNotice() {
        let now = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertFalse(showsBubble(makePresentation(status: .idle, updatedAt: now), now: now))
        // 표시 토글이 꺼져 있으면 무조건 접는다.
        XCTAssertFalse(
            PetBubbleVisibility.showsBubble(
                presentation: makePresentation(status: .running, updatedAt: now),
                showsCurrentTask: false,
                localActivityEnabled: true,
                now: now
            )
        )
        // 라이브 세션 공유가 꺼져 있으면 안내 문구를 위해 펼친 채로 둔다.
        XCTAssertTrue(
            PetBubbleVisibility.showsBubble(
                presentation: .idle,
                showsCurrentTask: true,
                localActivityEnabled: false,
                now: now
            )
        )
    }

    func testAutoHideLabelsReadNaturally() {
        XCTAssertEqual(PetBubbleVisibility.autoHideLabel(forSeconds: 0), "숨기지 않음")
        XCTAssertEqual(PetBubbleVisibility.autoHideLabel(forSeconds: 30), "30초")
        XCTAssertEqual(PetBubbleVisibility.autoHideLabel(forSeconds: 60), "1분")
        XCTAssertEqual(PetBubbleVisibility.autoHideLabel(forSeconds: 300), "5분")
        XCTAssertEqual(PetBubbleVisibility.autoHideLabel(forSeconds: 90), "1분 30초")
    }

    private func showsBubble(
        _ presentation: PetPresentation,
        now: Date,
        delay: TimeInterval = PetBubbleVisibility.defaultReadyAutoHideDelay
    ) -> Bool {
        PetBubbleVisibility.showsBubble(
            presentation: presentation,
            showsCurrentTask: true,
            localActivityEnabled: true,
            now: now,
            readyAutoHideDelay: delay
        )
    }

    private func makePresentation(
        status: PetActivityStatus,
        updatedAt: Date
    ) -> PetPresentation {
        PetPresentation(
            status: status,
            title: "gbike",
            detail: "테스트 입력",
            output: "테스트 출력",
            provider: "codex",
            sessionID: "s1",
            sessionIdentity: "codex:s1",
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: 42,
            updatedAt: updatedAt,
            activeCount: 1
        )
    }

    // MARK: - 프로바이더 배지

    /// 말풍선은 세션 프로바이더를 공식 로고 + 브랜드색으로 보여준다.
    /// 라이브 세션이 만들어내는 ID 는 셋 다 자산이 있어야 한다.
    @MainActor
    func testLiveSessionProvidersHaveLogoAndBrandColor() {
        for id in ["claude", "codex", "cursor"] {
            XCTAssertTrue(ProviderIcons.has(id: id), "\(id) 로고가 없다")
            XCTAssertNotNil(Palette.providerTint(forID: id), "\(id) 브랜드색이 없다")
        }
    }

    func testProviderTintIsCaseInsensitiveAndNilForUnknownID() {
        XCTAssertEqual(
            Palette.providerHexByID["codex"],
            Palette.hexCodex
        )
        XCTAssertNotNil(Palette.providerTint(forID: "CODEX"))
        XCTAssertNil(Palette.providerTint(forID: "unknown-tool"))
    }

    // MARK: - 작업 중 3점 표시

    /// 점마다 위상이 어긋나 한쪽에서 다른 쪽으로 훑고 지나간다.
    func testWorkingDotsWaveIsStaggeredAndBounded() {
        let samples = stride(from: 0.0, to: PetWorkingDots.period, by: 0.05)

        for time in samples {
            var levels: [Double] = []
            for index in 0..<PetWorkingDots.dotCount {
                let level = PetWorkingDots.intensity(
                    index: index,
                    time: time,
                    reduceMotion: false
                )
                XCTAssertGreaterThanOrEqual(level, 0.3)
                XCTAssertLessThanOrEqual(level, 1.0)
                levels.append(level)
            }
            // 같은 순간에 세 점이 모두 같은 밝기면 웨이브가 아니다.
            XCTAssertGreaterThan(
                (levels.max() ?? 0) - (levels.min() ?? 0),
                0.1,
                "t=\(time) 에서 점들이 함께 움직였다"
            )
        }
    }

    /// 한 주기가 지나면 같은 모양으로 돌아온다.
    func testWorkingDotsWaveRepeatsEveryPeriod() {
        for index in 0..<PetWorkingDots.dotCount {
            XCTAssertEqual(
                PetWorkingDots.intensity(index: index, time: 0.4, reduceMotion: false),
                PetWorkingDots.intensity(
                    index: index,
                    time: 0.4 + PetWorkingDots.period,
                    reduceMotion: false
                ),
                accuracy: 0.0001
            )
        }
    }

    /// 동작 줄이기를 켜면 멈춘 상태로 모두 같은 값을 준다.
    func testWorkingDotsHoldStillWhenReduceMotionIsOn() {
        for index in 0..<PetWorkingDots.dotCount {
            XCTAssertEqual(
                PetWorkingDots.intensity(index: index, time: 3.7, reduceMotion: true),
                1
            )
        }
    }

    /// 바깥 세로 테두리는 가로만, 위 테두리는 세로만, 모서리는 둘 다 조절한다.
    func testResizeHandleZonesCoverOuterAndTopEdges() {
        let size = PetOverlayGeometry.panelSize(
            bubble: PetOverlayGeometry.defaultBubbleSize
        )
        let bubble = PetOverlayGeometry.bubbleFrame(in: size, bubblePlacement: .left)

        XCTAssertEqual(
            PetOverlayGeometry.resizeHandle(
                at: CGPoint(x: bubble.minX + 2, y: bubble.midY),
                in: size,
                bubblePlacement: .left
            ),
            .horizontal
        )
        XCTAssertEqual(
            PetOverlayGeometry.resizeHandle(
                at: CGPoint(x: bubble.midX, y: bubble.maxY - 2),
                in: size,
                bubblePlacement: .left
            ),
            .vertical
        )
        XCTAssertEqual(
            PetOverlayGeometry.resizeHandle(
                at: CGPoint(x: bubble.minX + 2, y: bubble.maxY - 2),
                in: size,
                bubblePlacement: .left
            ),
            .corner
        )
        // 아바타 쪽 안쪽 테두리와 말풍선 가운데는 크기 조절 대상이 아니다.
        XCTAssertNil(
            PetOverlayGeometry.resizeHandle(
                at: CGPoint(x: bubble.maxX - 2, y: bubble.midY),
                in: size,
                bubblePlacement: .left
            )
        )
        XCTAssertNil(
            PetOverlayGeometry.resizeHandle(
                at: CGPoint(x: bubble.midX, y: bubble.midY),
                in: size,
                bubblePlacement: .left
            )
        )
        // 말풍선이 오른쪽이면 바깥 테두리도 오른쪽이다.
        let rightBubble = PetOverlayGeometry.bubbleFrame(in: size, bubblePlacement: .right)
        XCTAssertEqual(
            PetOverlayGeometry.resizeHandle(
                at: CGPoint(x: rightBubble.maxX - 2, y: rightBubble.midY),
                in: size,
                bubblePlacement: .right
            ),
            .horizontal
        )
    }

    /// 테두리별로 지정한 축만 바뀐다.
    func testEdgeHandlesResizeOnlyTheirAxis() {
        let start = PetOverlayGeometry.defaultBubbleSize
        let translation = CGSize(width: -60, height: 40)

        XCTAssertEqual(
            PetOverlayGeometry.resizedBubbleSize(
                from: start,
                translation: translation,
                bubblePlacement: .left,
                handle: .horizontal
            ),
            CGSize(width: start.width + 60, height: start.height)
        )
        XCTAssertEqual(
            PetOverlayGeometry.resizedBubbleSize(
                from: start,
                translation: translation,
                bubblePlacement: .left,
                handle: .vertical
            ),
            CGSize(width: start.width, height: start.height + 40)
        )
    }

    /// 크기를 키워도 펫은 화면에서 움직이지 않아야 한다. 아바타는 패널의 아바타 쪽
    /// 모서리에 고정 여백으로 붙으므로, 그 모서리와 하단이 유지되면 펫도 그대로다.
    func testResizeKeepsPetAnchoredOnScreen() {
        let visible = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let bubble = PetOverlayGeometry.defaultBubbleSize
        let panelSize = PetOverlayGeometry.panelSize(bubble: bubble)
        let bigger = CGSize(width: bubble.width + 120, height: bubble.height + 90)

        for placement in [PetBubblePlacement.left, .right] {
            let frame = CGRect(
                x: 400,
                y: 200,
                width: panelSize.width,
                height: panelSize.height
            )
            let resized = PetOverlayGeometry.resizedPanelFrame(
                from: frame,
                bubble: bigger,
                bubblePlacement: placement,
                visibleFrame: visible
            )

            XCTAssertEqual(
                frame.minY,
                resized.minY,
                accuracy: 0.001,
                "\(placement) 리사이즈 후 펫이 위아래로 움직였다"
            )
            // 말풍선이 왼쪽이면 펫은 오른쪽 끝(maxX), 오른쪽이면 왼쪽 끝(minX)에 붙는다.
            if placement == .left {
                XCTAssertEqual(
                    frame.maxX,
                    resized.maxX,
                    accuracy: 0.001,
                    "말풍선이 왼쪽일 때 펫이 좌우로 움직였다"
                )
            } else {
                XCTAssertEqual(
                    frame.minX,
                    resized.minX,
                    accuracy: 0.001,
                    "말풍선이 오른쪽일 때 펫이 좌우로 움직였다"
                )
            }
            XCTAssertEqual(
                PetOverlayGeometry.bubbleSize(in: resized.size),
                bigger
            )
        }
    }

    func testEveryCompatibleSpriteFrameStaysInsideSheet() throws {
        let sheet = CGRect(
            x: 0,
            y: 0,
            width: CodexPetSpriteLayout.sheetPixelWidth,
            height: CodexPetSpriteLayout.sheetPixelHeight(for: .v1)
        )
        // 둘러보기 두 행은 v2 시트에만 있으므로 v1 검사 대상이 아니다.
        for animation in CodexPetSpriteLayout.animations(in: .v1) {
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
