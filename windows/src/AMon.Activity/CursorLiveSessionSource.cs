using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace AMon.Activity;

public sealed class CursorLiveSessionSource : ILiveSessionSource
{
    public static readonly TimeSpan StaleAfter = TimeSpan.FromMinutes(15);
    public static readonly TimeSpan ActiveAfter = TimeSpan.FromSeconds(90);
    public const int MaxSessions = 8;

    private readonly string _databasePath;
    private readonly object _cacheLock = new();
    private string? _cachedFingerprint;
    private IReadOnlyList<LiveSession> _cachedSessions = [];

    public CursorLiveSessionSource(string? databasePath = null)
    {
        var resolved = string.IsNullOrWhiteSpace(databasePath)
            ? Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Cursor",
                "User",
                "globalStorage",
                "state.vscdb")
            : databasePath;
        _databasePath = Path.GetFullPath(
            Environment.ExpandEnvironmentVariables(resolved.Trim()));
    }

    public string Provider => "cursor";

    public async Task<IReadOnlyList<LiveSession>> PollAsync(
        LivePollContext context,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_databasePath))
            return [];
        var fingerprint = Fingerprint(_databasePath);
        IReadOnlyList<LiveSession>? cached = null;
        lock (_cacheLock)
        {
            if (_cachedFingerprint == fingerprint)
                cached = _cachedSessions;
        }
        if (cached is not null)
            return Refresh(cached, context.Now);

        var parsed = await ParseAsync(context.Now, cancellationToken);
        lock (_cacheLock)
        {
            _cachedFingerprint = fingerprint;
            _cachedSessions = parsed;
        }
        return Refresh(parsed, context.Now);
    }

    private async Task<IReadOnlyList<LiveSession>> ParseAsync(
        DateTimeOffset now,
        CancellationToken cancellationToken)
    {
        await using var connection = await OpenAsync(cancellationToken);
        if (connection is null)
            return [];

        var metas = new List<ComposerMeta>();
        await using (var command = connection.CreateCommand())
        {
            command.CommandText = """
                SELECT substr(key, 14),
                       CAST(json_extract(value, '$.createdAt') AS INTEGER),
                       CAST(json_extract(value, '$.lastUpdatedAt') AS INTEGER)
                  FROM cursorDiskKV
                 WHERE key > 'composerData:' AND key < 'composerData;'
                """;
            try
            {
                await using var rows = await command.ExecuteReaderAsync(cancellationToken);
                while (await rows.ReadAsync(cancellationToken))
                {
                    var updatedAt = FromEpoch(rows.IsDBNull(2) ? 0 : rows.GetInt64(2));
                    if (updatedAt is null || now - updatedAt > StaleAfter)
                        continue;
                    metas.Add(new ComposerMeta(
                        rows.GetString(0),
                        FromEpoch(rows.IsDBNull(1) ? 0 : rows.GetInt64(1)),
                        updatedAt.Value));
                }
            }
            catch (SqliteException)
            {
                return [];
            }
        }

        var sessions = new List<LiveSession>();
        foreach (var meta in metas
                     .OrderByDescending(static meta => meta.UpdatedAt)
                     .Take(MaxSessions))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var session = await ReadComposerAsync(connection, meta, cancellationToken);
            if (session is not null)
                sessions.Add(session);
        }
        return sessions;
    }

    private static async Task<LiveSession?> ReadComposerAsync(
        SqliteConnection connection,
        ComposerMeta meta,
        CancellationToken cancellationToken)
    {
        var json = await ValueAsync(connection, "composerData:" + meta.Id, cancellationToken);
        if (json is null)
            return null;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object)
                return null;

            var id = Text(root, "composerId") ?? meta.Id;
            var name = LiveText.FirstLine(Text(root, "name"), 120);
            var model = root.TryGetProperty("modelConfig", out var config)
                ? LiveText.FirstLine(Text(config, "modelName"), 128)
                : null;
            if (string.Equals(model, "default", StringComparison.OrdinalIgnoreCase))
                model = null;

            var headers = new List<BubbleHeader>();
            if (root.TryGetProperty("fullConversationHeadersOnly", out var headerArray))
            {
                if (headerArray.ValueKind != JsonValueKind.Array)
                    return null;
                foreach (var header in headerArray.EnumerateArray())
                {
                    if (header.ValueKind != JsonValueKind.Object)
                        continue;
                    var bubbleId = Text(header, "bubbleId");
                    if (string.IsNullOrWhiteSpace(bubbleId) ||
                        !TryInt32(header, "type", out var type) ||
                        !TryTimestamp(
                            header,
                            "createdAt",
                            allowUnknown: true,
                            out var createdAt))
                        continue;
                    headers.Add(new BubbleHeader(bubbleId, type, createdAt));
                }
            }

            var currentTask = await LatestTextAsync(
                connection, id, headers, type: 1, limit: 120, cancellationToken);
            if (currentTask is null && name is null)
                return null;
            var lastResult = await LatestTextAsync(
                connection, id, headers, type: 2, limit: 200, cancellationToken);
            if (!TryTimestamp(
                    root,
                    "createdAt",
                    allowUnknown: true,
                    out var composerCreatedAt) ||
                !TryTimestamp(
                    root,
                    "lastUpdatedAt",
                    allowUnknown: false,
                    out var composerUpdatedAt) ||
                composerUpdatedAt is null)
                return null;
            var startedAt = composerCreatedAt ?? composerUpdatedAt.Value;
            var updatedAt = composerUpdatedAt.Value;
            return new LiveSession(
                "cursor",
                LiveText.FirstLine(id, 128)!,
                "Cursor",
                null,
                "idle",
                [],
                currentTask ?? name,
                lastResult,
                model,
                LiveTokenSnapshot.Unavailable,
                startedAt,
                updatedAt);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static async Task<string?> LatestTextAsync(
        SqliteConnection connection,
        string composerId,
        IReadOnlyList<BubbleHeader> headers,
        int type,
        int limit,
        CancellationToken cancellationToken)
    {
        var fetched = 0;
        foreach (var header in headers.Reverse().Where(header => header.Type == type))
        {
            if (fetched++ >= 12)
                break;
            var json = await ValueAsync(
                connection,
                $"bubbleId:{composerId}:{header.Id}",
                cancellationToken);
            if (json is null)
                continue;
            try
            {
                using var document = JsonDocument.Parse(json);
                var text = LiveText.FirstLine(Text(document.RootElement, "text"), limit);
                if (text is not null)
                    return text;
            }
            catch (JsonException)
            {
                // One malformed bubble must not hide the composer.
            }
        }
        return null;
    }

    private async Task<SqliteConnection?> OpenAsync(CancellationToken cancellationToken)
    {
        foreach (var immutable in new[] { false, true })
        {
            var dataSource = immutable
                ? new Uri(_databasePath).AbsoluteUri + "?immutable=1"
                : _databasePath;
            var connection = new SqliteConnection(
                new SqliteConnectionStringBuilder
                {
                    DataSource = dataSource,
                    Mode = SqliteOpenMode.ReadOnly,
                    Pooling = false,
                    DefaultTimeout = 1
                }.ToString());
            try
            {
                await connection.OpenAsync(cancellationToken);
                await using var probe = connection.CreateCommand();
                probe.CommandText = "SELECT 1 FROM sqlite_master LIMIT 1";
                await probe.ExecuteScalarAsync(cancellationToken);
                return connection;
            }
            catch (SqliteException)
            {
                await connection.DisposeAsync();
            }
        }
        return null;
    }

    private static async Task<string?> ValueAsync(
        SqliteConnection connection,
        string key,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT value FROM cursorDiskKV WHERE key=$key";
        command.Parameters.AddWithValue("$key", key);
        return await command.ExecuteScalarAsync(cancellationToken) as string;
    }

    private static IReadOnlyList<LiveSession> Refresh(
        IReadOnlyList<LiveSession> sessions,
        DateTimeOffset now) =>
        sessions
            .Where(session => now - session.UpdatedAt <= StaleAfter)
            .Select(session => session with
            {
                Status = now - session.UpdatedAt <= ActiveAfter ? "active" : "idle"
            })
            .ToArray();

    private static string Fingerprint(string path)
    {
        static string Part(string candidate)
        {
            try
            {
                var info = new FileInfo(candidate);
                return info.Exists
                    ? $"{info.Length}:{info.LastWriteTimeUtc.Ticks}"
                    : "-1:0";
            }
            catch (Exception exception) when (
                exception is IOException or UnauthorizedAccessException)
            {
                return "-1:0";
            }
        }
        return Part(path) + "|" + Part(path + "-wal") + "|" + Part(path + "-shm");
    }

    private static bool TryTimestamp(
        JsonElement root,
        string property,
        bool allowUnknown,
        out DateTimeOffset? timestamp)
    {
        timestamp = null;
        if (root.ValueKind != JsonValueKind.Object)
            return false;
        if (!root.TryGetProperty(property, out var value))
            return allowUnknown;
        if (value.ValueKind == JsonValueKind.Null)
            return allowUnknown;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var epoch))
        {
            if (epoch == 0)
                return allowUnknown;
            timestamp = FromEpoch(epoch);
            return timestamp is not null;
        }
        if (value.ValueKind == JsonValueKind.String)
        {
            if (long.TryParse(value.GetString(), out epoch))
            {
                if (epoch == 0)
                    return allowUnknown;
                timestamp = FromEpoch(epoch);
                return timestamp is not null;
            }
            if (DateTimeOffset.TryParse(value.GetString(), out var parsedTimestamp))
            {
                timestamp = parsedTimestamp;
                return true;
            }
        }
        return false;
    }

    private static DateTimeOffset? FromEpoch(long epoch)
    {
        if (epoch <= 0)
            return null;
        try
        {
            return epoch > 10_000_000_000
                ? DateTimeOffset.FromUnixTimeMilliseconds(epoch)
                : DateTimeOffset.FromUnixTimeSeconds(epoch);
        }
        catch (ArgumentOutOfRangeException)
        {
            return null;
        }
    }

    private static string? Text(JsonElement root, string property) =>
        root.ValueKind == JsonValueKind.Object &&
        root.TryGetProperty(property, out var value) &&
        value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static bool TryInt32(
        JsonElement root,
        string property,
        out int number)
    {
        number = 0;
        return root.ValueKind == JsonValueKind.Object &&
               root.TryGetProperty(property, out var value) &&
               value.ValueKind == JsonValueKind.Number &&
               value.TryGetInt32(out number);
    }

    private sealed record ComposerMeta(
        string Id,
        DateTimeOffset? CreatedAt,
        DateTimeOffset UpdatedAt);

    private sealed record BubbleHeader(string Id, int Type, DateTimeOffset? CreatedAt);
}
