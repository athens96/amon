import AppKit
import CryptoKit
import Foundation

/// 서버가 제공하는 최신 릴리즈 정보.
struct UpdateInfo: Equatable {
    let version: String
    let sha256: String
    let sizeBytes: Int
    let notes: String?
}

enum UpdateError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

/// 앱 자동 업데이트 — 최신 버전 확인 + 다운로드/무결성검증/자가교체.
enum Updater {
    /// 서버 URL(베이스) → `<base>/api/v1`. 전체 경로를 넣어도 정리한다.
    static func apiBase(from serverURL: String) -> String? {
        var s = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        while s.hasSuffix("/") { s.removeLast() }
        if let range = s.range(of: "/api/v1") {
            s = String(s[..<range.lowerBound])
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s + "/api/v1"
    }

    /// 최신 버전을 확인해, 현재보다 높으면 `UpdateInfo` 를 돌려준다.
    /// 릴리즈 없음(404)·오류·동일/구버전이면 nil.
    static func checkLatest(serverURL: String) async -> UpdateInfo? {
        // 서버 릴리즈는 플랫폼(mac|windows)별로 분리된다. 이 앱은 macOS 이므로
        // platform=mac 을 명시한다(서버 기본값도 mac 이라 하위 호환).
        guard let base = apiBase(from: serverURL),
              let url = URL(string: base + "/app/latest?platform=mac")
        else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let (data, response) = try? await PinnedHTTP.session.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = obj["version"] as? String,
              let sha256 = obj["sha256"] as? String
        else { return nil }

        // 현재 버전보다 높을 때만.
        guard compareVersions(version, AppInfo.shortVersion) > 0 else { return nil }

        let size = (obj["size_bytes"] as? Int) ?? 0
        return UpdateInfo(
            version: version, sha256: sha256, sizeBytes: size,
            notes: obj["notes"] as? String
        )
    }

    /// "0.2.0" vs "0.1.0" 수치 비교. a>b: 1, ==: 0, a<b: -1.
    static func compareVersions(_ a: String, _ b: String) -> Int {
        func parts(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } }
        var pa = parts(a), pb = parts(b)
        let n = max(pa.count, pb.count)
        pa += Array(repeating: 0, count: n - pa.count)
        pb += Array(repeating: 0, count: n - pb.count)
        for i in 0..<n where pa[i] != pb[i] { return pa[i] > pb[i] ? 1 : -1 }
        return 0
    }

    /// 업데이트 zip 다운로드 → SHA256 검증 → 압축 해제 → 현재 .app 을 교체하고
    /// 재실행하는 helper 를 띄운 뒤 앱을 종료한다. 성공 시 리턴하지 않고 종료된다.
    @MainActor
    static func install(_ update: UpdateInfo, serverURL: String) async throws {
        let bundlePath = Bundle.main.bundlePath
        guard bundlePath.hasSuffix(".app") else {
            throw UpdateError.message(".app 번들로 실행할 때만 업데이트할 수 있습니다")
        }
        guard let base = apiBase(from: serverURL),
              let url = URL(string: base + "/app/download/" + update.version + "?platform=mac")
        else { throw UpdateError.message("다운로드 URL 이 올바르지 않습니다") }

        // 1) 다운로드
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (data, response) = try await PinnedHTTP.session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.message("다운로드 실패")
        }

        // 2) SHA256 무결성 검증
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest.lowercased() == update.sha256.lowercased() else {
            throw UpdateError.message("무결성 검증 실패 (SHA256 불일치)")
        }

        // 3) 임시 폴더에 저장 + ditto 로 해제
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("AIMonitorUpdate-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let zipURL = work.appendingPathComponent("update.zip")
        try data.write(to: zipURL)
        let extractDir = work.appendingPathComponent("extract")
        try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractDir.path])

        // 4) 해제 결과에서 AIMonitor.app 찾기
        guard let newApp = findApp(in: extractDir) else {
            throw UpdateError.message("압축 파일에서 AIMonitor.app 을 찾지 못했습니다")
        }

        // 5) helper 스크립트: 현재 앱 PID 종료 대기 → 검증된 staged 번들로 교체 → 재실행.
        // 다른 개발/테스트 AIMonitor 프로세스는 기다리지 않는다.
        let script = work.appendingPathComponent("swap.sh")
        try fm.createDirectory(at: AmonPaths.support, withIntermediateDirectories: true)
        let logURL = AmonPaths.support.appendingPathComponent("update.log")
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let body = """
        #!/bin/bash
        set -eu
        DEST="$1"; NEW="$2"; OLD_PID="$3"; LOG="$4"
        STAGED="${DEST}.amon-new-${OLD_PID}"
        BACKUP="${DEST}.amon-backup-${OLD_PID}"

        exec >>"$LOG" 2>&1
        echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] update helper start pid=$OLD_PID dest=$DEST"

        rollback() {
          STATUS=$?
          trap - ERR
          echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] update failed status=$STATUS"
          /bin/rm -rf "$STAGED"
          if [ -e "$BACKUP" ]; then
            /bin/rm -rf "$DEST"
            /bin/mv "$BACKUP" "$DEST"
            echo "previous app restored"
            /usr/bin/open "$DEST" || true
          fi
          exit "$STATUS"
        }
        trap rollback ERR

        for _ in $(/usr/bin/seq 1 120); do
          /bin/kill -0 "$OLD_PID" 2>/dev/null || break
          /bin/sleep 0.5
        done
        if /bin/kill -0 "$OLD_PID" 2>/dev/null; then
          echo "old app did not terminate within 60 seconds"
          false
        fi

        /bin/rm -rf "$STAGED" "$BACKUP"
        /usr/bin/ditto "$NEW" "$STAGED"
        /usr/bin/codesign --verify --deep --strict "$STAGED"

        /bin/mv "$DEST" "$BACKUP"
        /bin/mv "$STAGED" "$DEST"
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
        /usr/bin/open -n "$DEST"

        /bin/rm -rf "$BACKUP"
        trap - ERR
        echo "[$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)] update complete"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)

        // nohup 으로 현재 앱 프로세스와 helper 수명을 분리한다. 모든 출력은 update.log 로 간다.
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        helper.arguments = [
            "/bin/bash", script.path, bundlePath, newApp.path,
            String(currentPID), logURL.path,
        ]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()

        // 6) 현재 앱 종료 → helper 가 교체 후 재실행
        NSApp.terminate(nil)
    }

    // MARK: - helpers

    private static func run(_ launchPath: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw UpdateError.message("\(launchPath) 실패 (\(p.terminationStatus))")
        }
    }

    private static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let url as URL in en where url.lastPathComponent == "AIMonitor.app" {
            return url
        }
        return nil
    }
}
