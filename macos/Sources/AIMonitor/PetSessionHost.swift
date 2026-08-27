import AppKit

/// 세션을 띄운 호스트 앱(.app)이 지금 실행 중인지 확인한다 — 확인될 때만
/// 말풍선 클릭으로 그 앱에 이동한다(확인 실패 시 호출부는 조용히 생략).
enum PetSessionHost {
    /// 1순위는 훅이 기록한 PID(그 프로세스가 GUI 앱으로 살아 있을 때만),
    /// 2순위는 이름 매칭(PID 가 헬퍼 프로세스였거나 앱이 재시작된 경우).
    static func resolveRunningApp(hostApp: String?, hostPID: Int?) -> NSRunningApplication? {
        if let pid = hostPID,
           let app = NSRunningApplication(processIdentifier: pid_t(pid)),
           !app.isTerminated,
           app.activationPolicy != .prohibited {
            return app
        }
        guard let name = hostApp?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.activationPolicy == .regular, !app.isTerminated else { return false }
            return app.localizedName == name
                || app.bundleURL?.lastPathComponent == "\(name).app"
        }
    }

    /// 기록된 호스트가 종료된 경우의 2차 탐지 — 살아있는 CLI 프로세스들에서
    /// 같은 세션(cwd 일치)을 잡고 있는 다른 호스트 앱을 찾는다.
    /// 훅 없이 로그로만 수집하는 codex 도 프로세스 이름으로 같은 방식이 된다.
    static func redetectRunningApp(provider: String, cwd: String?) -> NSRunningApplication? {
        let processName: String
        switch provider {
        case "claude": processName = "claude"
        case "codex": processName = "codex"
        default: return nil  // cursor 는 앱 자체가 호스트 — 재탐지 대상이 아니다
        }
        let candidates = HostProcessScanner.candidates(processName: processName)
        guard let pick = HostProcessScanner.select(candidates, cwd: cwd) else { return nil }
        return resolveRunningApp(hostApp: pick.hostApp, hostPID: pick.hostPID)
    }

    /// 확인된 앱을 앞으로 가져온다.
    ///
    /// A-mon 은 accessory 앱 + 비활성 패널이라 macOS 14+ 협조적 활성화에서
    /// `activate()` 가 조용히 거부될 수 있다. 우리 쪽 활성화 권한을 넘겨준 뒤
    /// 시도하고, 그래도 안 되면 NSWorkspace 로 앱을 여는 폴백을 쓴다 — 이미 실행
    /// 중인 앱은 다시 뜨지 않고 앞으로만 온다.
    static func activate(_ app: NSRunningApplication) {
        let activated: Bool
        if #available(macOS 14.0, *) {
            NSApp.yieldActivation(to: app)
            activated = app.activate()
        } else {
            activated = app.activate(options: [])
        }
        guard !activated, let url = app.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}
