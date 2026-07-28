using System.Globalization;
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
            !Timestamp(root, "updated_at", out var updatedAt) ||
            now - updatedAt > StaleAfter)
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
        session = new LiveSession(
            LiveText.FirstLine(Text(root, "provider"), 32) ?? "claude",
            LiveText.FirstLine(id, 128)!,
            LiveText.FirstLine(Text(root, "project_label"), 80) ?? "Claude",
            LiveText.FirstLine(Text(root, "git_branch"), 128),
            LiveText.FirstLine(Text(root, "status"), 32) ?? "idle",
            agents,
            LiveText.FirstLine(Text(root, "current_task"), 120),
            LiveText.FirstLine(Text(root, "last_result"), 200),
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
            updatedAt);
        return true;
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
