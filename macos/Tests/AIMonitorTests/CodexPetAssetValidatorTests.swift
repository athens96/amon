import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import AIMonitor

final class CodexPetAssetValidatorTests: XCTestCase {
    func testValidV1SheetDetectsSpriteVersionFromDimensions() throws {
        let data = try makePNG(width: 1536, height: 1872)

        let metadata = try CodexPetAssetValidator.validate(data: data)

        XCTAssertEqual(metadata.format, .png)
        XCTAssertEqual(metadata.pixelWidth, 1536)
        XCTAssertEqual(metadata.pixelHeight, 1872)
        XCTAssertEqual(metadata.byteCount, data.count)
        XCTAssertEqual(metadata.spriteVersion, .v1)
    }

    func testAcceptsV2SheetWithTwoExtraLookRows() throws {
        let data = try makePNG(width: 1536, height: 2288)

        let metadata = try CodexPetAssetValidator.validate(data: data, spriteVersion: .v2)

        XCTAssertEqual(metadata.pixelHeight, 2288)
        XCTAssertEqual(metadata.spriteVersion, .v2)
    }

    func testAcceptsV3SheetWithRunningAwayRow() throws {
        let data = try makePNG(width: 1536, height: 2496)

        let metadata = try CodexPetAssetValidator.validate(data: data, spriteVersion: .v3)

        XCTAssertEqual(metadata.pixelHeight, 2496)
        XCTAssertEqual(metadata.spriteVersion, .v3)
    }

    /// 매니페스트가 선언한 버전과 실제 시트 크기가 어긋나면 조용히 넘기지 않는다.
    func testRejectsDeclaredVersionThatContradictsSheetHeight() throws {
        let data = try makePNG(width: 1536, height: 1872)

        XCTAssertThrowsError(
            try CodexPetAssetValidator.validate(data: data, spriteVersion: .v2)
        ) { error in
            XCTAssertEqual(
                error as? CodexPetAssetValidationError,
                .versionDimensionMismatch(
                    declaredVersion: 2,
                    width: 1536,
                    height: 1872,
                    expectedHeight: 2288
                )
            )
        }
    }

    func testRejectsWrongDimensions() throws {
        let data = try makePNG(width: 32, height: 48)

        XCTAssertThrowsError(try CodexPetAssetValidator.validate(data: data)) { error in
            XCTAssertEqual(
                error as? CodexPetAssetValidationError,
                .invalidDimensions(width: 32, height: 48)
            )
        }
    }

    func testRejectsOpaquePNGWithoutAlphaChannel() throws {
        let data = try makePNG(width: 1536, height: 1872, hasAlpha: false)

        XCTAssertThrowsError(try CodexPetAssetValidator.validate(data: data)) { error in
            XCTAssertEqual(
                error as? CodexPetAssetValidationError,
                .missingTransparency
            )
        }
    }

    func testRejectsFileLargerThanTwentyMiBBeforeDecoding() {
        let data = Data(count: CodexPetAssetValidator.maximumByteCount + 1)

        XCTAssertThrowsError(try CodexPetAssetValidator.validate(data: data)) { error in
            XCTAssertEqual(
                error as? CodexPetAssetValidationError,
                .fileTooLarge(
                    actualBytes: CodexPetAssetValidator.maximumByteCount + 1,
                    maximumBytes: CodexPetAssetValidator.maximumByteCount
                )
            )
        }
    }

    func testRejectsUnsupportedContentEvenWithImageLikeBytes() {
        let data = Data([0xff, 0xd8, 0xff, 0xe0])

        XCTAssertThrowsError(try CodexPetAssetValidator.validate(data: data)) { error in
            XCTAssertEqual(error as? CodexPetAssetValidationError, .unsupportedFormat)
        }
    }

    func testRecognizesWebPSignatureWithoutGuessingFrameLayout() {
        var bytes = Array("RIFF".utf8)
        bytes.append(contentsOf: [0, 0, 0, 0])
        bytes.append(contentsOf: Array("WEBP".utf8))

        XCTAssertEqual(CodexPetAssetValidator.format(of: Data(bytes)), .webP)
    }

    func testRejectsTruncatedPNGAsUnreadable() {
        let signature = Data([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])

        XCTAssertThrowsError(try CodexPetAssetValidator.validate(data: signature)) { error in
            XCTAssertEqual(error as? CodexPetAssetValidationError, .unreadableImage)
        }
    }

    private func makePNG(
        width: Int,
        height: Int,
        hasAlpha: Bool = true
    ) throws -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: (
                    hasAlpha
                        ? CGImageAlphaInfo.premultipliedLast
                        : CGImageAlphaInfo.noneSkipLast
                ).rawValue
            )
        )
        context.setFillColor(CGColor(red: 0.38, green: 0.38, blue: 1, alpha: 0.8))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let output = NSMutableData()
        let destination = try XCTUnwrap(
            CGImageDestinationCreateWithData(
                output,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        )
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return output as Data
    }
}
