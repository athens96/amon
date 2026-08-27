import XCTest
@testable import AIMonitor

final class PetSessionHostTests: XCTestCase {
    func testResolveReturnsNilWhenNothingIdentifiable() {
        XCTAssertNil(PetSessionHost.resolveRunningApp(hostApp: nil, hostPID: nil))
        XCTAssertNil(PetSessionHost.resolveRunningApp(hostApp: "   ", hostPID: nil))
    }

    func testResolveIgnoresDeadPIDWithoutName() {
        // 존재하지 않는 PID — 이름 폴백도 없으면 nil 이어야 한다(확인될 때만 이동).
        XCTAssertNil(PetSessionHost.resolveRunningApp(hostApp: nil, hostPID: 99_999_999))
    }

    func testPresentationCarriesHostFromSession() {
        let now = Date()
        let session = LiveSession(
            provider: "claude",
            sessionId: "s1",
            projectLabel: "proj",
            gitBranch: nil,
            status: "active",
            agents: [],
            currentTask: "작업",
            lastResult: nil,
            model: nil,
            totalTokens: nil,
            startedAt: now,
            updatedAt: now,
            hostApp: "Paseo",
            hostPID: 4321
        )
        let presentation = PetStateAdapter.presentation(for: [session])
        XCTAssertEqual(presentation.hostApp, "Paseo")
        XCTAssertEqual(presentation.hostPID, 4321)
    }

    func testIdlePresentationHasNoHost() {
        XCTAssertNil(PetPresentation.idle.hostApp)
        XCTAssertNil(PetPresentation.idle.hostPID)
    }
}
