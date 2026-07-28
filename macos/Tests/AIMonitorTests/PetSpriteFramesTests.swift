import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import AIMonitor

/// 시트에서 행을 잘라내는 규칙 — 특히 프레임 수가 공개되지 않은 둘러보기 두 행.
final class PetSpriteFramesTests: XCTestCase {
    func testTrailingTransparentFramesAreTrimmed() {
        let frames = [
            Self.makeFrame(opaque: true),
            Self.makeFrame(opaque: true),
            Self.makeFrame(opaque: false),
            Self.makeFrame(opaque: false),
        ]
        XCTAssertEqual(PetSpriteFrames.trimmingTrailingTransparent(frames).count, 2)
    }

    func testFullyUsedRowIsKeptWhole() {
        let frames = (0..<8).map { _ in Self.makeFrame(opaque: true) }
        XCTAssertEqual(PetSpriteFrames.trimmingTrailingTransparent(frames).count, 8)
    }

    /// 첫 프레임까지 비어 있으면 그 행은 없는 셈으로 친다.
    func testFullyTransparentRowBecomesEmpty() {
        let frames = (0..<8).map { _ in Self.makeFrame(opaque: false) }
        XCTAssertTrue(PetSpriteFrames.trimmingTrailingTransparent(frames).isEmpty)
    }

    /// 실제 v2 크기 시트를 만들어 행 좌표와 잘라내기를 함께 확인한다.
    func testLoadReadsRowsAtSpecCoordinates() throws {
        // 행 9(둘러보기 오른쪽)만 5열까지 쓰고 나머지 3열은 비워둔다.
        let url = try Self.writeSheet(
            version: .v2,
            usedColumns: [9: 5]
        )
        defer { try? FileManager.default.removeItem(at: url) }

        let frames = PetSpriteFrames.load(path: url.path, version: .v2)
        XCTAssertFalse(frames.isEmpty)

        XCTAssertEqual(frames.frames(for: .idle)?.count, 6)
        XCTAssertEqual(frames.frames(for: .runningRight)?.count, 8)
        XCTAssertEqual(frames.frames(for: .review)?.count, 6)
        // 비어 있는 뒤쪽 3열은 재생 대상에서 빠진다.
        XCTAssertEqual(frames.frames(for: .lookAroundRight)?.count, 5)
        XCTAssertEqual(frames.frames(for: .lookAroundLeft)?.count, 8)
    }

    /// v1 시트에서는 둘러보기 행을 아예 읽지 않는다.
    func testV1SheetHasNoLookAroundRows() throws {
        let url = try Self.writeSheet(version: .v1, usedColumns: [:])
        defer { try? FileManager.default.removeItem(at: url) }

        let frames = PetSpriteFrames.load(path: url.path, version: .v1)
        XCTAssertEqual(frames.frames(for: .idle)?.count, 6)
        XCTAssertNil(frames.frames(for: .lookAroundRight))
        XCTAssertNil(frames.frames(for: .lookAroundLeft))
    }

    func testV3SheetLoadsRunningAwayAtRowEleven() throws {
        let url = try Self.writeSheet(version: .v3, usedColumns: [:])
        defer { try? FileManager.default.removeItem(at: url) }

        let frames = PetSpriteFrames.load(path: url.path, version: .v3)
        XCTAssertEqual(frames.frames(for: .runningAway)?.count, 8)
    }

    func testMissingFileLoadsNothing() {
        XCTAssertTrue(PetSpriteFrames.load(path: "", version: .v2).isEmpty)
        XCTAssertTrue(
            PetSpriteFrames.load(path: "/tmp/amon-pet-does-not-exist.webp", version: .v2)
                .isEmpty
        )
    }

    // MARK: -

    private static func makeFrame(opaque: Bool) -> CGImage {
        let context = CGContext(
            data: nil,
            width: 192,
            height: 208,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        if opaque {
            context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
            context.fill(CGRect(x: 40, y: 40, width: 100, height: 100))
        }
        return context.makeImage()!
    }

    /// 각 행을 채운 시트를 임시 파일로 쓴다. `usedColumns` 로 특정 행만
    /// 일부 열까지 채워 뒤쪽을 투명하게 남길 수 있다.
    private static func writeSheet(
        version: CodexPetSpriteVersion,
        usedColumns: [Int: Int]
    ) throws -> URL {
        let width = CodexPetSpriteLayout.sheetPixelWidth
        let height = CodexPetSpriteLayout.sheetPixelHeight(for: version)
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))

        let frameWidth = CodexPetSpriteLayout.framePixelWidth
        let frameHeight = CodexPetSpriteLayout.framePixelHeight
        for row in 0..<CodexPetSpriteLayout.rowCount(for: version) {
            let columns = usedColumns[row] ?? CodexPetSpriteLayout.columnCount
            for column in 0..<columns {
                // CGContext 는 아래에서 위로 그리고, 프레임 좌표는 위에서 아래로 센다.
                let y = height - (row + 1) * frameHeight
                context.fill(
                    CGRect(
                        x: column * frameWidth + 40,
                        y: y + 40,
                        width: 100,
                        height: 100
                    )
                )
            }
        }

        let image = try XCTUnwrap(context.makeImage())
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("amon-pet-\(version.rawValue)-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
}
