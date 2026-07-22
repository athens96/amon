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

    /// 종료된 세션 기록(Claude Code + Codex) — 로컬 저장소에 적재한다.
    let sessionHistory = SessionHistoryManager()

    /// 로컬 사용량 SQLite 저장 계층 — 스캔 결과·세션을 적재한다.
    let usageStore = UsageStore.shared

    /// 도구별 사용량 요약. 초기값은 빈 요약(스캔 전).
    @Published var summaries: [ToolUsageSummary] =
        AITool.allCases.map { ToolUsageSummary(tool: $0) }

    @Published var isScanning = false
    @Published var lastScan: Date? = nil

    /// 라이브 세션 훅 설치("지금 설정 적용") 결과 상태.
    @Published var liveOutcome: ReportOutcome = .idle

    /// 사용 가능한 업데이트(현재보다 높은 버전). 없으면 nil.
    @Published var availableUpdate: UpdateInfo? = nil
    @Published var isInstallingUpdate = false
    @Published var updateError: String? = nil

    /// 현재 아이콘 상태(stage, 0~AppIcons.stageCount-1). 지금은 항상 0(=stage1).
    /// 나중에 상태 로직이 이 값을 바꾸면 메뉴바 아이콘이 해당 스테이지로 교체된다.
    @Published var iconStage: Int = 0

    /// 자동 스캔 주기 (초).
    private let autoReportInterval: TimeInterval = 600  // 10분
    /// 패널 오픈 재스캔 최소 간격 — 직전 스캔이 이보다 최근이면 생략(과도 스캔 방지).
    private let appearThrottle: TimeInterval = 15
    private var autoTask: Task<Void, Never>?

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

        // 새로 적재된 세션 기록을 로컬 SQLite 미러에 upsert한다.
        sessionHistory.onChanged = { [weak self] records in
            guard let self else { return }
            Task.detached(priority: .utility) { [store = usageStore] in
                store.upsert(sessions: records)
            }
        }

        // 앱 실행 즉시 1회 스캔하고 이후 주기 타이머를 건다.
        startAutoReport()
        // 라이브 쿼터도 실행 즉시 감지·조회 + 5분 주기 — 팝오버를 안 열어도
        // 캘리브레이션 표본이 쌓이고 한도 임박 알림이 동작한다.
        liveProviders.start()
        // 라이브 세션 공유가 켜져 있으면(영속 설정) 훅을 멱등 재설치한 뒤 폴링을
        // 시작한다. 앱 업데이트로 내장 훅 스크립트가 바뀐 경우 기존 디스크 스크립트도
        // 자동으로 갱신돼야 한다.
        if settings.liveActivityEnabled {
            applyInstall()
            liveActivity.codexRoot = settings.codexPath
            liveActivity.cursorPath = settings.cursorPath
            liveActivity.start()
        }
        // 세션 기록은 로컬로 계속 쌓는다(Codex 는 훅이 없어도 로그만으로 수집된다).
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

    /// 라이브 세션 공유 토글. 켜면 훅을 설치(결과를 liveOutcome 에)한 뒤 폴링 시작,
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

    /// 오늘 입력/출력/캐시(읽기+쓰기) 합 — 구성 표시용.
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
            }
            let merged = results
            // 스캔 결과를 로컬 SQLite 에 적재한다.
            store.upsert(summaries: merged)
            await MainActor.run {
                self.summaries = merged
                self.lastScan = Date()
                self.isScanning = false
            }
        }
    }

}
