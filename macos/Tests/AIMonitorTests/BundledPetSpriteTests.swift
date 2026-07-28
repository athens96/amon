import XCTest

@testable import AIMonitor

final class BundledPetSpriteTests: XCTestCase {
    func testAmonIsTheFirstBundledPetAndDefault() {
        XCTAssertEqual(BundledPet.all, [.amon, .dozyBoo])
        XCTAssertEqual(BundledPet.fallback, .amon)
        XCTAssertEqual(BundledPet.pet(id: nil), .amon)
        XCTAssertEqual(BundledPet.pet(id: "g-rider"), .amon)
        XCTAssertEqual(BundledPet.pet(id: "monthly-salary-cat"), .amon)
        XCTAssertEqual(BundledPet.pet(id: "dozy-boo"), .dozyBoo)
    }

    func testCustomSpriteWinsAndMissingCustomFallsBackToAmon() {
        let custom = "/tmp/custom-pet.webp"
        let bundled = "/bundle/Amon.webp"
        XCTAssertEqual(
            PetSpriteResolver.selection(
                customPath: custom,
                customVersion: .v2,
                bundled: .amon,
                bundledPath: bundled,
                fileExists: { _ in true }
            ),
            PetSpriteSelection(path: custom, version: .v2)
        )
        XCTAssertEqual(
            PetSpriteResolver.selection(
                customPath: custom,
                customVersion: .v2,
                bundled: .amon,
                bundledPath: bundled,
                fileExists: { $0 == bundled }
            ),
            PetSpriteSelection(path: bundled, version: .v3)
        )
    }

    func testLegacyMigrationSelectsAmonOnceWithoutDiscardingCustomSprite() {
        let result = BundledPetMigration.resolve(
            storedVersion: nil,
            storedBundledID: "g-rider",
            storedSpritePath: "/tmp/legacy.webp",
            storedSpriteVersion: 2
        )
        XCTAssertEqual(result.resolvedPet, .amon)
        XCTAssertNil(result.bundledID)
        XCTAssertEqual(result.spritePath, "/tmp/legacy.webp")
        XCTAssertEqual(result.spriteVersion, 2)
        XCTAssertTrue(result.persists)
    }

    func testAmonResourceContractWhenGeneratedAssetIsPresent() throws {
        guard let path = BundledPet.amon.path else {
            // The generated WebP is supplied by the hatch-pet pipeline. Keeping
            // this conditional lets code-only changes build before that job lands.
            return
        }
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "Amon.webp")
        let metadata = try CodexPetAssetValidator.validate(
            fileURL: URL(fileURLWithPath: path)
        )
        XCTAssertEqual(metadata.format, .webP)
        XCTAssertEqual(metadata.spriteVersion, .v3)
    }

    func testDozyBooAssetIsValidAndResolvesAtRuntime() throws {
        let path = try XCTUnwrap(BundledPet.dozyBoo.path)
        XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "DozyBoo.webp")
        let metadata = try CodexPetAssetValidator.validate(
            fileURL: URL(fileURLWithPath: path)
        )
        XCTAssertEqual(metadata.format, .webP)
        XCTAssertEqual(metadata.spriteVersion, .v1)
        let frames = PetSpriteFrames.load(path: path, version: .v1)
        for animation in CodexPetSpriteLayout.animations(in: .v1) {
            XCTAssertFalse(
                try XCTUnwrap(frames.frames(for: animation)).isEmpty,
                "\(animation) row must contain frames"
            )
        }
    }
}
