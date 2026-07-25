import SwiftUI

/// 앱 버전 정보 (Info.plist 기준).
enum AppInfo {
    /// "v0.1.0 (1)" 형태.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(short) (\(build))"
    }

    /// "0.1.0" — 자동 업데이트 비교용 순수 버전.
    static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}

/// 사용량을 수집하는 로컬 AI 코딩 도구.
///
/// 각 도구는 홈 디렉토리 아래 고유한 로그 저장소를 가진다. 기본 경로는
/// `defaultPath` 로 제공하되, 사용자가 설정 화면에서 바꿀 수 있다.
enum AITool: String, CaseIterable, Identifiable, Codable {
    case claudeCode
    case codex
    case openCode
    case cursor
    case gemini
    case qwen
    case copilot

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex CLI"
        case .openCode: return "OpenCode"
        case .cursor: return "Cursor"
        case .gemini: return "Gemini CLI"
        case .qwen: return "Qwen Code"
        case .copilot: return "Copilot CLI"
        }
    }

    /// 상태바 카드에 쓰이는 SF Symbol 이름.
    var iconName: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .codex: return "terminal"
        case .openCode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .gemini: return "diamond"
        case .qwen: return "q.circle"
        case .copilot: return "curlybraces"
        }
    }

    /// 도구별 구분 색 — DESIGN.html 카드 액센트 팔레트에서 차용. 토큰 출처: Palette
    var tint: Color {
        switch self {
        case .claudeCode: return Palette.tintClaudeCode
        case .codex:      return Palette.tintCodex
        case .openCode:   return Palette.tintOpenCode
        case .cursor:     return Palette.tintCursor
        case .gemini:     return Palette.tintGemini
        case .qwen:       return Palette.tintQwen
        case .copilot:    return Palette.tintCopilot
        }
    }

    /// 홈 디렉토리 기준 기본 로그 경로 (2026-07 공식 문서 기준 검증).
    /// CLAUDE_CONFIG_DIR / CODEX_HOME / OPENCODE_DB·OPENCODE_DATA_DIR 오버라이드 지원
    /// — 단 GUI 앱은 로그인 셸 export 를 못 보므로 launchctl setenv 된 값만 잡힌다.
    var defaultPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let env = ProcessInfo.processInfo.environment
        switch self {
        case .claudeCode:
            if let dir = env["CLAUDE_CONFIG_DIR"], !dir.isEmpty {
                return (dir as NSString).appendingPathComponent("projects")
            }
            return home.appendingPathComponent(".claude/projects").path
        case .codex:
            if let dir = env["CODEX_HOME"], !dir.isEmpty {
                return (dir as NSString).appendingPathComponent("sessions")
            }
            return home.appendingPathComponent(".codex/sessions").path
        case .openCode:
            return Self.defaultOpenCodePath(home: home, env: env)
        case .cursor:
            // Cursor(VS Code fork)의 채팅/토큰은 이 SQLite 에 있다(대화별 버블).
            return home.appendingPathComponent(
                "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
            ).path
        case .gemini:
            // Gemini CLI 세션은 <home>/tmp/<hash>/chats/session-*.json|jsonl 에 쌓인다.
            if let dir = env["GEMINI_DIR"], !dir.isEmpty {
                return (dir as NSString).appendingPathComponent("tmp")
            }
            return home.appendingPathComponent(".gemini/tmp").path
        case .qwen:
            // Qwen Code 는 Claude Code 와 같은 projects/**/*.jsonl 레이아웃을 쓴다.
            if let dir = env["QWEN_DIR"], !dir.isEmpty {
                return (dir as NSString).appendingPathComponent("projects")
            }
            return home.appendingPathComponent(".qwen/projects").path
        case .copilot:
            // Copilot CLI 세션 상태는 <home>/session-state/ 아래에 쌓인다.
            if let dir = env["COPILOT_DIR"], !dir.isEmpty {
                return (dir as NSString).appendingPathComponent("session-state")
            }
            return home.appendingPathComponent(".copilot/session-state").path
        }
    }

    /// OpenCode 데이터 위치 — CLI(xdg)와 데스크톱 앱(Application Support)이 달라
    /// 후보를 순서대로 검사해 실데이터(opencode.db 또는 storage/message)가 있는
    /// 첫 후보를 고른다. 없으면 CLI 기본값. (신버전은 opencode.db, 구버전은
    /// 파일 storage — 스캐너가 db 우선으로 해석한다.)
    private static func defaultOpenCodePath(home: URL, env: [String: String]) -> String {
        if let db = env["OPENCODE_DB"], !db.isEmpty { return db } // .db 파일 직접
        if let dir = env["OPENCODE_DATA_DIR"], !dir.isEmpty { return dir }
        let candidates = [
            home.appendingPathComponent(".local/share/opencode").path, // CLI (xdg)
            home.appendingPathComponent(
                "Library/Application Support/ai.opencode.desktop/opencode").path, // 데스크톱 앱
            home.appendingPathComponent("Library/Application Support/opencode").path,
        ]
        let fm = FileManager.default
        for c in candidates {
            if fm.fileExists(atPath: (c as NSString).appendingPathComponent("opencode.db")) {
                return c
            }
            var isDir: ObjCBool = false
            let storage = (c as NSString).appendingPathComponent("storage/message")
            if fm.fileExists(atPath: storage, isDirectory: &isDir), isDir.boolValue {
                return c
            }
        }
        return candidates[0]
    }

    /// 설정 화면에서 경로 입력란 아래 보여줄 안내 문구.
    var pathHint: String {
        switch self {
        case .claudeCode: return "프로젝트별 세션 로그(.jsonl)가 있는 폴더"
        case .codex: return "YYYY/MM/DD 아래 rollout-*.jsonl 이 쌓이는 폴더"
        case .openCode: return "opencode 데이터 폴더 — CLI(xdg)·데스크톱 앱 후보 자동 탐색, opencode.db 우선"
        case .cursor: return "Cursor state.vscdb (입력/출력만, 캐시 없음·대화 생성일 기준)"
        case .gemini: return "~/.gemini/tmp 아래 <hash>/chats/session-*.json|jsonl (GEMINI_DIR 오버라이드)"
        case .qwen: return "~/.qwen/projects 아래 세션 .jsonl (Claude Code 와 같은 레이아웃, QWEN_DIR 오버라이드)"
        case .copilot: return "~/.copilot/session-state 아래 세션 (uuid.jsonl 또는 uuid/events.jsonl, COPILOT_DIR 오버라이드)"
        }
    }
}

/// 정규화된 토큰 사용량. 도구별 세부 명칭이 달라도 동일 축으로 모은다.
///
/// - `input`  순수 입력 토큰 (캐시 히트분 제외)
/// - `output` 출력 토큰
/// - `cacheRead`  캐시 읽기(재사용) 토큰 — 보통 할인 과금
/// - `cacheWrite` 캐시 쓰기(생성) 토큰
/// - `reasoning`  추론 토큰 (있는 경우, `output` 의 부분집합일 수 있어 합계엔 미포함)
/// - `total`  도구가 제공하는 권위 있는 합계. 없으면 파서가 구성요소로 계산.
struct TokenUsage: Equatable, Codable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheWrite: Int = 0
    var reasoning: Int = 0
    var total: Int = 0

    static func + (lhs: TokenUsage, rhs: TokenUsage) -> TokenUsage {
        TokenUsage(
            input: lhs.input + rhs.input,
            output: lhs.output + rhs.output,
            cacheRead: lhs.cacheRead + rhs.cacheRead,
            cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
            reasoning: lhs.reasoning + rhs.reasoning,
            total: lhs.total + rhs.total
        )
    }

    static func += (lhs: inout TokenUsage, rhs: TokenUsage) {
        lhs = lhs + rhs
    }
}

/// 한 도구에 대한 스캔 결과 요약.
struct ToolUsageSummary: Identifiable, Codable {
    let tool: AITool
    /// 전체 누적 사용량.
    var usage: TokenUsage = TokenUsage()
    /// 오늘(로컬 자정 이후) 사용량.
    var today: TokenUsage = TokenUsage()
    /// 최근 보고 창(window) 내 일자별 사용량. 키는 로컬 "yyyy-MM-dd".
    var daily: [String: TokenUsage] = [:]
    /// 창 내 일자×모델별 사용량 — SQLite `usage_daily(date, tool, model)` 저장용.
    /// 바깥 키는 로컬 "yyyy-MM-dd", 안쪽 키는 모델 ID(미상은 ""). `daily` 의 모델
    /// 분해판이며, 모든 모델 버킷을 합치면 같은 날짜의 `daily` 와 일치한다.
    var dailyByModel: [String: [String: TokenUsage]] = [:]
    /// 창 내 일자×모델별 API 비용(USD) — 소스가 비용을 직접 주는 도구만
    /// (OpenCode, Cursor CSV). 없으면 비어 있고 서버가 요율표로 계산한다.
    var dailyCostByModel: [String: [String: Double]] = [:]
    /// 모델별 전체 누적 토큰(total 축). 키는 도구가 로그에 남긴 모델 ID.
    /// Claude Code=`message.model`, Codex=`turn_context.model`(없으면 "unknown"),
    /// OpenCode=`modelID`. Cursor 는 로그에 모델 정보가 없어 항상 빈 딕셔너리.
    var models: [String: Int] = [:]
    /// 도구가 로그에 남긴 API 비용 합계(USD). 현재 OpenCode 만 제공, 나머지는 0.
    var costUSD: Double = 0
    var sessionCount: Int = 0
    var lastActivity: Date? = nil
    /// 경로가 존재하고 읽을 수 있었는지.
    var pathExists: Bool = true
    /// 사용자에게 보여줄 안내/오류 메시지 (없으면 nil).
    var note: String? = nil

    var id: String { tool.rawValue }
}

// MARK: - 숫자 포맷

enum TokenFormat {
    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f
    }()

    /// 1,234,567 형태.
    static func grouped(_ n: Int) -> String {
        grouping.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// 12.3M 형태 — 큰 총합을 콤팩트하게.
    static func compact(_ n: Int) -> String {
        let d = Double(n)
        switch n {
        case 1_000_000_000...:
            return String(format: "%.2fB", d / 1_000_000_000)
        case 1_000_000...:
            return String(format: "%.2fM", d / 1_000_000)
        case 10_000...:
            return String(format: "%.1fK", d / 1_000)
        default:
            return grouped(n)
        }
    }
}
