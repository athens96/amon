import CoreGraphics
import XCTest

@testable import AIMonitor

/// v1(8×9), v2(8×11), v3(8×12) 시트 배치와 확장 행의 계약.
final class CodexPetSpriteVersionTests: XCTestCase {
    func testSheetHeightsMatchPublishedVersions() {
        XCTAssertEqual(CodexPetSpriteLayout.sheetPixelWidth, 1536)
        XCTAssertEqual(CodexPetSpriteLayout.sheetPixelHeight(for: .v1), 1872)
        XCTAssertEqual(CodexPetSpriteLayout.sheetPixelHeight(for: .v2), 2288)
        XCTAssertEqual(CodexPetSpriteLayout.sheetPixelHeight(for: .v3), 2496)
        XCTAssertEqual(CodexPetSpriteLayout.rowCount(for: .v1), 9)
        XCTAssertEqual(CodexPetSpriteLayout.rowCount(for: .v2), 11)
        XCTAssertEqual(CodexPetSpriteLayout.rowCount(for: .v3), 12)
    }

    func testVersionIsDetectedFromSheetSize() {
        XCTAssertEqual(
            CodexPetSpriteLayout.version(forPixelWidth: 1536, pixelHeight: 1872),
            .v1
        )
        XCTAssertEqual(
            CodexPetSpriteLayout.version(forPixelWidth: 1536, pixelHeight: 2288),
            .v2
        )
        XCTAssertEqual(
            CodexPetSpriteLayout.version(forPixelWidth: 1536, pixelHeight: 2496),
            .v3
        )
        XCTAssertNil(CodexPetSpriteLayout.version(forPixelWidth: 1536, pixelHeight: 2080))
        XCTAssertNil(CodexPetSpriteLayout.version(forPixelWidth: 1024, pixelHeight: 1872))
    }

    /// 각 애니메이션 행은 자기가 요구하는 버전의 시트 안에 들어와야 한다.
    func testAnimationRowsStayInsideTheirSheets() throws {
        for version in CodexPetSpriteVersion.allCases {
            let sheet = CGRect(
                x: 0,
                y: 0,
                width: CodexPetSpriteLayout.sheetPixelWidth,
                height: CodexPetSpriteLayout.sheetPixelHeight(for: version)
            )
            for animation in CodexPetSpriteLayout.animations(in: version) {
                let strip = try XCTUnwrap(CodexPetSpriteLayout.strips[animation])
                for column in 0..<strip.frameCount {
                    let frame = try XCTUnwrap(
                        CodexPetSpriteLayout.frameRect(column: column, animation: animation)
                    )
                    XCTAssertTrue(
                        sheet.contains(frame),
                        "\(version) \(animation) 열 \(column) 프레임이 시트를 벗어났다"
                    )
                }
            }
        }
    }

    /// 명세의 12행이 순서대로 행 0~11 에 놓인다.
    func testRowOrderMatchesPublishedSpec() throws {
        let expected: [(CodexPetSpriteLayout.Animation, Int)] = [
            (.idle, 0),
            (.runningRight, 1),
            (.runningLeft, 2),
            (.waving, 3),
            (.jumping, 4),
            (.failed, 5),
            (.waiting, 6),
            (.running, 7),
            (.review, 8),
            (.lookAroundRight, 9),
            (.lookAroundLeft, 10),
            (.runningAway, 11),
        ]
        XCTAssertEqual(expected.count, CodexPetSpriteLayout.Animation.allCases.count)
        for (animation, row) in expected {
            let strip = try XCTUnwrap(CodexPetSpriteLayout.strips[animation])
            XCTAssertEqual(strip.row, row, "\(animation) 는 행 \(row) 이어야 한다")
        }
    }

    /// 둘러보기 두 행은 v2 에만 있다 — v1 시트에서는 고르지 않는다.
    func testLookAroundRowsExistOnlyInV2() {
        XCTAssertEqual(CodexPetSpriteLayout.lookAround(.right), .lookAroundRight)
        XCTAssertEqual(CodexPetSpriteLayout.lookAround(.left), .lookAroundLeft)

        for animation in [
            CodexPetSpriteLayout.Animation.lookAroundRight, .lookAroundLeft,
        ] {
            XCTAssertFalse(CodexPetSpriteLayout.isAvailable(animation, in: .v1))
            XCTAssertTrue(CodexPetSpriteLayout.isAvailable(animation, in: .v2))
        }

        XCTAssertEqual(CodexPetSpriteLayout.animations(in: .v1).count, 9)
        XCTAssertEqual(CodexPetSpriteLayout.animations(in: .v2).count, 11)
        XCTAssertEqual(CodexPetSpriteLayout.animations(in: .v3).count, 12)
    }

    /// 둘러보기 행은 시트에 놓인 좌표가 행 9·10 이어야 한다.
    func testLookAroundFrameRects() throws {
        let right = try XCTUnwrap(
            CodexPetSpriteLayout.frameRect(column: 0, animation: .lookAroundRight)
        )
        XCTAssertEqual(right, CGRect(x: 0, y: 9 * 208, width: 192, height: 208))

        let left = try XCTUnwrap(
            CodexPetSpriteLayout.frameRect(column: 7, animation: .lookAroundLeft)
        )
        XCTAssertEqual(left, CGRect(x: 7 * 192, y: 10 * 208, width: 192, height: 208))

        XCTAssertNil(
            CodexPetSpriteLayout.frameRect(column: 8, animation: .lookAroundRight)
        )
    }

    func testRunningAwayExistsOnlyInV3AtRowEleven() throws {
        XCTAssertFalse(CodexPetSpriteLayout.isAvailable(.runningAway, in: .v2))
        XCTAssertTrue(CodexPetSpriteLayout.isAvailable(.runningAway, in: .v3))
        let frame = try XCTUnwrap(
            CodexPetSpriteLayout.frameRect(column: 7, animation: .runningAway)
        )
        XCTAssertEqual(frame, CGRect(x: 7 * 192, y: 11 * 208, width: 192, height: 208))
        XCTAssertEqual(CodexPetSpriteLayout.frameDurations(for: .runningAway).count, 8)
    }

    func testLocomotionRowsFollowDragDirection() {
        XCTAssertEqual(CodexPetSpriteLayout.locomotion(.right), .runningRight)
        XCTAssertEqual(CodexPetSpriteLayout.locomotion(.left), .runningLeft)
    }

    /// 시트가 선언보다 적은 프레임만 쓰면 타이밍도 그만큼 줄어들되,
    /// 마지막 프레임의 긴 마무리 박자는 유지한다.
    func testFrameDurationsTrimToActualFrameCount() {
        let full = CodexPetSpriteLayout.frameDurations(for: .lookAroundRight)
        XCTAssertEqual(full.count, 8)

        let trimmed = CodexPetSpriteLayout.frameDurations(
            for: .lookAroundRight,
            frameCount: 4
        )
        XCTAssertEqual(trimmed.count, 4)
        XCTAssertEqual(trimmed.last, full.last)
        XCTAssertEqual(Array(trimmed.dropLast()), Array(full.prefix(3)))

        // 선언보다 큰 값을 줘도 시트 밖으로 나가지 않는다.
        XCTAssertEqual(
            CodexPetSpriteLayout.frameDurations(for: .lookAroundRight, frameCount: 99).count,
            8
        )
    }

    /// 1회 재생은 마지막 프레임이 끝나면 nil 을 돌려 기본 루프로 되돌린다.
    func testOneShotPlaybackEndsAfterOneCycle() {
        let cycle = CodexPetSpriteLayout.cycleDuration(for: .jumping)
        XCTAssertGreaterThan(cycle, 0)

        XCTAssertEqual(
            CodexPetSpriteLayout.oneShotFrameIndex(
                elapsed: 0, animation: .jumping, reduceMotion: false
            ),
            0
        )
        XCTAssertEqual(
            CodexPetSpriteLayout.oneShotFrameIndex(
                elapsed: cycle - 0.01, animation: .jumping, reduceMotion: false
            ),
            4
        )
        XCTAssertNil(
            CodexPetSpriteLayout.oneShotFrameIndex(
                elapsed: cycle, animation: .jumping, reduceMotion: false
            )
        )
        // "동작 줄이기"에서는 1회 연출을 아예 건너뛴다.
        XCTAssertNil(
            CodexPetSpriteLayout.oneShotFrameIndex(
                elapsed: 0, animation: .jumping, reduceMotion: true
            )
        )
    }
}
