import AppKit
import CoreText
import XCTest
@testable import AIMonitor

final class UsageIslandGeometryTests: XCTestCase {
    func testNotchUsesAuxiliaryAreasOnDisplayWithNegativeOrigin() {
        let screen = CGRect(x: -1512, y: 200, width: 1512, height: 982)
        let left = CGRect(x: -1512, y: 1150, width: 650, height: 32)
        let right = CGRect(x: -650, y: 1150, width: 650, height: 32)
        let layout = UsageIslandGeometry.make(screen: screen, safeTop: 32, left: left, right: right)
        XCTAssertEqual(layout.gap, 212)
        XCTAssertEqual(layout.frame.midX, -756)
        XCTAssertEqual(layout.frame.maxY, screen.maxY)
        XCTAssertEqual(layout.frame.minX + layout.wingWidth, left.maxX)
        XCTAssertEqual(layout.frame.maxX - layout.wingWidth, right.minX)
    }

    func testNonNotchPillIsCenteredWithSeparationBetweenProviderIcons() {
        let screen = CGRect(x: 1920, y: -400, width: 1920, height: 1080)
        let layout = UsageIslandGeometry.make(screen: screen, safeTop: 0, left: nil, right: nil)
        XCTAssertEqual(layout.gap, 28)
        XCTAssertEqual(layout.frame.midX, screen.midX)
        XCTAssertEqual(layout.frame.maxY, screen.maxY)
        XCTAssertEqual(layout.frame.height, 32)
        XCTAssertLessThan(layout.frame.width, screen.width)
    }

    func testMissingAuxiliaryAreasStillReserveCameraSpace() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let layout = UsageIslandGeometry.make(screen: screen, safeTop: 38, left: nil, right: nil)
        XCTAssertEqual(layout.frame.height, 38)
        XCTAssertGreaterThan(layout.gap, 0)
        XCTAssertEqual(layout.frame.midX, screen.midX)
    }

    func testEmptyOverlappingAndStaleAuxiliaryAreasUseCenteredFallback() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let invalid: [(CGRect, CGRect)] = [
            (.zero, .zero),
            (CGRect(x: 0, y: 950, width: 900, height: 32), CGRect(x: 700, y: 950, width: 812, height: 32)),
            (CGRect(x: -1512, y: 950, width: 650, height: 32), CGRect(x: -650, y: 950, width: 650, height: 32))
        ]
        for (left, right) in invalid {
            let layout = UsageIslandGeometry.make(screen: screen, safeTop: 32, left: left, right: right)
            XCTAssertEqual(layout.frame.midX, screen.midX)
            XCTAssertGreaterThan(layout.gap, 0)
            XCTAssertTrue(screen.contains(layout.frame))
        }
    }

    func testAsymmetricNotchKeepsBothWingsInsideItsDisplay() {
        let screen = CGRect(x: -800, y: 50, width: 800, height: 600)
        let left = CGRect(x: -800, y: 618, width: 40, height: 32)
        let right = CGRect(x: -560, y: 618, width: 560, height: 32)
        let layout = UsageIslandGeometry.make(screen: screen, safeTop: 32, left: left, right: right)
        XCTAssertEqual(layout.gap, 200)
        XCTAssertEqual(layout.frame.minX + layout.wingWidth, left.maxX)
        XCTAssertEqual(layout.frame.maxX - layout.wingWidth, right.minX)
        XCTAssertTrue(screen.contains(layout.frame))
        XCTAssertLessThanOrEqual(layout.wingWidth, left.width)
    }

    func testNarrowAndShortDisplaysNeverProduceNegativeOrOffscreenGeometry() {
        for width in [8, 64, 200, 320] {
            for safeTop in [CGFloat(0), CGFloat(38)] {
                let screen = CGRect(x: 1400, y: -20, width: width, height: 20)
                let layout = UsageIslandGeometry.make(screen: screen, safeTop: safeTop, left: nil, right: nil)
                XCTAssertGreaterThanOrEqual(layout.frame.width, 0)
                XCTAssertGreaterThanOrEqual(layout.wingWidth, 0)
                XCTAssertGreaterThanOrEqual(layout.gap, 0)
                XCTAssertGreaterThanOrEqual(layout.frame.minX, screen.minX)
                XCTAssertLessThanOrEqual(layout.frame.maxX, screen.maxX)
                XCTAssertEqual(layout.frame.maxY, screen.maxY)
                XCTAssertLessThanOrEqual(layout.frame.height, screen.height)
            }
        }
    }

    func testInvalidScreenGeometryHasAnEmptySafeLayout() {
        for screen in [CGRect.zero, CGRect(x: CGFloat.infinity, y: 0, width: 800, height: 600),
                       CGRect(x: 0, y: 0, width: CGFloat.nan, height: 600)] {
            let layout = UsageIslandGeometry.make(screen: screen, safeTop: 38, left: nil, right: nil)
            XCTAssertEqual(layout.frame, CGRect.zero)
            XCTAssertEqual(layout.wingWidth, 0)
        }
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let layout = UsageIslandGeometry.make(screen: screen, safeTop: .nan, left: nil, right: nil)
        XCTAssertEqual(layout.frame.height, 32)
        XCTAssertEqual(layout.gap, 28)
    }

    func testAuxiliaryAreasAwayFromTheTopUseTheCameraFallback() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let layout = UsageIslandGeometry.make(screen: screen, safeTop: 32,
            left: CGRect(x: 0, y: 200, width: 100, height: 32),
            right: CGRect(x: 500, y: 200, width: 300, height: 32))
        XCTAssertEqual(layout.gap, 200)
        XCTAssertEqual(layout.frame.midX, screen.midX)
    }

    func testSummaryLimitsVisibleProvidersButKeepsAllMetersInTooltip() {
        let items = (1...4).map { UsageIslandItem(providerID: "\($0)", name: "Provider \($0)",
                                                lines: ["10%", "20%"], detail: "Provider \($0) · Session 10% 남음 · Week 20% 남음") }
        let summary = UsageIslandSummary(items: items, mode: "남음")
        XCTAssertEqual(summary.visible, Array(items.prefix(2)))
        XCTAssertEqual(summary.overflow, 2)
        XCTAssertTrue(summary.tooltip.contains("Provider 4"))
        XCTAssertTrue(summary.tooltip.contains("Week 20% 남음"))
        XCTAssertEqual(UsageIslandSummary(items: [], mode: "사용").overflow, 0)
        XCTAssertTrue(UsageIslandSummary(items: [], mode: "사용").tooltip.contains("기다리는 중"))
    }
}

final class UsageIslandRecencyAndColorTests: XCTestCase {
    private func item(_ id: String, lastUsed: TimeInterval?) -> UsageIslandItem {
        UsageIslandItem(providerID: id, name: id, lines: ["1%"], detail: id,
                        lastUsedAt: lastUsed.map { Date(timeIntervalSince1970: $0) })
    }

    func testVisibleShowsTwoMostRecentlyUsedProviders() {
        let items = [item("claude", lastUsed: 100), item("codex", lastUsed: 300),
                     item("cursor", lastUsed: 200), item("grok", lastUsed: nil)]
        let summary = UsageIslandSummary(items: items, mode: "사용")
        XCTAssertEqual(summary.visible.map(\.providerID), ["codex", "cursor"])
        XCTAssertEqual(summary.overflow, 2, "툴팁 overflow 는 전체 개수 기준이다")
    }

    func testProvidersWithoutUsageKeepOriginalOrderAtTheEnd() {
        let items = [item("a", lastUsed: nil), item("b", lastUsed: nil), item("c", lastUsed: 5)]
        XCTAssertEqual(UsageIslandSummary.recentFirst(items).map(\.providerID), ["c", "a", "b"])
        XCTAssertEqual(UsageIslandSummary(items: items, mode: "사용").visible.map(\.providerID), ["c", "a"])
    }

    func testEqualUsageDatesHaveAStableProviderOrder() {
        let items = [item("cursor", lastUsed: 100), item("codex", lastUsed: 100),
                     item("claude", lastUsed: 100)]
        XCTAssertEqual(UsageIslandSummary.recentFirst(items), items)
    }

    func testDarkAccentFallsBackToWhiteOnBlackIsland() {
        XCTAssertEqual(UsageIslandSummary.iconColorHex(for: Palette.hexGrok), "#ffffff")
        XCTAssertEqual(UsageIslandSummary.iconColorHex(for: "#000000"), "#ffffff")
        XCTAssertEqual(UsageIslandSummary.iconColorHex(for: Palette.hexClaude), Palette.hexClaude)
        XCTAssertEqual(UsageIslandSummary.iconColorHex(for: Palette.hexCodex), Palette.hexCodex)
        XCTAssertEqual(UsageIslandSummary.iconColorHex(for: "not-a-color"), "#ffffff")
    }
}

@MainActor
final class UsageIslandFontTests: XCTestCase {
    func testEveryPackagedWeightResolvesToItsExpectedFontAndIncludesTheLicense() throws {
        for weight in ["Light", "Regular", "Medium", "SemiBold", "Bold"] {
            let url = try XCTUnwrap(AIMonitorResources.url(forResource: "Poppins-\(weight)", withExtension: "ttf"),
                                   "The installed-app resource resolver must find \(weight)")
            XCTAssertEqual(UsageIslandFonts.resourceURL(weight: weight), url)
            let descriptors = try XCTUnwrap(CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor])
            let names = descriptors.compactMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String }
            XCTAssertTrue(names.contains("Poppins-\(weight)"), "The packaged file must contain the expected font, not merely exist")
        }
        let licenseURL = try XCTUnwrap(AIMonitorResources.url(forResource: "OFL", withExtension: "txt"))
        let license = try String(contentsOf: licenseURL, encoding: .utf8)
        XCTAssertTrue(license.contains("Copyright 2020 The Poppins Project Authors"))
        XCTAssertTrue(license.contains("SIL OPEN FONT LICENSE Version 1.1"))
    }

    func testPackagedFontsRegisterWithoutUsingTheSystemFallback() throws {
        _ = NSApplication.shared
        try UsageIslandFonts.validateResources()
        for weight in ["Light", "Regular", "Medium", "SemiBold", "Bold"] {
            XCTAssertEqual(UsageIslandFonts.font(12, weight: weight).fontName, "Poppins-\(weight)")
        }
        XCTAssertNil(UsageIslandFonts.resourceURL(weight: "MissingWeight"))
        XCTAssertEqual(UsageIslandFonts.font(12, weight: "MissingWeight").pointSize, 12)
    }
}

@MainActor
final class UsageIslandViewTests: XCTestCase {
    func testWingsMirrorAroundTheNotchWithIconNearTheCamera() {
        let rect = CGRect(x: 12, y: 0, width: 120, height: 32)
        let left = UsageIslandView.slotLayout(in: rect, slot: 0)
        let right = UsageIslandView.slotLayout(in: rect, slot: 1)
        // 왼쪽 날개: 사용량 → 아이콘 (아이콘이 노치 쪽 = 오른쪽 끝, 텍스트는 오른쪽 정렬)
        XCTAssertEqual(left.icon.maxX, rect.maxX)
        XCTAssertEqual(left.alignment, .right)
        XCTAssertLessThanOrEqual(left.text.maxX, left.icon.minX)
        // 오른쪽 날개: 아이콘 → 사용량 (아이콘이 노치 쪽 = 왼쪽 끝, 텍스트는 왼쪽 정렬)
        XCTAssertEqual(right.icon.minX, rect.minX)
        XCTAssertEqual(right.alignment, .left)
        XCTAssertGreaterThanOrEqual(right.text.minX, right.icon.maxX)
        XCTAssertEqual(left.icon.midY, rect.midY)
        XCTAssertEqual(right.icon.midY, rect.midY)
    }

    func testUnlimitedMetersRemainLabeledAsUsedWhenRemainingIsSelected() {
        let unlimited = LiveProvidersManager.MenuBarUsage(meterLabel: "Requests", isSession: false,
                                                         format: .count(suffix: ""), used: 12, limit: 0)
        let limited = LiveProvidersManager.MenuBarUsage(meterLabel: "Session", isSession: true,
                                                       format: .percent, used: 42, limit: 100)
        XCTAssertEqual(UsageIslandSummary.line(for: unlimited, showingRemaining: true), "12")
        XCTAssertEqual(UsageIslandSummary.modeLabel(for: unlimited, showingRemaining: true), "사용")
        XCTAssertEqual(UsageIslandSummary.line(for: limited, showingRemaining: true), "58%")
        XCTAssertEqual(UsageIslandSummary.modeLabel(for: limited, showingRemaining: true), "남음")
        XCTAssertEqual(UsageIslandSummary.line(for: limited, showingRemaining: false), "42%")
        XCTAssertEqual(UsageIslandSummary.modeLabel(for: limited, showingRemaining: false), "사용")
    }

    func testMoneyAndRequestMetersRespectTheirActualLimits() {
        let money = LiveProvidersManager.MenuBarUsage(meterLabel: "Total usage", isSession: false,
            format: .dollars, used: 4, limit: 20)
        let unboundedMoney = LiveProvidersManager.MenuBarUsage(meterLabel: "Total usage", isSession: false,
            format: .dollars, used: 4, limit: 0)
        let requests = LiveProvidersManager.MenuBarUsage(meterLabel: "Requests", isSession: false,
            format: .count(suffix: ""), used: 25, limit: 100)
        XCTAssertEqual(UsageIslandSummary.line(for: money, showingRemaining: false), "20%")
        XCTAssertEqual(UsageIslandSummary.line(for: money, showingRemaining: true), "80%")
        XCTAssertEqual(UsageIslandSummary.line(for: unboundedMoney, showingRemaining: true), "$4.00")
        XCTAssertEqual(UsageIslandSummary.line(for: requests, showingRemaining: true), "75%")
        XCTAssertEqual(UsageIslandSummary.modeLabel(for: money, showingRemaining: false), "사용")
        XCTAssertEqual(UsageIslandSummary.modeLabel(for: money, showingRemaining: true), "남음")
        XCTAssertEqual(UsageIslandSummary.modeLabel(for: unboundedMoney, showingRemaining: true), "사용")
        XCTAssertEqual(UsageIslandSummary.modeLabel(for: requests, showingRemaining: true), "남음")
    }

    func testUnboundedValuesStayNumericAndUsedAcrossBothDisplayModes() {
        let meters: [(LiveProvidersManager.MenuBarUsage, String)] = [
            (.init(meterLabel: "Total usage", isSession: false, format: .dollars, used: 4, limit: 0), "$4.00"),
            (.init(meterLabel: "Requests", isSession: false, format: .count(suffix: " requests"), used: 12, limit: 0), "12"),
            (.init(meterLabel: "Requests", isSession: false, format: .count(suffix: ""), used: 12, limit: -1), "12"),
        ]
        for (meter, number) in meters {
            for remaining in [false, true] {
                XCTAssertEqual(UsageIslandSummary.line(for: meter, showingRemaining: remaining), number)
                XCTAssertEqual(UsageIslandSummary.modeLabel(for: meter, showingRemaining: remaining), "사용",
                               "An unbounded meter has no remaining allowance to label")
            }
        }
        let percent = LiveProvidersManager.MenuBarUsage(meterLabel: "Session", isSession: true,
            format: .percent, used: 67, limit: 0)
        XCTAssertEqual(UsageIslandSummary.line(for: percent, showingRemaining: true), "33%")
        XCTAssertEqual(UsageIslandSummary.modeLabel(for: percent, showingRemaining: true), "남음",
                       "A percentage already supplies a bounded ratio without a separate numeric limit")
    }

    func testSmallSlotsKeepIconsAndTextInsideTheAvailableWing() {
        let rect = CGRect(x: 12, y: 5, width: 8, height: 10)
        for slot in [0, 1] {
            let layout = UsageIslandView.slotLayout(in: rect, slot: slot)
            XCTAssertTrue(rect.contains(layout.icon))
            XCTAssertGreaterThanOrEqual(layout.text.width, 0)
            XCTAssertGreaterThanOrEqual(layout.text.minX, rect.minX)
            XCTAssertLessThanOrEqual(layout.text.maxX, rect.maxX)
        }
    }
    func testFlatTopKeepsOnlyTheLowerCornersTransparent() {
        let rect = CGRect(x: 0, y: 0, width: 288, height: 32)
        let outline = UsageIslandView.shape(in: rect)
        XCTAssertFalse(outline.contains(CGPoint(x: 1, y: 1)))
        XCTAssertTrue(outline.contains(CGPoint(x: 1, y: 31)))
        XCTAssertTrue(outline.contains(CGPoint(x: 144, y: 16)))
    }

    func testAccessiblePressUsesTheSameExistingPanelCallback() {
        let view = UsageIslandView(frame: CGRect(x: 0, y: 0, width: 288, height: 32))
        var opened = false
        view.onOpen = { anchor in opened = anchor === view }
        view.summary = UsageIslandSummary(items: [], mode: "사용")
        XCTAssertEqual(view.accessibilityRole(), .button)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertTrue(opened)
    }

    func testWaitingViewIsAccessibleBeforeAnyProviderUpdate() {
        let view = UsageIslandView(frame: CGRect(x: 0, y: 0, width: 288, height: 32))
        XCTAssertEqual(view.accessibilityRole(), .button)
        XCTAssertTrue(view.accessibilityLabel()?.contains("amon") == true)
        XCTAssertTrue(view.accessibilityLabel()?.contains("기다리는 중") == true)
        XCTAssertFalse(view.accessibilityPerformPress())
        XCTAssertFalse(view.accessibilityPerformShowMenu())
    }

    func testHitTestingConvertsFromTheSuperviewCoordinateSystem() {
        let parent = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 200))
        let view = makeView()
        view.setFrameOrigin(NSPoint(x: 40, y: 70))
        parent.addSubview(view)
        let rect = view.popoverAnchorRect
        let center = view.convert(NSPoint(x: rect.midX, y: rect.midY), to: parent)
        let corner = view.convert(NSPoint(x: rect.minX + 1, y: rect.minY + 1), to: parent)
        XCTAssertTrue(view.hitTest(center) === view)
        XCTAssertNil(view.hitTest(corner))
        view.isHidden = true
        XCTAssertNil(view.hitTest(center))
    }

    func testClickCapturesCloseIntentBeforeTransientDismissal() throws {
        let view = makeView()
        var shown = true
        var targets: [Bool] = []
        view.isOpen = { shown }
        view.onSetOpen = { value, anchor in
            XCTAssertTrue(anchor === view)
            targets.append(value)
            shown = value
        }
        view.prepareMousePress()
        shown = false // AppKit's transient popover dismissal between down and up.
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view))
        XCTAssertEqual(targets, [false], "The second click must close, not reopen the panel")
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view))
        XCTAssertEqual(targets, [false, true])
    }

    func testDraggingOutCancelsTheClickAndClearsItsCapturedIntent() throws {
        let view = makeView()
        var targets: [Bool] = []
        view.onSetOpen = { value, _ in targets.append(value) }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view,
            point: CGPoint(x: view.bounds.maxX + 20, y: view.bounds.maxY + 20)))
        XCTAssertTrue(targets.isEmpty)
        view.isOpen = { true }
        view.mouseDown(with: try mouseEvent(.leftMouseDown, in: view))
        view.mouseUp(with: try mouseEvent(.leftMouseUp, in: view))
        XCTAssertEqual(targets, [false])
    }

    func testKeyboardAndVoiceOverShareTheToggleAndEscapeCloses() throws {
        let view = UsageIslandView(frame: CGRect(x: 0, y: 0, width: 288, height: 32))
        var shown = false
        view.isOpen = { shown }
        view.onSetOpen = { value, _ in shown = value }
        view.onClose = { shown = false }
        view.keyDown(with: try keyEvent(36, characters: "\r"))
        XCTAssertTrue(shown)
        view.keyDown(with: try keyEvent(49, characters: " ", repeating: true))
        XCTAssertTrue(shown, "Holding a key must not repeatedly toggle the popover")
        view.keyDown(with: try keyEvent(49, characters: " "))
        XCTAssertFalse(shown)
        XCTAssertTrue(view.accessibilityPerformPress())
        XCTAssertTrue(shown)
        view.keyDown(with: try keyEvent(53, characters: "\u{1B}"))
        XCTAssertFalse(shown)
    }

    func testStoppedControllerIgnoresUpdatesAndQueuedDisplayNotifications() async {
        _ = NSApplication.shared
        let controller = UsageIslandController(onOpen: { _ in }, onClose: {}, makeMenu: { NSMenu() })
        var geometryChanges = 0
        controller.onGeometryChange = { geometryChanges += 1 }
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        controller.stop()
        controller.stop()
        controller.update(summary: UsageIslandPreview.sample, enabled: true)
        await Task.yield()
        XCTAssertNil(controller.anchor)
        XCTAssertEqual(geometryChanges, 1)
        XCTAssertFalse(controller.view.accessibilityPerformPress())
        XCTAssertFalse(controller.containsScreenPoint(.zero))
    }

    func testIslandToggleDefaultsOnAndPersistsWithoutChangingQuotaPreference() {
        let name = "UsageIslandTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.islandEnabled)
        settings.menuBarQuotaEnabled = false
        settings.islandEnabled = false
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertFalse(reloaded.islandEnabled)
        XCTAssertFalse(reloaded.menuBarQuotaEnabled)
    }

    func testIslandSettingRetainsStandalonePrivacyDefaultsAndCustomPetVersion() {
        let name = "UsageIslandStandaloneTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(BundledPetMigration.currentVersion, forKey: "pet.migration")
        defaults.set("/tmp/island-test-custom-v3.png", forKey: "pet.spritePath")
        defaults.set(3, forKey: "pet.spriteVersion")
        defaults.set(false, forKey: "menubar.quota")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.serverURL, "")
        XCTAssertEqual(settings.userKey, "")
        XCTAssertFalse(settings.localActivityEnabled)
        XCTAssertFalse(settings.menuBarQuotaEnabled)
        XCTAssertTrue(settings.islandEnabled)
        XCTAssertEqual(settings.petSpriteVersion, 3)
        XCTAssertEqual(settings.petSpritePath, "/tmp/island-test-custom-v3.png")
        settings.islandEnabled = false
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.serverURL, "")
        XCTAssertFalse(reloaded.localActivityEnabled)
        XCTAssertFalse(reloaded.menuBarQuotaEnabled)
        XCTAssertEqual(reloaded.petSpriteVersion, 3)
        XCTAssertEqual(reloaded.petSpritePath, settings.petSpritePath)
    }

    private func makeView() -> UsageIslandView {
        let geometry = UsageIslandGeometry.make(screen: CGRect(x: 0, y: 0, width: 1200, height: 800),
            safeTop: 0, left: nil, right: nil)
        let view = UsageIslandView(frame: CGRect(origin: .zero, size: geometry.panelFrame.size))
        view.geometry = geometry
        view.reduceMotion = true
        return view
    }

    private func mouseEvent(_ type: NSEvent.EventType, in view: UsageIslandView,
                            point: CGPoint? = nil) throws -> NSEvent {
        let anchor = view.popoverAnchorRect
        let local = point ?? CGPoint(x: anchor.midX, y: anchor.midY)
        let location = view.convert(local, to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
    }

    private func keyEvent(_ code: UInt16, characters: String, repeating: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: repeating, keyCode: code))
    }
}
