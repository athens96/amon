using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AMon.Core;
using Microsoft.Data.Sqlite;

namespace AMon.Collectors.Scanners;

public sealed class CursorScanner : IUsageScanner
{
    internal const string LocalFallbackNote =
        "Cursor usage-events API를 사용할 수 없어 로컬 state.vscdb 기록을 유지했습니다.";
    private const string LastGoodDatabaseNote =
        "state.vscdb WAL 읽기가 일시적으로 실패해 직전 정상 스캔을 유지했습니다.";
    private const string ImmutableDatabaseNote =
        "state.vscdb WAL 읽기가 실패해 체크포인트된 DB만 읽었습니다.";

    private static readonly HttpClient DefaultHttpClient = new(new HttpClientHandler
    {
        // Never forward the manually supplied Cursor session cookie to a redirect target.
        AllowAutoRedirect = false
    })
    {
        Timeout = TimeSpan.FromSeconds(30)
    };

    private readonly string? _explicitPath;
    private readonly string _eventCachePath;
    private readonly Func<string, string?> _getEnvironmentVariable;
    private readonly CursorUsageEventsClient _usageEvents;
    private readonly IncrementalSourceMemo<CursorDatabaseSnapshot> _databaseMemo = new();
    private readonly StaleAsyncMemo<CursorCsvResult> _csvMemo =
        new(TimeSpan.FromMinutes(10));

    public CursorScanner(
        string? databasePath = null,
        Func<string, string?>? getEnvironmentVariable = null,
        HttpClient? httpClient = null,
        string? eventCachePath = null)
    {
        _explicitPath = databasePath;
        _eventCachePath = eventCachePath ?? CursorUsageEventCache.DefaultPath();
        _getEnvironmentVariable = getEnvironmentVariable ?? Environment.GetEnvironmentVariable;
        _usageEvents = new CursorUsageEventsClient(httpClient ?? DefaultHttpClient);
    }

    public string Tool => "cursor";

    internal int CachedDatabaseParseCount => _databaseMemo.ParseCount;
    internal int CachedCsvFetchCount => _csvMemo.FetchCount;

    public async Task<ToolSummary> ScanAsync(
        UsageScanContext context,
        CancellationToken cancellationToken = default)
    {
        var databasePath = ResolvePath();
        var exists = File.Exists(databasePath);
        if (!exists)
            return new ScannerResultBuilder(Tool, "Cursor", false, context)
                .Build(
                    0,
                    null,
                    $"state.vscdb 를 찾을 수 없습니다. {LocalFallbackNote}",
                    scanSucceeded: false);

        try
        {
            CursorDatabaseSnapshot snapshot;
            string? databaseNote = null;
            try
            {
                snapshot = await _databaseMemo.ResolveAsync(
                    SourceFingerprint.ForSqlite(databasePath),
                    parseCancellationToken =>
                        ParseDatabaseAsync(
                            databasePath,
                            immutable: false,
                            parseCancellationToken),
                    cancellationToken);
            }
            catch (SqliteException)
            {
                if (_databaseMemo.TryGetLastGood(out snapshot))
                {
                    databaseNote = LastGoodDatabaseNote;
                }
                else
                {
                    snapshot = await ParseDatabaseAsync(
                        databasePath,
                        immutable: true,
                        cancellationToken);
                    databaseNote = ImmutableDatabaseNote;
                }
            }
            string? accessToken;
            try
            {
                accessToken = await ReadAccessTokenFromDatabaseAsync(
                    databasePath,
                    cancellationToken);
            }
            catch (SqliteException)
            {
                accessToken = null;
            }
            var csv = string.IsNullOrWhiteSpace(accessToken)
                ? null
                : await _csvMemo.ResolveAsync(
                    CsvCacheKey(accessToken, context),
                    context.Now,
                    fetchCancellationToken => _usageEvents.FetchAsync(
                        accessToken,
                        context,
                        fetchCancellationToken),
                    cancellationToken);

            // The session history estimates per-composer tokens from these same events; keep the
            // latest fetch on disk so the estimate survives an offline restart (stale-while-revalidate).
            if (csv is { Events.Count: > 0 })
            {
                CursorUsageEventCache.Store(
                    _eventCachePath,
                    context.Now,
                    csv.Events.Select(static item => new CursorUsageEvent(
                        item.Timestamp,
                        item.Model,
                        item.Usage.InputTokens,
                        item.Usage.OutputTokens,
                        item.Usage.CacheReadTokens,
                        item.Usage.CacheWriteTokens,
                        item.Usage.ReportedTotalTokens)).ToArray());
            }

            var result = csv is { Events.Count: > 0 }
                ? BuildWithCsv(
                    context,
                    snapshot.Bubbles,
                    snapshot.SessionCount,
                    snapshot.CreatedAt,
                    csv)
                : BuildDatabaseFallback(
                    context,
                    snapshot.Bubbles,
                    snapshot.SessionCount,
                    snapshot.CreatedAt);
            return string.IsNullOrWhiteSpace(databaseNote)
                ? result
                : result with
                {
                    Note = string.Join(
                        " ",
                        new[] { result.Note, databaseNote }
                            .Where(static note => !string.IsNullOrWhiteSpace(note)))
                };
        }
        catch (SqliteException)
        {
            return new ScannerResultBuilder(Tool, "Cursor", true, context).Build(
                0,
                null,
                $"cursorDiskKV 조회 실패 (형식 상이?). {LocalFallbackNote}",
                scanSucceeded: false);
        }
    }

    private static async Task<CursorDatabaseSnapshot> ParseDatabaseAsync(
        string databasePath,
        bool immutable,
        CancellationToken cancellationToken)
    {
        await using var connection = new SqliteConnection(
            ReadOnlyConnectionString(databasePath, immutable));
        await connection.OpenAsync(cancellationToken);
        var bubbles = await ReadBubblesAsync(connection, cancellationToken);
        var composers = bubbles
            .Select(static bubble => bubble.ComposerId)
            .ToHashSet(StringComparer.Ordinal);
        var createdAt = await ReadComposerTimesAsync(
            connection,
            composers,
            cancellationToken);
        return new CursorDatabaseSnapshot(
            bubbles,
            composers.Count,
            createdAt);
    }

    private static async Task<string?> ReadAccessTokenFromDatabaseAsync(
        string databasePath,
        CancellationToken cancellationToken)
    {
        await using var connection = new SqliteConnection(
            ReadOnlyConnectionString(databasePath, immutable: false));
        await connection.OpenAsync(cancellationToken);
        return await ReadAccessTokenAsync(connection, cancellationToken);
    }

    private static string CsvCacheKey(
        string accessToken,
        UsageScanContext context)
    {
        var credentialFingerprint = Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(accessToken)));
        return string.Join(
            '\0',
            credentialFingerprint,
            context.WindowStart,
            context.Today,
            context.TimeZone.Id);
    }

    private static ToolSummary BuildWithCsv(
        UsageScanContext context,
        IReadOnlyList<Bubble> bubbles,
        int sessions,
        IReadOnlyDictionary<string, DateTimeOffset> createdAt,
        CursorCsvResult csv)
    {
        var builder = new ScannerResultBuilder("cursor", "Cursor", true, context);
        DateTimeOffset? lastActivity = null;

        // CSV owns the scan window. Only DB history before that window (or records whose
        // approximate composer date is unavailable) contributes to all-time totals.
        foreach (var bubble in bubbles)
        {
            createdAt.TryGetValue(bubble.ComposerId, out var timestamp);
            if (timestamp != default)
            {
                var date = context.LocalDate(timestamp);
                if (date >= context.WindowStart && date <= context.Today)
                    continue;
                if (timestamp > lastActivity)
                    lastActivity = timestamp;
            }

            builder.AddTotal(
                new TokenUsage(bubble.Input, bubble.Output),
                model: null,
                includeModelTotal: false);
        }

        foreach (var usageEvent in csv.Events)
        {
            builder.Add(
                usageEvent.Usage,
                usageEvent.Timestamp,
                usageEvent.Model,
                usageEvent.CostUsd);
            if (usageEvent.Timestamp > lastActivity)
                lastActivity = usageEvent.Timestamp;
        }

        return builder.Build(sessions, lastActivity, "소비 토큰은 Cursor 대시보드 API 기준");
    }

    private static ToolSummary BuildDatabaseFallback(
        UsageScanContext context,
        IReadOnlyList<Bubble> bubbles,
        int sessions,
        IReadOnlyDictionary<string, DateTimeOffset> createdAt)
    {
        var builder = new ScannerResultBuilder("cursor", "Cursor", true, context);
        DateTimeOffset? lastActivity = null;
        foreach (var bubble in bubbles)
        {
            createdAt.TryGetValue(bubble.ComposerId, out var timestamp);
            builder.Add(
                new TokenUsage(bubble.Input, bubble.Output),
                timestamp == default ? null : timestamp,
                model: null);
            if (timestamp > lastActivity)
                lastActivity = timestamp;
        }

        var prefix = bubbles.Count == 0 ? "토큰 기록이 있는 대화가 없습니다. " : string.Empty;
        return builder.Build(sessions, lastActivity, prefix + LocalFallbackNote);
    }

    private static async Task<List<Bubble>> ReadBubblesAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT key,
                   json_extract(value, '$.tokenCount.inputTokens'),
                   json_extract(value, '$.tokenCount.outputTokens')
              FROM cursorDiskKV
             WHERE key LIKE 'bubbleId:%'
               AND (json_extract(value, '$.tokenCount.inputTokens') > 0
                    OR json_extract(value, '$.tokenCount.outputTokens') > 0)
            """;
        await using var rows = await command.ExecuteReaderAsync(cancellationToken);
        var bubbles = new List<Bubble>();
        while (await rows.ReadAsync(cancellationToken))
        {
            var key = rows.IsDBNull(0) ? string.Empty : rows.GetString(0);
            var parts = key.Split(':', 3);
            if (parts.Length != 3 || string.IsNullOrWhiteSpace(parts[1]))
                continue;

            bubbles.Add(new Bubble(
                parts[1],
                rows.IsDBNull(1) ? 0 : Math.Max(0, rows.GetInt64(1)),
                rows.IsDBNull(2) ? 0 : Math.Max(0, rows.GetInt64(2))));
        }
        return bubbles;
    }

    private static async Task<Dictionary<string, DateTimeOffset>> ReadComposerTimesAsync(
        SqliteConnection connection,
        IEnumerable<string> composerIds,
        CancellationToken cancellationToken)
    {
        var result = new Dictionary<string, DateTimeOffset>(StringComparer.Ordinal);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT json_extract(value, '$.createdAt')
              FROM cursorDiskKV
             WHERE key = $key
            """;
        var key = command.Parameters.Add("$key", SqliteType.Text);
        foreach (var composerId in composerIds)
        {
            cancellationToken.ThrowIfCancellationRequested();
            key.Value = "composerData:" + composerId;
            var value = await command.ExecuteScalarAsync(cancellationToken);
            if (TryEpochMilliseconds(value, out var timestamp))
                result[composerId] = timestamp;
        }
        return result;
    }

    private static async Task<string?> ReadAccessTokenAsync(
        SqliteConnection connection,
        CancellationToken cancellationToken)
    {
        try
        {
            await using var command = connection.CreateCommand();
            command.CommandText = """
                SELECT value
                  FROM ItemTable
                 WHERE key = 'cursorAuth/accessToken'
                """;
            var value = await command.ExecuteScalarAsync(cancellationToken) as string;
            if (string.IsNullOrWhiteSpace(value))
                return null;

            try
            {
                return JsonSerializer.Deserialize<string>(value) ?? value;
            }
            catch (JsonException)
            {
                return value;
            }
        }
        catch (SqliteException)
        {
            // ItemTable is absent in signed-out/older installations. Local history remains valid.
            return null;
        }
    }

    private string ResolvePath()
    {
        if (!string.IsNullOrWhiteSpace(_explicitPath))
            return Path.GetFullPath(Environment.ExpandEnvironmentVariables(_explicitPath.Trim()));

        var overridePath = _getEnvironmentVariable("CURSOR_DB");
        if (!string.IsNullOrWhiteSpace(overridePath))
            return Path.GetFullPath(Environment.ExpandEnvironmentVariables(overridePath.Trim()));

        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        return Path.Combine(appData, "Cursor", "User", "globalStorage", "state.vscdb");
    }

    private static bool TryEpochMilliseconds(object? value, out DateTimeOffset timestamp)
    {
        timestamp = default;
        if (value is long number && number > 0)
        {
            timestamp = DateTimeOffset.FromUnixTimeMilliseconds(number);
            return true;
        }
        if (value is double floating && floating > 0)
        {
            timestamp = DateTimeOffset.FromUnixTimeMilliseconds(checked((long)floating));
            return true;
        }
        if (value is string text && long.TryParse(text, out number) && number > 0)
        {
            timestamp = DateTimeOffset.FromUnixTimeMilliseconds(number);
            return true;
        }
        return false;
    }

    private static string ReadOnlyConnectionString(string path, bool immutable)
    {
        var dataSource = immutable
            ? new Uri(Path.GetFullPath(path)).AbsoluteUri + "?immutable=1"
            : Path.GetFullPath(path);
        return new SqliteConnectionStringBuilder
        {
            DataSource = dataSource,
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
            DefaultTimeout = 1
        }.ToString();
    }

    private readonly record struct Bubble(string ComposerId, long Input, long Output);

    private sealed record CursorDatabaseSnapshot(
        IReadOnlyList<Bubble> Bubbles,
        int SessionCount,
        IReadOnlyDictionary<string, DateTimeOffset> CreatedAt);
}
