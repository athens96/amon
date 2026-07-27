import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import AIMonitor

final class CodexPetPackageImporterTests: XCTestCase {
    func testImportsNestedCodexPetPackageUsingManifestSprite() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent(
            "pixel-coder",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        try Data("not the sprite".utf8).write(
            to: package.appendingPathComponent("preview.png")
        )
        let sprite = try makePNG(width: 1536, height: 1872)
        try sprite.write(to: package.appendingPathComponent("spritesheet.png"))
        try manifestData(
            displayName: "Pixel Coder",
            spritesheetPath: "spritesheet.png"
        ).write(to: package.appendingPathComponent("pet.json"))

        let archive = try createArchive(
            in: directory,
            inputs: ["pixel-coder"],
            extension: "zip"
        )
        let payload = try CodexPetPackageImporter.load(fileURL: archive)

        XCTAssertEqual(payload.displayName, "Pixel Coder")
        XCTAssertEqual(payload.data, sprite)
        XCTAssertEqual(payload.metadata.format, .png)
        XCTAssertEqual(payload.metadata.pixelWidth, 1536)
        XCTAssertEqual(payload.metadata.pixelHeight, 1872)
        XCTAssertEqual(payload.metadata.spriteVersion, .v1)
    }

    /// 실제 codex-pets v2 패키지처럼 pet.json 이 버전을 선언하고 시트가 11행인 경우.
    func testImportsV2PackageDeclaredByManifestSpriteVersionNumber() throws {
        let directory = try makeTemporaryDirectory()
        let package = directory.appendingPathComponent("svinushka", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        let sprite = try makePNG(width: 1536, height: 2288)
        try sprite.write(to: package.appendingPathComponent("spritesheet.png"))
        try manifestData(
            displayName: "Svinushka",
            spritesheetPath: "spritesheet.png",
            spriteVersionNumber: 2
        ).write(to: package.appendingPathComponent("pet.json"))

        let archive = try createArchive(
            in: directory,
            inputs: ["svinushka"],
            extension: "zip"
        )
        let payload = try CodexPetPackageImporter.load(fileURL: archive)

        XCTAssertEqual(payload.displayName, "Svinushka")
        XCTAssertEqual(payload.metadata.pixelHeight, 2288)
        XCTAssertEqual(payload.metadata.spriteVersion, .v2)
    }

    /// 매니페스트 선언과 실제 시트 크기가 어긋나면 설치를 막는다.
    func testRejectsManifestVersionThatDoesNotMatchSheet() throws {
        let directory = try makeTemporaryDirectory()
        let package = directory.appendingPathComponent("mismatch", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        try makePNG(width: 1536, height: 1872)
            .write(to: package.appendingPathComponent("spritesheet.png"))
        try manifestData(
            displayName: "Mismatch",
            spritesheetPath: "spritesheet.png",
            spriteVersionNumber: 2
        ).write(to: package.appendingPathComponent("pet.json"))

        let archive = try createArchive(
            in: directory,
            inputs: ["mismatch"],
            extension: "zip"
        )

        XCTAssertThrowsError(try CodexPetPackageImporter.load(fileURL: archive)) { error in
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

    func testRecognizesZIPBySignatureWhenExtensionIsDifferent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("pet", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        try makePNG(width: 1536, height: 1872).write(
            to: package.appendingPathComponent("spritesheet.png")
        )
        try manifestData(
            displayName: "Renamed ZIP",
            spritesheetPath: "spritesheet.png"
        ).write(to: package.appendingPathComponent("pet.json"))

        let archive = try createArchive(
            in: directory,
            inputs: ["pet"],
            extension: "codexpet"
        )
        let payload = try CodexPetPackageImporter.load(fileURL: archive)

        XCTAssertEqual(payload.displayName, "Renamed ZIP")
        XCTAssertEqual(payload.metadata.format, .png)
    }

    func testImportsStandalonePNGWithoutZIPRegression() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sprite = try makePNG(width: 1536, height: 1872)
        let file = directory.appendingPathComponent("spritesheet.png")
        try sprite.write(to: file)

        let payload = try CodexPetPackageImporter.load(
            fileURL: file,
            spriteVersion: .v1
        )

        XCTAssertEqual(payload.data, sprite)
        XCTAssertNil(payload.displayName)
        XCTAssertEqual(payload.metadata.format, .png)
        XCTAssertEqual(payload.metadata.spriteVersion, .v1)
    }

    func testRejectsManifestPathTraversal() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let package = directory.appendingPathComponent("pet", isDirectory: true)
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        try manifestData(
            displayName: "Unsafe",
            spritesheetPath: "../spritesheet.png"
        ).write(to: package.appendingPathComponent("pet.json"))

        let archive = try createArchive(
            in: directory,
            inputs: ["pet"],
            extension: "zip"
        )

        XCTAssertThrowsError(
            try CodexPetPackageImporter.load(fileURL: archive)
        ) { error in
            XCTAssertEqual(
                error as? CodexPetPackageImportError,
                .unsafeEntryPath("../spritesheet.png")
            )
        }
    }

    func testRejectsMultiplePetManifestsInsteadOfPickingOne() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for name in ["pet-a", "pet-b"] {
            let package = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(
                at: package,
                withIntermediateDirectories: true
            )
            try manifestData(
                displayName: name,
                spritesheetPath: "spritesheet.png"
            ).write(to: package.appendingPathComponent("pet.json"))
        }

        let archive = try createArchive(
            in: directory,
            inputs: ["pet-a", "pet-b"],
            extension: "zip"
        )

        XCTAssertThrowsError(
            try CodexPetPackageImporter.load(fileURL: archive)
        ) { error in
            XCTAssertEqual(
                error as? CodexPetPackageImportError,
                .ambiguousManifest
            )
        }
    }

    func testImportsExternalCodexPetArchiveWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment[
            "AMON_CODEX_PET_TEST_ARCHIVE"
        ] else {
            throw XCTSkip("AMON_CODEX_PET_TEST_ARCHIVE is not set")
        }

        let payload = try CodexPetPackageImporter.load(
            fileURL: URL(fileURLWithPath: path)
        )

        XCTAssertEqual(payload.metadata.pixelWidth, 1536)
        XCTAssertEqual(payload.metadata.pixelHeight, 1872)
        XCTAssertEqual(payload.metadata.format, .png)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func createArchive(
        in directory: URL,
        inputs: [String],
        extension fileExtension: String
    ) throws -> URL {
        let archive = directory
            .appendingPathComponent("pet-package")
            .appendingPathExtension(fileExtension)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = directory
        process.arguments = ["-q", "-X", "-r", archive.path] + inputs
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return archive
    }

    private func manifestData(
        displayName: String,
        spritesheetPath: String,
        spriteVersionNumber: Int? = nil
    ) throws -> Data {
        var object: [String: Any] = [
            "id": "test-pet",
            "displayName": displayName,
            "spritesheetPath": spritesheetPath
        ]
        if let spriteVersionNumber {
            object["spriteVersionNumber"] = spriteVersionNumber
        }
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
    }

    private func makePNG(width: Int, height: Int) throws -> Data {
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
        context.setFillColor(
            CGColor(red: 0.2, green: 0.75, blue: 0.35, alpha: 0.85)
        )
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
