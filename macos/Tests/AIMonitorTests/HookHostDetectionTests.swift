import Foundation
import XCTest

@testable import AIMonitor

final class HookHostDetectionTests: XCTestCase {
    func testHookRecordsMainPIDAcrossElectronDaemonAndSupervisor() throws {
        let result = try detect([
            "100": "200 /usr/local/bin/claude",
            "200": "300 /Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper",
            "300": "400 /Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper",
            "400": "1 /Applications/Paseo.app/Contents/MacOS/Paseo",
        ])
        XCTAssertEqual(result.host, "Paseo")
        XCTAssertEqual(result.pid, 400)
    }

    func testHookAllowsNameOnlyHelperButStopsAtDifferentAppOrShell() throws {
        let throughName = try detect([
            "100": "200 /Applications/Paseo.app/Contents/Frameworks/Paseo Helper.app/Contents/MacOS/Paseo Helper",
            "200": "300 Paseo Supervisor",
            "300": "1 /Applications/Paseo.app/Contents/MacOS/Paseo",
        ])
        XCTAssertEqual(throughName.pid, 300)
        for outside in [
            "/Applications/Terminal.app/Contents/MacOS/Terminal",
            "/Other/Paseo.app/Contents/MacOS/Paseo",
            "/bin/zsh",
        ] {
            let result = try detect([
                "100": "200 /Applications/Paseo.app/Contents/MacOS/Paseo",
                "200": "300 \(outside)",
                "300": "1 /Applications/Paseo.app/Contents/MacOS/Paseo",
            ])
            XCTAssertEqual(result.pid, 100, outside)
        }
    }

    func testHookKeepsHostUnknownWithoutAGUIAncestor() throws {
        let result = try detect([
            "100": "200 /opt/homebrew/bin/tmux",
            "200": "1 /usr/bin/login",
        ])
        XCTAssertNil(result.host)
        XCTAssertNil(result.pid)
    }

    func testHookKeepsLastVerifiedHostIfAParentExitsDuringLookup() throws {
        let result = try detect([
            "100": "200 /Applications/Paseo Preview.app/Contents/MacOS/Paseo Preview",
        ])
        XCTAssertEqual(result.host, "Paseo Preview")
        XCTAssertEqual(result.pid, 100)
    }

    /// 실제 설치용 스크립트에서 detect_host 만 실행한다.
    /// ps 와 getppid 는 주입한 프로세스 표로 대체해 실호스트·설정에 접근하지 않는다.
    private func detect(_ chain: [String: String]) throws -> (host: String?, pid: Int?) {
        let harness = #"""
import ast, json, re, sys, types
fixture = json.load(sys.stdin)
tree = ast.parse(fixture["source"])
function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == "detect_host")
module = ast.Module(body=[function], type_ignores=[])
def fake_ps(args, **kwargs):
    assert args[:2] == ["/bin/ps", "-p"] and args[3:] == ["-o", "ppid=,comm="]
    value = fixture["chain"].get(args[2])
    return types.SimpleNamespace(returncode=0 if value is not None else 1, stdout=value or "")
namespace = {
    "os": types.SimpleNamespace(getppid=lambda: 100),
    "subprocess": types.SimpleNamespace(run=fake_ps),
    "re": re,
}
exec(compile(module, "live_hook_host_test", "exec"), namespace)
host, pid = namespace["detect_host"]()
json.dump({"host": host, "pid": pid}, sys.stdout)
"""#
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", harness]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: [
            "source": HookInstaller.hookScriptSourceForTesting,
            "chain": chain,
        ]))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(
            data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? "")
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (result["host"] as? String, result["pid"] as? Int)
    }
}
