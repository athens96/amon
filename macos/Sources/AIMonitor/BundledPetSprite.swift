import Foundation

/// 앱에 함께 넣어 두는 펫 — 커스텀 펫이 없을 때 이 중 하나로 그린다.
///
/// 파일은 `Sources/AIMonitor/PetSprites/<resourceName>.webp` 에 두고 SwiftPM 이
/// 리소스 번들로 묶는다. Makefile 은 그 번들을 .app 안으로 복사한다.
struct BundledPet: Identifiable, Equatable {
    let id: String
    let displayName: String
    let resourceName: String
    /// 표준 애니메이션 9행짜리 v1 시트(1536×1872).
    let spriteVersion: CodexPetSpriteVersion

    static let resourceExtension = "webp"

    static let dozyBoo = BundledPet(
        id: "dozy-boo",
        displayName: "Dozy Boo",
        resourceName: "DozyBoo",
        spriteVersion: .v1
    )

    /// A-mon에는 Dozy Boo 한 종만 번들하며, 이 펫이 기본값이다.
    static let all: [BundledPet] = [.dozyBoo]

    /// 저장값이 없거나 구버전에서 삭제된 펫 ID가 남아 있어도 Dozy Boo로 돌아간다.
    ///
    /// 사용자가 카드를 눌러 고르기 전까지는 `pet.bundledID` 를 저장하지 않으므로,
    /// 여기(=`all` 의 첫 항목)를 바꾸면 아직 고르지 않은 사용자에게 그대로 반영된다.
    static var fallback: BundledPet { all[0] }

    /// 저장된 식별자를 펫으로 되돌린다. 모르는 값(구버전·수동 편집)은 기본 펫이다.
    static func pet(id: String?) -> BundledPet {
        guard let id, let match = all.first(where: { $0.id == id }) else {
            return fallback
        }
        return match
    }

    /// 번들에 들어 있는 파일 경로. 어디서도 찾지 못하면 nil 이다.
    var path: String? {
        BundledPetResources.url(
            forResource: resourceName,
            withExtension: Self.resourceExtension
        )?.path
    }
}

/// 번들 펫 파일을 찾는다.
///
/// `Bundle.module` 은 번들을 못 찾으면 앱을 죽이므로 쓰지 않는다. 실행 형태마다
/// 리소스가 놓이는 자리가 달라서 후보를 순서대로 훑고, 없으면 조용히 nil 을
/// 돌려 호출부가 직접 그리는 폴백 펫으로 떨어지게 한다.
enum BundledPetResources {
    /// SwiftPM 이 만드는 리소스 번들 이름 — `<패키지>_<타깃>.bundle`.
    static let bundleName = "AIMonitor_AIMonitor"

    static func url(forResource name: String, withExtension ext: String) -> URL? {
        if let bundle = resourceBundle,
           let url = bundle.url(forResource: name, withExtension: ext) {
            return url
        }
        // 리소스 번들을 못 찾는 경우를 대비해 앱 번들 Resources 도 직접 본다.
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    private final class BundleFinder {}

    private static let resourceBundle: Bundle? = {
        let own = Bundle(for: BundleFinder.self)
        let candidates = [
            // .app 안: Contents/Resources/
            Bundle.main.resourceURL,
            own.resourceURL,
            // `swift run`·테스트: 실행 파일 옆
            Bundle.main.bundleURL,
            own.bundleURL,
            own.bundleURL.deletingLastPathComponent(),
        ]
        for directory in candidates.compactMap({ $0 }) {
            let url = directory.appendingPathComponent("\(bundleName).bundle")
            if let bundle = Bundle(url: url) {
                return bundle
            }
        }
        return nil
    }()
}

/// 저장된 펫 설정을 번들 펫 체계로 맞춘다.
///
/// 번들 펫이 없던 시절 설정에서 올라와도 사용자가 가져온 커스텀 펫 선택은
/// 그대로 보존한다. 커스텀 펫이 없거나 파일이 사라진 경우에만 Dozy Boo로 폴백한다.
///
/// 정리를 마쳤다는 표시는 `pet.bundledID` 가 아니라 별도의 마이그레이션 번호에
/// 남긴다. `pet.bundledID` 는 **사용자가 직접 고른 펫만** 담아야, 저장값이 없는
/// 사용자가 `BundledPet.fallback` 을 계속 따라갈 수 있기 때문이다.
enum BundledPetMigration {
    /// 지금까지 적용한 정리 단계. 저장값이 이보다 낮으면 한 번 더 정리한다.
    static let currentVersion = 1

    struct Result: Equatable {
        /// 사용자가 고른 펫. nil 이면 저장하지 않는다(= 기본 펫을 따라감).
        let bundledID: String?
        let spritePath: String
        let spriteVersion: Int
        /// 저장소에 새로 굳혀야 하는지 — `init` 에서는 `didSet` 이 돌지 않는다.
        let persists: Bool

        /// 지금 그릴 펫 — 고른 적이 없으면 기본 펫이다.
        var resolvedPet: BundledPet { BundledPet.pet(id: bundledID) }
    }

    static func resolve(
        storedVersion: Int?,
        storedBundledID: String?,
        storedSpritePath: String,
        storedSpriteVersion: Int
    ) -> Result {
        guard (storedVersion ?? 0) >= currentVersion else {
            // 삭제된 구형 번들 ID는 저장하지 않고 Dozy Boo 기본값으로 수렴한다.
            // 사용자가 가져온 커스텀 시트는 절대 해제하지 않는다.
            return Result(
                bundledID: nil,
                spritePath: storedSpritePath,
                spriteVersion: storedSpriteVersion == 2 ? 2 : 1,
                persists: true
            )
        }
        // 정리를 마친 뒤에는 사용자가 직접 넣은 커스텀 펫도, 직접 고른 번들 펫도
        // 그대로 둔다. 모르는 값은 읽을 때 기본 펫으로 해석되므로 굳이 고쳐 쓰지 않는다.
        return Result(
            bundledID: storedBundledID,
            spritePath: storedSpritePath,
            spriteVersion: storedSpriteVersion,
            persists: false
        )
    }
}

/// 실제로 그릴 스프라이트 한 장.
struct PetSpriteSelection: Equatable {
    let path: String
    let version: CodexPetSpriteVersion
}

/// 커스텀 펫 → 번들 펫 순서로 그릴 시트를 고른다.
enum PetSpriteResolver {
    /// 커스텀 펫이 설정돼 있고 파일이 남아 있으면 그것을, 아니면 고른 번들 펫을 쓴다.
    /// 둘 다 없으면 nil — 호출부가 직접 그리는 폴백 펫으로 떨어진다.
    static func selection(
        customPath: String,
        customVersion: CodexPetSpriteVersion,
        bundled: BundledPet,
        bundledPath: String?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> PetSpriteSelection? {
        if !customPath.isEmpty, fileExists(customPath) {
            return PetSpriteSelection(path: customPath, version: customVersion)
        }
        if let bundledPath, fileExists(bundledPath) {
            return PetSpriteSelection(
                path: bundledPath,
                version: bundled.spriteVersion
            )
        }
        return nil
    }
}
