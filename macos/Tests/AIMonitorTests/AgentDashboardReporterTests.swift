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
}
