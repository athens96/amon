import XCTest

@testable import AIMonitor

final class BundledPetSpriteTests: XCTestCase {
    func testDozyBooIsTheOnlyBundledPetAndDefault() {
        XCTAssertEqual(BundledPet.all, [.dozyBoo])
        XCTAssertEqual(BundledPet.fallback, .dozyBoo)
        XCTAssertEqual(BundledPet.pet(id: nil), .dozyBoo)
        XCTAssertEqual(BundledPet.pet(id: "g-rider"), .dozyBoo)
        XCTAssertEqual(BundledPet.pet(id: "monthly-salary-cat"), .dozyBoo)
    }

    func testCustomSpriteWinsAndMissingCustomFallsBackToDozyBoo() {
        let custom = "/tmp/custom-pet.webp"
        let bundled = "/bundle/DozyBoo.webp"
        XCTAssertEqual(
            PetSpriteResolver.selection(
                customPath: custom,
                customVersion: .v2,
                bundled: .dozyBoo,
                bundledPath: bundled,
                fileExists: { _ in true }
            ),
            PetSpriteSelection(path: custom, version: .v2)
        )
        XCTAssertEqual(
            PetSpriteResolver.selection(
                customPath: custom,
                customVersion: .v2,
                bundled: .dozyBoo,
                bundledPath: bundled,
                fileExists: { $0 == bundled }
            ),
            PetSpriteSelection(path: bundled, version: .v1)
        )
    }

    func testLegacyMigrationSelectsDozyBooOnce() {
        let result = BundledPetMigration.resolve(
            storedVersion: nil,
            storedBundledID: "g-rider",
            storedSpritePath: "/tmp/legacy.webp",
            storedSpriteVersion: 2
        )
        XCTAssertEqual(result.resolvedPet, .dozyBoo)
        XCTAssertNil(result.bundledID)
        XCTAssertEqual(result.spritePath, "/tmp/legacy.webp")
        XCTAssertEqual(result.spriteVersion, 2)
        XCTAssertTrue(result.persists)
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
