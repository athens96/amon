import Foundation

// openusage HTTPClient 이식 — 프록시(ProxyConfig)·로그 리댁션(LogRedaction)은 제외해 표면을 줄이되,
// 로컬 language server(Antigravity)용 self-signed loopback 신뢰는 그대로 유지한다.

struct HTTPRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 15
}

struct HTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

struct URLSessionHTTPClient: HTTPClient {
    /// true 면 `127.0.0.1` 의 self-signed 인증서를 신뢰하는 loopback 세션 사용(로컬 LS 전용).
    var allowsInsecureLoopback: Bool = false

    private static let session = URLSession(configuration: .default)
    private static let loopbackSession = URLSession(configuration: .ephemeral, delegate: LoopbackTLSDelegate(), delegateQueue: nil)

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let session = allowsInsecureLoopback ? Self.loopbackSession : Self.session
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        // 헤더/바디는 절대 로깅하지 않는다(토큰 유출 방지) — 메서드+상태코드만.
        AppLog.debug(.http, "\(request.method) \(request.url.host ?? "?") -> \(http.statusCode)")
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

enum HTTPClientError: Error, LocalizedError {
    case invalidResponse
    var errorDescription: String? { "Invalid HTTP response." }
}

/// `127.0.0.1` 에 한해 self-signed 서버 인증서를 신뢰한다. 그 외 호스트/챌린지는 기본 검증으로 폴백.
private final class LoopbackTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
