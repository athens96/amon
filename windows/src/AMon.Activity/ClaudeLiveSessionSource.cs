using System.Globalization;
using System.Text;
using System.Text.Json;

namespace AMon.Activity;

public sealed class ClaudeLiveSessionSource : ILiveSessionSource
{
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(15);
    public static readonly TimeSpan CleanupRetention = TimeSpan.FromMinutes(30);
    private readonly string _liveDirectory;

    public ClaudeLiveSessionSource(string? liveDirectory = null)
    {
        // The legacy directory is shared with hooks installed by earlier releases.
        _liveDirectory = Path.GetFullPath(liveDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
            "A-mon",
            "live"));
    }

    public string Provider => "claude";

    public async Task<IReadOnlyList<LiveSession>> PollAsync(
        LivePollContext context,
        CancellationToken cancellationToken = default)
    {
        if (!Directory.Exists(_liveDirectory))
            return [];

        var sessions = new List<LiveSession>();
        IEnumerable<string> paths;
        try
        {
            paths = Directory.EnumerateFiles(_liveDirectory, "*.json", SearchOption.TopDirectoryOnly)
                .ToArray();
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return [];
        }

        foreach (var path in paths)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var stamp = TryGetStamp(path);
            var retained = false;
            try
            {
                var json = await LiveSharedFile.ReadAllTextAsync(path, cancellationToken);
                using var document = JsonDocument.Parse(json);
                if (TryParse(document.RootElement, context.Now, out var session))
                {
                    sessions.Add(session);
                    retained = true;
                }
            }
            catch (Exception exception) when (
                exception is IOException or UnauthorizedAccessException or JsonException)
            {
                // Hook writes atomically, but antivirus/rotation may still make one read transient.
            }

            if (!retained
                && stamp is { } snapshotStamp
                && IsExpired(snapshotStamp, context.Now))
                TryDeleteUnchanged(path, snapshotStamp);
        }

        CleanupExpiredTombstones(context.Now, cancellationToken);
        return sessions
            .OrderBy(static session => session.StartedAt)
            .ThenBy(static session => session.SessionId, StringComparer.Ordinal)
            .ToArray();
    }

    private void CleanupExpiredTombstones(
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        var endedDirectory = Path.Combine(_liveDirectory, ".ended");
        if (!Directory.Exists(endedDirectory))
            return;

        string[] paths;
        try
        {
            paths = Directory
                .EnumerateFiles(
                    endedDirectory,
                    "*.tombstone",
                    SearchOption.TopDirectoryOnly)
                .ToArray();
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return;
        }

        foreach (var path in paths)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (TryGetStamp(path) is not { } stamp || !IsExpired(stamp, now))
                continue;
            TryDeleteUnchanged(path, stamp);
        }
    }

    private static FileStamp? TryGetStamp(string path)
    {
        try
        {
            var info = new FileInfo(path);
            return info.Exists
                ? new FileStamp(info.Length, info.LastWriteTimeUtc)
                : null;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }

    private static bool IsExpired(FileStamp stamp, DateTimeOffset now) =>
        now - new DateTimeOffset(
            DateTime.SpecifyKind(stamp.LastWriteTimeUtc, DateTimeKind.Utc))
        > CleanupRetention;

    private static void TryDeleteUnchanged(string path, FileStamp expected)
    {
        try
        {
            if (TryGetStamp(path) != expected)
                return;
            File.Delete(path);
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            // A concurrent hook update wins over cleanup.
        }
    }

    private static bool TryParse(
        JsonElement root,
        DateTimeOffset now,
        out LiveSession session)
    {
        session = null!;
        if (root.ValueKind != JsonValueKind.Object)
            return false;

        var id = Text(root, "session_id");
        if (string.IsNullOrWhiteSpace(id) ||
            !Timestamp(root, "started_at", out var startedAt) ||
            !Timestamp(root, "updated_at", out var hookUpdatedAt))
            return false;

        var updatedAt = LastActivity(root, hookUpdatedAt);
        if (now - updatedAt > StaleAfter)
            return false;

        var agents = new List<LiveAgent>();
        if (root.TryGetProperty("agents", out var agentArray))
        {
            if (agentArray.ValueKind != JsonValueKind.Array)
                return false;
            foreach (var item in agentArray.EnumerateArray())
            {
                if (item.ValueKind != JsonValueKind.Object)
                    return false;
                if (!Timestamp(item, "started_at", out var agentStarted))
                    continue;
                agents.Add(new LiveAgent(
                    LiveText.FirstLine(Text(item, "tool_use_id"), 128) ?? string.Empty,
                    LiveText.FirstLine(Text(item, "agent_type"), 64) ?? string.Empty,
                    LiveText.FirstLine(Text(item, "description"), 256) ?? string.Empty,
                    agentStarted));
            }
        }

        var input = Nonnegative(root, "input_tokens");
        var output = Nonnegative(root, "output_tokens");
        var cacheRead = Nonnegative(root, "cache_read_tokens");
        var cacheWrite = Nonnegative(root, "cache_write_tokens");
        var total = Nonnegative(root, "total_tokens");
        var hasTokens = input is not null ||
                        output is not null ||
                        cacheRead is not null ||
                        cacheWrite is not null ||
                        total is not null;
        if (total is null && hasTokens)
            total = (input ?? 0) + (output ?? 0) + (cacheRead ?? 0) + (cacheWrite ?? 0);
        var transcriptPath = Text(root, "transcript_path");
        var latestOutput = LatestTranscriptOutput(transcriptPath);
        session = new LiveSession(
            LiveText.FirstLine(Text(root, "provider"), 32) ?? "claude",
            LiveText.FirstLine(id, 128)!,
            LiveText.FirstLine(Text(root, "project_label"), 80) ?? "Claude",
            LiveText.FirstLine(Text(root, "git_branch"), 128),
            LiveText.FirstLine(Text(root, "status"), 32) ?? "idle",
            agents,
            LiveText.FirstLine(Text(root, "current_task"), 120),
            latestOutput ?? LiveText.FirstLine(Text(root, "last_result"), 200),
            LiveText.FirstLine(Text(root, "model"), 128),
            hasTokens
                ? new LiveTokenSnapshot(
                    input,
                    output,
                    cacheRead,
                    cacheWrite,
                    null,
                    total,
                    LiveTokenScope.LatestMessage)
                : LiveTokenSnapshot.Unavailable,
            startedAt,
            updatedAt,
            LiveText.FirstLine(Text(root, "notice"), 200));
        return true;
    }

    /// <summary>
    /// Reads only the latest 256 KiB and returns assistant text written after the most
    /// recent human prompt. This keeps a long running turn live without retaining the
    /// transcript or exposing tool/thinking blocks.
    /// </summary>
    private static string? LatestTranscriptOutput(string? path)
    {
        if (string.IsNullOrWhiteSpace(path))
            return null;

        try
        {
            using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            const int maximumBytes = 256 * 1024;
            var offset = Math.Max(0, stream.Length - maximumBytes);
            stream.Seek(offset, SeekOrigin.Begin);
            var buffer = new byte[checked((int)(stream.Length - offset))];
            stream.ReadExactly(buffer);
            var lines = Encoding.UTF8.GetString(buffer).Split('\n');
            var firstCompleteLine = offset > 0 ? 1 : 0;
            for (var index = lines.Length - 1; index >= firstCompleteLine; index--)
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
                    continue;
                }

                using (document)
                {
                    var root = document.RootElement;
                    if (root.ValueKind != JsonValueKind.Object ||
                        root.TryGetProperty("isSidechain", out var sidechain) &&
                        sidechain.ValueKind == JsonValueKind.True)
                        continue;
                    var type = Text(root, "type");
                    if (type == "user" && IsHumanPromptSource(Text(root, "promptSource")) &&
                        root.TryGetProperty("message", out var userMessage) &&
                        userMessage.TryGetProperty("content", out var userContent) &&
                        HumanPromptText(userContent) is not null)
                        return null;
                    if (type != "assistant" ||
                        !root.TryGetProperty("message", out var message) ||
                        !message.TryGetProperty("content", out var content))
                        continue;
                    var text = AssistantText(content);
                    if (LiveText.FirstLine(text, 200) is { } output)
                        return output;
                }
            }
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or ArgumentException
                or NotSupportedException or PathTooLongException)
        {
        }

        return null;
    }

    private static string? AssistantText(JsonElement content)
    {
        if (content.ValueKind == JsonValueKind.String)
            return content.GetString();
        if (content.ValueKind != JsonValueKind.Array)
            return null;
        var parts = content.EnumerateArray()
            .Where(block => Text(block, "type") == "text")
            .Select(block => Text(block, "text"))
            .Where(static text => !string.IsNullOrWhiteSpace(text));
        var joined = string.Join(' ', parts);
        return string.IsNullOrWhiteSpace(joined) ? null : joined;
    }

    private static string? HumanPromptText(JsonElement content)
    {
        string? text = null;
        if (content.ValueKind == JsonValueKind.String)
            text = content.GetString();
        else if (content.ValueKind == JsonValueKind.Array)
        {
            if (content.EnumerateArray().Any(block => Text(block, "type") == "tool_result"))
                return null;
            text = content.EnumerateArray()
                .Where(block => Text(block, "type") == "text")
                .Select(block => Text(block, "text"))
                .FirstOrDefault(IsRealHumanPrompt);
        }
        return IsRealHumanPrompt(text) ? text : null;
    }

    private static bool IsRealHumanPrompt(string? text)
    {
        var value = text?.TrimStart();
        if (string.IsNullOrWhiteSpace(value))
            return false;
        string[] injected =
            ["<command-", "<local-command", "<system-reminder", "<user-prompt-submit-hook", "<task-notification"];
        return !injected.Any(prefix => value.StartsWith(prefix, StringComparison.OrdinalIgnoreCase));
    }

    private static bool IsHumanPromptSource(string? source) =>
        source is "typed" or "sdk";

    /// <summary>
    /// When the session was last actually alive.
    ///
    /// The hook only touches the session file at the start and end of a turn and around
    /// subagent calls. A long turn that just uses tools never updates it, so a healthy
    /// session used to trip the 15 minute stale rule and vanish from the pet.
    ///
    /// The transcript is appended to throughout the turn, so its write time tracks real
    /// activity. Take whichever is newer — same result as running the hook on every tool
    /// call, without paying for a process launch each time.
    /// </summary>
    private static DateTimeOffset LastActivity(JsonElement root, DateTimeOffset hookUpdatedAt)
    {
        var path = Text(root, "transcript_path");
        if (string.IsNullOrWhiteSpace(path))
            return hookUpdatedAt;

        try
        {
            var info = new FileInfo(path);
            if (!info.Exists)
                return hookUpdatedAt;
            var written = new DateTimeOffset(
                DateTime.SpecifyKind(info.LastWriteTimeUtc, DateTimeKind.Utc));
            return written > hookUpdatedAt ? written : hookUpdatedAt;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException or ArgumentException
                or NotSupportedException or PathTooLongException)
        {
            return hookUpdatedAt;
        }
    }

    private static string? Text(JsonElement root, string property) =>
        root.ValueKind == JsonValueKind.Object &&
        root.TryGetProperty(property, out var value) &&
        value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static long? Nonnegative(JsonElement root, string property)
    {
        if (root.ValueKind != JsonValueKind.Object ||
            !root.TryGetProperty(property, out var value) ||
            value.ValueKind != JsonValueKind.Number ||
            !value.TryGetInt64(out var number) ||
            number < 0)
            return null;
        return number;
    }

    private static bool Timestamp(
        JsonElement root,
        string property,
        out DateTimeOffset timestamp)
    {
        timestamp = default;
        return root.ValueKind == JsonValueKind.Object &&
               root.TryGetProperty(property, out var value) &&
               value.ValueKind == JsonValueKind.String &&
               DateTimeOffset.TryParse(
                   value.GetString(),
                   CultureInfo.InvariantCulture,
                   DateTimeStyles.AssumeUniversal,
                   out timestamp);
    }

    private readonly record struct FileStamp(
        long Length,
        DateTime LastWriteTimeUtc);
}
