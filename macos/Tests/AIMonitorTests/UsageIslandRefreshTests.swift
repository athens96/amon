import AppKit
import XCTest

@testable import AIMonitor

final class UsageIslandFittedGeometryTests: XCTestCase {
    func testUnequalContentUsesEqualWingsCenteredAroundTheCamera() {
        let screen = CGRect(x: -1512, y: 200, width: 1512, height: 982)
        let left = CGRect(x: -1512, y: 1144, width: 650, height: 38)
        let right = CGRect(x: -650, y: 1144, width: 650, height: 38)
        let small = UsageIslandGeometry.make(screen: screen, safeTop: 38, left: left, right: right,
            wings: (left: 73.2, right: 165.6))
        let longer = UsageIslandGeometry.make(screen: screen, safeTop: 38, left: left, right: right,
            wings: (left: 241.2, right: 165.6))
        for geometry in [small, longer] {
            XCTAssertEqual(geometry.leftWing, geometry.rightWing)
            XCTAssertEqual(geometry.frame.minX + geometry.leftWing, left.maxX)
            XCTAssertEqual(geometry.frame.maxX - geometry.rightWing, right.minX)
            XCTAssertEqual(geometry.frame.maxY, screen.maxY)
            XCTAssertTrue(screen.contains(geometry.frame))
        }
        XCTAssertLessThan(longer.frame.minX, small.frame.minX)
        XCTAssertGreaterThan(longer.frame.maxX, small.frame.maxX)
        XCTAssertEqual(longer.frame.midX, small.frame.midX,
                       "A longer meter expands both wings without shifting the island off-center")
        XCTAssertGreaterThanOrEqual(small.leftWing, 165.6)
        XCTAssertGreaterThanOrEqual(longer.rightWing, 241.2)
    }

    func testEqualWingsFitTheSmallerPhysicalRegionOfAnAsymmetricDisplay() {
        let screen = CGRect(x: -800, y: -50, width: 800, height: 600)
        let left = CGRect(x: -800, y: 518, width: 40, height: 32)
        let right = CGRect(x: -560, y: 518, width: 560, height: 32)
        let geometry = UsageIslandGeometry.make(screen: screen, safeTop: 32, left: left, right: right,
            wings: (left: 500, right: 500))
        XCTAssertTrue(screen.contains(geometry.frame))
        XCTAssertLessThanOrEqual(geometry.leftWing, left.width)
        XCTAssertEqual(geometry.rightWing, geometry.leftWing,
                       "The smaller physical region limits both wings so the island remains centered")
        XCTAssertEqual(geometry.frame.minX + geometry.leftWing, left.maxX)
        XCTAssertEqual(geometry.frame.maxX - geometry.rightWing, right.minX)
    }

    func testFittedWidthsRemainFiniteForNarrowDisplaysAndInvalidMeasurements() {
        for width in [8, 64, 200, 1512] {
            let screen = CGRect(x: 1400, y: -20, width: width, height: 20)
            for wings in [(CGFloat.nan, CGFloat.infinity), (CGFloat(-20), CGFloat(100_000))] {
                let geometry = UsageIslandGeometry.make(screen: screen, safeTop: 38, left: nil, right: nil,
                    wings: (left: wings.0, right: wings.1))
                XCTAssertTrue(geometry.frame.minX.isFinite)
                XCTAssertTrue(geometry.frame.maxX.isFinite)
                XCTAssertGreaterThanOrEqual(geometry.leftWing, 0)
                XCTAssertGreaterThanOrEqual(geometry.rightWing, 0)
                XCTAssertGreaterThanOrEqual(geometry.frame.minX, screen.minX)
                XCTAssertLessThanOrEqual(geometry.frame.maxX, screen.maxX)
                XCTAssertLessThanOrEqual(geometry.frame.height, screen.height)
            }
        }
    }

    func testPreferredDisplayFollowsMainBeforeFallingBackToANotch() {
        let notch = UsageIslandScreen(frame: CGRect(x: -1512, y: 0, width: 1512, height: 982), safeTop: 38)
        let external = UsageIslandScreen(frame: CGRect(x: 0, y: -400, width: 1920, height: 1080), safeTop: 0)
        XCTAssertEqual(UsageIslandScreen.preferred(in: [notch, external], mainFrame: external.frame), external)
        XCTAssertEqual(UsageIslandScreen.preferred(in: [external, notch], mainFrame: nil), notch)
        XCTAssertEqual(UsageIslandScreen.preferred(in: [external], mainFrame: notch.frame), external)
        XCTAssertNil(UsageIslandScreen.preferred(in: [], mainFrame: external.frame))
    }
}

@MainActor
final class UsageIslandPresentationTests: XCTestCase {
    private func item(_ id: String, lines: [String], detail: String? = nil) -> UsageIslandItem {
        UsageIslandItem(providerID: id, name: id, lines: lines, detail: detail ?? id)
    }

    func testContentMeasuresEachMeterBeforeUsingTheirMaximumForBothWings() {
        let view = UsageIslandView()
        view.summary = UsageIslandSummary(items: [item("claude", lines: ["8%"]),
            item("codex", lines: ["42%"])], mode: "사용")
        let short = view.fittedWings()
        view.summary = UsageIslandSummary(items: [item("claude", lines: ["$12,345.67"]),
            item("codex", lines: ["42%"])], mode: "사용")
        let long = view.fittedWings()
        XCTAssertGreaterThan(long.left, short.left)
        XCTAssertEqual(long.right, short.right)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let shortGeometry = UsageIslandGeometry.make(screen: screen, safeTop: 0, left: nil, right: nil, wings: short)
        let longGeometry = UsageIslandGeometry.make(screen: screen, safeTop: 0, left: nil, right: nil, wings: long)
        XCTAssertEqual(longGeometry.leftWing, longGeometry.rightWing)
        XCTAssertGreaterThan(longGeometry.leftWing, shortGeometry.leftWing)
        XCTAssertEqual(longGeometry.frame.midX, screen.midX)
        let twoLines = ["8%", "123456"]
        let singleWidth = UsageIslandView.contentWidth(lines: [twoLines[1]], hasIcon: true, size: 10)
        XCTAssertEqual(UsageIslandView.contentWidth(lines: twoLines, hasIcon: true, size: 10), singleWidth)
        XCTAssertGreaterThan(singleWidth,
            UsageIslandView.contentWidth(lines: [twoLines[1]], hasIcon: false, size: 10))
    }

    func testOverflowBadgeIsMeasuredButHiddenThirdLinesAreNot() {
        let view = UsageIslandView()
        let first = item("claude", lines: ["10%", "20%"])
        let second = item("codex", lines: ["10%"])
        view.summary = UsageIslandSummary(items: [first, second], mode: "사용")
        let twoProviders = view.fittedWings()
        view.summary = UsageIslandSummary(items: [first, second, item("cursor", lines: ["1%"])], mode: "사용")
        let overflow = view.fittedWings()
        XCTAssertEqual(overflow.left, twoProviders.left)
        XCTAssertGreaterThan(overflow.right, twoProviders.right)
        view.summary = UsageIslandSummary(items: [item("claude",
            lines: first.lines + [String(repeating: "unrendered", count: 50)]), second,
            item("cursor", lines: ["1%"])], mode: "사용")
        XCTAssertEqual(view.fittedWings().left, overflow.left)
        XCTAssertEqual(view.fittedWings().right, overflow.right)
    }

    func testSingleProviderDoesNotPutModeWordsInTheUnusedWing() {
        let view = UsageIslandView()
        let unusedWidth = UsageIslandView.contentWidth(lines: [""], hasIcon: false, size: 11)
        for mode in ["사용", "남음"] {
            view.summary = UsageIslandSummary(items: [item("claude", lines: ["42%"], detail: "Session 42% \(mode)")], mode: mode)
            XCTAssertEqual(view.fittedWings().right, unusedWidth)
            XCTAssertTrue(view.summary.tooltip.contains("Session 42% \(mode)"))
        }
    }

    func testFlatTopOutlineHasOneContourAndProportionalLowerCorners() {
        for height in [CGFloat(20), 32, 38, 76] {
            let rect = CGRect(x: 30, y: 40, width: height * 8, height: height)
            let shape = UsageIslandView.shape(in: rect)
            XCTAssertTrue(shape.contains(CGPoint(x: rect.minX + height * 0.02, y: rect.maxY - height * 0.02)))
            XCTAssertFalse(shape.contains(CGPoint(x: rect.minX + height * 0.02, y: rect.minY + height * 0.02)))
            XCTAssertTrue(shape.contains(CGPoint(x: rect.minX + height * 0.5, y: rect.minY + height * 0.02)))
            let elements = (0..<shape.elementCount).map { shape.element(at: $0) }
            // AppKit appends an empty moveTo after closePath. Count subpaths
            // containing drawable segments, so overlapping stroked shapes still fail.
            var drawnContours = 0
            var hasSegments = false
            for element in elements {
                switch element {
                case .moveTo, .closePath: hasSegments = false
                default:
                    if !hasSegments { drawnContours += 1; hasSegments = true }
                }
            }
            XCTAssertEqual(drawnContours, 1)
            XCTAssertEqual(elements.filter { $0 == .closePath }.count, 1,
                           "The glow outline must not contain an internal edge from overlapping shapes")
        }
    }

    func testPressExpansionKeepsTheScreenEdgeAndTopCenterFixed() {
        let rect = CGRect(x: 29, y: 17, width: 527, height: 38)
        let transform = UsageIslandView.visualTransform(islandRect: rect, scale: UsageIslandView.pressedScale)
        let anchor = CGPoint(x: rect.midX, y: rect.maxY)
        let transformed = transform.transform(anchor)
        XCTAssertEqual(transformed.x, anchor.x, accuracy: 0.001)
        XCTAssertEqual(transformed.y, anchor.y, accuracy: 0.001)
        let enlarged = UsageIslandView.visualRect(islandRect: rect, scale: UsageIslandView.pressedScale)
        XCTAssertEqual(enlarged.maxY, rect.maxY, accuracy: 0.001)
        XCTAssertEqual(enlarged.midX, rect.midX, accuracy: 0.001)
        XCTAssertLessThan(enlarged.minY, rect.minY)
        XCTAssertLessThan(enlarged.minX, rect.minX)
        XCTAssertGreaterThan(enlarged.maxX, rect.maxX)
    }

    func testPressedHitRegionTracksTheOutlineWhilePopupAnchorStaysStable() {
        let geometry = UsageIslandGeometry.make(screen: CGRect(x: 0, y: 0, width: 1440, height: 900),
            safeTop: 0, left: nil, right: nil)
        let view = UsageIslandView(frame: CGRect(origin: .zero, size: geometry.panelFrame.size))
        view.geometry = geometry
        view.reduceMotion = false
        let anchor = view.popoverAnchorRect
        let expandingEdge = CGPoint(x: anchor.minX - 1, y: anchor.maxY - 1)
        XCTAssertNil(view.hitTest(expandingEdge))
        view.setScaleForPreview(UsageIslandView.pressedScale)
        XCTAssertTrue(view.hitTest(expandingEdge) === view)
        XCTAssertEqual(view.popoverAnchorRect, anchor,
                       "Opening a popup must not anchor it to a transient press animation")
        XCTAssertNil(view.hitTest(CGPoint(x: 1, y: anchor.midY)),
                     "Transparent panel padding used by neon must never intercept clicks")
        view.resetInteraction()
        XCTAssertNil(view.hitTest(expandingEdge))
    }

    func testPanelPaddingContainsPressedContentEvenForVeryWideMeters() {
        var margins: [CGFloat] = []
        for wings in [(CGFloat(70), CGFloat(100)), (CGFloat(700), CGFloat(1000))] {
            let geometry = UsageIslandGeometry.make(screen: CGRect(x: -3840, y: -200, width: 3840, height: 2160),
                safeTop: 0, left: nil, right: nil, wings: (left: wings.0, right: wings.1))
            let bounds = CGRect(origin: .zero, size: geometry.panelFrame.size)
            let enlarged = UsageIslandView.visualRect(islandRect: geometry.islandRect,
                scale: UsageIslandView.pressedScale)
            XCTAssertTrue(bounds.contains(enlarged), "Pressed content must not be clipped by the NSPanel")
            let remainingMargin = [enlarged.minX, bounds.maxX - enlarged.maxX,
                                   enlarged.minY, bounds.maxY - enlarged.maxY].min() ?? 0
            XCTAssertGreaterThanOrEqual(remainingMargin, UsageIslandView.neonBlurRadius,
                "Neon's 14pt blur must have space beyond the enlarged outline")
            margins.append(geometry.islandRect.minX)
            XCTAssertEqual(geometry.islandRect.offsetBy(dx: geometry.panelFrame.minX, dy: geometry.panelFrame.minY),
                           geometry.frame)
        }
        XCTAssertGreaterThan(margins[1], margins[0],
                             "A fixed outset cannot contain the larger press expansion of wider content")
    }

    func testAnimationProgressStaysBoundedAndFinishesWithoutOvershoot() {
        let duration = UsageIslandView.animationDuration
        for (start, target) in [(CGFloat(1), UsageIslandView.pressedScale), (UsageIslandView.pressedScale, CGFloat(1))] {
            let values = [0, duration / 4, duration / 2, duration, duration * 2].map {
                UsageIslandView.animationScale(from: start, to: target, elapsed: $0)
            }
            XCTAssertEqual(values.first, start)
            XCTAssertEqual(values.last, target)
            for value in values {
                XCTAssertGreaterThanOrEqual(value, min(start, target))
                XCTAssertLessThanOrEqual(value, max(start, target))
            }
            for (before, after) in zip(values, values.dropFirst()) {
                if start < target { XCTAssertLessThanOrEqual(before, after) }
                else { XCTAssertGreaterThanOrEqual(before, after) }
            }
        }
    }
}

@MainActor
final class UsageIslandInteractionRefreshTests: XCTestCase {
    private let screen = UsageIslandScreen(frame: CGRect(x: 20_000, y: 20_000, width: 1440, height: 900), safeTop: 0)

    private func summary(line: String = "42%", detail: String = "session") -> UsageIslandSummary {
        UsageIslandSummary(items: [
            UsageIslandItem(providerID: "claude", name: "Claude", lines: [line], detail: detail),
            UsageIslandItem(providerID: "codex", name: "Codex", lines: ["18%"], detail: "week"),
        ], mode: "사용")
    }

    private func makeController() -> UsageIslandController {
        _ = NSApplication.shared
        let target = screen
        return UsageIslandController(onOpen: { _ in }, onClose: {}, makeMenu: { NSMenu() },
                                     screenProvider: { target })
    }

    private func pressEvent(in view: UsageIslandView) throws -> NSEvent {
        let rect = view.popoverAnchorRect
        return try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
            location: view.convert(CGPoint(x: rect.midX, y: rect.midY), to: nil), modifierFlags: [],
            timestamp: 1, windowNumber: view.window?.windowNumber ?? 0, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 1))
    }

    func testMetadataRefreshPreservesOpenPopupUntilTheVisibleGeometryChanges() {
        let controller = makeController()
        defer { controller.stop() }
        var shown = false
        var geometryChanges = 0
        controller.onGeometryChange = { shown = false; geometryChanges += 1 }
        controller.update(summary: summary(), enabled: true)
        let original = controller.view.geometry
        let initialChanges = geometryChanges
        shown = true
        controller.update(summary: summary(detail: "new reset time, identical visible text"), enabled: true)
        XCTAssertEqual(controller.view.geometry, original)
        XCTAssertEqual(geometryChanges, initialChanges)
        XCTAssertTrue(shown, "Polling metadata must not dismiss a popup whose anchor has not moved")
        XCTAssertTrue(controller.view.summary.tooltip.contains("new reset time"))

        controller.update(summary: summary(line: "$123,456,789.00"), enabled: true)
        XCTAssertNotEqual(controller.view.geometry, original)
        XCTAssertEqual(geometryChanges, initialChanges + 1)
        XCTAssertFalse(shown, "A changed content width needs a new popup anchor")
        let resized = controller.view.geometry
        controller.update(summary: summary(line: "$123,456,789.00"), enabled: true)
        XCTAssertEqual(controller.view.geometry, resized)
        XCTAssertEqual(geometryChanges, initialChanges + 1)
    }

    func testWatcherFollowsAChangedScreenWithoutAnySummaryUpdate() {
        _ = NSApplication.shared
        var active = screen
        let controller = UsageIslandController(onOpen: { _ in }, onClose: {}, makeMenu: { NSMenu() },
                                              screenProvider: { active })
        defer { controller.stop() }
        controller.update(summary: summary(), enabled: true)
        let before = controller.view.geometry
        let originalSummary = controller.view.summary
        var geometryChanges = 0
        controller.onGeometryChange = { geometryChanges += 1 }
        active = UsageIslandScreen(frame: screen.frame.offsetBy(dx: -2500, dy: 300), safeTop: 0)
        controller.checkScreen()
        XCTAssertEqual(controller.view.geometry.frame.minX, before.frame.minX - 2500)
        XCTAssertEqual(controller.view.geometry.frame.maxY, before.frame.maxY + 300)
        XCTAssertEqual(controller.view.geometry.frame.size, before.frame.size)
        XCTAssertEqual(controller.view.summary, originalSummary)
        XCTAssertEqual(geometryChanges, 1)
        XCTAssertTrue(controller.isWatchingScreen)
    }

    func testWatcherKeepsThePopupAnchorStableUntilItsPopupCloses() {
        _ = NSApplication.shared
        var active = screen
        var shown = true
        let controller = UsageIslandController(onOpen: { _ in }, onClose: {}, makeMenu: { NSMenu() },
            isOpen: { shown }, screenProvider: { active })
        defer { controller.stop() }
        controller.update(summary: summary(), enabled: true)
        let original = controller.view.geometry
        var changes = 0
        controller.onGeometryChange = { changes += 1 }
        controller.checkScreen()
        controller.checkScreen()
        XCTAssertEqual(changes, 0)
        XCTAssertTrue(shown)
        active = UsageIslandScreen(frame: screen.frame.offsetBy(dx: -2500, dy: 300), safeTop: 0)
        controller.checkScreen()
        XCTAssertEqual(controller.view.geometry, original,
                       "A key popup must not cause its own anchor to move under the pointer")
        XCTAssertEqual(changes, 0)
        shown = false
        controller.checkScreen()
        XCTAssertEqual(controller.view.geometry.frame.minX, original.frame.minX - 2500)
        XCTAssertEqual(changes, 1)
        controller.checkScreen()
        XCTAssertEqual(changes, 1, "Repeated checks on the same display must not dismiss a newly opened popup")
    }

    func testWatcherAndDelayedChecksCannotResurrectDisabledSleepingOrStoppedPanels() {
        for transition in ["disable", "sleep", "stop"] {
            _ = NSApplication.shared
            var reads = 0
            let target = screen
            let controller = UsageIslandController(onOpen: { _ in }, onClose: {}, makeMenu: { NSMenu() },
                screenProvider: { reads += 1; return target })
            defer { controller.stop() }
            controller.update(summary: summary(), enabled: true)
            XCTAssertTrue(controller.isWatchingScreen)
            controller.scheduleScreenCheck()
            XCTAssertTrue(controller.hasPendingScreenCheck)
            switch transition {
            case "disable": controller.update(summary: summary(), enabled: false)
            case "sleep": controller.setSleeping(true)
            default: controller.stop()
            }
            let readsWhenHidden = reads
            XCTAssertFalse(controller.isWatchingScreen, transition)
            XCTAssertFalse(controller.hasPendingScreenCheck, transition)
            controller.checkScreen()
            controller.scheduleScreenCheck()
            XCTAssertEqual(reads, readsWhenHidden,
                           "\(transition) must stop both screen queries and panel resurrection")
            XCTAssertNil(controller.anchor, transition)
            XCTAssertFalse(controller.isWatchingScreen, transition)
            XCTAssertFalse(controller.hasPendingScreenCheck, transition)
            if transition == "stop" {
                controller.setSleeping(false)
                controller.update(summary: summary(detail: "late callback"), enabled: true)
                XCTAssertNil(controller.anchor)
                XCTAssertFalse(controller.isWatchingScreen)
            }
        }
    }

    func testWakeResumesOnlyAnEnabledPanelAndStartsAFreshWatcher() {
        let controller = makeController()
        defer { controller.stop() }
        controller.update(summary: summary(), enabled: true)
        controller.scheduleScreenCheck()
        controller.setSleeping(true)
        XCTAssertFalse(controller.isWatchingScreen)
        XCTAssertFalse(controller.hasPendingScreenCheck)
        controller.setSleeping(false)
        XCTAssertNotNil(controller.anchor)
        XCTAssertTrue(controller.isWatchingScreen)
        XCTAssertFalse(controller.hasPendingScreenCheck)

        controller.setSleeping(true)
        controller.update(summary: summary(), enabled: false)
        controller.setSleeping(false)
        controller.checkScreen()
        XCTAssertNil(controller.anchor, "Waking cannot undo an explicit user disable during sleep")
        XCTAssertFalse(controller.isWatchingScreen)
        controller.update(summary: summary(), enabled: true)
        XCTAssertTrue(controller.isWatchingScreen)
        XCTAssertNotNil(controller.anchor)
    }

    func testDelayedExternalClickCheckUsesTheUpdatedFocusAndClearsPendingWork() async {
        _ = NSApplication.shared
        var active = screen
        let controller = UsageIslandController(onOpen: { _ in }, onClose: {}, makeMenu: { NSMenu() },
                                              screenProvider: { active })
        defer { controller.stop() }
        controller.update(summary: summary(), enabled: true)
        let original = controller.view.geometry.frame
        let moved = expectation(description: "The delayed click check observes the new main screen")
        controller.onGeometryChange = { moved.fulfill() }
        controller.scheduleScreenCheck()
        XCTAssertTrue(controller.hasPendingScreenCheck)
        active = UsageIslandScreen(frame: screen.frame.offsetBy(dx: -2500, dy: 300), safeTop: 0)
        // Below the regular 1-second watcher interval: only the click path can
        // satisfy this callback. No actual app focus, logs, or user screen changes.
        await fulfillment(of: [moved], timeout: 0.75)
        XCTAssertEqual(controller.view.geometry.frame.minX, original.minX - 2500)
        XCTAssertEqual(controller.view.geometry.frame.maxY, original.maxY + 300)
        XCTAssertFalse(controller.hasPendingScreenCheck)
        XCTAssertTrue(controller.isWatchingScreen)
        controller.onGeometryChange = nil
    }

    func testReducedMotionInterruptsThePressWithoutRemovingHoverFeedback() throws {
        let controller = makeController()
        defer { controller.stop() }
        controller.update(summary: summary(), enabled: true)
        let view = controller.view
        view.reduceMotion = false
        view.hovered = true
        view.setScaleForPreview(1.03)
        view.mouseDown(with: try pressEvent(in: view))
        XCTAssertTrue(view.isAnimatingScale)
        view.reduceMotion = true
        XCTAssertFalse(view.isAnimatingScale)
        XCTAssertEqual(view.scale, 1)
        XCTAssertTrue(view.hovered, "Reduced Motion preserves nonmoving hover feedback")
        view.mouseDown(with: try pressEvent(in: view))
        XCTAssertFalse(view.isAnimatingScale)
        XCTAssertEqual(view.scale, 1)
    }

    func testPointerExitCancelsAMidPressAnimationFromEitherEventPath() throws {
        for useMouseExit in [false, true] {
            let controller = makeController()
            defer { controller.stop() }
            controller.update(summary: summary(), enabled: true)
            let view = controller.view
            view.reduceMotion = false
            view.hovered = true
            view.setScaleForPreview(1.03)
            view.mouseDown(with: try pressEvent(in: view))
            XCTAssertTrue(view.isAnimatingScale)
            if useMouseExit {
                let event = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
                    modifierFlags: [], timestamp: 2, windowNumber: view.window?.windowNumber ?? 0,
                    context: nil, eventNumber: 2, trackingNumber: 1, userData: nil))
                view.mouseExited(with: event)
            } else {
                view.hovered = false // Controller's global mouse/passthrough path.
            }
            XCTAssertFalse(view.hovered)
            XCTAssertFalse(view.isAnimatingScale, "Pointer exit must not leave a timer running off-island")
            XCTAssertEqual(view.scale, 1)
        }
    }

    func testDisablingAndStoppingClearInFlightInteractionState() throws {
        for stop in [false, true] {
            let controller = makeController()
            defer { controller.stop() }
            controller.update(summary: summary(), enabled: true)
            let view = controller.view
            view.reduceMotion = false
            view.hovered = true
            view.setScaleForPreview(1.03)
            view.mouseDown(with: try pressEvent(in: view))
            XCTAssertTrue(view.isAnimatingScale)
            if stop { controller.stop() }
            else { controller.update(summary: summary(), enabled: false) }
            XCTAssertFalse(view.isAnimatingScale)
            XCTAssertEqual(view.scale, 1)
            XCTAssertFalse(view.hovered)
            XCTAssertNil(controller.anchor)
        }
    }

    func testResetCancelsCapturedIntentBeforeTheNextClick() throws {
        let controller = makeController()
        defer { controller.stop() }
        controller.update(summary: summary(), enabled: true)
        let view = controller.view
        view.reduceMotion = true
        var shown = true
        var requested: [Bool] = []
        view.isOpen = { shown }
        view.onSetOpen = { value, _ in requested.append(value) }
        view.prepareMousePress()
        view.resetInteraction()
        shown = false
        view.mouseDown(with: try pressEvent(in: view))
        let down = try pressEvent(in: view)
        let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: down.locationInWindow,
            modifierFlags: [], timestamp: 2, windowNumber: view.window?.windowNumber ?? 0,
            context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
        view.mouseUp(with: up)
        XCTAssertEqual(requested, [true])
    }

    func testCanceledPressCannotReopenThePopupOnItsLateMouseUp() throws {
        for cancellation in ["reset", "disable", "reflow"] {
            let controller = makeController()
            defer { controller.stop() }
            controller.update(summary: summary(), enabled: true)
            let view = controller.view
            view.reduceMotion = true
            var requested: [Bool] = []
            view.isOpen = { false }
            view.onSetOpen = { value, _ in requested.append(value) }
            let down = try pressEvent(in: view)
            view.mouseDown(with: down)
            switch cancellation {
            case "disable": controller.update(summary: summary(), enabled: false)
            case "reflow": controller.update(summary: summary(line: "$123,456,789.00"), enabled: true)
            default: view.resetInteraction()
            }
            // Release inside the new visible shape so hit testing cannot conceal
            // the stale-intent regression after the width changes.
            let anchor = view.popoverAnchorRect
            let inside = view.convert(CGPoint(x: anchor.midX, y: anchor.midY), to: nil)
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: inside,
                modifierFlags: [], timestamp: 2, windowNumber: view.window?.windowNumber ?? 0,
                context: nil, eventNumber: 2, clickCount: 1, pressure: 0))
            view.mouseUp(with: up)
            XCTAssertTrue(requested.isEmpty,
                          "A \(cancellation) canceled the press; its release cannot reopen the popup")
        }
    }
}
