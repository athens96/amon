import SwiftUI

/// amon 공통 타이포 스케일.
///
/// macOS 에서 SwiftUI 의 `.caption` 과 `.caption2` 는 둘 다 10pt 로 렌더링돼
/// 팝오버 전체가 10pt 잔글씨가 되는 문제가 있었다 — 시스템 텍스트 스타일 대신
/// 여기 정의한 고정 크기 토큰을 쓴다. 전체 크기를 조정할 땐 이 파일만 고치면 된다.
extension Font {
    /// 팝오버 헤더 제목 (구 `.headline` 13pt).
    static let amonTitle = Font.system(size: 18, weight: .semibold)
    /// 카드·섹션 제목 (구 `.subheadline.weight(.semibold)` 11pt).
    static let amonSection = Font.system(size: 15, weight: .semibold)
    /// 본문 라벨·값 (구 `.caption` 10pt).
    static let amonBody = Font.system(size: 13)
    /// 보조 설명·메타 (구 `.caption2` 10pt).
    static let amonCaption = Font.system(size: 12)
    /// 경로·URL 입력란 (구 `.caption` monospaced 10pt).
    static let amonMono = Font.system(size: 13, design: .monospaced)
}
