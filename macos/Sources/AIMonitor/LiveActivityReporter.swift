import Foundation

/// 살아있는 세션/서브에이전트 스냅샷을 웹 서버로 POST 한다.
///
/// 다른 보고 채널과 같은 패턴 — 베이스 URL + `/api/v1/ai-live/report`, `user_key`
/// 인증, `PinnedHTTP` 세션, 15초 타임아웃, 동일한 상태코드 스위치. 페이로드는
/// 서비스 모니터 AI Live API의 요청 계약과 필드가 1:1로 맞는다.
enum LiveActivityReporter {
    static let reportPath = "/api/v1/ai-live/report"

    /// 베이스 URL → 최종 보고 엔드포인트.
    static func endpoint(from serverURL: String) -> URL? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if !s.contains("/ai-live/report") { s += reportPath }
        return URL(string: s)
    }

    // snake_case 프로퍼티명 직접 사용 — 다른 보고 페이로드와 동일한 컨벤션(CodingKeys 없음).
    private struct Payload: Encodable {
        let user_key: String
        let sessions: [SessionPayload]
    }

    private struct SessionPayload: Encodable {
        let provider: String
        let session_id: String
        let project_label: String
        let git_branch: String?
        let status: String
        let agents: [AgentPayload]
        let current_task: String?
        let model: String?
        let total_tokens: Int?
        let started_at: Date
    }

    private struct AgentPayload: Encodable {
        let tool_use_id: String
        let agent_type: String
        let description: String
        let started_at: Date
    }

    static func send(serverURL: String, userKey: String, sessions: [LiveSession]) async throws {
        guard let url = endpoint(from: serverURL) else {
            throw ReportError.message("서버 URL이 올바르지 않습니다")
        }
        let key = userKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw ReportError.message("유저 키가 비어 있습니다") }

        let payload = Payload(
            user_key: key,
            sessions: sessions.map { session in
                SessionPayload(
                    provider: session.provider,
                    session_id: session.sessionId,
                    project_label: session.projectLabel,
                    git_branch: session.gitBranch,
                    status: session.status,
                    agents: session.agents.map { agent in
                        AgentPayload(
                            tool_use_id: agent.toolUseId,
                            agent_type: agent.agentType,
                            description: agent.description,
                            started_at: agent.startedAt
                        )
                    },
                    current_task: session.currentTask,
                    model: session.model,
                    total_tokens: session.totalTokens,
                    started_at: session.startedAt
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15
        request.httpBody = try encoder.encode(payload)

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
