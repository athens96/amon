import SwiftUI

/// 앱 전역 상태.
///
/// 설정(폴더 경로)과 스캔 결과(도구별 토큰 사용량)를 보관한다. 무거운 파일
/// 파싱은 `Task.detached` 로 백그라운드에서 돌리고, 결과만 메인에서 반영한다.
@MainActor
final class AppState: ObservableObject {
    /// 사용자 설정 — 뷰에는 별도 EnvironmentObject 로도 주입된다.
    let settings = AppSettings()

    /// 라이브 프로바이더 쿼터(9종) 관리자 — 로컬 자격증명을 읽어 세션/주간/크레딧 한도를 조회.
    /// 팝오버에 별도 EnvironmentObject 로 주입된다.
    let liveProviders = LiveProvidersManager()

    /// 쿼터 %→토큰 추론 캘리브레이터 — (로컬 Δ토큰, 쿼터 Δ%) 페어로 개인 환율을 학습한다.
    let quotaCalibrator = QuotaCalibrator()

    /// 쿼터 한도 임박(잔여 10% 미만) macOS 알림.
    let quotaNotifier = QuotaNotifier()

    /// Claude Code 라이브 세션/서브에이전트 폴링 관리자 — 훅이 써 둔 로컬 상태 파일을 읽는다.
    let liveActivity = LiveActivityManager()

    /// 종료된 세션 기록(Claude Code + Codex + Cursor) — 이 기기의 로컬 저장소에만 적재한다.
    let sessionHistory = SessionHistoryManager()

    /// 로컬 사용량 SQLite 저장 계층 — 스캔 결과·세션을 적재하고, 에이전트 대시보드 업로드의 소스.
    let usageStore = UsageStore.shared

    /// 도구별 사용량 요약. 초기값은 빈 요약(스캔 전).
    @Published var summaries: [ToolUsageSummary] =
        AITool.allCases.map { ToolUsageSummary(tool: $0) }

    @Published var isScanning = false
    @Published var lastScan: Date? = nil

    /// 헤더와 메뉴바·아일랜드·펫의 바로가기가 같은 패널 화면을 선택한다.
    @Published var panelScreen: MenuBarContentView.Screen = .dashboard
    @Published var settingsScrollTarget: SettingsSection?

    /// 에이전트 대시보드 업로드 상태.
    @Published var dashboardOutcome: ReportOutcome = .idle

    /// 라이브 세션 훅 설치("지금 설정 적용") 결과 상태.
    @Published var liveOutcome: ReportOutcome = .idle

    /// 사용 가능한 업데이트(현재보다 높은 버전). 없으면 nil.
    @Published var availableUpdate: UpdateInfo? = nil
    @Published var isInstallingUpdate = false
    @Published var updateError: String? = nil

    /// 현재 아이콘 상태. 단일 amon 템플릿을 쓰므로 지금은 항상 0이다.
    /// 나중에 상태 로직이 이 값을 바꾸면 메뉴바 아이콘이 해당 스테이지로 교체된다.
    @Published var iconStage: Int = 0

    /// 자동 스캔·전송 주기 (초). 앱이 떠 있는 동안 이 간격으로 재전송한다.
    private let autoReportInterval: TimeInterval = 600  // 10분
    /// 패널 오픈 재스캔 최소 간격 — 직전 스캔이 이보다 최근이면 생략(과도 스캔 방지).
    private let appearThrottle: TimeInterval = 15
    private var autoTask: Task<Void, Never>?
    private var dashboardSyncTask: Task<Void, Never>?
    private let dashboardSyncDebounce: TimeInterval = 5
    private var dashboardUploadInFlight = false
    private var dashboardSyncRequested = false
    private var dashboardRetryAttempt = 0
    init() {
        // 콜드 스타트: 직전 스캔 결과가 SQLite 에 있으면 즉시 렌더해 빈 화면을 피한다.
        // (스캔은 곧바로 startAutoReport 에서 돌아 최신값으로 덮어쓴다.)
        let stored = usageStore.load()
        if stored.contains(where: { $0.usage.total > 0 }) { summaries = stored }

        // 라이브 쿼터 갱신 때마다: ① 환율 캘리브레이션 표본 기록 ② 한도 임박 알림.
        liveProviders.onRefreshed = { [weak self] snapshots in
            self?.calibrate(snapshots)
            if self?.settings.quotaAlertsEnabled == true {
                self?.quotaNotifier.check(snapshots)
            }
        }

        // 새로 적재된 세션 기록은 로컬 SQLite 미러에만 upsert 한다.
        sessionHistory.onChanged = { [weak self] records in
            guard let self else { return }
            Task.detached(priority: .utility) { [store = usageStore] in
                store.upsert(sessions: records)
                await MainActor.run { self.scheduleAgentDashboardSync() }
            }
        }

        restoreDashboardOutcome()

        // 앱 실행 즉시 1회 스캔·전송하고, 이후 주기 타이머를 건다.
        // (패널을 한 번도 안 열어도 백그라운드로 계속 보고된다.)
        startAutoReport()
        // 라이브 쿼터도 실행 즉시 감지·조회 + 5분 주기 — 팝오버를 안 열어도
        // 캘리브레이션 표본이 쌓이고 한도 임박 알림이 동작한다.
        liveProviders.start()
        // 이 기기의 현재 활동 표시가 켜져 있으면 훅을 멱등 재설치한 뒤 로컬 폴링을
        // 시작한다. 앱 업데이트로 내장 훅 스크립트가 바뀐 경우 기존 디스크 스크립트도
        // 자동으로 갱신돼야 한다.
        if settings.localActivityEnabled {
            applyInstall()
            liveActivity.codexRoot = settings.codexPath
            liveActivity.cursorPath = settings.cursorPath
            liveActivity.start()
        }
        // 세션 기록은 현재 활동 표시 설정과 무관하게 로컬로 계속 쌓는다.
        sessionHistory.claudePath = settings.claudePath
        sessionHistory.codexPath = settings.codexPath
        sessionHistory.cursorPath = settings.cursorPath
        sessionHistory.start()
    }

    /// 쿼터 스냅샷의 % 미터와 현재 로컬 누적 토큰을 페어로 캘리브레이터에 기록한다.
    /// 로컬 스캔(10분)과 쿼터 갱신(5분)의 주기 차이는 EWMA 가 평활한다.
    private func calibrate(_ snapshots: [ProviderSnapshot]) {
        for snapshot in snapshots {
            guard let tool = QuotaCalibrator.providerToTool[snapshot.providerID],
                  let summary = summaries.first(where: { $0.tool == tool })
            else { continue }
            for line in snapshot.lines {
                guard case .progress(let label, let used, _, .percent, _, _, _) = line else { continue }
                quotaCalibrator.record(
                    providerID: snapshot.providerID,
                    label: label,
                    usedPercent: used,
                    cumulativeTokens: summary.usage.total
                )
            }
        }
    }

    /// 이 기기의 현재 활동 표시 토글. 켜면 훅을 설치한 뒤 로컬 폴링을 시작하고,
    /// 끄면 폴링을 멈추고 훅을 제거한다.
    func setLiveActivity(enabled: Bool) {
        if enabled {
            applyInstall()
            liveActivity.codexRoot = settings.codexPath
            liveActivity.cursorPath = settings.cursorPath
            liveActivity.start()
        } else {
            liveActivity.stop()
            _ = HookInstaller.uninstall()
            liveOutcome = .idle
        }
    }

    /// 훅을 다시 설치한다("지금 설정 적용" 버튼) — 외부에서 settings.json 이 초기화된
    /// 경우 복구용. 성공/실패를 liveOutcome 으로 표시한다.
    func reinstallLiveHooks() {
        applyInstall()
    }

    private func applyInstall() {
        switch HookInstaller.install() {
        case .success:
            liveOutcome = .success(Date())
        case .failure(let error):
            liveOutcome = .failure(error.localizedDescription)
        }
    }

    /// 모든 도구 오늘 총 토큰.
    var grandToday: Int { summaries.reduce(0) { $0 + $1.today.total } }

    /// 오늘 입력/출력/캐시(읽기+쓰기) 합 — 집계 구성 표시용.
    var grandTodayInput: Int { summaries.reduce(0) { $0 + $1.today.input } }
    var grandTodayOutput: Int { summaries.reduce(0) { $0 + $1.today.output } }
    var grandTodayCache: Int {
        summaries.reduce(0) { $0 + $1.today.cacheRead + $1.today.cacheWrite }
    }

    /// 어제(로컬 "yyyy-MM-dd") 전체 도구 합산 사용량 — 히어로 카드 전일 대비 표시용.
    var grandYesterday: TokenUsage {
        guard let day = Calendar.current.date(byAdding: .day, value: -1, to: Date()) else {
            return TokenUsage()
        }
        let key = UsageScanner.dayKey(day)
        return summaries.reduce(TokenUsage()) { $0 + ($1.daily[key] ?? TokenUsage()) }
    }

    /// 모든 도구 전체 누적 토큰.
    var grandTotal: Int { summaries.reduce(0) { $0 + $1.usage.total } }

    /// 아이콘 상태(stage)를 바꾼다 — 메뉴바 아이콘이 해당 스테이지로 교체된다.
    /// (지금은 호출부가 없고, 나중에 상태 로직에서 사용.)
    func setIconStage(_ stage: Int) {
        iconStage = min(max(stage, 0), AppIcons.stageCount - 1)
    }

    /// 실행 중 주기적으로(autoReportInterval) 스캔·전송. 앱당 1회만 시작.
    func startAutoReport() {
        guard autoTask == nil else { return }
        scan(priority: .utility)  // 실행 즉시 1회 — 사용자 대기 없는 백그라운드 작업
        checkForUpdate()
        autoTask = Task { [weak self] in
            guard let interval = self?.autoReportInterval else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                // 주기 스캔은 .utility — 24/7 상주 앱이 사용자 인터랙션 우선순위로
                // 돌면 배터리/발열 coalescing 에 불리하다.
                self?.scan(priority: .utility)
                self?.checkForUpdate()
            }
        }
    }

    /// 서버에서 최신 버전을 확인해 현재보다 높으면 `availableUpdate` 를 채운다.
    /// 자동 설치가 켜져 있으면(기본) 발견 즉시 설치까지 진행한다 — 시작 시 1회 +
    /// 10분 주기라 앱을 재실행하지 않아도 새 릴리즈가 알아서 반영된다.
    func checkForUpdate() {
        let serverURL = settings.serverURL
        guard !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            let info = await Updater.checkLatest(serverURL: serverURL)
            self.availableUpdate = info
            if info != nil, self.settings.autoUpdateEnabled, !self.isInstallingUpdate {
                self.installUpdate()
            }
        }
    }

    /// 감지된 업데이트를 다운로드·설치한다. 성공 시 앱이 종료·재실행된다.
    func installUpdate() {
        guard let update = availableUpdate, !isInstallingUpdate else { return }
        let serverURL = settings.serverURL
        isInstallingUpdate = true
        updateError = nil
        Task {
            do {
                try await Updater.install(update, serverURL: serverURL)
            } catch {
                self.updateError = error.localizedDescription
                self.isInstallingUpdate = false
            }
        }
    }

    /// 패널이 열릴 때 재스캔 — 직전 스캔이 아주 최근이면 생략(과도 스캔 방지).
    func scanOnAppear() {
        if let last = lastScan, Date().timeIntervalSince(last) < appearThrottle { return }
        scan()
    }

    /// 현재 설정 경로로 사용량을 다시 스캔한다.
    /// - Parameter priority: 팝오버/버튼 등 인터랙티브 경로는 기본 `.userInitiated`,
    ///   타이머 구동 백그라운드 스캔은 `.utility` 로 호출한다.
    func scan(priority: TaskPriority = .userInitiated) {
        guard !isScanning else { return }
        isScanning = true

        // 경로는 메인에서 읽어 값으로 캡처(스레드 경계 안전).
        let claude = settings.claudePath
        let codex = settings.codexPath
        // 설정에서 경로를 바꿨어도 따라가게
        sessionHistory.claudePath = claude
        sessionHistory.codexPath = codex
        sessionHistory.cursorPath = settings.cursorPath
        liveActivity.codexRoot = codex
        liveActivity.cursorPath = settings.cursorPath
        let openCode = settings.openCodePath
        let cursor = settings.cursorPath
        let gemini = settings.geminiPath
        let qwen = settings.qwenPath
        let copilot = settings.copilotPath

        Task.detached(priority: priority) { [store = usageStore] in
            var results = UsageScanner.scanAll(
                claude: claude, codex: codex, openCode: openCode, cursor: cursor,
                gemini: gemini, qwen: qwen, copilot: copilot
            )
            // Cursor 소비 폴백 — 최신 Cursor 는 로컬 DB 버블에 tokenCount 를 더 이상
            // 기록하지 않아(2025-12 이후 항상 0) 대시보드 CSV 로 최근 창을 채운다.
            // 자격증명이 없거나 오프라인이면 nil — DB 스캔 값 그대로.
            if let events = await CursorUsageEvents.fetchDaily() {
                CursorUsageEvents.merge(into: &results, result: events)
                // 세션별 토큰 추정 캐시도 같은 응답으로 갱신 — 별도 네트워크 절약.
                CursorSessionTokens.store(events: events.rawEvents)
            }
            let merged = results
            // 스캔 결과를 로컬 SQLite 에 적재 (스냅샷 업로드·다음 콜드 스타트의 소스).
            store.upsert(summaries: merged)
            await MainActor.run {
                self.summaries = merged
                self.lastScan = Date()
                self.isScanning = false
                // 에이전트 대시보드 동기화(서버 연동 설정됨 + 내용 변경 시).
                self.scheduleAgentDashboardSync()
            }
        }
    }

    /// 로컬 usage.db 스냅샷을 에이전트 대시보드 서버로 업로드한다.
    /// 별도 토글 없이 서버 연동(URL+유저 키) 설정이 곧 전송 동의다.
    /// - 자동(스캔 사이클 끝): 서버 설정됨 + 직전 업로드 대비 내용 변경 시에만 전송.
    /// - 수동("지금 전송"): 변경 감지 없이 즉시 시도.
    func syncAgentDashboard(manual: Bool = false) {
        if manual {
            dashboardSyncTask?.cancel()
            dashboardSyncTask = nil
        }
        guard settings.reportConfigured else {
            if manual { recordDashboardFailure("서버 URL과 유저 키를 먼저 입력하세요") }
            return
        }
        if dashboardUploadInFlight {
            dashboardSyncRequested = true
            return
        }

        let serverURL = settings.serverURL
        let userKey = settings.userKey
        let lastSig = settings.dashboardLastUploadSHA
        dashboardUploadInFlight = true
        dashboardOutcome = .sending

        Task { [store = usageStore] in
            // 논리 콘텐츠 서명(generated_at 제외)으로 변경 감지 — 파일 SHA 는 스캔마다
            // generated_at 이 바뀌어 항상 달라지므로 쓸 수 없다. 자동은 변경 시에만,
            // 수동("지금 전송")은 항상 전송한다.
            let contentSig =
                await Task.detached(priority: .utility) { store.contentSignature() }.value
            let sig = AgentDashboardReporter.uploadSignature(
                contentSignature: contentSig,
                serverURL: serverURL,
                userKey: userKey
            )
            if !manual, !sig.isEmpty, sig == lastSig {
                self.restoreDashboardOutcome()
                self.finishDashboardUpload()
                return
            }

            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("amon-usage-upload-\(UUID().uuidString).db")
            defer { try? FileManager.default.removeItem(at: tmp) }
            let snapshot = await Task.detached(priority: .utility) {
                store.uploadSnapshot(to: tmp)
            }.value
            guard let snapshot else {
                self.recordDashboardFailure("스냅샷 생성 실패")
                self.scheduleDashboardRetryAfterFailure()
                return
            }
            self.settings.dashboardLastUploadAttemptAt = Date()
            do {
                _ = try await AgentDashboardReporter.send(
                    serverURL: serverURL, userKey: userKey, snapshot: snapshot
                )
                let succeededAt = Date()
                if !sig.isEmpty { self.settings.dashboardLastUploadSHA = sig }
                self.settings.dashboardLastUploadSuccessAt = succeededAt
                self.settings.dashboardLastUploadError = nil
                self.settings.dashboardLastUploadErrorAt = nil
                self.dashboardRetryAttempt = 0
                self.dashboardOutcome = .success(succeededAt)
                self.finishDashboardUpload()
            } catch {
                self.recordDashboardFailure(error.localizedDescription)
                if AgentDashboardReporter.shouldRetry(error) {
                    self.scheduleDashboardRetryAfterFailure()
                } else {
                    self.finishDashboardUpload()
                }
            }
        }
    }

    private func scheduleAgentDashboardSync(after delay: TimeInterval? = nil) {
        guard settings.reportConfigured else { return }
        dashboardSyncTask?.cancel()
        let nanoseconds = UInt64((delay ?? dashboardSyncDebounce) * 1_000_000_000)
        dashboardSyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanoseconds)
            if Task.isCancelled { return }
            guard let self else { return }
            self.dashboardSyncTask = nil
            self.syncAgentDashboard()
        }
    }

    private func finishDashboardUpload(retryAfter: TimeInterval? = nil) {
        dashboardUploadInFlight = false
        if dashboardSyncRequested {
            dashboardSyncRequested = false
            scheduleAgentDashboardSync(after: 1)
        } else if let retryAfter {
            scheduleAgentDashboardSync(after: retryAfter)
        }
    }

    private func scheduleDashboardRetryAfterFailure() {
        dashboardRetryAttempt += 1
        finishDashboardUpload(
            retryAfter: AgentDashboardReporter.retryDelay(forAttempt: dashboardRetryAttempt)
        )
    }

    private func recordDashboardFailure(_ message: String) {
        let now = Date()
        settings.dashboardLastUploadError = message
        settings.dashboardLastUploadErrorAt = now
        dashboardOutcome = .failure(message)
    }

    private func restoreDashboardOutcome() {
        let successAt = settings.dashboardLastUploadSuccessAt
        let errorAt = settings.dashboardLastUploadErrorAt
        if let message = settings.dashboardLastUploadError,
           let errorAt,
           successAt == nil || errorAt > successAt! {
            dashboardOutcome = .failure(message)
        } else if let successAt {
            dashboardOutcome = .success(successAt)
        } else {
            dashboardOutcome = .idle
        }
    }

}
