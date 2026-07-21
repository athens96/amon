import Foundation

/// 보고와 업데이트 확인에 사용하는 공용 HTTPS 세션.
/// 공개 인증기관의 시스템 신뢰 저장소를 그대로 사용한다.
enum PinnedHTTP {
    static let session = URLSession(configuration: .ephemeral)
}
