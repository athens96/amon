import AppKit

/// amon 기본 메뉴바 아이콘.
///
/// 원본은 `Sources/AIMonitor/Assets/amon-menubar-template.png` 에 두고 SwiftPM
/// 리소스 번들에서 읽는다. 상태별 이미지를 소스에 base64로 중복하지 않는다.
enum AppIcons {
    static let iconCount = 1
    static let stageCount = 1
    static let names = ["amon"]

    static let resourceName = "amon-menubar-template"
    static let resourceExtension = "png"
    static let menuBarPointSize: CGFloat = 18

    /// 설정 화면 썸네일과 메뉴바 렌더링에 함께 사용하는 원본 이미지.
    static func rawImage(icon: Int, stage: Int = 0) -> NSImage? {
        guard icon == 0, stage == 0,
              let url = AIMonitorResources.url(
                  forResource: resourceName,
                  withExtension: resourceExtension
              )
        else { return nil }
        return NSImage(contentsOf: url)
    }

    /// 메뉴바 표시용 템플릿 이미지. macOS가 현재 메뉴바 대비색을 적용한다.
    static func menuBarImage(icon: Int, stage: Int = 0) -> NSImage? {
        guard let source = rawImage(icon: icon, stage: stage),
              let image = source.copy() as? NSImage
        else { return nil }
        image.size = NSSize(width: menuBarPointSize, height: menuBarPointSize)
        image.isTemplate = true
        return image
    }

    /// 커스텀 아이콘 파일 → 메뉴바 크기 NSImage. 컬러 원본은 그대로 유지한다.
    static func customMenuBarImage(path: String) -> NSImage? {
        guard !path.isEmpty, let image = NSImage(contentsOfFile: path), image.isValid else {
            return nil
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = menuBarPointSize / max(size.width, size.height)
        image.size = NSSize(width: size.width * scale, height: size.height * scale)
        image.isTemplate = false
        return image
    }

    /// 커스텀 아이콘 원본 로드 — 설정 썸네일용.
    static func customRawImage(path: String) -> NSImage? {
        guard !path.isEmpty else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
