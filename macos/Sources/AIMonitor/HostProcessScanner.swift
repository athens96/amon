import Darwin
import Foundation

/// 살아있는 CLI 프로세스(claude·codex)에서 호스트 앱을 재탐지한다.
///
/// 세션 파일의 host_app/host_pid 는 훅이 기록한 시점의 것이라, 같은 세션을 두
/// 호스트가 쓰다가 기록된 쪽이 종료되면 낡은 값이 남는다. 이때 말풍선 클릭이
/// 조용히 실패하는 대신, 지금 떠 있는 CLI 프로세스들의 부모 체인을 훑어 같은
/// 세션(cwd 일치)의 다른 호스트 앱을 찾는다. 훅의 detect_host 와 같은 원리를
/// libproc 으로 프로세스 생성 없이 수행한다(클릭 시점 1회, 수 ms).
enum HostProcessScanner {
    struct Candidate: Equatable {
        /// 부모 체인에서 찾은 가장 바깥 .app 번들 이름.
        let hostApp: String
        /// 그 .app 프로세스의 PID.
        let hostPID: Int
        /// CLI 프로세스의 작업 디렉토리 — 세션 cwd 와 매칭한다.
        let cwd: String
    }

    /// 이름이 processName 인 모든 프로세스의 (호스트 앱, cwd) 후보.
    static func candidates(processName: String) -> [Candidate] {
        allPIDs().compactMap { pid -> Candidate? in
            guard matches(pid, processName: processName),
                  let cwd = workingDirectory(of: pid),
                  let host = hostAncestor(of: pid)
            else { return nil }
            return Candidate(hostApp: host.name, hostPID: Int(host.pid), cwd: cwd)
        }
    }

    /// claude CLI 는 버전명 실행파일로 exec 되어 커널 p_comm 이 "2.1.226" 같은
    /// 버전 문자열이다(실측). ps/pgrep 이 보여주는 이름은 argv[0]이므로, p_comm 이
    /// 안 맞으면 argv[0] 마지막 경로 성분으로 한 번 더 판정한다(codex 는 p_comm 으로 끝).
    private static func matches(_ pid: pid_t, processName: String) -> Bool {
        if name(of: pid) == processName { return true }
        guard let argv0 = argv0(of: pid) else { return false }
        return (argv0 as NSString).lastPathComponent == processName
    }

    /// KERN_PROCARGS2 레이아웃: argc(Int32) | exec_path\0 | \0패딩 | argv[0]\0 | …
    /// 같은 사용자 프로세스만 읽힌다 — CLI 는 항상 본인 소유라 충분하다.
    private static func argv0(of pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }  // exec_path
        while index < size, buffer[index] == 0 { index += 1 }  // 패딩
        let start = index
        while index < size, buffer[index] != 0 { index += 1 }
        guard index > start else { return nil }
        return String(bytes: buffer[start..<index], encoding: .utf8)
    }

    /// 후보 중 이동할 하나를 고르는 순수 로직.
    ///
    /// cwd 가 정확히 일치하는 프로세스가 최우선(같은 세션을 이어받은 다른 호스트).
    /// 일치가 없어도 후보의 호스트 앱이 단 하나뿐이면 그 앱으로 본다 — 세션이
    /// 어디서 돌든 그 앱밖에 없다는 뜻이다. 여러 앱이 섞여 있으면 추측하지 않는다.
    static func select(_ candidates: [Candidate], cwd: String?) -> Candidate? {
        if let cwd, !cwd.isEmpty,
           let match = candidates.first(where: { $0.cwd == cwd }) {
            return match
        }
        let hosts = Set(candidates.map(\.hostApp))
        guard hosts.count == 1 else { return nil }
        return candidates.first
    }

    /// 실행 경로에서 가장 바깥 .app 번들 이름을 뽑는다 — 훅 detect_host 의
    /// `/([^/]+)\.app/` 첫 매칭과 같은 규칙(헬퍼 프로세스도 본체 앱 이름이 나온다).
    static func appBundleName(inPath path: String) -> String? {
        guard let appRange = path.range(of: ".app/") else { return nil }
        let prefix = path[..<appRange.lowerBound]
        guard let slash = prefix.lastIndex(of: "/") else { return nil }
        let name = prefix[prefix.index(after: slash)...]
        return name.isEmpty ? nil : String(name)
    }

    // MARK: - libproc 래퍼

    private static func allPIDs() -> [pid_t] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        // 스냅샷 사이에 프로세스가 늘 수 있어 여유를 둔다.
        var pids = [pid_t](repeating: 0, count: Int(needed) + 64)
        let written = proc_listallpids(
            &pids, Int32(pids.count * MemoryLayout<pid_t>.size)
        )
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written))).filter { $0 > 0 }
    }

    private static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return info
    }

    /// p_comm(16자 잘림) — CLI 이름 매칭에는 충분하다("claude", "codex").
    private static func name(of pid: pid_t) -> String? {
        guard let info = bsdInfo(of: pid) else { return nil }
        return withUnsafeBytes(of: info.pbi_comm) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else {
                return nil
            }
            return String(cString: base)
        }
    }

    private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        return withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else {
                return nil
            }
            return String(cString: base)
        }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 부모 체인을 따라 가장 가까운 GUI 앱(.app)을 찾는다 — 훅 detect_host 와 동일.
    private static func hostAncestor(of pid: pid_t) -> (name: String, pid: pid_t)? {
        var current = bsdInfo(of: pid)?.pbi_ppid
        for _ in 0..<15 {
            guard let raw = current, raw > 1 else { return nil }
            let ancestor = pid_t(raw)
            if let path = executablePath(of: ancestor),
               let app = appBundleName(inPath: path) {
                return (app, ancestor)
            }
            current = bsdInfo(of: ancestor)?.pbi_ppid
        }
        return nil
    }
}
