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

    private func app(
        _ pid: pid_t, name: String = "Paseo", path: String = "/Applications/Paseo.app",
        regular: Bool = true, terminated: Bool = false
    ) -> PetSessionHost.ApplicationSnapshot {
        PetSessionHost.ApplicationSnapshot(
            pid: pid, name: name, bundlePath: path, isRegular: regular, isTerminated: terminated
        )
    }

    func testHelperPIDIsPromotedToItsExactRunningMainBundle() {
        let helper = app(200, name: "Paseo Helper",
                         path: "/Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app", regular: false)
        let main = app(400)
        let otherInstallation = app(500, path: "/Other/Paseo.app")
        XCTAssertEqual(PetSessionHost.resolveApplication(
            hostApp: nil, recorded: helper, running: [otherInstallation, helper, main]
        ), main)
    }

    func testHelperWithoutRunningRegularMainAppCannotBeActivated() {
        let helper = app(200, name: "Paseo Helper",
                         path: "/Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app", regular: false)
        XCTAssertNil(PetSessionHost.resolveApplication(
            hostApp: "Paseo Helper", recorded: helper, running: [helper, app(400, terminated: true)]
        ))
        XCTAssertNil(PetSessionHost.resolveApplication(
            hostApp: "Paseo", recorded: app(400, regular: false), running: [app(400, regular: false)]
        ))
    }

    func testHostNameFindsRestartedAppButNeverATerminatedOrAccessoryApp() {
        let restarted = app(500, name: "Localized Name")
        XCTAssertEqual(PetSessionHost.resolveApplication(
            hostApp: " Paseo\n", recorded: app(400, terminated: true),
            running: [app(200, regular: false), app(400, terminated: true), restarted]
        ), restarted)
    }

    func testInvalidPIDDoesNotTrapOrResolveAnUnrelatedApp() {
        XCTAssertNil(PetSessionHost.resolveRunningApp(hostApp: nil, hostPID: Int.max))
        XCTAssertNil(PetSessionHost.resolveRunningApp(hostApp: nil, hostPID: -1))
    }

    func testMainBundleIsNotMistakenForAHelper() {
        XCTAssertNil(PetSessionHost.outerBundlePath(for: "/Applications/Paseo.app"))
        XCTAssertNil(PetSessionHost.outerBundlePath(for: "/Applications/Paseo.app/"))
        XCTAssertEqual(PetSessionHost.outerBundlePath(
            for: "/Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app"
        ), "/Applications/Paseo.app")
    }

    private final class ActivationHarness {
        var canActivate = true
        var active = false
        var requestAccepted = true
        var requests: [String] = []
        var scheduled: [() -> Void] = []

        var actions: PetSessionHost.ActivationActions {
            .init(
                canActivate: { self.canActivate },
                isActive: { self.active },
                requestActivation: {
                    self.requests.append("activate")
                    return self.requestAccepted
                },
                openApplication: { completion in
                    self.requests.append("workspace")
                    completion()
                },
                activateViaScript: { self.requests.append("script") },
                schedule: { _, action in self.scheduled.append(action) }
            )
        }

        func advance() {
            guard !scheduled.isEmpty else { return }
            scheduled.removeFirst()()
        }
    }

    func testAcceptedButIgnoredActivationFallsBackAfterCheckingTheWindow() {
        let h = ActivationHarness()
        PetSessionHost.activate(using: h.actions)
        XCTAssertEqual(h.requests, ["activate"])
        h.advance()
        XCTAssertEqual(h.requests, ["activate", "workspace"])
        h.advance()
        XCTAssertEqual(h.requests, ["activate", "workspace", "script"])
    }

    func testActualActivationSuccessStopsFurtherFallbacks() {
        for succeedsAtWorkspace in [false, true] {
            let h = ActivationHarness()
            h.requestAccepted = false  // 반환값보다 실제 상태가 우선이다.
            PetSessionHost.activate(using: h.actions)
            if succeedsAtWorkspace { h.advance() }
            h.active = true
            h.advance()
            XCTAssertEqual(h.requests, succeedsAtWorkspace ? ["activate", "workspace"] : ["activate"])
        }
    }

    func testTerminatedHelperOrSupersededRequestNeverReopensTheHost() {
        for cancelAfterWorkspace in [false, true] {
            let h = ActivationHarness()
            PetSessionHost.activate(using: h.actions)
            if cancelAfterWorkspace { h.advance() }
            h.canActivate = false
            h.advance()
            XCTAssertEqual(h.requests, cancelAfterWorkspace ? ["activate", "workspace"] : ["activate"])
        }
        let unavailable = ActivationHarness()
        unavailable.canActivate = false
        PetSessionHost.activate(using: unavailable.actions)
        XCTAssertTrue(unavailable.requests.isEmpty)
    }

    func testAppleScriptUsesLiteralBundleIDAndEscapesFallbackAppNames() {
        XCTAssertEqual(PetSessionHost.activationScript(bundleID: "app.paseo", name: "Paseo Helper"),
                       "tell application id \"app.paseo\" to activate")
        XCTAssertEqual(PetSessionHost.activationScript(bundleID: nil, name: "A \"Preview\"\\App"),
                       "tell application \"A \\\"Preview\\\"\\\\App\" to activate")
        XCTAssertNil(PetSessionHost.activationScript(bundleID: nil, name: ""))
    }
}
