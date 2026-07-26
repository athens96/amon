using System.Text.Json;
using AMon.Core;
using Microsoft.Data.Sqlite;

namespace AMon.Collectors.Scanners;

public sealed class OpenCodeScanner : IUsageScanner
{
    private const string LastGoodDatabaseNote =
        "opencode.db WAL 읽기가 일시적으로 실패해 직전 정상 스캔을 유지했습니다.";
    private const string ImmutableDatabaseNote =
        "opencode.db WAL 읽기가 실패해 체크포인트된 DB만 읽었습니다.";

    private readonly string? _explicitPath;
    private readonly Func<string, string?> _getEnvironmentVariable;
    private readonly IncrementalFileCache<ParsedFileContribution> _legacyCache = new();
    private readonly IncrementalSourceMemo<ParsedFileContribution> _databaseMemo = new();

    public OpenCodeScanner(
        string? path = null,
        Func<string, string?>? getEnvironmentVariable = null)
    {
        _explicitPath = path;
        _getEnvironmentVariable = getEnvironmentVariable ?? Environment.GetEnvironmentVariable;
    }

    public string Tool => "openCode";

    internal int CachedLegacyFileParseCount => _legacyCache.ParseCount;
    internal int CachedDatabaseParseCount => _databaseMemo.ParseCount;

    public async Task<ToolSummary> ScanAsync(
        UsageScanContext context,
        CancellationToken cancellationToken = default)
    {
        var path = ResolvePath();
        var directDatabase = path.EndsWith(".db", StringComparison.OrdinalIgnoreCase);
        var pathExists = directDatabase ? File.Exists(path) : Directory.Exists(path);
        var builder = new ScannerResultBuilder(Tool, "OpenCode", pathExists, context);
        if (!pathExists)
            return builder.Build(
                0,
                null,
                "경로를 찾을 수 없습니다",
                scanSucceeded: false);

        var databasePath = directDatabase ? path : Path.Combine(path, "opencode.db");
        if (File.Exists(databasePath))
            return await ScanDatabaseAsync(databasePath, builder, cancellationToken);

        var messageDirectory = FindLegacyMessageDirectory(path);
        if (messageDirectory is null)
            return builder.Build(0, null, "opencode.db / storage/message 가 없습니다 (미사용?)");

        return await ScanLegacyFilesAsync(messageDirectory, builder, cancellationToken);
    }

    private async Task<ToolSummary> ScanDatabaseAsync(
        string databasePath,
        ScannerResultBuilder builder,
        CancellationToken cancellationToken)
    {
        ParsedFileContribution contribution;
        string? databaseNote = null;
        try
        {
            contribution = await _databaseMemo.ResolveAsync(
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
            if (_databaseMemo.TryGetLastGood(out contribution))
            {
                databaseNote = LastGoodDatabaseNote;
            }
            else
            {
                try
                {
                    contribution = await ParseDatabaseAsync(
                        databasePath,
                        immutable: true,
                        cancellationToken);
                    databaseNote = ImmutableDatabaseNote;
                }
                catch (SqliteException)
                {
                    return builder.Build(
                        0,
                        null,
                        "opencode.db message 조회 실패 (스키마 상이?)",
                        scanSucceeded: false);
                }
            }
        }

        contribution.Apply(builder);
        var lastActivity = contribution.Entries
            .Where(static entry => entry.Timestamp is not null)
            .Select(static entry => entry.Timestamp)
            .Max();
        var result = builder.Build(
            contribution.SessionIds.Count,
            lastActivity,
            databaseNote);
        return result.Usage.TotalTokens == 0
            ? result with
            {
                Note = string.Join(
                    " ",
                    new[]
                    {
                        databaseNote,
                        "opencode.db 에 사용 기록이 없습니다"
                    }.Where(static note => !string.IsNullOrWhiteSpace(note)))
            }
            : result;
    }

    private async Task<ToolSummary> ScanLegacyFilesAsync(
        string messageDirectory,
        ScannerResultBuilder builder,
        CancellationToken cancellationToken)
    {
        var sessions = new HashSet<string>(StringComparer.Ordinal);
        DateTimeOffset? lastActivity = null;
        var paths = Directory.EnumerateFiles(
                messageDirectory,
                "*.json",
                SearchOption.AllDirectories)
            .OrderBy(static file => file, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var cachedFiles = await _legacyCache.ResolveAsync(
            paths,
            static (file, parseCancellationToken) =>
                new ValueTask<ParsedFileContribution>(
                    ParseLegacyFileAsync(file, parseCancellationToken)),
            cancellationToken);
        foreach (var cachedFile in cachedFiles)
        {
            cancellationToken.ThrowIfCancellationRequested();
            cachedFile.Value.Apply(builder);
            foreach (var session in cachedFile.Value.SessionIds)
                sessions.Add(session);
            foreach (var entry in cachedFile.Value.Entries)
            {
                if (entry.Timestamp > lastActivity)
                    lastActivity = entry.Timestamp;
            }
        }

        return builder.Build(
            sessions.Count,
            lastActivity,
            sessions.Count == 0 ? "사용 기록이 없습니다" : null);
    }

    private static async Task<ParsedFileContribution> ParseDatabaseAsync(
        string databasePath,
        bool immutable,
        CancellationToken cancellationToken)
    {
        var entries = new List<ParsedUsageEntry>();
        var sessions = new HashSet<string>(StringComparer.Ordinal);
        await using var connection = new SqliteConnection(
            ReadOnlyConnectionString(databasePath, immutable));
        await connection.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT time_created, data
              FROM message
             WHERE json_extract(data, '$.role') = 'assistant'
            """;
        await using var rows = await command.ExecuteReaderAsync(cancellationToken);
        while (await rows.ReadAsync(cancellationToken))
        {
            cancellationToken.ThrowIfCancellationRequested();
            var timestamp = rows.IsDBNull(0) || rows.GetInt64(0) <= 0
                ? (DateTimeOffset?)null
                : DateTimeOffset.FromUnixTimeMilliseconds(rows.GetInt64(0));
            if (rows.IsDBNull(1) ||
                !TryReadMessage(rows.GetString(1), out var message))
            {
                continue;
            }

            entries.Add(new ParsedUsageEntry(
                message.Usage,
                timestamp,
                message.Model,
                message.CostUsd));
            if (!string.IsNullOrWhiteSpace(message.SessionId))
                sessions.Add(message.SessionId);
        }

        return new ParsedFileContribution(entries, sessions.ToArray());
    }

    private static async Task<ParsedFileContribution> ParseLegacyFileAsync(
        string file,
        CancellationToken cancellationToken)
    {
        var json = await SharedFile.ReadAllTextAsync(file, cancellationToken);
        if (!TryReadMessage(json, out var message))
        {
            try
            {
                using var _ = JsonDocument.Parse(json);
            }
            catch (JsonException exception)
            {
                throw new InvalidDataException(
                    "OpenCode legacy message JSON is incomplete or malformed.",
                    exception);
            }
            return ParsedFileContribution.Empty;
        }
        if (!string.Equals(message.Role, "assistant", StringComparison.OrdinalIgnoreCase))
        {
            return ParsedFileContribution.Empty;
        }

        var timestamp = message.Timestamp ??
            new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero);
        var session = string.IsNullOrWhiteSpace(message.SessionId)
            ? Path.GetFileName(Path.GetDirectoryName(file))
            : message.SessionId;
        return new ParsedFileContribution(
            [
                new ParsedUsageEntry(
                    message.Usage,
                    timestamp,
                    message.Model,
                    message.CostUsd)
            ],
            string.IsNullOrWhiteSpace(session) ? [] : [session]);
    }

    private string ResolvePath()
    {
        if (!string.IsNullOrWhiteSpace(_explicitPath))
            return Path.GetFullPath(Environment.ExpandEnvironmentVariables(_explicitPath.Trim()));

        var databaseOverride = _getEnvironmentVariable("OPENCODE_DB");
        if (!string.IsNullOrWhiteSpace(databaseOverride))
            return Path.GetFullPath(Environment.ExpandEnvironmentVariables(databaseOverride.Trim()));

        var dataOverride = _getEnvironmentVariable("OPENCODE_DATA_DIR");
        if (!string.IsNullOrWhiteSpace(dataOverride))
            return Path.GetFullPath(Environment.ExpandEnvironmentVariables(dataOverride.Trim()));

        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var candidates = new[]
        {
            Path.Combine(localAppData, "opencode", "data"),
            Path.Combine(localAppData, "ai.opencode.desktop", "opencode"),
            Path.Combine(appData, "opencode"),
            Path.Combine(userProfile, ".local", "share", "opencode")
        };
        return candidates.FirstOrDefault(HasOpenCodeData) ?? candidates[0];
    }

    private static bool HasOpenCodeData(string path) =>
        File.Exists(Path.Combine(path, "opencode.db")) ||
        Directory.Exists(Path.Combine(path, "storage", "message"));

    private static string? FindLegacyMessageDirectory(string path) =>
        new[]
        {
            Path.Combine(path, "storage", "message"),
            Path.Combine(path, "message"),
            path
        }.FirstOrDefault(Directory.Exists);

    private static bool TryReadMessage(string json, out OpenCodeMessage message)
    {
        message = default;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var role = root.TryGetProperty("role", out var roleValue) ? roleValue.GetString() : null;
            var model = root.TryGetProperty("modelID", out var modelValue) ? modelValue.GetString() : null;
            var sessionId = root.TryGetProperty("sessionID", out var sessionValue) ? sessionValue.GetString() : null;
            var cost = JsonUsage.Decimal(root, "cost");
            var usage = default(TokenUsage);
            if (root.TryGetProperty("tokens", out var tokens) && tokens.ValueKind == JsonValueKind.Object)
            {
                var cacheRead = 0L;
                var cacheWrite = 0L;
                if (tokens.TryGetProperty("cache", out var cache) && cache.ValueKind == JsonValueKind.Object)
                {
                    cacheRead = JsonUsage.Int64(cache, "read");
                    cacheWrite = JsonUsage.Int64(cache, "write");
                }

                usage = new TokenUsage(
                    JsonUsage.Int64(tokens, "input"),
                    JsonUsage.Int64(tokens, "output"),
                    cacheRead,
                    cacheWrite,
                    JsonUsage.Int64(tokens, "reasoning"));
            }

            DateTimeOffset? timestamp = null;
            if (root.TryGetProperty("time", out var time) && time.ValueKind == JsonValueKind.Object)
                timestamp = JsonUsage.Timestamp(time, "created");

            message = new OpenCodeMessage(role, model, sessionId, cost, usage, timestamp);
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
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

    private readonly record struct OpenCodeMessage(
        string? Role,
        string? Model,
        string? SessionId,
        decimal CostUsd,
        TokenUsage Usage,
        DateTimeOffset? Timestamp);
}
