import Foundation

/// 종료된 세션 기록을 웹 서버로 POST 한다.
///
/// `LiveActivityReporter` 와 같은 패턴 — 베이스 URL + `/api/v1/ai-live/history`,
/// `user_key` 인증, `PinnedHTTP` 세션, 15초 타임아웃. `SessionRecord` 의 CodingKeys
/// 가 이미 snake_case 라 백엔드 `AISessionHistoryReport` 계약과 그대로 맞는다.
enum SessionHistoryReporter {
    static let reportPath = "/api/v1/ai-live/history"

    static func endpoint(from serverURL: String) -> URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("/ai-live/history") { s += reportPath }
        return URL(string: s)
    }

    private struct Payload: Encodable {
        let user_key: String
        let sessions: [SessionRecord]
    }

    static func send(serverURL: String, userKey: String, sessions: [SessionRecord]) async throws {
        guard !sessions.isEmpty else { return }
        guard let url = endpoint(from: serverURL) else {
            throw ReportError.message("서버 URL이 올바르지 않습니다")
        }
        let key = userKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ReportError.message("유저 키가 비어 있습니다") }

        // `sourcePath` 는 이 기기의 로그 파일 경로 — 상세 화면에서만 쓰는 로컬 값이라
        // 서버로 보내지 않는다(Optional 이라 nil 이면 키 자체가 빠진다).
        let payload = sessions.map { record -> SessionRecord in
            var copy = record
            copy.sourcePath = nil
            return copy
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try AmonJSON.encoder().encode(
            Payload(user_key: key, sessions: payload)
        )

        let (data, response) = try await PinnedHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReportError.message("서버 응답을 받지 못했습니다")
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401:
            throw ReportError.message("유효하지 않은 유저 키입니다")
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            let tail = body.isEmpty ? "" : ": \(body.prefix(120))"
            throw ReportError.message("서버 오류 \(http.statusCode)\(tail)")
        }
    }
}
