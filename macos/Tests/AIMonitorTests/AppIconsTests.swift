import AppKit
import XCTest

@testable import AIMonitor

final class AppIconsTests: XCTestCase {
    func testDefaultAmonMenuBarIconLoadsFromResourceBundle() throws {
        XCTAssertEqual(AppIcons.iconCount, 1)
        XCTAssertEqual(AppIcons.stageCount, 1)
        XCTAssertEqual(AppIcons.names, ["amon"])

        let image = try XCTUnwrap(AppIcons.rawImage(icon: 0))
        XCTAssertEqual(image.size, NSSize(width: 44, height: 44))
        XCTAssertNil(AppIcons.rawImage(icon: 1))
        XCTAssertNil(AppIcons.rawImage(icon: 0, stage: 1))

        let menuBarImage = try XCTUnwrap(AppIcons.menuBarImage(icon: 0))
        XCTAssertEqual(
            menuBarImage.size,
            NSSize(width: AppIcons.menuBarPointSize, height: AppIcons.menuBarPointSize)
        )
        XCTAssertTrue(menuBarImage.isTemplate)
    }
}
