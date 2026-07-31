import Foundation

/// 훅 설치/제거 중 발생할 수 있는 오류.
enum HookInstallError: LocalizedError {
    case scriptWriteFailed(String)
    case settingsUnreadable(String)
    case settingsInvalidJSON
    case settingsWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .scriptWriteFailed(let m): return "훅 스크립트 저장 실패: \(m)"
        case .settingsUnreadable(let m): return "~/.claude/settings.json 을 읽지 못했습니다: \(m)"
        case .settingsInvalidJSON:
            return "~/.claude/settings.json 이 올바른 JSON 이 아닙니다 — 손상 방지를 위해 중단했습니다"
        case .settingsWriteFailed(let m): return "~/.claude/settings.json 저장 실패: \(m)"
        }
    }
}

/// Claude Code 훅 시스템에 amon 라이브 세션 훅을 설치/제거한다.
///
/// - 호환성을 위해 파이썬 훅 스크립트(순수 stdlib)를 기존
///   `~/Library/Application Support/A-mon/hooks/live_hook.py`에 둔다.
///   에 써 두고, `~/.claude/settings.json` 의 `hooks` 서브트리에 6개 이벤트 엔트리를 넣는다.
/// - settings.json 은 다른 도구가 쓴 임의 키가 있을 수 있어 `Codable` 대신
///   `JSONSerialization` 으로 `[String: Any]` 로 다뤄, `hooks` 서브트리만 건드리고
///   나머지는 그대로 보존한다.
/// - 우리 엔트리는 command 문자열에 `live_hook.py` 가 들어있는지로만 식별한다 —
///   다른 도구(예: 이 저장소의 cmux 훅)의 matcher 그룹은 절대 건드리지 않는다.
enum HookInstaller {
    /// matcher 없이(모든 호출) 거는 이벤트.
    ///
    /// `Notification` 은 Claude 가 툴 권한을 묻거나 입력을 기다릴 때 온다 — 펫의
    /// "입력 필요"(needsInput) 상태를 만드는 유일한 신호다.
    private static let noMatcherEvents = [
        "SessionStart", "UserPromptSubmit", "Stop", "SessionEnd", "Notification",
    ]
    /// 서브에이전트(Agent) 툴에만 거는 이벤트.
    private static let agentMatcherEvents = ["PreToolUse", "PostToolUse"]
    private static var allEvents: [String] { noMatcherEvents + agentMatcherEvents }

    /// 시스템 파이썬으로 실행하는 이식성 있는 접두사 — miniconda 등 사용자 고유 경로를
    /// 박아 넣지 않는다. `PATH` 의 python3(Xcode CLT 또는 시스템)를 찾는다.
    private static let pythonPrefix = "/usr/bin/env python3"

    static var supportDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/A-mon", isDirectory: true)
    }

    static var scriptURL: URL {
        supportDir
            .appendingPathComponent("hooks", isDirectory: true)
            .appendingPathComponent("live_hook.py", isDirectory: false)
    }

    static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    /// 훅 스크립트를 디스크에 쓰고, settings.json 에 6개 이벤트 엔트리를 멱등하게 등록한다.
    static func install() -> Result<Void, HookInstallError> {
        do {
            try writeScript()
        } catch {
            return .failure(.scriptWriteFailed(error.localizedDescription))
        }

        // 경로에 공백("Application Support")이 있으므로 반드시 따옴표로 감싼다.
        let command = "\(pythonPrefix) '\(scriptURL.path)'"

        var root: [String: Any]
        switch readSettings() {
        case .success(let dict): root = dict
        case .failure(let e): return .failure(e)
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in noMatcherEvents {
            hooks[event] = upsert(into: hooks[event], group: hookGroup(matcher: nil, command: command))
        }
        for event in agentMatcherEvents {
            hooks[event] = upsert(into: hooks[event], group: hookGroup(matcher: "Agent", command: command))
        }
        root["hooks"] = hooks

        return writeSettings(root)
    }

    /// 6개 이벤트에서 우리 엔트리(command 에 live_hook.py 포함)만 제거하고, 스크립트도 지운다.
    static func uninstall() -> Result<Void, HookInstallError> {
        var root: [String: Any]
        switch readSettings() {
        case .success(let dict): root = dict
        case .failure(let e): return .failure(e)
        }

        guard var hooks = root["hooks"] as? [String: Any] else {
            // 훅 서브트리 자체가 없으면 제거할 것도 없다 — settings.json 을 새로 만들지 않는다.
            deleteScript()
            return .success(())
        }

        for event in allEvents {
            guard let existing = hooks[event] else { continue }
            var groups = normalizeGroups(existing)
            groups.removeAll { groupContainsOurHook($0) }
            if groups.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = groups
            }
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }

        deleteScript()
        return writeSettings(root)
    }

    // MARK: - settings.json 조작 헬퍼

    /// 우리 엔트리가 이미 있으면 교체(경로/파이썬 변경 대응), 없으면 추가한다.
    private static func upsert(into existing: Any?, group: [String: Any]) -> [[String: Any]] {
        var groups = normalizeGroups(existing)
        if let idx = groups.firstIndex(where: { groupContainsOurHook($0) }) {
            groups[idx] = group
        } else {
            groups.append(group)
        }
        return groups
    }

    private static func hookGroup(matcher: String?, command: String) -> [String: Any] {
        // async:true — 사용자의 실제 툴 실행을 절대 막지 않도록 비동기로 뜬다.
        let hookCommand: [String: Any] = [
            "type": "command",
            "command": command,
            "timeout": 5,
            "async": true,
        ]
        var group: [String: Any] = ["hooks": [hookCommand]]
        if let matcher { group["matcher"] = matcher }
        return group
    }

    private static func normalizeGroups(_ value: Any?) -> [[String: Any]] {
        guard let arr = value as? [Any] else { return [] }
        // 실제 Claude Code matcher 그룹은 모두 dict 다 — dict 만 추려도 다른 도구 그룹은 보존된다.
        return arr.compactMap { $0 as? [String: Any] }
    }

    private static func groupContainsOurHook(_ group: [String: Any]) -> Bool {
        guard let hooks = group["hooks"] as? [Any] else { return false }
        for case let h as [String: Any] in hooks {
            if let cmd = h["command"] as? String, cmd.contains("live_hook.py") {
                return true
            }
        }
        return false
    }

    /// settings.json 읽기 — 파일 없음/빈 파일은 `{}`, 깨진 JSON 은 오류(손상 방지).
    private static func readSettings() -> Result<[String: Any], HookInstallError> {
        let url = claudeSettingsURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .success([:])
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return .failure(.settingsUnreadable(error.localizedDescription))
        }
        if data.isEmpty { return .success([:]) }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let dict = obj as? [String: Any] else {
                return .failure(.settingsInvalidJSON)
            }
            return .success(dict)
        } catch {
            return .failure(.settingsInvalidJSON)
        }
    }

    /// settings.json 쓰기(원자적). 참고: Swift 딕셔너리는 순서가 없어 키 순서가 바뀔 수
    /// 있다 — 유효한 JSON 이고 Claude Code 파싱에 영향이 없어 v1 에서 감수하는 트레이드오프다.
    private static func writeSettings(_ root: [String: Any]) -> Result<Void, HookInstallError> {
        let url = claudeSettingsURL
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            return .failure(.settingsWriteFailed(error.localizedDescription))
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
            try data.write(to: url, options: .atomic)
            return .success(())
        } catch {
            return .failure(.settingsWriteFailed(error.localizedDescription))
        }
    }

    // MARK: - 스크립트 파일

    private static func writeScript() throws {
        let dir = scriptURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try hookScriptSource.write(to: scriptURL, atomically: true, encoding: .utf8)
    }

    private static func deleteScript() {
        try? FileManager.default.removeItem(at: scriptURL)
    }

    // MARK: - 임베드된 파이썬 훅 스크립트 (순수 stdlib, plain python3 로 실행)

    /// Claude Code 훅 시스템이 stdin JSON 으로 호출하는 스크립트. 절대 크래시/블록하지
    /// 않도록 전부 예외를 삼키고 항상 exit(0). 프롬프트 원문은 저장하지 않는다.
    /// (Swift raw string `#"""..."""#` 로 감싸 파이썬의 따옴표/역슬래시를 그대로 보존한다.)
    static let hookScriptSource: String = #"""
#!/usr/bin/env python3
# amon 라이브 세션 훅 — Claude Code 훅 시스템이 stdin JSON 페이로드로 호출한다.
#
# payload["hook_event_name"] 로 디스패치한다(argv 가 아니라 JSON 필드 기준 — 항상 존재).
# 세션별 상태를 레거시 ~/Library/Application Support/A-mon/live/<session_id>.json 에 원자적으로
# 유지하고, macOS 앱이 이 디렉토리를 폴링해 로컬 현재 활동 화면에 표시한다.
#
# 개인정보 규칙: tool_input["prompt"] 는 절대 읽거나 저장하지 않는다.
# 오직 description(1줄 요약)만 보관한다.
#
# 절대 크래시/블록하지 않는다: 모든 예외를 삼키고 항상 exit(0). 표준 라이브러리만 사용.
import json
import os
import re
import subprocess
import sys
import tempfile
import datetime
from pathlib import Path


def now_iso():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat()


def live_dir():
    d = Path.home() / "Library" / "Application Support" / "A-mon" / "live"
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def pending_dir():
    """종료된 세션을 앱이 집계(토큰)해 히스토리로 옮길 때까지 놔두는 곳.
    훅은 토큰 스캔을 하지 않는다 — 트랜스크립트가 수 MB 라 훅을 느리게 만든다."""
    d = Path.home() / "Library" / "Application Support" / "A-mon" / "history" / "pending"
    d.mkdir(parents=True, exist_ok=True)
    try:
        os.chmod(d, 0o700)
    except OSError:
        pass
    return d


def safe_id(session_id):
    cleaned = re.sub(r"[^A-Za-z0-9._-]", "_", str(session_id))[:128]
    return cleaned or "unknown"


def session_path(session_id):
    return live_dir() / (safe_id(session_id) + ".json")


def project_label(cwd):
    if not cwd:
        return ""
    return os.path.basename(os.path.normpath(cwd))


def git_branch(cwd):
    if not cwd:
        return None
    try:
        r = subprocess.run(
            ["git", "-C", cwd, "rev-parse", "--abbrev-ref", "HEAD"],
            timeout=2,
            capture_output=True,
            text=True,
        )
        if r.returncode == 0:
            branch = r.stdout.strip()
            return branch or None
    except Exception:
        return None
    return None


def default_session(session_id, cwd):
    now = now_iso()
    return {
        "provider": "claude",  # 훅이 있는 건 Claude Code 뿐 — Codex 는 앱이 로그로 수집
        "session_id": str(session_id),
        "cwd": cwd or "",
        "project_label": project_label(cwd),
        "git_branch": git_branch(cwd),
        "status": "active",
        "agents": [],
        "agent_total": 0,  # 세션 동안 실행된 서브에이전트 누적 수(현재 실행 중과 별개)
        "current_task": None,
        "last_result": None,
        "notice": None,  # 입력 대기 사유(Notification 훅) — 대기가 풀리면 지운다
        "model": None,
        "total_tokens": None,
        "input_tokens": None,
        "output_tokens": None,
        "transcript_path": "",  # 앱이 세션당 토큰을 집계할 때 읽는다
        "started_at": now,
        "updated_at": now,
    }


# 사람이 친 프롬프트가 아닌 주입 텍스트(슬래시 명령 출력·훅 주입·리마인더)의 접두어.
NON_PROMPT_PREFIXES = (
    "<command-",
    "<local-command",
    "<system-reminder",
    "<user-prompt-submit-hook",
)


def is_real_prompt(text):
    t = (text or "").lstrip()
    return bool(t) and not t.startswith(NON_PROMPT_PREFIXES)


# 대화를 조작할 뿐 작업이 아닌 내장 슬래시 명령. 이것들은 어시스턴트 턴을 만들지
# 않으므로 Stop 도 오지 않는다 — 작업으로 기록하면 완료되지 않은 채 남는다.
# 사용자 스킬(`/oh-my-claudecode:...` 등)은 실제 작업이므로 건드리지 않는다.
NON_TASK_COMMANDS = frozenset(
    [
        "clear", "compact", "resume", "exit", "quit", "help", "login", "logout",
        "status", "config", "cost", "doctor", "model", "context", "usage",
    ]
)


def is_task_prompt(text):
    """사람이 시킨 '작업' 인지. 주입 텍스트와 내장 명령은 작업이 아니다."""
    if not is_real_prompt(text):
        return False
    t = (text or "").strip()
    if t.startswith("/"):
        # `/clear`, `/compact` 같은 내장 명령은 인자가 붙어도 어시스턴트 턴을 만들지
        # 않으므로 이름만 보고 걸러낸다. 이름에 콜론이 있는 사용자 스킬은 통과한다.
        name = t[1:].split(None, 1)[0].lower() if len(t) > 1 else ""
        if not name:
            return False  # 슬래시만 친 경우 — 작업이 아니다
        return name not in NON_TASK_COMMANDS
    return True


def extract_prompt_text(content):
    """메시지 content 에서 사용자가 실제로 타이핑한 텍스트만 뽑는다.
    tool_result 블록이 섞여 있으면(=API 왕복용 user 턴이지 사람이 친 프롬프트가
    아님) None — 이게 없으면 도구 결과를 프롬프트로 오인해서 보고하게 된다.
    슬래시 명령 출력·훅 주입 텍스트도 프롬프트가 아니므로 걸러낸다."""
    if isinstance(content, str):
        return content if is_real_prompt(content) else None
    if isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return None
        for b in content:
            if not isinstance(b, dict) or b.get("type") != "text":
                continue
            text = b.get("text", "")
            if is_real_prompt(text):
                return text
    return None


def extract_assistant_text(content):
    """어시스턴트 응답에서 사람이 읽는 텍스트만 뽑는다.
    tool_use/thinking 블록은 건너뛰고 text 블록만 본다(툴만 부른 턴은 None)."""
    if isinstance(content, str):
        return content.strip() or None
    if isinstance(content, list):
        parts = [
            b.get("text", "") for b in content
            if isinstance(b, dict) and b.get("type") == "text"
        ]
        joined = " ".join(p for p in parts if p).strip()
        return joined or None
    return None


def scan_tail_for(transcript_path, tail_bytes, kind):
    """파일 끝 tail_bytes 만 읽어 역순으로 kind("user"|"assistant") 메시지를 찾는다.
    서브에이전트(isSidechain) 라인은 본 세션 것이 아니므로 건너뛴다."""
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - tail_bytes))
            chunk = f.read()
    except Exception:
        return None
    extract = extract_prompt_text if kind == "user" else extract_assistant_text
    for raw in reversed(chunk.split(b"\n")):
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            continue  # 창 경계에서 잘린 첫 라인 등
        if obj.get("type") != kind or obj.get("isSidechain"):
            continue
        # 사람이 직접 타이핑한 프롬프트만. 훅 주입·스킬 출력·task-notification 라인엔
        # promptSource 가 없거나 "system" 이다(전 트랜스크립트 실측).
        if kind == "user" and obj.get("promptSource") != "typed":
            continue
        text = extract((obj.get("message") or {}).get("content"))
        if text:
            return text
    return None


# 꼬리 창을 단계적으로 넓힌다 — 툴 결과가 큰 세션은 마지막 사용자 프롬프트가
# 수백 KB 뒤에 있을 수 있다(실측: 64KB 안엔 tool_result user 턴만 5개).
# 보통 첫 창에서 끝나고, 못 찾으면 4MB 까지만 시도하고 포기한다.
TAIL_WINDOWS = (262144, 1048576, 4194304)


def read_last_message(transcript_path, kind):
    try:
        size = os.path.getsize(transcript_path)
    except OSError:
        return None
    for window in TAIL_WINDOWS:
        text = scan_tail_for(transcript_path, window, kind)
        if text:
            return text
        if window >= size:
            break  # 이미 파일 전체를 훑었다
    return None


def first_line(text, limit):
    """요약용 — 첫 줄만, limit 자로 자른다. 전체 본문은 절대 보관하지 않는다."""
    if not text:
        return None
    stripped = text.strip()
    if not stripped:
        return None
    return stripped.splitlines()[0][:limit] or None


def load_session(session_id, cwd):
    p = session_path(session_id)
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
        if isinstance(data, dict):
            data.setdefault("provider", "claude")
            data.setdefault("session_id", str(session_id))
            data.setdefault("cwd", cwd or "")
            data.setdefault("project_label", project_label(data.get("cwd") or cwd))
            data.setdefault("git_branch", None)
            data.setdefault("status", "active")
            data.setdefault("current_task", None)
            data.setdefault("last_result", None)
            data.setdefault("notice", None)
            data.setdefault("model", None)
            data.setdefault("total_tokens", None)
            data.setdefault("input_tokens", None)
            data.setdefault("output_tokens", None)
            data.setdefault("transcript_path", "")
            data.setdefault("agent_total", 0)
            if not isinstance(data.get("agents"), list):
                data["agents"] = []
            data.setdefault("started_at", now_iso())
            data.setdefault("updated_at", now_iso())
            return data
    except Exception:
        pass
    return default_session(session_id, cwd)


def write_session(session_id, data):
    p = session_path(session_id)
    data["updated_at"] = now_iso()
    fd, tmp = tempfile.mkstemp(dir=str(p.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, p)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def remember_transcript(data, payload):
    """모든 훅 페이로드에 오는 transcript_path 를 보관 — 앱이 토큰 집계에 쓴다."""
    tp = payload.get("transcript_path")
    if tp:
        data["transcript_path"] = str(tp)


def resume_from_wait(data):
    """대기가 풀렸다 — 무언가 진행됐다는 뜻이므로 입력 대기 표시를 지운다.

    Notification 에는 "이제 안 기다린다" 는 반대 이벤트가 없다. 그래서 이후에 오는
    어떤 이벤트(툴 실행·응답 종료·새 프롬프트)든 대기 해제 신호로 삼는다. 이게 없으면
    펫이 needsInput 에 붙박여 자동으로 접히지도 않는다."""
    data["notice"] = None
    if data.get("status") == "needs_input":
        data["status"] = "active"


def refresh_current_task(data, payload):
    """transcript 에서 최신 typed user 메시지를 다시 읽어 current_task 를 갱신한다.
    UserPromptSubmit 시점엔 새 프롬프트가 아직 파일에 안 써진 경우가 있어, 이후
    PreToolUse/Stop 같은 이벤트에서도 재동기화해야 첫 프롬프트에 고정되지 않는다."""
    transcript_path = data.get("transcript_path") or payload.get("transcript_path")
    if not transcript_path:
        return
    text = read_last_message(transcript_path, "user")
    if text:
        latest = first_line(text, 120)
        if latest:
            data["current_task"] = latest


def refresh_model_tokens(data, payload):
    """transcript tail 에서 최근 assistant usage/model 을 읽는다.
    Claude transcript 에는 Codex 같은 별도 누적 token_count 이벤트가 없으므로, 라이브
    화면에는 최신 assistant 메시지의 모델과 토큰 합계만 보낸다. 전체 세션 합계는
    앱의 세션 히스토리 스캐너가 종료 후 별도로 계산한다."""
    transcript_path = data.get("transcript_path") or payload.get("transcript_path")
    if not transcript_path:
        return
    try:
        size = os.path.getsize(transcript_path)
    except OSError:
        return
    for window in TAIL_WINDOWS:
        found = scan_tail_for_usage(transcript_path, window)
        if found:
            model, total, input_tokens, output_tokens = found
            if model:
                data["model"] = model[:128]
            if total and total > 0:
                data["total_tokens"] = total
            if input_tokens is not None and input_tokens >= 0:
                data["input_tokens"] = input_tokens
            if output_tokens is not None and output_tokens >= 0:
                data["output_tokens"] = output_tokens
            return
        if window >= size:
            break


def scan_tail_for_usage(transcript_path, tail_bytes):
    try:
        with open(transcript_path, "rb") as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - tail_bytes))
            chunk = f.read()
    except Exception:
        return None
    for raw in reversed(chunk.split(b"\n")):
        raw = raw.strip()
        if not raw:
            continue
        try:
            obj = json.loads(raw)
        except Exception:
            continue
        if obj.get("type") != "assistant" or obj.get("isSidechain"):
            continue
        message = obj.get("message") or {}
        usage = message.get("usage") or {}
        if not isinstance(usage, dict):
            continue
        input_tokens = nonnegative_int(usage.get("input_tokens"))
        output_tokens = nonnegative_int(usage.get("output_tokens"))
        cache_read = nonnegative_int(usage.get("cache_read_input_tokens")) or 0
        cache_creation = nonnegative_int(usage.get("cache_creation_input_tokens")) or 0
        total = (input_tokens or 0) + (output_tokens or 0) + cache_read + cache_creation
        model = message.get("model")
        if model or total > 0:
            return (
                str(model) if model else None,
                total,
                input_tokens,
                output_tokens,
            )
    return None


def nonnegative_int(value):
    """usage 값이 숫자일 때만 안전하게 정수화한다. 깨진 값은 훅 전체를 막지 않는다."""
    try:
        parsed = int(value)
        return parsed if parsed >= 0 else None
    except (TypeError, ValueError, OverflowError):
        return None


def handle_pretooluse(payload):
    session_id = payload.get("session_id")
    if not session_id:
        return
    cwd = payload.get("cwd") or ""
    tool_input = payload.get("tool_input") or {}
    tool_use_id = str(payload.get("tool_use_id") or "")[:128]
    # tool_input["prompt"] 는 절대 읽지 않는다 — description(1줄)만 보관.
    description = str(tool_input.get("description") or "")[:256]
    agent_type = str(tool_input.get("subagent_type") or "")[:64]
    data = load_session(session_id, cwd)
    remember_transcript(data, payload)
    refresh_current_task(data, payload)
    refresh_model_tokens(data, payload)
    known = {a.get("tool_use_id") for a in data.get("agents", [])}
    agents = [a for a in data.get("agents", []) if a.get("tool_use_id") != tool_use_id]
    agents.append(
        {
            "tool_use_id": tool_use_id,
            "agent_type": agent_type,
            "description": description,
            "started_at": now_iso(),
        }
    )
    data["agents"] = agents
    if tool_use_id not in known:  # 재시도로 같은 id 가 다시 와도 두 번 세지 않는다
        data["agent_total"] = int(data.get("agent_total", 0)) + 1
    resume_from_wait(data)
    data["status"] = "active"
    write_session(session_id, data)


def handle_posttooluse(payload):
    session_id = payload.get("session_id")
    if not session_id:
        return
    cwd = payload.get("cwd") or ""
    tool_use_id = str(payload.get("tool_use_id") or "")[:128]
    data = load_session(session_id, cwd)
    remember_transcript(data, payload)
    refresh_current_task(data, payload)
    refresh_model_tokens(data, payload)
    data["agents"] = [a for a in data.get("agents", []) if a.get("tool_use_id") != tool_use_id]
    resume_from_wait(data)
    write_session(session_id, data)


def handle_sessionstart(payload):
    session_id = payload.get("session_id")
    if not session_id:
        return
    cwd = payload.get("cwd") or ""
    # SessionStart 는 진짜 첫 시작뿐 아니라 resume/compact/clear 때도 다시 온다. 이미
    # 파일이 있으면(=같은 세션이 이어지는 중) cwd/project_label/git_branch 를
    # 덮어쓰지 않는다 — 재발화 시점에 셸이 서브모듈 등으로 일시 cd 돼 있으면
    # 엉뚱한 프로젝트명으로 고정돼버리는 버그였다. 상태/시각만 갱신.
    if session_path(session_id).exists():
        data = load_session(session_id, cwd)
        remember_transcript(data, payload)
        resume_from_wait(data)
        if payload.get("source") == "clear":
            # /clear 는 대화를 비우지만 세션 id 는 그대로다. 직전 작업 내용을 남겨두면
            # 펫이 끝난 작업을 계속 "작업 중" 으로 보여준다 — 게다가 /clear 에는
            # 어시스턴트 턴이 없어 Stop 이 오지 않으므로 완료 표시로 넘어갈 기회조차
            # 없다. 여기서 비워야 빈 대화 상태와 화면이 맞는다.
            data["current_task"] = None
            data["last_result"] = None
            data["agents"] = []
            data["status"] = "idle"
        else:
            data["status"] = "active"
        write_session(session_id, data)
    else:
        data = default_session(session_id, cwd)
        remember_transcript(data, payload)
        write_session(session_id, data)


def handle_userpromptsubmit(payload):
    session_id = payload.get("session_id")
    if not session_id:
        return
    cwd = payload.get("cwd") or ""
    data = load_session(session_id, cwd)
    remember_transcript(data, payload)
    resume_from_wait(data)
    data["status"] = "active"
    # 페이로드의 prompt 가 방금 제출된 원문이다. 트랜스크립트는 이 시점에 아직
    # 새 프롬프트가 안 써진 경우가 있어 먼저 읽으면 직전 입력으로 한 턴 밀린다.
    # 로컬 UI에는 첫 줄 120자만 저장하고 서버로는 보내지 않는다.
    #
    # is_task_prompt 를 여기서도 건다 — 트랜스크립트 경로에만 걸려 있어서 주입 텍스트나
    # 내장 슬래시 명령이 페이로드로 들어오면 그대로 작업으로 찍혔다.
    prompt = payload.get("prompt")
    if isinstance(prompt, str) and not is_task_prompt(prompt):
        prompt = None
    latest = first_line(prompt, 120) if isinstance(prompt, str) else None
    if latest:
        data["current_task"] = latest
        data["last_result"] = None
    elif payload.get("transcript_path"):
        text = read_last_message(payload["transcript_path"], "user")
        if text:
            data["current_task"] = first_line(text, 120)
            data["last_result"] = None
        else:
            refresh_current_task(data, payload)
    refresh_model_tokens(data, payload)
    write_session(session_id, data)


def handle_stop(payload):
    session_id = payload.get("session_id")
    if not session_id:
        return
    cwd = payload.get("cwd") or ""
    data = load_session(session_id, cwd)
    remember_transcript(data, payload)
    refresh_current_task(data, payload)
    refresh_model_tokens(data, payload)
    resume_from_wait(data)
    data["status"] = "idle"
    # 턴이 끝났다 — 방금 낸 응답의 첫 줄(200자)만 요약으로 남긴다.
    # Stop 페이로드에 응답 본문이 온다는 보장이 없어 트랜스크립트에서 읽는다.
    transcript_path = data.get("transcript_path") or payload.get("transcript_path")
    if transcript_path:
        data["last_result"] = first_line(read_last_message(transcript_path, "assistant"), 200)
    write_session(session_id, data)


def handle_notification(payload):
    """Claude 가 사람을 기다린다 — 툴 권한 승인 요청이나 입력 대기.

    이 훅이 "기다리는 중" 을 알 수 있는 유일한 신호다. 상태를 needs_input 으로 올리면
    펫이 최우선으로 표시하고 자동으로 접지 않는다(PetBubbleVisibility).
    message 는 Claude 가 만든 안내 문구라 사용자 프롬프트 원문이 아니다 — 그대로
    한 줄만 보관한다.
    """
    session_id = payload.get("session_id")
    if not session_id:
        return
    cwd = payload.get("cwd") or ""
    data = load_session(session_id, cwd)
    remember_transcript(data, payload)
    message = payload.get("message")
    data["notice"] = first_line(message, 200) if isinstance(message, str) else None
    data["status"] = "needs_input"
    write_session(session_id, data)


def handle_sessionend(payload):
    """세션 종료 — 라이브에서 빼고 pending 으로 넘긴다.

    토큰 집계는 여기서 하지 않는다(트랜스크립트가 수 MB 라 훅이 느려진다).
    앱이 pending 을 주워 토큰을 붙이고 히스토리에 적재한 뒤 파일을 지운다.
    """
    session_id = payload.get("session_id")
    if not session_id:
        return
    live = session_path(session_id)
    if not live.exists():
        return
    cwd = payload.get("cwd") or ""
    data = load_session(session_id, cwd)
    remember_transcript(data, payload)
    data["ended_at"] = now_iso()

    dest = pending_dir() / (safe_id(session_id) + ".json")
    fd, tmp = tempfile.mkstemp(dir=str(dest.parent), suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f, ensure_ascii=False)
        os.replace(tmp, dest)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        return  # pending 기록에 실패하면 라이브 파일을 지우지 않는다(기록 유실 방지)
    try:
        os.unlink(live)
    except OSError:
        pass


HANDLERS = {
    "PreToolUse": handle_pretooluse,
    "PostToolUse": handle_posttooluse,
    "SessionStart": handle_sessionstart,
    "UserPromptSubmit": handle_userpromptsubmit,
    "Stop": handle_stop,
    "SessionEnd": handle_sessionend,
    "Notification": handle_notification,
}


def main():
    try:
        raw = sys.stdin.read()
    except Exception:
        return
    if not raw:
        return
    try:
        payload = json.loads(raw)
    except Exception:
        return
    if not isinstance(payload, dict):
        return
    handler = HANDLERS.get(payload.get("hook_event_name"))
    if handler is None:
        return
    try:
        handler(payload)
    except Exception:
        return


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
"""#
}
