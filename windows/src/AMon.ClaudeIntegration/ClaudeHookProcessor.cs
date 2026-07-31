using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AMon.ClaudeIntegration;

public sealed class ClaudeHookProcessor
{
    private const int MaximumTranscriptTailBytes = 4 * 1024 * 1024;
    private static readonly TimeSpan TombstoneLifetime = TimeSpan.FromSeconds(30);
    private static readonly string[] NonPromptPrefixes =
    [
        "<command-",
        "<local-command",
        "<system-reminder",
        "<user-prompt-submit-hook",
    ];

    // Built-in slash commands that only manipulate the conversation. They produce no
    // assistant turn, so no Stop follows — recording one as a task leaves it never finishing.
    private static readonly HashSet<string> NonTaskCommands = new(StringComparer.Ordinal)
    {
        "clear", "compact", "resume", "exit", "quit", "help", "login", "logout",
        "status", "config", "cost", "doctor", "model", "context", "usage",
    };

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        WriteIndented = false,
    };

    private readonly string liveDirectory;
    private readonly TimeProvider timeProvider;

    public ClaudeHookProcessor(string? liveDirectory = null, TimeProvider? timeProvider = null)
    {
        this.liveDirectory = liveDirectory ?? ResolveDefaultLiveDirectory();
        this.timeProvider = timeProvider ?? TimeProvider.System;
    }

    public void Process(string json)
    {
        var liveData = new ClaudeLiveDataStore(liveDirectory);
        if (liveData.IsDisabled)
        {
            return;
        }

        HookPayload? payload;
        try
        {
            payload = JsonSerializer.Deserialize<HookPayload>(json, JsonOptions);
        }
        catch (JsonException)
        {
            return;
        }

        if (payload is null || string.IsNullOrWhiteSpace(payload.SessionId))
        {
            return;
        }

        using var mutex = CreateSessionMutex(payload.SessionId);
        try
        {
            if (!mutex.WaitOne(TimeSpan.FromSeconds(4)))
            {
                return;
            }
        }
        catch (AbandonedMutexException)
        {
            // The previous hook died while updating. We own the mutex now.
        }

        try
        {
            using var mutation = ClaudeLiveMutationLock.TryAcquire(
                liveDirectory,
                TimeSpan.FromSeconds(4));
            if (mutation is null || liveData.IsDisabled)
            {
                return;
            }
            ProcessLocked(payload);
        }
        finally
        {
            try
            {
                mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // A failed acquisition is already handled above.
            }
        }
    }

    public string GetSessionPath(string sessionId) =>
        Path.Combine(liveDirectory, $"{SessionIdentity(sessionId)}.json");

    public string GetTombstonePath(string sessionId) =>
        Path.Combine(liveDirectory, ".ended", $"{SessionIdentity(sessionId)}.tombstone");

    private void ProcessLocked(HookPayload payload)
    {
        var path = GetSessionPath(payload.SessionId!);
        var tombstonePath = GetTombstonePath(payload.SessionId!);
        var now = timeProvider.GetUtcNow();
        if (payload.EventName == "SessionEnd")
        {
            WriteTombstone(tombstonePath, now);
            TryDelete(path);
            return;
        }

        if (HasActiveTombstone(tombstonePath, now))
        {
            if (payload.EventName == "SessionStart" &&
                string.Equals(payload.Source, "resume", StringComparison.Ordinal))
            {
                TryDelete(tombstonePath);
            }
            else
            {
            // Older amon versions registered async hooks. A queued event can therefore
            // arrive after SessionEnd; never let it resurrect the completed session.
                return;
            }
        }

        var session = ReadSession(path) ?? new ClaudeLiveSession
        {
            SessionId = payload.SessionId!,
            WorkingDirectory = payload.WorkingDirectory ?? string.Empty,
            ProjectLabel = ProjectLabel(payload.WorkingDirectory),
            Status = "active",
            StartedAt = now,
            UpdatedAt = now,
        };
        if (!string.IsNullOrWhiteSpace(payload.TranscriptPath))
        {
            session.TranscriptPath = payload.TranscriptPath;
        }

        switch (payload.EventName)
        {
            case "SessionStart":
                ResumeFromWait(session);
                if (string.Equals(payload.Source, "clear", StringComparison.Ordinal))
                {
                    // /clear empties the conversation but keeps the session id. Leaving the
                    // previous task behind makes the pet show finished work as still running,
                    // and /clear produces no assistant turn, so Stop never arrives to move it
                    // on. Clearing here is what keeps the display matching an empty
                    // conversation. compact/resume continue the work, so they are left alone.
                    session.CurrentTask = null;
                    session.LastResult = null;
                    session.Agents.Clear();
                    session.Status = "idle";
                }
                else
                {
                    session.Status = "active";
                }

                break;
            case "UserPromptSubmit":
                ResumeFromWait(session);
                session.Status = "active";
                session.CurrentTask = IsTaskPrompt(payload.Prompt)
                    ? FirstLine(payload.Prompt, 120)
                    : null;
                session.LastResult = null;
                var submittedTask = session.CurrentTask;
                RefreshFromTranscript(session, includeAssistantResult: false);
                session.CurrentTask = submittedTask ?? session.CurrentTask;
                break;
            case "Notification":
                // This hook fires for two different situations:
                //   1. A tool permission prompt, mid-turn. Nothing proceeds until a person
                //      acts on it.
                //   2. An idle notice ("Claude is waiting for your input"), which arrives
                //      well after the turn ended. Not blocked, just out of instructions.
                //
                // Raising both to needs_input meant case 2 landed after Stop and dragged a
                // finished session back to "waiting". needs_input deliberately never
                // auto-collapses, so it stuck there and the pet claimed to be waiting for
                // input long after the work was done.
                //
                // Tell them apart by the transcript, not by wording — the text varies with
                // version and language, the shape of the record does not. A blocking notice
                // leaves a tool_use with no result behind it; an idle one does not.
                //
                // The status flag is only the fallback because Stop does not always arrive:
                // interrupt a turn and status stays "active", so a later idle notice would
                // drag a perfectly finished session into "waiting". The transcript still
                // shows where it stopped, which is why it is asked first.
                //
                // A session already in needs_input is left alone. Ignoring a permission
                // prompt long enough produces an idle notice behind it, and overwriting there
                // would turn "needs your permission to use Bash" into "waiting for your
                // input" — losing the one thing the reason exists to say.
                if (!string.Equals(session.Status, "needs_input", StringComparison.Ordinal))
                {
                    var blocked = TurnIsOpen(session.TranscriptPath ?? payload.TranscriptPath)
                        ?? !string.Equals(session.Status, "idle", StringComparison.Ordinal);
                    if (blocked)
                    {
                        session.Notice = FirstLine(payload.Message, 200);
                        session.Status = "needs_input";
                    }
                }

                break;
            case "Stop":
                ResumeFromWait(session);
                session.Status = "idle";
                session.LastResult = FirstLine(payload.LastAssistantMessage, 200);
                var officialLastResult = session.LastResult;
                RefreshFromTranscript(session, includeAssistantResult: true);
                session.LastResult = officialLastResult ?? session.LastResult;
                session.Agents.Clear();
                break;
            case "PreToolUse" when IsAgentTool(payload.ToolName):
                RefreshFromTranscript(session, includeAssistantResult: false);
                UpsertAgent(session, payload, now);
                ResumeFromWait(session);
                session.Status = "active";
                break;
            case "PostToolUse" when IsAgentTool(payload.ToolName):
                session.Agents.RemoveAll(agent =>
                    string.Equals(agent.ToolUseId, payload.ToolUseId, StringComparison.Ordinal));
                ResumeFromWait(session);
                break;
            default:
                return;
        }

        session.UpdatedAt = now;
        WriteAtomic(path, session);
    }

    private static void RefreshFromTranscript(
        ClaudeLiveSession session,
        bool includeAssistantResult)
    {
        if (string.IsNullOrWhiteSpace(session.TranscriptPath))
        {
            return;
        }

        var lines = ReadTranscriptTail(session.TranscriptPath);
        if (lines.Count == 0)
        {
            return;
        }

        string? latestUser = null;
        AssistantSnapshot? latestAssistant = null;
        for (var index = lines.Count - 1;
             index >= 0 && (latestUser is null || latestAssistant is null);
             index--)
        {
            JsonDocument document;
            try
            {
                document = JsonDocument.Parse(lines[index]);
            }
            catch (JsonException)
            {
                continue;
            }

            using (document)
            {
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object ||
                    GetBoolean(root, "isSidechain"))
                {
                    continue;
                }

                var type = GetString(root, "type");
                if (latestUser is null && type == "user")
                {
                    latestUser = ExtractTypedUser(root);
                }
                else if (latestAssistant is null && type == "assistant")
                {
                    latestAssistant = ExtractAssistant(root);
                }
            }
        }

        if (latestUser is not null)
        {
            session.CurrentTask = FirstLine(latestUser, 120);
        }

        if (latestAssistant is not null)
        {
            session.Model = FirstLine(latestAssistant.Model, 128);
            session.InputTokens = latestAssistant.InputTokens;
            session.OutputTokens = latestAssistant.OutputTokens;
            session.CacheReadTokens = latestAssistant.CacheReadTokens;
            session.CacheWriteTokens = latestAssistant.CacheWriteTokens;
            session.TotalTokens =
                latestAssistant.InputTokens +
                latestAssistant.OutputTokens +
                latestAssistant.CacheReadTokens +
                latestAssistant.CacheWriteTokens;
            if (includeAssistantResult && latestAssistant.Text is not null)
            {
                session.LastResult = FirstLine(latestAssistant.Text, 200);
            }
        }
    }

    /// <summary>
    /// Whether the current turn is still in flight, judged from the transcript itself.
    ///
    /// The status flag is written by the Stop hook, and Stop does not arrive when the user
    /// interrupts or the process dies — so trusting it alone misreads both directions. The
    /// record does not lie: if a tool_use raised since the last typed prompt has no
    /// tool_result behind it, the turn is still going. Waiting on a permission prompt looks
    /// exactly like that — the call is written, only the result is missing.
    ///
    /// Two details matter. An assistant message is split across lines by block
    /// (thinking/text/tool_use), so the last line alone is not enough and the whole turn has
    /// to be paired up. And a tool_use abandoned by an earlier interrupted turn can still sit
    /// in the window, so the scan starts at the last typed prompt to leave that behind.
    /// </summary>
    /// <returns>null when it cannot be determined; the caller falls back to the status.</returns>
    private static bool? TurnIsOpen(string? transcriptPath)
    {
        if (string.IsNullOrWhiteSpace(transcriptPath))
            return null;

        var lines = ReadTranscriptTail(transcriptPath);
        if (lines.Count == 0)
            return null;

        // -1 keeps every line in range when no typed prompt is present in the window.
        var turnStart = -1;
        var uses = new List<(int Line, string Id)>();
        var results = new List<(int Line, string Id)>();

        for (var index = 0; index < lines.Count; index += 1)
        {
            if (string.IsNullOrWhiteSpace(lines[index]))
                continue;

            JsonDocument document;
            try
            {
                document = JsonDocument.Parse(lines[index]);
            }
            catch (JsonException)
            {
                continue; // a line clipped by the window edge
            }

            using (document)
            {
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object || GetBoolean(root, "isSidechain"))
                    continue;

                if (GetString(root, "type") == "user" && GetString(root, "promptSource") == "typed")
                    turnStart = index;

                if (!root.TryGetProperty("message", out var message) ||
                    message.ValueKind != JsonValueKind.Object ||
                    !message.TryGetProperty("content", out var content) ||
                    content.ValueKind != JsonValueKind.Array)
                    continue;

                foreach (var block in content.EnumerateArray())
                {
                    if (block.ValueKind != JsonValueKind.Object)
                        continue;
                    switch (GetString(block, "type"))
                    {
                        case "tool_use" when GetString(block, "id") is { Length: > 0 } useId:
                            uses.Add((index, useId));
                            break;
                        case "tool_result"
                            when GetString(block, "tool_use_id") is { Length: > 0 } resultId:
                            results.Add((index, resultId));
                            break;
                    }
                }
            }
        }

        var answered = results
            .Where(result => result.Line >= turnStart)
            .Select(result => result.Id)
            .ToHashSet(StringComparer.Ordinal);
        return uses.Any(use => use.Line >= turnStart && !answered.Contains(use.Id));
    }

    private static List<string> ReadTranscriptTail(string path)
    {
        try
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            var offset = Math.Max(0, stream.Length - MaximumTranscriptTailBytes);
            stream.Seek(offset, SeekOrigin.Begin);
            var length = checked((int)(stream.Length - offset));
            var buffer = new byte[length];
            stream.ReadExactly(buffer);
            var text = Encoding.UTF8.GetString(buffer);
            var lines = text.Split('\n').ToList();
            if (offset > 0 && lines.Count > 0)
            {
                lines.RemoveAt(0);
            }

            return lines;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or ArgumentException)
        {
            return [];
        }
    }

    private static string? ExtractTypedUser(JsonElement root)
    {
        if (GetString(root, "promptSource") != "typed" ||
            !root.TryGetProperty("message", out var message) ||
            !message.TryGetProperty("content", out var content))
        {
            return null;
        }

        string? text = null;
        if (content.ValueKind == JsonValueKind.String)
        {
            text = content.GetString();
        }
        else if (content.ValueKind == JsonValueKind.Array)
        {
            if (content.EnumerateArray().Any(block =>
                    GetString(block, "type") == "tool_result"))
            {
                return null;
            }

            text = content.EnumerateArray()
                .Where(block => GetString(block, "type") == "text")
                .Select(block => GetString(block, "text"))
                .FirstOrDefault(IsRealPrompt);
        }

        return IsRealPrompt(text) ? text : null;
    }

    private static AssistantSnapshot? ExtractAssistant(JsonElement root)
    {
        if (!root.TryGetProperty("message", out var message))
        {
            return null;
        }

        var text = message.TryGetProperty("content", out var content)
            ? ExtractAssistantText(content)
            : null;
        var model = GetString(message, "model");
        long input = 0;
        long output = 0;
        long cacheRead = 0;
        long cacheWrite = 0;
        if (message.TryGetProperty("usage", out var usage) &&
            usage.ValueKind == JsonValueKind.Object)
        {
            input = GetNonnegativeInt64(usage, "input_tokens");
            output = GetNonnegativeInt64(usage, "output_tokens");
            cacheRead = GetNonnegativeInt64(usage, "cache_read_input_tokens");
            cacheWrite = GetNonnegativeInt64(usage, "cache_creation_input_tokens");
        }

        return text is null && model is null && input + output + cacheRead + cacheWrite == 0
            ? null
            : new AssistantSnapshot(text, model, input, output, cacheRead, cacheWrite);
    }

    private static string? ExtractAssistantText(JsonElement content)
    {
        if (content.ValueKind == JsonValueKind.String)
        {
            return content.GetString();
        }

        if (content.ValueKind != JsonValueKind.Array)
        {
            return null;
        }

        var parts = content.EnumerateArray()
            .Where(block => GetString(block, "type") == "text")
            .Select(block => GetString(block, "text"))
            .Where(text => !string.IsNullOrWhiteSpace(text));
        var joined = string.Join(' ', parts);
        return string.IsNullOrWhiteSpace(joined) ? null : joined;
    }

    private static string? GetString(JsonElement element, string name) =>
        element.ValueKind == JsonValueKind.Object &&
        element.TryGetProperty(name, out var property) &&
        property.ValueKind == JsonValueKind.String
            ? property.GetString()
            : null;

    private static bool GetBoolean(JsonElement element, string name) =>
        element.TryGetProperty(name, out var property) &&
        property.ValueKind is JsonValueKind.True;

    private static long GetNonnegativeInt64(JsonElement element, string name)
    {
        if (!element.TryGetProperty(name, out var property) ||
            !property.TryGetInt64(out var value))
        {
            return 0;
        }

        return Math.Max(0, value);
    }

    private static bool IsRealPrompt(string? text)
    {
        var value = text?.TrimStart();
        return !string.IsNullOrWhiteSpace(value) &&
            !NonPromptPrefixes.Any(prefix =>
                value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// Whether this is work a person asked for. Injected text and built-in commands are not.
    /// </summary>
    private static bool IsTaskPrompt(string? text)
    {
        if (!IsRealPrompt(text))
        {
            return false;
        }

        var value = text!.Trim();
        if (!value.StartsWith('/'))
        {
            return true;
        }

        // Built-in commands produce no assistant turn even with arguments, so match on the
        // name alone. User skills carry a colon in the name and pass straight through.
        var name = value[1..].Split((char[]?)null, 2)[0].ToLowerInvariant();
        return name.Length > 0 && !NonTaskCommands.Contains(name);
    }

    /// <summary>
    /// The wait is over — something moved, so drop the waiting indicator.
    ///
    /// Notification has no matching "no longer waiting" event, so any later event (a tool
    /// run, the end of a response, a new prompt) counts as the release signal. Without this
    /// the pet sticks on needs_input and never auto-collapses.
    /// </summary>
    private static void ResumeFromWait(ClaudeLiveSession session)
    {
        session.Notice = null;
        if (string.Equals(session.Status, "needs_input", StringComparison.Ordinal))
        {
            session.Status = "active";
        }
    }

    private static string ProjectLabel(string? workingDirectory)
    {
        if (string.IsNullOrWhiteSpace(workingDirectory))
        {
            return string.Empty;
        }

        var trimmed = workingDirectory.TrimEnd('/', '\\');
        var separator = Math.Max(trimmed.LastIndexOf('/'), trimmed.LastIndexOf('\\'));
        return separator >= 0 ? trimmed[(separator + 1)..] : trimmed;
    }

    private static void UpsertAgent(ClaudeLiveSession session, HookPayload payload, DateTimeOffset now)
    {
        var toolUseId = FirstLine(payload.ToolUseId, 128);
        if (string.IsNullOrEmpty(toolUseId))
        {
            return;
        }

        session.Agents.RemoveAll(agent =>
            string.Equals(agent.ToolUseId, toolUseId, StringComparison.Ordinal));
        session.Agents.Add(new ClaudeLiveAgent
        {
            ToolUseId = toolUseId,
            AgentType = FirstLine(payload.ToolInput?.SubagentType, 64),
            Description = FirstLine(payload.ToolInput?.Description, 256),
            StartedAt = now,
        });
    }

    private ClaudeLiveSession? ReadSession(string path)
    {
        try
        {
            return JsonSerializer.Deserialize<ClaudeLiveSession>(
                File.ReadAllText(path, Encoding.UTF8),
                JsonOptions);
        }
        catch (IOException)
        {
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static void WriteAtomic(string path, ClaudeLiveSession session)
    {
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(path)}.{Environment.ProcessId}.{Guid.NewGuid():N}.tmp");
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(session, JsonOptions);
            using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            TryDelete(temporaryPath);
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static void WriteTombstone(string path, DateTimeOffset now)
    {
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(path)}.{Environment.ProcessId}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.WriteThrough))
            using (var writer = new StreamWriter(
                stream,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)))
            {
                writer.Write(now.ToString("O", CultureInfo.InvariantCulture));
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, path, overwrite: true);
        }
        finally
        {
            TryDelete(temporaryPath);
        }
    }

    private static bool HasActiveTombstone(string path, DateTimeOffset now)
    {
        if (!File.Exists(path))
        {
            return false;
        }

        try
        {
            var value = File.ReadAllText(path, Encoding.UTF8);
            if (DateTimeOffset.TryParseExact(
                    value,
                    "O",
                    CultureInfo.InvariantCulture,
                    DateTimeStyles.RoundtripKind,
                    out var endedAt) &&
                now - endedAt <= TombstoneLifetime)
            {
                return true;
            }
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            // A tombstone that cannot be read is conservatively treated as active.
            return true;
        }

        TryDelete(path);
        return false;
    }

    private static Mutex CreateSessionMutex(string sessionId)
    {
        return new Mutex(false, $"AMon.ClaudeLive.{SessionIdentity(sessionId)}");
    }

    private static bool IsAgentTool(string? toolName) =>
        string.Equals(toolName, "Agent", StringComparison.OrdinalIgnoreCase) ||
        string.Equals(toolName, "Task", StringComparison.OrdinalIgnoreCase);

    private static string SessionIdentity(string sessionId)
    {
        var builder = new StringBuilder(Math.Min(sessionId.Length, 80));
        foreach (var character in sessionId.Take(80))
        {
            builder.Append(
                char.IsAsciiLetterOrDigit(character) || character is '.' or '_' or '-'
                    ? character
                    : '_');
        }

        if (builder.Length == 0)
        {
            builder.Append("unknown");
        }

        var digest = Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(sessionId)))[..24];
        return $"{builder}-{digest}";
    }

    private static string? FirstLine(string? value, int maximumRunes)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return null;
        }

        var line = value.Trim().Split(['\r', '\n'], 2)[0].Trim();
        if (line.Length == 0)
        {
            return null;
        }

        var builder = new StringBuilder();
        var count = 0;
        foreach (var rune in line.EnumerateRunes())
        {
            if (count++ >= maximumRunes)
            {
                break;
            }

            if (Rune.GetUnicodeCategory(rune) != UnicodeCategory.Control)
            {
                builder.Append(rune);
            }
        }

        return builder.Length == 0 ? null : builder.ToString();
    }

    private static string ResolveDefaultLiveDirectory()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        if (string.IsNullOrEmpty(appData))
        {
            appData = Environment.GetEnvironmentVariable("APPDATA");
        }

        if (string.IsNullOrEmpty(appData))
        {
            throw new InvalidOperationException("APPDATA is unavailable.");
        }

        // Keep reading the legacy path written by existing hook installations.
        return Path.Combine(appData, "A-mon", "live");
    }

    private sealed class HookPayload
    {
        [JsonPropertyName("session_id")]
        public string? SessionId { get; init; }

        [JsonPropertyName("cwd")]
        public string? WorkingDirectory { get; init; }

        [JsonPropertyName("hook_event_name")]
        public string? EventName { get; init; }

        [JsonPropertyName("source")]
        public string? Source { get; init; }

        [JsonPropertyName("transcript_path")]
        public string? TranscriptPath { get; init; }

        [JsonPropertyName("prompt")]
        public string? Prompt { get; init; }

        [JsonPropertyName("last_assistant_message")]
        public string? LastAssistantMessage { get; init; }

        // Notification only. Claude's own wording for what it is waiting on.
        [JsonPropertyName("message")]
        public string? Message { get; init; }

        [JsonPropertyName("tool_name")]
        public string? ToolName { get; init; }

        [JsonPropertyName("tool_use_id")]
        public string? ToolUseId { get; init; }

        [JsonPropertyName("tool_input")]
        public AgentToolInput? ToolInput { get; init; }
    }

    private sealed class AgentToolInput
    {
        [JsonPropertyName("subagent_type")]
        public string? SubagentType { get; init; }

        [JsonPropertyName("description")]
        public string? Description { get; init; }

        // Deliberately no "prompt" property. Agent prompts are never read or retained.
    }

    private sealed record AssistantSnapshot(
        string? Text,
        string? Model,
        long InputTokens,
        long OutputTokens,
        long CacheReadTokens,
        long CacheWriteTokens);
}
