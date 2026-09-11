import AppKit

/// 세션을 띄운 호스트 앱(.app)이 지금 실행 중인지 확인한다 — 확인될 때만
/// 말풍선 클릭으로 그 앱에 이동한다(확인 실패 시 호출부는 조용히 생략).
enum PetSessionHost {
    /// AppKit 객체 없이 오래된 PID·헬퍼·종료 상태의 선택 규칙을 검증한다.
    struct ApplicationSnapshot: Equatable {
        let pid: pid_t
        let name: String?
        let bundlePath: String?
        let isRegular: Bool
        let isTerminated: Bool
    }

    /// 1순위는 훅이 기록한 PID(그 프로세스가 GUI 앱으로 살아 있을 때만),
    /// 2순위는 이름 매칭(PID 가 헬퍼 프로세스였거나 앱이 재시작된 경우).
    static func resolveRunningApp(hostApp: String?, hostPID: Int?) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        let recorded = hostPID.flatMap { pid_t(exactly: $0) }
            .flatMap { $0 > 1 ? NSRunningApplication(processIdentifier: $0) : nil }
        guard let picked = resolveApplication(
            hostApp: hostApp,
            recorded: recorded.map(snapshot),
            running: running.map(snapshot)
        ) else { return nil }
        return ([recorded].compactMap { $0 } + running).first {
            $0.processIdentifier == picked.pid && !$0.isTerminated && $0.activationPolicy == .regular
        }
    }

    static func resolveApplication(
        hostApp: String?, recorded: ApplicationSnapshot?, running: [ApplicationSnapshot]
    ) -> ApplicationSnapshot? {
        let regular = running.filter { $0.isRegular && !$0.isTerminated }
        if let recorded, !recorded.isTerminated {
            if recorded.isRegular { return recorded }
            if let bundle = recorded.bundlePath,
               let outer = outerBundlePath(for: bundle),
               let app = regular.first(where: { $0.bundlePath == outer }) {
                return app
            }
        }
        guard let name = hostApp?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty
        else { return nil }
        return regular.first { app in
            app.name == name || app.bundlePath.map { ($0 as NSString).lastPathComponent } == "\(name).app"
        }
    }

    /// 중첩된 헬퍼가 속한 본체 번들 경로. 이미 본체인 경로는 nil 이다.
    static func outerBundlePath(for bundlePath: String) -> String? {
        let path = bundlePath.hasSuffix("/") ? String(bundlePath.dropLast()) : bundlePath
        guard let outer = HostProcessScanner.outermostBundlePath(inPath: path + "/"),
              outer != path else { return nil }
        return outer
    }

    private static func snapshot(_ app: NSRunningApplication) -> ApplicationSnapshot {
        ApplicationSnapshot(
            pid: app.processIdentifier, name: app.localizedName, bundlePath: app.bundleURL?.path,
            isRegular: app.activationPolicy == .regular, isTerminated: app.isTerminated
        )
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

    struct ActivationActions {
        let canActivate: () -> Bool
        let isActive: () -> Bool
        let requestActivation: () -> Bool
        let openApplication: (@escaping () -> Void) -> Void
        let activateViaScript: () -> Void
        let schedule: (TimeInterval, @escaping () -> Void) -> Void
    }

    /// activate() 의 true 는 요청 접수일 뿐이다. 실제 활성 상태를 확인한 뒤
    /// NSWorkspace → 앱 자체의 AppleScript activate 순으로 폴백한다.
    static func activate(using actions: ActivationActions) {
        guard actions.canActivate() else { return }
        _ = actions.requestActivation()
        actions.schedule(0.25) {
            guard actions.canActivate(), !actions.isActive() else { return }
            actions.openApplication {
                actions.schedule(0.35) {
                    guard actions.canActivate(), !actions.isActive() else { return }
                    actions.activateViaScript()
                }
            }
        }
    }

    private static var activationRequest = UUID()

    /// 어떤 호출 경로에서도 헬퍼를 활성화하거나 그 bundle id 를 스크립트로 열지 않는다.
    static func activate(_ target: NSRunningApplication) {
        let request = UUID()
        activationRequest = request
        guard !target.isTerminated,
              let app = resolveRunningApp(hostApp: nil, hostPID: Int(target.processIdentifier))
        else { return }
        activate(using: ActivationActions(
            canActivate: {
                activationRequest == request && !app.isTerminated && app.activationPolicy == .regular
            },
            isActive: { app.isActive },
            requestActivation: {
                if #available(macOS 14.0, *) {
                    NSApp.yieldActivation(to: app)
                    return app.activate()
                }
                return app.activate(options: [.activateIgnoringOtherApps])
            },
            openApplication: { completion in
                guard let url = app.bundleURL else { return }
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
                    completion()
                }
            },
            activateViaScript: {
                guard let source = activationScript(bundleID: app.bundleIdentifier, name: app.localizedName)
                else { return }
                var error: NSDictionary?
                NSAppleScript(source: source)?.executeAndReturnError(&error)
            },
            schedule: { delay, action in
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
            }
        ))
    }

    static func activationScript(bundleID: String?, name: String?) -> String? {
        func quoted(_ value: String) -> String {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
            return "\"\(escaped)\""
        }
        if let bundleID, !bundleID.isEmpty {
            return "tell application id \(quoted(bundleID)) to activate"
        }
        guard let name, !name.isEmpty else { return nil }
        return "tell application \(quoted(name)) to activate"
    }
}
