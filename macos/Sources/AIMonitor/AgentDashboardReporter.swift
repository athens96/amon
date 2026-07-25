import CryptoKit
import Foundation

/// 로컬 `usage.db` 스냅샷을 에이전트 대시보드 서버로 업로드한다.
///
/// 다른 보고 채널과 같은 패턴 — 베이스 URL + `/api/v1/ai-agents/report`, `user_key`
/// 인증, `PinnedHTTP` 세션, 15초 타임아웃. 다만 JSON 이 아니라 multipart/form-data 로
/// (user_key 필드 + db 파일) 을 보낸다. 변경 감지(SHA-256)는 호출부(AppState)가 맡는다.
enum AgentDashboardReporter {
    static let reportPath = "/api/v1/ai-agents/report"

    /// 베이스 URL → 최종 업로드 엔드포인트 URL.
    static func endpoint(from serverURL: String) -> URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("/ai-agents/report") { s += reportPath }
        return URL(string: s)
    }

    /// 파일의 SHA-256(hex) — 내용 변경 감지용. 실패 시 nil.
    static func sha256(of fileURL: URL) -> String? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 업로드 변경 감지용 서명. 콘텐츠뿐 아니라 정규화한 목적지와 유저 키도 포함하므로
    /// 웹에서 키를 재발급하거나 다른 계정 키로 교체하면 같은 데이터도 한 번 다시 전송된다.
    /// 저장되는 값은 SHA-256뿐이라 유저 키 원문은 사이드카/UserDefaults에 추가로 남지 않는다.
    static func uploadSignature(
        contentSignature: String,
        serverURL: String,
        userKey: String
    ) -> String {
        let destination = endpoint(from: serverURL)?.absoluteString ?? ""
        let key = userKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let data = Data("\(destination)\u{0}\(key)\u{0}\(contentSignature)".utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 스냅샷 db 파일을 multipart 로 업로드한다. 성공 시 서버가 저장한 바이트 수를 돌려준다.
    /// 실패 시 `ReportError` throw (401=유저키 오류, 413=크기 초과).
    @discardableResult
    static func send(serverURL: String, userKey: String, snapshot: URL) async throws -> Int {
        guard let url = endpoint(from: serverURL) else {
            throw ReportError.message("서버 URL이 올바르지 않습니다")
        }
        let key = userKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ReportError.message("유저 키가 비어 있습니다") }
        guard let fileData = try? Data(contentsOf: snapshot) else {
            throw ReportError.message("스냅샷을 읽을 수 없습니다")
        }

        let boundary = "amon-\(UUID().uuidString)"
        var body = Data()
        func append(_ s: String) { body.append(s.data(using: .utf8)!) }

        // user_key 필드
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"user_key\"\r\n\r\n")
        append("\(key)\r\n")
        // db 파일
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"db\"; filename=\"usage-upload.db\"\r\n")
        append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        append("\r\n")
        append("--\(boundary)--\r\n")

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type"
        )
        request.timeoutInterval = 15
        request.httpBody = body

        let (data, response) = try await PinnedHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ReportError.message("서버 응답을 받지 못했습니다")
        }
        switch http.statusCode {
        case 200..<300:
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return (obj?["bytes"] as? Int) ?? fileData.count
        case 401:
            throw ReportError.message("유효하지 않은 유저 키입니다")
        case 413:
            throw ReportError.message("업로드 크기가 서버 제한을 초과했습니다")
        default:
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            let tail = bodyText.isEmpty ? "" : ": \(bodyText.prefix(120))"
            throw ReportError.message("서버 오류 \(http.statusCode)\(tail)")
        }
    }
}
