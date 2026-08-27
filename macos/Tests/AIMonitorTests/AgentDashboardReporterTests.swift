import XCTest
@testable import AIMonitor

final class AgentDashboardReporterTests: XCTestCase {
    func testEndpointAcceptsBaseURLAndFullReportURL() {
        XCTAssertEqual(
            AgentDashboardReporter.endpoint(from: " https://amon.example/ ")?.absoluteString,
            "https://amon.example/api/v1/ai-agents/report"
        )
        XCTAssertEqual(
            AgentDashboardReporter.endpoint(
                from: "https://amon.example/api/v1/ai-agents/report"
            )?.absoluteString,
            "https://amon.example/api/v1/ai-agents/report"
        )
    }

    func testUploadSignatureNormalizesWhitespace() {
        let first = AgentDashboardReporter.uploadSignature(
            contentSignature: "content",
            serverURL: " https://amon.example/ ",
            userKey: " amon-key "
        )
        let second = AgentDashboardReporter.uploadSignature(
            contentSignature: "content",
            serverURL: "https://amon.example",
            userKey: "amon-key"
        )
        XCTAssertEqual(first, second)
    }

    func testUploadSignatureChangesWhenUserKeyChanges() {
        let first = AgentDashboardReporter.uploadSignature(
            contentSignature: "same-content",
            serverURL: "https://amon.example",
            userKey: "amon-key-1"
        )
        let second = AgentDashboardReporter.uploadSignature(
            contentSignature: "same-content",
            serverURL: "https://amon.example",
            userKey: "amon-key-2"
        )
        XCTAssertNotEqual(first, second)
    }

    func testRetryDelayUsesBoundedExponentialBackoff() {
        XCTAssertEqual(AgentDashboardReporter.retryDelay(forAttempt: 1), 15)
        XCTAssertEqual(AgentDashboardReporter.retryDelay(forAttempt: 2), 30)
        XCTAssertEqual(AgentDashboardReporter.retryDelay(forAttempt: 3), 60)
        XCTAssertEqual(AgentDashboardReporter.retryDelay(forAttempt: 6), 300)
        XCTAssertEqual(AgentDashboardReporter.retryDelay(forAttempt: 20), 300)
    }

    func testOnlyTransientHTTPStatusesAreRetried() {
        for status in [408, 425, 429, 500, 502, 503, 599] {
            XCTAssertTrue(AgentDashboardReporter.isRetryableHTTPStatus(status), "status \(status)")
        }
        for status in [400, 401, 403, 404, 413, 422, 426] {
            XCTAssertFalse(AgentDashboardReporter.isRetryableHTTPStatus(status), "status \(status)")
        }
    }

    func testPermanentUploadErrorsDoNotRetry() {
        let permanent = AgentDashboardReporter.UploadError(
            message: "유효하지 않은 유저 키입니다",
            retryable: false
        )
        let transient = AgentDashboardReporter.UploadError(
            message: "서버 오류 503",
            retryable: true
        )

        XCTAssertFalse(AgentDashboardReporter.shouldRetry(permanent))
        XCTAssertTrue(AgentDashboardReporter.shouldRetry(transient))
        XCTAssertTrue(AgentDashboardReporter.shouldRetry(URLError(.timedOut)))
        XCTAssertFalse(AgentDashboardReporter.shouldRetry(URLError(.badURL)))
    }
}
