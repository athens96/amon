using System.Globalization;
using System.Text.Json;

namespace AMon.Activity;

public sealed class CodexLiveSessionSource : ILiveSessionSource
{
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(15);
    public static readonly TimeSpan ActiveAfter = TimeSpan.FromSeconds(90);
    public const int MaxFiles = 20;
    private readonly string _root;
    private readonly object _cacheLock = new();
    private readonly Dictionary<string, CacheEntry> _cache =
        new(StringComparer.OrdinalIgnoreCase);
    private int _parsedFileCount;

    public CodexLiveSessionSource(string? root = null)
    {
        var resolved = root;
        if (string.IsNullOrWhiteSpace(resolved))
        {
            var home = Environment.GetEnvironmentVariable("CODEX_HOME");
            resolved = Path.Combine(
                string.IsNullOrWhiteSpace(home)
                    ? Path.Combine(
                        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                        ".codex")
                    : Environment.ExpandEnvironmentVariables(home.Trim()),
                "sessions");
        }
        _root = Path.GetFullPath(
            Environment.ExpandEnvironmentVariables(resolved.Trim()));
    }

    public string Provider => "codex";

    public int ParsedFileCount => Volatile.Read(ref _parsedFileCount);

    public int CachedFileCount
    {
        get
        {
            lock (_cacheLock)
                return _cache.Count;
        }
    }

    public Task<IReadOnlyList<LiveSession>> PollAsync(
        LivePollContext context,
        CancellationToken cancellationToken = default) =>
        Task.Run<IReadOnlyList<LiveSession>>(
            () => Poll(context.Now, cancellationToken),
            cancellationToken);

    private IReadOnlyList<LiveSession> Poll(
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        if (!Directory.Exists(_root))
        {
            ClearCache();
            return [];
        }

        IReadOnlyList<FileCandidate> files;
        try
        {
            files = Directory
                .EnumerateFiles(_root, "rollout-*.jsonl", SearchOption.AllDirectories)
                .Select(static path =>
                {
                    var info = new FileInfo(path);
                    return new FileCandidate(
                        Path.GetFullPath(info.FullName),
                        info.Length,
                        new DateTimeOffset(
                            DateTime.SpecifyKind(info.LastWriteTimeUtc, DateTimeKind.Utc)));
                })
                .Where(item => now - item.ModifiedAt <= StaleAfter)
                .OrderByDescending(static item => item.ModifiedAt)
                .Take(MaxFiles)
                .ToArray();
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return [];
        }

        SweepCache(files.Select(static file => file.Path));
        var sessions = new List<LiveSession>();
        foreach (var file in files)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var parsed = CachedOrParse(file, cancellationToken);
            if (parsed is not null)
                sessions.Add(Materialize(parsed, now));
        }
        return sessions;
    }

    private ParsedCodexSession? CachedOrParse(
        FileCandidate file,
        CancellationToken cancellationToken)
    {
        lock (_cacheLock)
        {
            if (_cache.TryGetValue(file.Path, out var cached) &&
                cached.Length == file.Length &&
                cached.ModifiedAt == file.ModifiedAt)
                return cached.Parsed;
        }

        var parsed = Parse(file.Path, file.ModifiedAt, cancellationToken);
        Interlocked.Increment(ref _parsedFileCount);
        lock (_cacheLock)
            _cache[file.Path] = new CacheEntry(file.Length, file.ModifiedAt, parsed);
        return parsed;
    }

    private void SweepCache(IEnumerable<string> paths)
    {
        var current = paths.ToHashSet(StringComparer.OrdinalIgnoreCase);
        lock (_cacheLock)
        {
            foreach (var path in _cache.Keys.Where(path => !current.Contains(path)).ToArray())
                _cache.Remove(path);
        }
    }

    private void ClearCache()
    {
        lock (_cacheLock)
            _cache.Clear();
    }

    private static ParsedCodexSession? Parse(
        string path,
        DateTimeOffset modifiedAt,
        CancellationToken cancellationToken)
    {
        string? sessionId = null;
        string? cwd = null;
        string? model = null;
        string? currentTask = null;
        string? lastResult = null;
        DateTimeOffset? startedAt = null;
        DateTimeOffset? updatedAt = null;
        LiveTokenSnapshot tokens = LiveTokenSnapshot.Unavailable;
        var hasLifecycle = false;
        var lifecycleActive = false;
        string? attentionStatus = null;

        try
        {
            foreach (var line in LiveSharedFile.ReadLines(path))
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (line.Length > 32 * 1024 * 1024)
                    continue;
                JsonDocument document;
                try
                {
                    document = JsonDocument.Parse(line);
                }
                catch (JsonException)
                {
                    continue;
                }
                using (document)
                {
                    var root = document.RootElement;
                    if (root.ValueKind != JsonValueKind.Object)
                        continue;
                    var timestamp = ParseTimestamp(root);
                    if (timestamp is not null)
                    {
                        startedAt ??= timestamp;
                        updatedAt = timestamp;
                    }
                    if (!root.TryGetProperty("payload", out var payload) ||
                        payload.ValueKind != JsonValueKind.Object)
                        continue;

                    switch (Text(root, "type"))
                    {
                        case "session_meta":
                            sessionId = Nonempty(Text(payload, "id")) ?? sessionId;
                            cwd = Nonempty(Text(payload, "cwd")) ?? cwd;
                            break;
                        case "turn_context":
                            cwd = Nonempty(Text(payload, "cwd")) ?? cwd;
                            model = Nonempty(Text(payload, "model")) ?? model;
                            break;
                        case "event_msg":
                            ParseEvent(
                                payload,
                                ref currentTask,
                                ref lastResult,
                                ref tokens,
                                ref hasLifecycle,
                                ref lifecycleActive,
                                ref attentionStatus);
                            break;
                        case "response_item":
                            ParseResponse(
                                payload,
                                ref currentTask,
                                ref lastResult,
                                ref attentionStatus);
                            break;
                    }
                }
            }
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }

        if (string.IsNullOrWhiteSpace(sessionId) || startedAt is null)
            return null;
        currentTask ??= Summary(model, tokens.TotalTokens);
        return new ParsedCodexSession(
            LiveText.FirstLine(sessionId, 128)!,
            LiveText.FirstLine(Path.GetFileName(cwd), 80) ?? "Codex",
            currentTask,
            lastResult,
            LiveText.FirstLine(model, 128),
            tokens,
            startedAt.Value,
            updatedAt ?? modifiedAt,
            hasLifecycle,
            lifecycleActive,
            attentionStatus,
            modifiedAt,
            path,
            cwd);
    }

    private static LiveSession Materialize(
        ParsedCodexSession parsed,
        DateTimeOffset now) =>
        new(
            "codex",
            parsed.SessionId,
            parsed.ProjectLabel,
            null,
            parsed.AttentionStatus
            ?? (parsed.HasLifecycle
                ? (parsed.LifecycleActive ? "active" : "idle")
                : (now - parsed.ModifiedAt <= ActiveAfter ? "active" : "idle")),
            [],
            parsed.CurrentTask,
            parsed.LastResult,
            parsed.Model,
            parsed.Tokens,
            parsed.StartedAt,
            parsed.UpdatedAt,
            TranscriptPath: parsed.Path,
            WorkingDirectory: parsed.WorkingDirectory);

    private static void ParseEvent(
        JsonElement payload,
        ref string? currentTask,
        ref string? lastResult,
        ref LiveTokenSnapshot tokens,
        ref bool hasLifecycle,
        ref bool lifecycleActive,
        ref string? attentionStatus)
    {
        switch (Text(payload, "type"))
        {
            case "task_started":
            case "turn_started":
                hasLifecycle = true;
                lifecycleActive = true;
                attentionStatus = null;
                break;
            case "task_complete":
            case "turn_complete":
                hasLifecycle = true;
                lifecycleActive = false;
                attentionStatus = null;
                break;
            case "turn_aborted":
                hasLifecycle = true;
                lifecycleActive = false;
                attentionStatus = string.Equals(
                    Text(payload, "reason"),
                    "interrupted",
                    StringComparison.OrdinalIgnoreCase)
                    ? null
                    : "blocked";
                break;
            case "exec_approval_request":
            case "apply_patch_approval_request":
            case "request_user_input":
                hasLifecycle = true;
                lifecycleActive = true;
                attentionStatus = "needs_input";
                break;
            case "error":
            case "task_failed":
            case "turn_failed":
                hasLifecycle = true;
                lifecycleActive = false;
                attentionStatus = "blocked";
                break;
            case "user_message":
                var user = Text(payload, "message") ?? Text(payload, "text");
                if (LiveText.IsCodexUserText(user))
                {
                    currentTask = LiveText.FirstLine(user, 120);
                    lastResult = null;
                    attentionStatus = null;
                }
                break;
            case "agent_message":
                var agent = Text(payload, "message") ?? Text(payload, "text");
                if (LiveText.IsPlainAgentPreview(agent))
                    lastResult = LiveText.FirstLine(agent, 200);
                break;
            case "token_count":
                if (payload.TryGetProperty("info", out var info) &&
                    info.ValueKind == JsonValueKind.Object &&
                    info.TryGetProperty("total_token_usage", out var usage) &&
                    usage.ValueKind == JsonValueKind.Object)
                {
                    var rawInput = Nonnegative(usage, "input_tokens");
                    var cached = Nonnegative(usage, "cached_input_tokens") ?? 0;
                    var output = Nonnegative(usage, "output_tokens");
                    var reasoning = Nonnegative(usage, "reasoning_output_tokens");
                    var total = Nonnegative(usage, "total_tokens");
                    total = total is > 0 ? total : (rawInput ?? 0) + (output ?? 0);
                    tokens = new LiveTokenSnapshot(
                        rawInput is null ? null : Math.Max(0, rawInput.Value - cached),
                        output,
                        cached,
                        0,
                        reasoning,
                        total,
                        LiveTokenScope.SessionCumulative);
                }
                break;
        }
    }

    private static void ParseResponse(
        JsonElement payload,
        ref string? currentTask,
        ref string? lastResult,
        ref string? attentionStatus)
    {
        var type = Text(payload, "type");
        if (type is "function_call_output" or "custom_tool_call_output")
        {
            attentionStatus = null;
            return;
        }
        if (type is "exec_approval_request"
            or "apply_patch_approval_request"
            or "request_user_input")
        {
            attentionStatus = "needs_input";
            return;
        }
        if (type is "function_call" or "custom_tool_call")
        {
            var name = Text(payload, "name");
            if (name is "request_user_input"
                or "exec_approval_request"
                or "apply_patch_approval_request")
                attentionStatus = "needs_input";
            return;
        }
        if (!string.Equals(type, "message", StringComparison.Ordinal))
            return;
        var role = Text(payload, "role");
        if (role == "user")
        {
            var text = ContentText(payload, ["input_text", "text"]);
            if (LiveText.IsCodexUserText(text))
            {
                currentTask = LiveText.FirstLine(text, 120);
                lastResult = null;
                attentionStatus = null;
            }
        }
        else if (role == "assistant")
        {
            var text = ContentText(payload, ["output_text", "text"]) ??
                       Text(payload, "text") ??
                       Text(payload, "message");
            lastResult = LiveText.FirstLine(text, 200) ?? lastResult;
        }
    }

    private static string? ContentText(JsonElement payload, HashSet<string> types)
    {
        if (payload.ValueKind != JsonValueKind.Object ||
            !payload.TryGetProperty("content", out var content) ||
            content.ValueKind != JsonValueKind.Array)
            return null;
        foreach (var block in content.EnumerateArray())
        {
            if (types.Contains(Text(block, "type") ?? string.Empty) &&
                Nonempty(Text(block, "text")) is { } text)
                return text;
        }
        return null;
    }

    private static string? Summary(string? model, long? tokens)
    {
        var parts = new List<string>();
        if (!string.IsNullOrWhiteSpace(model))
            parts.Add($"model {model}");
        if (tokens is not null)
            parts.Add($"{tokens:N0} tokens");
        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }

    private static DateTimeOffset? ParseTimestamp(JsonElement root) =>
        DateTimeOffset.TryParse(
            Text(root, "timestamp"),
            CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal,
            out var timestamp)
            ? timestamp
            : null;

    private static string? Text(JsonElement root, string property) =>
        root.ValueKind == JsonValueKind.Object &&
        root.TryGetProperty(property, out var value) &&
        value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static string? Nonempty(string? value) =>
        string.IsNullOrWhiteSpace(value) ? null : value;

    private static long? Nonnegative(JsonElement root, string property) =>
        root.ValueKind == JsonValueKind.Object &&
        root.TryGetProperty(property, out var value) &&
        value.ValueKind == JsonValueKind.Number &&
        value.TryGetInt64(out var number) &&
        number >= 0
            ? number
            : null;

    private sealed record FileCandidate(
        string Path,
        long Length,
        DateTimeOffset ModifiedAt);

    private sealed record CacheEntry(
        long Length,
        DateTimeOffset ModifiedAt,
        ParsedCodexSession? Parsed);

    private sealed record ParsedCodexSession(
        string SessionId,
        string ProjectLabel,
        string? CurrentTask,
        string? LastResult,
        string? Model,
        LiveTokenSnapshot Tokens,
        DateTimeOffset StartedAt,
        DateTimeOffset UpdatedAt,
        bool HasLifecycle,
        bool LifecycleActive,
        string? AttentionStatus,
        DateTimeOffset ModifiedAt,
        string? Path = null,
        string? WorkingDirectory = null);
}
