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
}
