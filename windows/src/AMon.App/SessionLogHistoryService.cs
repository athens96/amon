using System.Text.Json;
using System.IO;
using System.Text.RegularExpressions;
using AMon.Activity;
using AMon.App.ViewModels;

namespace AMon.App;

public sealed class SessionLogHistoryService
{
    public static string? FindSessionLogPath(
        string provider,
        string sessionId,
        string? claudeRoot = null,
        string? codexRoot = null,
        string? cursorRoot = null)
    {
        if (string.IsNullOrWhiteSpace(sessionId))
            return null;
        // Cursor's "log" is the global state.vscdb; the session is a row inside it.
        if (string.Equals(provider, "cursor", StringComparison.OrdinalIgnoreCase))
            return CursorSessionHistory.ResolveDatabasePath(cursorRoot);
        var isCodex = string.Equals(provider, "codex", StringComparison.OrdinalIgnoreCase);
        var root = isCodex
            ? ResolveCodexRoot(codexRoot)
            : ResolveClaudeRoot(claudeRoot);
        if (!Directory.Exists(root))
            return null;
        var pattern = isCodex ? $"*{sessionId}.jsonl" : $"{sessionId}.jsonl";
        try
        {
            return Directory.EnumerateFiles(root, pattern, SearchOption.AllDirectories)
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .FirstOrDefault();
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    public Task<IReadOnlyList<SessionRecord>> ScanAsync(
        string? claudeRoot,
        string? codexRoot,
        string? cursorRoot = null,
        CancellationToken cancellationToken = default) =>
        Task.Run(
            () => Scan(claudeRoot, codexRoot, cursorRoot, cancellationToken),
            cancellationToken);

    private static IReadOnlyList<SessionRecord> Scan(
        string? claudeRoot,
        string? codexRoot,
        string? cursorRoot,
        CancellationToken cancellationToken)
    {
        var records = new List<SessionRecord>();
        AddRecentFiles(records, ResolveClaudeRoot(claudeRoot), "*.jsonl", "claude", cancellationToken);
        AddRecentFiles(records, ResolveCodexRoot(codexRoot), "rollout-*.jsonl", "codex", cancellationToken);
        AddCursorSessions(records, cursorRoot, cancellationToken);
        return records
            .OrderByDescending(static record => record.EndedAt)
            .Take(200)
            .ToArray();
    }

    private static void AddRecentFiles(
        ICollection<SessionRecord> records,
        string root,
        string pattern,
        string provider,
        CancellationToken cancellationToken)
    {
        if (!Directory.Exists(root))
            return;
        IEnumerable<string> files;
        try
        {
            files = Directory.EnumerateFiles(root, pattern, SearchOption.AllDirectories)
                .OrderByDescending(File.GetLastWriteTimeUtc)
                .Take(200)
                .ToArray();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return;
        }

        foreach (var file in files)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var record = ReadRecord(file, provider);
            if (record is not null)
                records.Add(record);
        }
    }

    /// Ended Cursor conversations from the global state database. Cursor keeps no per-session
    /// token counts locally, so the token columns stay zero (the macOS client fills them with an
    /// estimate attributed from dashboard usage events; that estimate is not ported).
    private static void AddCursorSessions(
        ICollection<SessionRecord> records,
        string? cursorRoot,
        CancellationToken cancellationToken)
    {
        var databasePath = CursorSessionHistory.ResolveDatabasePath(cursorRoot);
        if (databasePath is null)
            return;
        cancellationToken.ThrowIfCancellationRequested();
        IReadOnlyList<CursorSessionSummary> summaries;
        try
        {
            summaries = CursorSessionHistory.Scan(databasePath, DateTimeOffset.UtcNow);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException)
        {
            return;
        }
        foreach (var summary in summaries)
        {
            records.Add(new SessionRecord(
                "cursor",
                summary.Id,
                summary.ProjectLabel ?? "Cursor",
                null,
                "completed",
                Trim(summary.Prompts.LastOrDefault(), 180),
                Trim(summary.LastResult, 240),
                summary.Model,
                0,
                0,
                0,
                0,
                summary.AgentCount,
                summary.StartedAt,
                summary.EndedAt,
                databasePath));
        }
    }

    private static SessionRecord? ReadRecord(string path, string provider)
    {
        var turns = SessionTranscriptParser.Parse(path, provider);
        if (turns.Count == 0)
            return null;
        var info = new FileInfo(path);
        var startedAt = turns
            .Where(static turn => turn.Timestamp is not null)
            .Select(static turn => turn.Timestamp!.Value)
            .DefaultIfEmpty(new DateTimeOffset(info.CreationTimeUtc))
            .Min();
        var endedAt = turns
            .Where(static turn => turn.Timestamp is not null)
            .Select(static turn => turn.Timestamp!.Value)
            .DefaultIfEmpty(new DateTimeOffset(info.LastWriteTimeUtc))
            .Max();
        var usage = turns
            .Where(static turn => turn.Usage is not null)
            .Select(static turn => turn.Usage!)
            .Aggregate(new SessionTurnUsage(0, 0, 0, 0), static (total, item) => total.Add(item));
        var firstPrompt = turns.FirstOrDefault(static turn => turn.Role == "사용자")?.Text;
        var lastResult = turns.LastOrDefault(static turn => turn.Role == "AI")?.Text;
        var sessionId = provider == "claude"
            ? Path.GetFileNameWithoutExtension(path)
            : CodexSessionId(path);
        var project = provider == "claude"
            ? Path.GetFileName(Path.GetDirectoryName(path)) ?? "Claude 프로젝트"
            : SessionTranscriptParser.ReadCodexWorkingDirectory(path) ?? "Codex 프로젝트";

        return new SessionRecord(
            provider,
            sessionId,
            project,
            null,
            "completed",
            Trim(firstPrompt, 180),
            Trim(lastResult, 240),
            turns.Select(static turn => turn.Model).FirstOrDefault(static model => !string.IsNullOrWhiteSpace(model)),
            usage.InputTokens,
            usage.OutputTokens,
            checked(usage.CacheReadTokens + usage.CacheWriteTokens),
            usage.TotalTokens,
            0,
            startedAt,
            endedAt,
            path);
    }

    private static string ResolveClaudeRoot(string? configured) =>
        ResolveRoot(configured, Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".claude", "projects"));

    private static string ResolveCodexRoot(string? configured) =>
        ResolveRoot(configured, Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".codex", "sessions"));

    private static string ResolveRoot(string? configured, string fallback)
    {
        if (string.IsNullOrWhiteSpace(configured))
            return fallback;
        var expanded = Environment.ExpandEnvironmentVariables(configured.Trim());
        if (expanded.StartsWith("~/", StringComparison.Ordinal)
            || expanded.StartsWith("~\\", StringComparison.Ordinal))
            expanded = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                expanded[2..]);
        return Path.GetFullPath(expanded);
    }

    private static string CodexSessionId(string path)
    {
        var name = Path.GetFileNameWithoutExtension(path);
        var pieces = name.Split('-');
        return pieces.Length >= 6 ? string.Join('-', pieces[^5..]) : name;
    }

    private static string? Trim(string? value, int length) =>
        string.IsNullOrWhiteSpace(value)
            ? null
            : value.Length <= length ? value : value[..length] + "…";
}

public static class SessionTranscriptParser
{
    public static IReadOnlyList<SessionTurnViewModel> Parse(string path, string provider, string? sessionId = null)
    {
        if (!File.Exists(path))
            return [];
        try
        {
            return provider switch
            {
                "codex" => ParseCodex(path),
                "cursor" => ParseCursor(path, sessionId),
                _ => ParseClaude(path),
            };
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or JsonException or Microsoft.Data.Sqlite.SqliteException)
        {
            return [];
        }
    }

    public static SessionAuditViewModel Audit(string path, string provider, string? sessionId = null)
    {
        if (!File.Exists(path))
            return SessionAuditViewModel.Empty;
        var builder = new AuditBuilder();
        try
        {
            if (provider == "cursor")
            {
                if (!string.IsNullOrWhiteSpace(sessionId))
                {
                    foreach (var call in CursorSessionHistory.ReadToolCalls(path, sessionId))
                        CollectCursorAudit(call, builder);
                }
            }
            else
            {
                foreach (var line in ReadSharedLines(path))
                {
                    using var document = TryDocument(line);
                    if (document is null)
                        continue;
                    if (provider == "codex")
                        CollectCodexAudit(document.RootElement, builder);
                    else
                        CollectClaudeAudit(document.RootElement, builder);
                }
            }
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or Microsoft.Data.Sqlite.SqliteException)
        {
            return SessionAuditViewModel.Empty;
        }
        return builder.Finish();
    }

    /// Collects one session's tool activity into the audit vocabulary: shell commands, file
    /// reads/writes, skill invocations, and MCP plugin (server) calls. Ported from the macOS
    /// `SessionAuditor.Builder`.
    internal sealed class AuditBuilder
    {
        private readonly List<string> _commands = [];
        private readonly Dictionary<string, SessionFileAccessViewModel> _files = new(StringComparer.OrdinalIgnoreCase);
        private readonly Dictionary<string, int> _skills = new(StringComparer.Ordinal);
        private readonly Dictionary<string, int> _plugins = new(StringComparer.Ordinal);

        public void Shell(string? command)
        {
            if (!string.IsNullOrWhiteSpace(command))
                _commands.Add(command);
        }

        public void File(string? path, bool write)
        {
            if (string.IsNullOrWhiteSpace(path))
                return;
            _files.TryGetValue(path, out var existing);
            existing ??= new SessionFileAccessViewModel(path, 0, 0);
            _files[path] = write
                ? existing with { Writes = existing.Writes + 1 }
                : existing with { Reads = existing.Reads + 1 };
        }

        /// One skill use (the `skill` argument of Claude's `Skill` tool).
        public void Skill(string? name)
        {
            var trimmed = name?.Trim();
            if (!string.IsNullOrEmpty(trimmed))
                _skills[trimmed] = _skills.GetValueOrDefault(trimmed) + 1;
        }

        /// One tool call; counted as a plugin call only when the name is an MCP tool.
        public void McpTool(string? toolName)
        {
            if (McpServerName(toolName) is { } server)
                _plugins[server] = _plugins.GetValueOrDefault(server) + 1;
        }

        public SessionAuditViewModel Finish()
        {
            var files = _files.Values.OrderByDescending(static file => file.Reads + file.Writes).ToArray();
            var findings = _commands
                .SelectMany(RiskFindings)
                .Concat(files.SelectMany(FileRiskFindings))
                .DistinctBy(static finding => $"{finding.Severity}|{finding.Title}|{finding.Evidence}")
                .ToArray();
            var commandCounts = _commands
                .Select(CommandName)
                .Where(static name => !string.IsNullOrWhiteSpace(name))
                .GroupBy(static name => name!, StringComparer.OrdinalIgnoreCase)
                .OrderByDescending(static group => group.Count())
                .Take(10)
                .Select(group => $"{group.Key} ×{group.Count():N0}")
                .ToArray();
            return new SessionAuditViewModel(_commands, files, findings, commandCounts, Ranked(_skills), Ranked(_plugins));
        }

        private static IReadOnlyList<string> Ranked(Dictionary<string, int> counts) =>
            counts
                .OrderByDescending(static pair => pair.Value)
                .ThenBy(static pair => pair.Key, StringComparer.Ordinal)
                .Select(static pair => $"{pair.Key} ×{pair.Value:N0}")
                .ToArray();
    }

    /// The MCP server (plugin) name behind a tool name, or `null` when the tool is not MCP.
    /// Claude = `mcp__<server>__<tool>`; Cursor uses single underscores (`mcp_<server>_<tool>`),
    /// where the server boundary is unknown so only the first segment is taken (best effort).
    public static string? McpServerName(string? toolName)
    {
        if (string.IsNullOrEmpty(toolName))
            return null;
        if (toolName.StartsWith("mcp__", StringComparison.Ordinal))
        {
            var rest = toolName[5..];
            var separator = rest.IndexOf("__", StringComparison.Ordinal);
            return CleanPluginName(separator >= 0 ? rest[..separator] : rest);
        }
        if (toolName.StartsWith("mcp_", StringComparison.Ordinal))
        {
            var rest = toolName[4..];
            var separator = rest.IndexOf('_');
            var server = separator >= 0 ? rest[..separator] : rest;
            return server.Length == 0 ? null : server;
        }
        return null;
    }

    /// Claude Code plugin MCP naming (`plugin_<name>_t`) → the human-readable plugin name.
    private static string CleanPluginName(string raw)
    {
        var name = raw;
        if (name.StartsWith("plugin_", StringComparison.Ordinal))
            name = name["plugin_".Length..];
        if (name.EndsWith("_t", StringComparison.Ordinal))
            name = name[..^2];
        return name.Length == 0 ? raw : name;
    }

    private static void CollectClaudeAudit(JsonElement root, AuditBuilder builder)
    {
        if (String(root, "type") != "assistant"
            || !Property(root, "message", out var message)
            || !Property(message, "content", out var content)
            || content.ValueKind != JsonValueKind.Array)
            return;
        foreach (var block in content.EnumerateArray())
        {
            if (String(block, "type") != "tool_use"
                || !Property(block, "input", out var input))
                continue;
            var name = String(block, "name") ?? string.Empty;
            switch (name)
            {
                case "Bash" or "Shell" or "exec_command":
                    builder.Shell(String(input, "command"));
                    break;
                case "Read":
                    builder.File(String(input, "file_path"), write: false);
                    break;
                case "Write" or "Edit" or "MultiEdit":
                    builder.File(String(input, "file_path"), write: true);
                    break;
                case "NotebookEdit":
                    builder.File(String(input, "notebook_path"), write: true);
                    break;
                case "Skill":
                    builder.Skill(String(input, "skill"));
                    break;
                default:
                    if (name.StartsWith("mcp__", StringComparison.Ordinal))
                        builder.McpTool(name);
                    // Other tools (MCP filesystem servers, say) that name a file still count as
                    // file access so the sensitive-path rules keep seeing them.
                    builder.File(
                        String(input, "file_path") ?? String(input, "notebook_path"),
                        name.Contains("write", StringComparison.OrdinalIgnoreCase) || name.Contains("edit", StringComparison.OrdinalIgnoreCase));
                    break;
            }
        }
    }

    private static void CollectCodexAudit(JsonElement root, AuditBuilder builder)
    {
        if (!Property(root, "payload", out var payload))
            return;
        // MCP tool calls can arrive under either function_call or custom_tool_call names.
        builder.McpTool(String(payload, "name"));
        var type = String(payload, "type");
        if (type == "local_shell_call"
            && Property(payload, "action", out var action)
            && Property(action, "command", out var commandValue))
        {
            builder.Shell(commandValue.ValueKind == JsonValueKind.Array
                ? string.Join(' ', commandValue.EnumerateArray().Select(static item => item.GetString()))
                : commandValue.GetString());
            return;
        }
        if (type != "function_call" && type != "custom_tool_call")
            return;
        var name = String(payload, "name") ?? string.Empty;
        var raw = String(payload, "arguments") ?? String(payload, "input");
        if (string.IsNullOrWhiteSpace(raw))
            return;
        JsonDocument? arguments = null;
        try { arguments = JsonDocument.Parse(raw); } catch (JsonException) { }
        using (arguments)
        {
            if (arguments is null)
                return;
            var input = arguments.RootElement;
            if (name is "exec_command" or "shell")
                builder.Shell(String(input, "cmd") ?? String(input, "command"));
            var path = String(input, "path") ?? String(input, "file_path");
            if (!string.IsNullOrWhiteSpace(path))
                builder.File(path, name.Contains("write", StringComparison.OrdinalIgnoreCase)
                    || name.Contains("patch", StringComparison.OrdinalIgnoreCase));
        }
    }

    /// `toolFormerData` on Cursor bubbles (measured: `read_file_v2`, `edit_file_v2`,
    /// `run_terminal_cmd`, `mcp_<server>_<tool>`, with paths and commands in `params`/`rawArgs`).
    private static void CollectCursorAudit(CursorToolCall call, AuditBuilder builder)
    {
        var name = call.Name.ToLowerInvariant();
        builder.McpTool(call.Name);
        var parameters = call.Parameters;
        string? First(params string[] keys)
        {
            if (parameters is not { } element)
                return null;
            foreach (var key in keys)
            {
                if (String(element, key) is { Length: > 0 } value)
                    return value;
            }
            return null;
        }
        var path = First("relativeWorkspacePath", "targetFile", "path", "effectiveUri", "file_path");
        if (name.Contains("terminal") || name.Contains("shell") || name == "run_command")
            builder.Shell(First("command", "cmd", "commandLine"));
        else if (name.StartsWith("read_file") || name.StartsWith("list_dir"))
            builder.File(path, write: false);
        else if (name.StartsWith("edit_file") || name.StartsWith("write") || name.StartsWith("create_file")
            || name.StartsWith("delete_file") || name.StartsWith("search_replace") || name.StartsWith("apply"))
            builder.File(path, write: true);
    }

    private static IReadOnlyList<SessionTurnViewModel> ParseCursor(string databasePath, string? sessionId)
    {
        if (string.IsNullOrWhiteSpace(sessionId))
            return [];
        return CursorSessionHistory.ReadTurns(databasePath, sessionId)
            .Select(static turn => new SessionTurnViewModel(turn.IsUser ? "사용자" : "AI", turn.Text, turn.Timestamp, null, null))
            .ToArray();
    }

    private static IEnumerable<SessionFindingViewModel> RiskFindings(string command)
    {
        foreach (var (severity, title, pattern) in CommandRiskRules)
        {
            if (Regex.IsMatch(command, pattern, RegexOptions.IgnoreCase))
                yield return new SessionFindingViewModel(severity, title, command);
        }
    }

    private static IEnumerable<SessionFindingViewModel> FileRiskFindings(
        SessionFileAccessViewModel file)
    {
        if (Regex.IsMatch(
                file.Path,
                @"(^|[\\/])(\.env|\.ssh)([\\/]|$)|credentials|secrets?\.(json|ya?ml)|\.(pem|p12)$",
                RegexOptions.IgnoreCase))
        {
            yield return new SessionFindingViewModel(
                file.Writes > 0 ? "위험" : "주의",
                file.Writes > 0 ? "민감한 파일 쓰기" : "민감한 파일 읽기",
                file.Path);
        }
    }

    private static string? CommandName(string command)
    {
        var first = Regex.Split(command.Trim(), @"\s+").FirstOrDefault();
        return first is "sudo" or "env" or "nohup"
            ? Regex.Split(command.Trim(), @"\s+").Skip(1).FirstOrDefault()
            : first;
    }

    private static readonly (string Severity, string Title, string Pattern)[] CommandRiskRules =
    [
        ("위험", "루트 또는 홈 재귀 삭제", @"\brm\s+[^;&|]*-[a-z]*r[a-z]*f[a-z]*\s+(/|~|\$HOME)\b"),
        ("주의", "재귀 강제 삭제", @"\brm\s+(-[a-z]*r[a-z]*f[a-z]*|-[a-z]*f[a-z]*r[a-z]*)\b"),
        ("주의", "Git 이력 강제 되돌림", @"\bgit\s+reset\s+--hard\b"),
        ("주의", "Git 강제 푸시", @"\bgit\s+push\b[^;&|]*(--force|-f)\b"),
        ("위험", "원격 스크립트 즉시 실행", @"\b(curl|wget)\b[^;&|]*\|\s*(ba|z)?sh\b"),
        ("주의", "관리자 권한 실행", @"(^|[\s;&|])sudo\s"),
        ("위험", "데이터베이스 파괴 명령", @"\b(drop\s+(table|database|schema)|truncate\s+table)\b"),
    ];

    public static string? ReadCodexWorkingDirectory(string path)
    {
        foreach (var line in ReadSharedLines(path).Take(40))
        {
            using var document = TryDocument(line);
            if (document is null)
                continue;
            var root = document.RootElement;
            if (Property(root, "payload", out var payload)
                && String(payload, "cwd") is { Length: > 0 } cwd)
                return Path.GetFileName(cwd.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
        }
        return null;
    }

    private static IReadOnlyList<SessionTurnViewModel> ParseClaude(string path)
    {
        var turns = new List<SessionTurnViewModel>();
        foreach (var line in ReadSharedLines(path))
        {
            using var document = TryDocument(line);
            if (document is null)
                continue;
            var root = document.RootElement;
            var type = String(root, "type");
            if (!Property(root, "message", out var message))
                continue;
            var timestamp = Date(root, "timestamp");
            var model = String(message, "model");
            if (type == "user")
            {
                var promptSource = String(root, "promptSource");
                if (Boolean(root, "isSidechain") ||
                    (promptSource != "typed" && promptSource != "sdk"))
                    continue;
                var text = ContentText(message, "content");
                if (!string.IsNullOrWhiteSpace(text) &&
                    !text.TrimStart().StartsWith("<task-notification", StringComparison.OrdinalIgnoreCase))
                    turns.Add(new SessionTurnViewModel("사용자", text, timestamp, model, null));
            }
            else if (type == "assistant")
            {
                var text = ContentText(message, "content");
                var usage = Property(message, "usage", out var usageElement)
                    ? Usage(usageElement, "input_tokens", "output_tokens",
                        "cache_read_input_tokens", "cache_creation_input_tokens")
                    : null;
                if (!string.IsNullOrWhiteSpace(text))
                    turns.Add(new SessionTurnViewModel("AI", text, timestamp, model, usage));
            }
        }
        return turns;
    }

    private static IReadOnlyList<SessionTurnViewModel> ParseCodex(string path)
    {
        var turns = new List<SessionTurnViewModel>();
        string? model = null;
        SessionTurnUsage? cumulative = null;
        foreach (var line in ReadSharedLines(path))
        {
            using var document = TryDocument(line);
            if (document is null)
                continue;
            var root = document.RootElement;
            if (!Property(root, "payload", out var payload))
                continue;
            var timestamp = Date(root, "timestamp");
            var payloadType = String(payload, "type");
            if (payloadType == "turn_context")
            {
                model = String(payload, "model") ?? model;
                continue;
            }
            if (payloadType == "user_message")
            {
                var text = String(payload, "message");
                if (!string.IsNullOrWhiteSpace(text) && !text.StartsWith('<'))
                    turns.Add(new SessionTurnViewModel("사용자", text, timestamp, model, null));
                continue;
            }
            if (payloadType == "token_count"
                && Property(payload, "info", out var info)
                && Property(info, "total_token_usage", out var total))
            {
                cumulative = Usage(
                    total,
                    "input_tokens",
                    "output_tokens",
                    "cached_input_tokens",
                    null);
                continue;
            }
            if (String(root, "type") == "response_item")
            {
                var role = String(payload, "role");
                var text = ContentText(payload, "content");
                if (!string.IsNullOrWhiteSpace(text) && role == "assistant")
                    turns.Add(new SessionTurnViewModel("AI", text, timestamp, model, null));
            }
        }
        if (cumulative is not null && turns.Count > 0)
        {
            var last = turns[^1];
            turns[^1] = last with { Usage = cumulative };
        }
        return turns;
    }

    private static JsonDocument? TryDocument(string line)
    {
        try { return JsonDocument.Parse(line); }
        catch (JsonException) { return null; }
    }

    private static IEnumerable<string> ReadSharedLines(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete,
            64 * 1024,
            FileOptions.SequentialScan);
        using var reader = new StreamReader(stream);
        while (reader.ReadLine() is { } line)
            yield return line;
    }

    private static bool Property(JsonElement element, string name, out JsonElement value)
    {
        if (element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out value))
            return true;
        value = default;
        return false;
    }

    private static string? String(JsonElement element, string name) =>
        Property(element, name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static bool Boolean(JsonElement element, string name) =>
        Property(element, name, out var value)
        && value.ValueKind == JsonValueKind.True;

    private static DateTimeOffset? Date(JsonElement element, string name) =>
        String(element, name) is { } value && DateTimeOffset.TryParse(value, out var date)
            ? date
            : null;

    private static string? ContentText(JsonElement element, string name)
    {
        if (!Property(element, name, out var content))
            return null;
        if (content.ValueKind == JsonValueKind.String)
            return content.GetString();
        if (content.ValueKind != JsonValueKind.Array)
            return null;
        var parts = new List<string>();
        foreach (var item in content.EnumerateArray())
        {
            if (item.ValueKind == JsonValueKind.String)
                parts.Add(item.GetString() ?? string.Empty);
            else if (Property(item, "text", out var text) && text.ValueKind == JsonValueKind.String)
                parts.Add(text.GetString() ?? string.Empty);
        }
        return string.Join("\n\n", parts.Where(static part => !string.IsNullOrWhiteSpace(part)));
    }

    private static SessionTurnUsage? Usage(
        JsonElement element,
        string input,
        string output,
        string cacheRead,
        string? cacheWrite)
    {
        var usage = new SessionTurnUsage(
            Number(element, input),
            Number(element, output),
            Number(element, cacheRead),
            cacheWrite is null ? 0 : Number(element, cacheWrite));
        return usage.TotalTokens > 0 ? usage : null;
    }

    private static long Number(JsonElement element, string name) =>
        Property(element, name, out var value)
        && value.ValueKind == JsonValueKind.Number
        && value.TryGetInt64(out var number)
            ? number
            : 0;
}

public sealed record SessionTurnUsage(
    long InputTokens,
    long OutputTokens,
    long CacheReadTokens,
    long CacheWriteTokens)
{
    public long TotalTokens => checked(
        InputTokens + OutputTokens + CacheReadTokens + CacheWriteTokens);

    public SessionTurnUsage Add(SessionTurnUsage other) => new(
        checked(InputTokens + other.InputTokens),
        checked(OutputTokens + other.OutputTokens),
        checked(CacheReadTokens + other.CacheReadTokens),
        checked(CacheWriteTokens + other.CacheWriteTokens));
}

public sealed record SessionTurnViewModel(
    string Role,
    string Text,
    DateTimeOffset? Timestamp,
    string? Model,
    SessionTurnUsage? Usage)
{
    public string Time => Timestamp?.ToLocalTime().ToString("HH:mm:ss") ?? string.Empty;
    public string UsageText => Usage is null ? string.Empty : $"{Usage.TotalTokens:N0} 토큰";
}

public sealed record SessionAuditViewModel(
    IReadOnlyList<string> ShellCommands,
    IReadOnlyList<SessionFileAccessViewModel> FileAccesses,
    IReadOnlyList<SessionFindingViewModel> Findings,
    IReadOnlyList<string> CommandCounts,
    IReadOnlyList<string> Skills,
    IReadOnlyList<string> Plugins)
{
    public static SessionAuditViewModel Empty { get; } = new([], [], [], [], [], []);

    /// Skills and MCP plugins as one list for the detail panel ("skill:name ×N", "mcp:server ×N").
    public IReadOnlyList<string> Extensions =>
        [.. Skills.Select(static skill => $"스킬 {skill}"), .. Plugins.Select(static plugin => $"MCP {plugin}")];

    public string Summary =>
        $"쉘 {ShellCommands.Count:N0} · 파일 {FileAccesses.Count:N0} · 위험 신호 {Findings.Count:N0} · 스킬 {Skills.Count:N0} · MCP {Plugins.Count:N0}";
}

public sealed record SessionFileAccessViewModel(string Path, int Reads, int Writes)
{
    public string Summary => $"읽기 {Reads:N0} · 쓰기 {Writes:N0}";
}

public sealed record SessionFindingViewModel(string Severity, string Title, string Evidence);
