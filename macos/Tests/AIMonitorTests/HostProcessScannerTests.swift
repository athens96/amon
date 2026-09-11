import XCTest
@testable import AIMonitor

final class HostProcessScannerTests: XCTestCase {
    private func candidate(
        host: String, pid: Int = 100, cwd: String
    ) -> HostProcessScanner.Candidate {
        HostProcessScanner.Candidate(hostApp: host, hostPID: pid, cwd: cwd)
    }

    func testSelectPrefersExactCwdMatch() {
        let picked = HostProcessScanner.select(
            [
                candidate(host: "Terminal", cwd: "/work/other"),
                candidate(host: "Orca", cwd: "/work/proj"),
            ],
            cwd: "/work/proj"
        )
        XCTAssertEqual(picked?.hostApp, "Orca")
    }

    func testSelectFallsBackToUniqueHostWhenNoCwdMatch() {
        // cwd 는 안 맞지만 후보 호스트가 하나뿐 — 그 앱으로 본다.
        let picked = HostProcessScanner.select(
            [
                candidate(host: "Paseo", cwd: "/work/a"),
                candidate(host: "Paseo", pid: 200, cwd: "/work/b"),
            ],
            cwd: "/work/proj"
        )
        XCTAssertEqual(picked?.hostApp, "Paseo")
    }

    func testSelectRefusesToGuessAmongMultipleHosts() {
        let picked = HostProcessScanner.select(
            [
                candidate(host: "Paseo", cwd: "/work/a"),
                candidate(host: "Terminal", cwd: "/work/b"),
            ],
            cwd: "/work/proj"
        )
        XCTAssertNil(picked)
    }

    func testSelectEmptyCandidates() {
        XCTAssertNil(HostProcessScanner.select([], cwd: "/work/proj"))
        XCTAssertNil(HostProcessScanner.select([], cwd: nil))
    }

    func testAppBundleNameTakesOutermostBundle() {
        XCTAssertEqual(
            HostProcessScanner.appBundleName(
                inPath: "/Applications/Orca.app/Contents/Frameworks/Orca Helper.app/Contents/MacOS/Orca Helper"
            ),
            "Orca"
        )
        XCTAssertEqual(
            HostProcessScanner.appBundleName(
                inPath: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"
            ),
            "Terminal"
        )
        XCTAssertNil(HostProcessScanner.appBundleName(inPath: "/opt/homebrew/bin/tmux"))
        XCTAssertNil(HostProcessScanner.appBundleName(inPath: ""))
    }

    func testLiveScanDoesNotCrash() {
        // 머신 상태에 의존하므로 내용은 단정하지 않는다 — 크래시/행 없이 도는지만 본다.
        _ = HostProcessScanner.candidates(processName: "claude")
    }

    func testElectronHelpersResolveToTheMainHostPID() {
        let parents: [pid_t: pid_t] = [100: 200, 200: 300, 300: 400, 400: 1]
        let paths: [pid_t: String] = [
            200: "/Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper",
            300: "/Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper",
            400: "/Applications/Paseo.app/Contents/MacOS/Paseo",
        ]
        let host = HostProcessScanner.topmostBundleAncestor(
            startingAt: 100, parent: { parents[$0] }, executablePath: { paths[$0] }
        )
        XCTAssertEqual(host?.name, "Paseo")
        XCTAssertEqual(host?.pid, 400)
    }

    func testAncestorStopsAtAnotherAppOrOutsideTheBundle() {
        for outside in [
            "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal",
            "/Other/Paseo.app/Contents/MacOS/Paseo",
            "/usr/bin/python3",
        ] {
            let parents: [pid_t: pid_t] = [100: 200, 200: 300, 300: 400]
            let paths: [pid_t: String] = [
                200: "/Applications/Paseo.app/Contents/MacOS/Paseo",
                300: outside,
                400: "/Applications/Paseo.app/Contents/MacOS/Paseo",
            ]
            let host = HostProcessScanner.topmostBundleAncestor(
                startingAt: 100, parent: { parents[$0] }, executablePath: { paths[$0] }
            )
            XCTAssertEqual(host?.pid, 200, outside)
        }
    }

    func testAncestorHandlesMissingPathsAndNeverInventsATmuxHost() {
        let parents: [pid_t: pid_t] = [100: 200, 200: 300, 300: 1]
        let paths: [pid_t: String] = [200: "/opt/homebrew/bin/tmux", 300: "/usr/bin/login"]
        XCTAssertNil(HostProcessScanner.topmostBundleAncestor(
            startingAt: 100, parent: { parents[$0] }, executablePath: { paths[$0] }
        ))
        XCTAssertNil(HostProcessScanner.topmostBundleAncestor(
            startingAt: 100, parent: { parents[$0] }, executablePath: { _ in nil }
        ))
    }

    func testAncestorLookupIsBoundedForChangingProcessTrees() {
        var visits = 0
        let host = HostProcessScanner.topmostBundleAncestor(
            startingAt: 100,
            parent: { $0 == 100 ? 200 : 100 },
            executablePath: { _ in
                visits += 1
                return "/Applications/Paseo.app/Contents/MacOS/Paseo"
            }
        )
        XCTAssertEqual(host?.name, "Paseo")
        XCTAssertLessThanOrEqual(visits, 2)
        XCTAssertNil(HostProcessScanner.topmostBundleAncestor(
            startingAt: 100, parent: { $0 + 1 }, executablePath: { _ in nil }, maxDepth: 0
        ))
    }

    func testOutermostBundlePathPreservesSpacesAndInstallationDirectory() {
        XCTAssertEqual(HostProcessScanner.outermostBundlePath(
            inPath: "/Users/test/Applications/Paseo Preview.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"
        ), "/Users/test/Applications/Paseo Preview.app")
        XCTAssertNil(HostProcessScanner.outermostBundlePath(inPath: "/opt/homebrew/bin/codex"))
    }
}
