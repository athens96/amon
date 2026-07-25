import Foundation

/// 세션 상세의 **정적 분석** 결과 — 원본 로그에서 툴 호출을 추출해
/// ① 쉘 요청 ② 파일 read/write ③ 위험 신호(규칙 매칭)를 만든다.
/// AI 는 쓰지 않는다 — 전부 로컬 정규식/문자열 규칙이고, 결과는 화면 전용으로
/// 저장·서버 전송하지 않는다(트랜스크립트 상세와 같은 원칙).
struct SessionAudit: Equatable {
    struct ShellCommand: Equatable, Identifiable {
        let id: Int
        let command: String
        let timestamp: Date?
        /// 서브에이전트(sidechain)가 실행한 것 — 본 세션 요청과 구분 표시.
        let fromSubagent: Bool
    }

    struct FileAccess: Equatable, Identifiable {
        var id: String { path }
        let path: String
        var reads: Int
        var writes: Int
    }

    /// 쉘 명령에서 뽑은 프로그램 이름별 사용 횟수(파이프/연산자 분해 후 집계).
    struct CommandCount: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let count: Int
    }

    /// 이름별 사용 횟수 — 스킬·플러그인(MCP) 집계 공용.
    struct NamedCount: Equatable, Identifiable {
        var id: String { name }
        let name: String
        let count: Int
    }

    enum Severity: Equatable {
        case critical  // 위험 — 빨강
        case warning  // 주의 — 주황
    }

    struct Finding: Equatable, Identifiable {
        var id: String { "\(title)|\(evidence)" }
        let severity: Severity
        let title: String
        /// 규칙에 걸린 명령/경로 원문(잘라서).
        let evidence: String
    }

    var shellCommands: [ShellCommand] = []
    var fileAccesses: [FileAccess] = []
    var findings: [Finding] = []
    /// 많이 사용된 커맨드 — 횟수 내림차순.
    var commandCounts: [CommandCount] = []
    /// 사용된 스킬 — 횟수 내림차순(Claude `Skill` 툴, 플러그인 스킬은 `plugin:skill`).
    var skills: [NamedCount] = []
    /// 사용된 플러그인/MCP 서버 — 횟수 내림차순(`mcp__<서버>__<툴>` 등에서 추출).
    var plugins: [NamedCount] = []

    var isEmpty: Bool {
        shellCommands.isEmpty && fileAccesses.isEmpty && findings.isEmpty
            && skills.isEmpty && plugins.isEmpty
    }

    /// 많이 읽은/쓴 파일 — 요약 섹션용 정렬(뷰에서 prefix 로 자른다).
    var topReadFiles: [FileAccess] {
        fileAccesses.filter { $0.reads > 0 }.sorted { $0.reads > $1.reads }
    }
    var topWrittenFiles: [FileAccess] {
        fileAccesses.filter { $0.writes > 0 }.sorted { $0.writes > $1.writes }
    }
}

/// 세션 원본 로그 → `SessionAudit`. 파싱 규칙은 프로바이더별 로그 포맷(전부 실측)
/// 기준이고, 위험 규칙은 `RiskRules` 의 정적 테이블이다.
enum SessionAuditor {

    // MARK: - 위험 규칙 (정적 테이블)

    /// 쉘 명령 텍스트에 정규식으로 매칭한다. 순서 = 표시 우선순위.
    private struct CommandRule {
        let severity: SessionAudit.Severity
        let title: String
        let regex: NSRegularExpression
    }

    private static func rule(
        _ severity: SessionAudit.Severity, _ title: String, _ pattern: String
    ) -> CommandRule? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return nil }
        return CommandRule(severity: severity, title: title, regex: regex)
    }

    private static let commandRules: [CommandRule] = [
        // 파괴적 명령
        rule(.critical, "루트/홈 대상 재귀 삭제", #"rm\s+(-[a-z]*[rf][a-z]*\s+)+["']?(/|~/?|\$HOME/?)\*?["']?(\s|$|[;&|])"#),
        rule(.warning, "재귀 강제 삭제(rm -rf)", #"rm\s+(-[a-z]*r[a-z]*f[a-z]*|-[a-z]*f[a-z]*r[a-z]*)\b"#),
        rule(.critical, "디스크 장치 직접 쓰기(dd)", #"\bdd\b[^|;&]*\bof=/dev/"#),
        rule(.warning, "git 이력 강제 되돌림(reset --hard)", #"git\s+reset\s+--hard"#),
        rule(.warning, "git 강제 푸시(force push)", #"git\s+push\s+[^|;&]*(--force|-f)\b"#),
        rule(.critical, "DB 테이블/데이터베이스 삭제", #"\b(drop\s+(table|database|schema)|truncate\s+table)\b"#),
        rule(.critical, "인프라 일괄 파괴(terraform destroy)", #"terraform\s+destroy"#),
        rule(.warning, "쿠버네티스 리소스 삭제", #"kubectl\s+delete\b"#),
        // 원격 코드 실행/우회
        rule(.critical, "원격 스크립트 즉시 실행(curl|sh)", #"(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z|da)?sh\b"#),
        rule(.critical, "인코딩 페이로드 실행(base64|sh)", #"base64\s+(-d|--decode)[^|;&]*\|\s*(ba|z)?sh\b"#),
        rule(.critical, "리버스 쉘 패턴", #"(/dev/tcp/|nc\s+[^|;&]*\s-e\s|ncat\s+[^|;&]*\s-e\s)"#),
        // 권한/시스템 변경
        rule(.warning, "관리자 권한 실행(sudo)", #"(^|[\s;&|])sudo\s"#),
        rule(.warning, "전체 개방 권한(chmod 777)", #"chmod\s+(-[a-z]+\s+)*0?777\b"#),
        rule(.warning, "시스템 상주 등록(launchctl/crontab)", #"\b(launchctl\s+(load|bootstrap)|crontab\s+(-e|[^-]))"#),
        // 흔적 제거
        rule(.warning, "쉘 히스토리 삭제/비활성화", #"(history\s+-c|unset\s+HISTFILE|>\s*~/\.(bash|zsh)_history)"#),
    ].compactMap { $0 }

    /// 민감 경로 — 명령 텍스트와 파일 접근 경로 양쪽에 적용한다.
    private struct PathRule {
        let title: String
        let regex: NSRegularExpression
        /// 쓰기일 때 심각도(읽기는 한 단계 낮게 취급).
        let writeSeverity: SessionAudit.Severity
    }

    private static func pathRule(
        _ title: String, _ pattern: String, writeSeverity: SessionAudit.Severity = .critical
    ) -> PathRule? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return nil }
        return PathRule(title: title, regex: regex, writeSeverity: writeSeverity)
    }

    private static let pathRules: [PathRule] = [
        pathRule("SSH 키/설정 접근", #"(^|/)\.ssh(/|$)|id_(rsa|ed25519|ecdsa)|authorized_keys"#),
        pathRule("클라우드 자격증명 접근", #"(^|/)\.aws/credentials|(^|/)\.netrc|gcloud/.*credentials|(^|/)\.kube/config"#),
        pathRule("환경변수 시크릿 접근(.env)", #"(^|/)\.env(\.[a-z]+)?$"#, writeSeverity: .warning),
        pathRule("토큰/키 파일 접근", #"\.(pem|p12|keystore)$|(^|/)(credentials|secrets?)\.(json|ya?ml)$"#),
        pathRule("시스템 설정 변경", #"^/etc/|^/Library/Launch(Agents|Daemons)/"#),
        pathRule("사용자 상주 항목 변경", #"/Library/LaunchAgents/"#),
        pathRule("키체인 접근", #"login\.keychain|(^|[\s/])security\s+(find|dump)-"#),
    ].compactMap { $0 }

    // MARK: - 규칙 적용

    static func findings(
        commands: [SessionAudit.ShellCommand], files: [SessionAudit.FileAccess]
    ) -> [SessionAudit.Finding] {
        var out: [SessionAudit.Finding] = []
        var seen = Set<String>()

        // 근거는 화면에서 접힘/펼침으로 전체를 볼 수 있어야 하므로 넉넉히 남긴다
        // (위험 명령 원문이 잘리면 판단이 안 된다). 개수가 적어 메모리 부담 없음.
        func add(_ severity: SessionAudit.Severity, _ title: String, _ evidence: String) {
            let finding = SessionAudit.Finding(
                severity: severity, title: title,
                evidence: String(evidence.prefix(2000))
            )
            guard seen.insert(finding.id).inserted else { return }
            out.append(finding)
        }

        for command in commands {
            let text = command.command
            let range = NSRange(text.startIndex..., in: text)
            for rule in commandRules
            where rule.regex.firstMatch(in: text, range: range) != nil {
                add(rule.severity, rule.title, text)
            }
            for rule in pathRules
            where rule.regex.firstMatch(in: text, range: range) != nil {
                add(.warning, "\(rule.title) (쉘 명령 내)", text)
            }
        }
        for file in files {
            let range = NSRange(file.path.startIndex..., in: file.path)
            for rule in pathRules
            where rule.regex.firstMatch(in: file.path, range: range) != nil {
                let writes = file.writes > 0
                add(
                    writes ? rule.writeSeverity : .warning,
                    rule.title + (writes ? " — 쓰기" : " — 읽기"),
                    file.path
                )
            }
        }
        // 위험(빨강) 먼저.
        return out.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity == .critical }
            return lhs.title < rhs.title
        }
    }

    // MARK: - 커맨드 사용 빈도

    /// 프로그램 이름이 아닌 쉘 키워드 — 벗겨내고 다음 토큰을 본다.
    /// if/while/until 은 바로 뒤가 조건 **명령**이라 벗기면 그 명령이 잡힌다.
    private static let shellKeywords: Set<String> = [
        "do", "then", "else", "elif", "fi", "done", "esac", "in",
        "if", "while", "until", "!",
        "{", "}", "(", ")", "((", "))",
    ]
    /// 실제 프로그램 앞에 붙는 래퍼 — 건너뛰고 다음 토큰을 본다.
    private static let commandWrappers: Set<String> = [
        "sudo", "time", "nohup", "env", "exec", "command", "nice", "xargs", "caffeinate",
    ]

    /// 한 쉘 호출을 파이프/연산자(`| && || ; 줄바꿈`)로 분해해 세그먼트별
    /// 프로그램 이름을 뽑는다. `FOO=1` 환경변수 지정과 래퍼(sudo 등)는 건너뛴다.
    /// 따옴표 안 구분자까지 정확히 다루지는 않는 휴리스틱이다(정적 분석 요약용).
    static func programNames(in command: String) -> [String] {
        var out: [String] = []
        let segments = command.split(whereSeparator: { ";|&\n".contains($0) })
        for segment in segments {
            var tokens = segment.split(separator: " ", omittingEmptySubsequences: true)[...]
            // 흐름 제어 키워드(if/for/while 은 조건이라 스킵, do/then 뒤가 본문)를 벗긴다.
            while let first = tokens.first.map(String.init) {
                if shellKeywords.contains(first) { tokens = tokens.dropFirst(); continue }
                break
            }
            if ["for", "case"].contains(tokens.first.map(String.init) ?? "") {
                continue  // 변수 헤더(for f in …) — 본문은 do 세그먼트에서 잡힌다
            }
            // FOO=bar 환경변수 지정과 래퍼를 건너뛴다.
            while let first = tokens.first.map(String.init) {
                if first.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression) != nil
                    || commandWrappers.contains(first) {
                    tokens = tokens.dropFirst()
                    continue
                }
                break
            }
            guard var name = tokens.first.map(String.init) else { continue }
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`)("))
            guard !name.isEmpty, !name.hasPrefix("$"), !name.hasPrefix("<"), !name.hasPrefix(">"),
                  !name.hasPrefix("#"), !shellKeywords.contains(name)
            else { continue }
            if name.contains("/") { name = String(name.split(separator: "/").last ?? "") }
            guard !name.isEmpty else { continue }
            out.append(name)
        }
        return out
    }

    static func commandCounts(
        _ commands: [SessionAudit.ShellCommand]
    ) -> [SessionAudit.CommandCount] {
        var counts: [String: Int] = [:]
        for command in commands {
            for name in programNames(in: command.command) {
                counts[name, default: 0] += 1
            }
        }
        return counts
            .map { SessionAudit.CommandCount(name: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name < rhs.name
            }
    }

    // MARK: - 스킬 · 플러그인(MCP) 이름 추출

    /// 툴 이름이 MCP 호출이면 서버(플러그인) 이름을 돌려준다.
    /// Claude = `mcp__<server>__<tool>`, Cursor(추정) = `mcp_<server>_<tool>`.
    static func mcpServerName(from toolName: String) -> String? {
        if toolName.hasPrefix("mcp__") {
            let rest = toolName.dropFirst(5)
            if let sep = rest.range(of: "__") {
                return cleanPluginName(String(rest[..<sep.lowerBound]))
            }
            return cleanPluginName(String(rest))
        }
        // Cursor 계열 단일 언더스코어 — 서버 경계를 모르니 첫 세그먼트만(best effort).
        if toolName.hasPrefix("mcp_"), !toolName.hasPrefix("mcp__") {
            let rest = toolName.dropFirst(4)
            if let sep = rest.range(of: "_") {
                return String(rest[..<sep.lowerBound])
            }
            return rest.isEmpty ? nil : String(rest)
        }
        return nil
    }

    /// Claude Code 플러그인 MCP 네이밍(`plugin_<name>_t`)을 사람이 읽는 이름으로.
    static func cleanPluginName(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("plugin_") { name = String(name.dropFirst("plugin_".count)) }
        if name.hasSuffix("_t") { name = String(name.dropLast(2)) }
        return name.isEmpty ? raw : name
    }

    // MARK: - Claude Code 트랜스크립트

    /// assistant 라인의 `tool_use` 블록에서 Bash 명령과 파일 툴 호출을 뽑는다.
    /// 서브에이전트 파일(subagents/*.jsonl)과 sidechain 라인은 fromSubagent 로 구분.
    static func auditClaude(mainTranscript path: String) -> SessionAudit {
        var builder = Builder()
        collectClaude(URL(fileURLWithPath: path), subagent: false, into: &builder)
        let main = URL(fileURLWithPath: path)
        let subagentDir = main.deletingLastPathComponent()
            .appendingPathComponent(main.deletingPathExtension().lastPathComponent, isDirectory: true)
            .appendingPathComponent("subagents", isDirectory: true)
        if let files = try? FileManager.default.contentsOfDirectory(
            at: subagentDir, includingPropertiesForKeys: nil
        ) {
            for file in files.sorted(by: { $0.path < $1.path })
            where file.pathExtension == "jsonl" {
                collectClaude(file, subagent: true, into: &builder)
            }
        }
        return builder.finish()
    }

    private static func collectClaude(_ file: URL, subagent: Bool, into builder: inout Builder) {
        guard let data = try? Data(contentsOf: file) else { return }
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  let message = obj["message"] as? [String: Any],
                  let blocks = message["content"] as? [[String: Any]]
            else { continue }
            let timestamp = (obj["timestamp"] as? String).flatMap(SessionHistoryScanner.parseISO)
            let sidechain = subagent || (obj["isSidechain"] as? Bool ?? false)
            for block in blocks where block["type"] as? String == "tool_use" {
                guard let name = block["name"] as? String,
                      let input = block["input"] as? [String: Any]
                else { continue }
                switch name {
                case "Bash":
                    if let command = input["command"] as? String, !command.isEmpty {
                        builder.shell(command, at: timestamp, subagent: sidechain)
                    }
                case "Read":
                    builder.file(input["file_path"] as? String, write: false)
                case "Write", "Edit", "MultiEdit":
                    builder.file(input["file_path"] as? String, write: true)
                case "NotebookEdit":
                    builder.file(input["notebook_path"] as? String, write: true)
                case "Skill":
                    builder.skill(input["skill"] as? String)
                default:
                    if name.hasPrefix("mcp__") { builder.mcpTool(name) }
                }
            }
        }
    }

    // MARK: - Codex rollout

    /// 실측된 네 형태를 모두 받는다:
    /// `function_call:exec_command`({"cmd"}) · `function_call:shell`({"command":[..]})
    /// · `local_shell_call`(action.command) · `custom_tool_call:exec`(JS 래퍼 —
    /// `exec_command({cmd:"…"})` 를 정규식으로 추출) · `custom_tool_call:apply_patch`
    /// + `patch_apply_end.changes`(파일 쓰기, 절대경로 권위값).
    static func auditCodex(rollout path: String) -> SessionAudit {
        var builder = Builder()
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return builder.finish()
        }
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any]
            else { continue }
            let timestamp = (obj["timestamp"] as? String).flatMap(SessionHistoryScanner.parseISO)
            // MCP 툴 호출은 function_call/custom_tool_call 어느 쪽 이름에도 올 수 있다.
            if let callName = payload["name"] as? String, callName.hasPrefix("mcp") {
                builder.mcpTool(callName)
            }
            switch payload["type"] as? String {
            case "function_call":
                let arguments = decodeJSONObject(payload["arguments"])
                switch payload["name"] as? String {
                case "exec_command":
                    if let cmd = arguments?["cmd"] as? String {
                        builder.shell(cmd, at: timestamp, subagent: false)
                    }
                case "shell":
                    if let parts = arguments?["command"] as? [String] {
                        builder.shell(parts.joined(separator: " "), at: timestamp, subagent: false)
                    } else if let cmd = arguments?["command"] as? String {
                        builder.shell(cmd, at: timestamp, subagent: false)
                    }
                default:
                    break
                }
            case "local_shell_call":
                let action = payload["action"] as? [String: Any]
                if let parts = action?["command"] as? [String] {
                    builder.shell(parts.joined(separator: " "), at: timestamp, subagent: false)
                } else if let cmd = action?["command"] as? String {
                    builder.shell(cmd, at: timestamp, subagent: false)
                }
            case "custom_tool_call":
                let input = payload["input"] as? String ?? ""
                switch payload["name"] as? String {
                case "exec":
                    for cmd in extractWrappedCommands(from: input) {
                        builder.shell(cmd, at: timestamp, subagent: false)
                    }
                case "apply_patch":
                    for (file, isWrite) in patchFiles(from: input) {
                        builder.file(file, write: isWrite)
                    }
                default:
                    break
                }
            case "patch_apply_end":
                if let changes = payload["changes"] as? [String: Any] {
                    for file in changes.keys { builder.file(file, write: true) }
                }
            default:
                break
            }
        }
        return builder.finish()
    }

    /// omc 계열 JS 래퍼에서 `exec_command({... cmd:"…" ...})` 의 cmd 문자열들을 뽑는다.
    /// 키가 따옴표로 감싸였든 아니든, 한 입력에 여러 호출이 있든 전부.
    static func extractWrappedCommands(from input: String) -> [String] {
        guard let regex = try? NSRegularExpression(
            pattern: #""?cmd"?\s*:\s*"((?:\\.|[^"\\])*)""#
        ) else { return [] }
        let range = NSRange(input.startIndex..., in: input)
        return regex.matches(in: input, range: range).compactMap { match in
            guard let r = Range(match.range(at: 1), in: input) else { return nil }
            let escaped = String(input[r])
            // 캡처값은 JSON 문자열 이스케이프 그대로다 — JSON 으로 되돌려 해제한다.
            guard let data = "[\"\(escaped)\"]".data(using: .utf8),
                  let decoded = (try? JSONSerialization.jsonObject(with: data)) as? [String],
                  let cmd = decoded.first, !cmd.isEmpty
            else { return nil }
            return cmd
        }
    }

    /// apply_patch 본문 헤더에서 (경로, 쓰기여부) — Add/Update/Delete 모두 쓰기다.
    static func patchFiles(from patch: String) -> [(String, Bool)] {
        var out: [(String, Bool)] = []
        for line in patch.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["*** Add File: ", "*** Update File: ", "*** Delete File: "]
            where text.hasPrefix(prefix) {
                out.append((String(text.dropFirst(prefix.count)), true))
            }
        }
        return out
    }

    private static func decodeJSONObject(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] { return dict }
        guard let s = value as? String, let data = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Cursor 버블

    /// `toolFormerData`(실측: name=read_file_v2/edit_file_v2/…, params/rawArgs 에
    /// 경로·명령) 를 버블 순서대로 훑는다.
    static func auditCursor(dbPath: String, sessionId: String) -> SessionAudit {
        var builder = Builder()
        let dbURL = URL(fileURLWithPath: dbPath)
        _ = CursorStateDB.withDB(dbURL) { db -> Void in
            guard let composer = CursorStateDB.composer(db, id: sessionId) else { return }
            for header in composer.headers {
                guard let raw = CursorStateDB.bubbleObject(
                    db, composerId: composer.id, bubbleId: header.bubbleId
                ), let tool = raw["toolFormerData"] as? [String: Any]
                else { continue }
                absorbCursorTool(tool, at: header.createdAt, into: &builder)
            }
        }
        return builder.finish()
    }

    static func absorbCursorTool(
        _ tool: [String: Any], at timestamp: Date?, into builder: inout Builder
    ) {
        let rawName = tool["name"] as? String ?? ""
        let name = rawName.lowercased()
        let params = decodeJSONObject(tool["params"]) ?? decodeJSONObject(tool["rawArgs"]) ?? [:]

        // MCP 툴 호출이면 플러그인으로도 집계(파일/쉘 분류와 별개).
        if name.hasPrefix("mcp") { builder.mcpTool(rawName) }

        func firstString(_ keys: [String]) -> String? {
            for key in keys {
                if let value = params[key] as? String, !value.isEmpty { return value }
            }
            return nil
        }
        let path = firstString([
            "relativeWorkspacePath", "targetFile", "path", "effectiveUri", "file_path",
        ])

        if name.contains("terminal") || name.contains("shell") || name == "run_command" {
            if let cmd = firstString(["command", "cmd", "commandLine"]) {
                builder.shell(cmd, at: timestamp, subagent: false)
            }
        } else if name.hasPrefix("read_file") || name.hasPrefix("list_dir") {
            builder.file(path, write: false)
        } else if name.hasPrefix("edit_file") || name.hasPrefix("write")
            || name.hasPrefix("create_file") || name.hasPrefix("delete_file")
            || name.hasPrefix("search_replace") || name.hasPrefix("apply") {
            builder.file(path, write: true)
        }
    }

    // MARK: - 수집 빌더

    struct Builder {
        private var shellCommands: [SessionAudit.ShellCommand] = []
        private var accessOrder: [String] = []
        private var accesses: [String: SessionAudit.FileAccess] = [:]
        private var skillOrder: [String] = []
        private var skillCounts: [String: Int] = [:]
        private var pluginOrder: [String] = []
        private var pluginCounts: [String: Int] = [:]

        /// 스킬 사용 1건(`Skill` 툴의 skill 값 등).
        mutating func skill(_ name: String?) {
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            if skillCounts[name] == nil { skillOrder.append(name) }
            skillCounts[name, default: 0] += 1
        }

        /// MCP 툴 호출 1건 — 서버(플러그인) 이름을 뽑아 집계. MCP 아니면 무시.
        mutating func mcpTool(_ toolName: String) {
            guard let server = SessionAuditor.mcpServerName(from: toolName) else { return }
            if pluginCounts[server] == nil { pluginOrder.append(server) }
            pluginCounts[server, default: 0] += 1
        }

        mutating func shell(_ command: String, at timestamp: Date?, subagent: Bool) {
            shellCommands.append(
                SessionAudit.ShellCommand(
                    id: shellCommands.count, command: command,
                    timestamp: timestamp, fromSubagent: subagent
                )
            )
        }

        mutating func file(_ path: String?, write: Bool) {
            guard let path, !path.isEmpty else { return }
            if accesses[path] == nil {
                accessOrder.append(path)
                accesses[path] = SessionAudit.FileAccess(path: path, reads: 0, writes: 0)
            }
            if write { accesses[path]?.writes += 1 } else { accesses[path]?.reads += 1 }
        }

        func finish() -> SessionAudit {
            let files = accessOrder.compactMap { accesses[$0] }
            func rank(_ order: [String], _ counts: [String: Int]) -> [SessionAudit.NamedCount] {
                order
                    .map { SessionAudit.NamedCount(name: $0, count: counts[$0] ?? 0) }
                    .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
            }
            return SessionAudit(
                shellCommands: shellCommands,
                fileAccesses: files,
                findings: SessionAuditor.findings(commands: shellCommands, files: files),
                commandCounts: SessionAuditor.commandCounts(shellCommands),
                skills: rank(skillOrder, skillCounts),
                plugins: rank(pluginOrder, pluginCounts)
            )
        }
    }

}

/// 상세 화면과 같은 lazy 원칙 — 분석 화면을 열 때만 원본 로그를 읽는다.
enum SessionAuditLoader {
    /// 메인 스레드에서 부르지 말 것(파일 I/O). 뷰는 `Task.detached` 로 감싼다.
    static func load(
        _ record: SessionRecord, claudeRoot: String, codexRoot: String, cursorRoot: String
    ) throws -> SessionAudit {
        guard let path = SessionTranscriptLoader.resolveSource(
            record, claudeRoot: claudeRoot, codexRoot: codexRoot, cursorRoot: cursorRoot
        ) else { throw TranscriptError.sourceNotFound }

        switch record.provider {
        case "codex":
            return SessionAuditor.auditCodex(rollout: path)
        case "cursor":
            return SessionAuditor.auditCursor(dbPath: path, sessionId: record.sessionId)
        default:
            return SessionAuditor.auditClaude(mainTranscript: path)
        }
    }
}
