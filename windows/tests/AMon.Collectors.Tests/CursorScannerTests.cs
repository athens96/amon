using AMon.Collectors;
using AMon.Collectors.Scanners;
using Microsoft.Data.Sqlite;
using System.Net;
using System.Text;
using System.Text.Json;
using Xunit;

namespace AMon.Collectors.Tests;

public sealed class CursorScannerTests
{
    static CursorScannerTests() => SQLitePCL.Batteries_V2.Init();

    [Fact]
    public async Task Local_history_aggregates_bubbles_and_deduplicates_composer_sessions()
    {
        var databasePath = Path.Combine(
            Path.GetTempPath(),
            $"amon-cursor-{Guid.NewGuid():N}.vscdb");
        await CreateDatabaseAsync(databasePath);

        var result = await new CursorScanner(databasePath).ScanAsync(Context());

        Assert.True(result.PathExists);
        Assert.Equal(2, result.Sessions);
        Assert.Equal(17, result.Usage.InputTokens);
        Assert.Equal(8, result.Usage.OutputTokens);
        Assert.Equal(25, result.Usage.TotalTokens);
        Assert.Equal(2, result.Daily.Count);
        Assert.Contains("로컬 state.vscdb", result.Note);
        Assert.Equal(25, result.ModelTotals["unknown"]);
    }

    [Fact]
    public async Task Environment_override_is_used_and_missing_path_is_reported()
    {
        var missing = Path.Combine(Path.GetTempPath(), $"missing-{Guid.NewGuid():N}.vscdb");
        var result = await new CursorScanner(
            getEnvironmentVariable: name => name == "CURSOR_DB" ? missing : null)
            .ScanAsync(Context());

        Assert.False(result.PathExists);
        Assert.False(result.ScanSucceeded);
        Assert.Contains("찾을 수 없습니다", result.Note);
        Assert.Contains("usage-events API", result.Note);
    }

    [Fact]
    public async Task Csv_success_replaces_database_window_and_maps_named_columns()
    {
        var databasePath = Path.Combine(
            Path.GetTempPath(),
            $"amon-cursor-csv-{Guid.NewGuid():N}.vscdb");
        var token = CreateJwt("auth0|user_123");
        await CreateCsvDatabaseAsync(databasePath, token);
        var csv = """
            Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
            2026-07-25T10:00:00.000Z,"gpt,5",2,5,3,4,14,1.25
            2026-07-26T11:00:00Z,claude,1,6,0,3,12,0.50
            """;
        string? requestUri = null;
        string? cookie = null;
        var httpClient = new HttpClient(new StubHandler(request =>
        {
            requestUri = request.RequestUri?.ToString();
            cookie = request.Headers.GetValues("Cookie").Single();
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent(csv, Encoding.UTF8, "text/csv")
            };
        }));

        var result = await new CursorScanner(databasePath, httpClient: httpClient).ScanAsync(Context());

        var expectedStart = DateTimeOffset.Parse("2026-06-27T00:00:00Z").ToUnixTimeMilliseconds();
        var expectedEnd = Context().Now.ToUnixTimeMilliseconds();
        Assert.Contains($"startDate={expectedStart}", requestUri);
        Assert.Contains($"endDate={expectedEnd}", requestUri);
        Assert.Contains("strategy=tokens", requestUri);
        Assert.Equal($"WorkosCursorSessionToken=user_123%3A%3A{token}", cookie);
        Assert.Equal(2, result.Sessions);
        Assert.Equal(111, result.Usage.InputTokens);
        Assert.Equal(17, result.Usage.OutputTokens);
        Assert.Equal(3, result.Usage.CacheReadTokens);
        Assert.Equal(3, result.Usage.CacheWriteTokens);
        Assert.Equal(136, result.Usage.TotalTokens);
        Assert.Equal(1.75m, result.CostUsd);
        Assert.Equal(2, result.Daily.Count);
        Assert.DoesNotContain(result.Daily, day => day.Model == "unknown");
        Assert.Equal(14, result.ModelTotals["gpt,5"]);
        Assert.Equal(12, result.ModelTotals["claude"]);
        Assert.Contains("대시보드 API 기준", result.Note);
    }

    [Fact]
    public async Task Csv_failure_keeps_database_result_without_leaking_secrets()
    {
        var databasePath = Path.Combine(
            Path.GetTempPath(),
            $"amon-cursor-failure-{Guid.NewGuid():N}.vscdb");
        var token = CreateJwt("auth0|user_123") + "-private";
        await CreateCsvDatabaseAsync(databasePath, token);
        const string privateBody = "private-response-body";
        var httpClient = new HttpClient(new StubHandler(_ =>
            new HttpResponseMessage(HttpStatusCode.InternalServerError)
            {
                Content = new StringContent(privateBody)
            }));

        var result = await new CursorScanner(databasePath, httpClient: httpClient).ScanAsync(Context());

        Assert.Equal(132, result.Usage.TotalTokens);
        Assert.Equal(132, result.ModelTotals["unknown"]);
        Assert.Contains("로컬 state.vscdb", result.Note);
        Assert.DoesNotContain(token, result.Note);
        Assert.DoesNotContain(privateBody, result.Note);
    }

    [Fact]
    public async Task Csv_is_fetched_once_per_ttl_and_failure_keeps_same_credentials_stale_value()
    {
        var databasePath = Path.Combine(
            Path.GetTempPath(),
            $"amon-cursor-ttl-{Guid.NewGuid():N}.vscdb");
        await CreateCsvDatabaseAsync(databasePath, CreateJwt("auth0|user_123"));
        const string csv = """
            Date,Model,Input (w/ Cache Write),Input (w/o Cache Write),Cache Read,Output Tokens,Total Tokens,Cost
            2026-07-26T11:00:00Z,gpt-5,0,6,0,3,9,0.25
            """;
        var requests = 0;
        var httpClient = new HttpClient(new StubHandler(_ =>
        {
            requests++;
            return requests == 1
                ? new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = new StringContent(csv, Encoding.UTF8, "text/csv")
                }
                : new HttpResponseMessage(HttpStatusCode.InternalServerError);
        }));
        var scanner = new CursorScanner(databasePath, httpClient: httpClient);
        var now = DateTimeOffset.Parse("2026-07-26T12:00:00Z");

        var fresh = await scanner.ScanAsync(Context(now));
        var withinTtl = await scanner.ScanAsync(Context(now.AddMinutes(5)));
        var requestsWithinTtl = requests;
        var fetchesWithinTtl = scanner.CachedCsvFetchCount;
        var staleAfterFailure = await scanner.ScanAsync(Context(now.AddMinutes(11)));

        Assert.Equal(1, requestsWithinTtl);
        Assert.Equal(fresh.Usage, withinTtl.Usage);
        Assert.Equal(1, scanner.CachedDatabaseParseCount);
        Assert.Equal(1, fetchesWithinTtl);
        Assert.Equal(fresh.Usage, staleAfterFailure.Usage);
        Assert.Equal(2, requests);
        Assert.Equal(2, scanner.CachedCsvFetchCount);
        Assert.Contains("대시보드 API 기준", staleAfterFailure.Note);
    }

    [Fact]
    public async Task Database_scan_reads_latest_bubble_that_exists_only_in_wal()
    {
        var databasePath = Path.Combine(
            Path.GetTempPath(),
            $"amon-cursor-wal-{Guid.NewGuid():N}.vscdb");
        await using var writer = new SqliteConnection(
            $"Data Source={databasePath};Pooling=False");
        await writer.OpenAsync();
        await using (var setup = writer.CreateCommand())
        {
            setup.CommandText = """
                PRAGMA journal_mode=WAL;
                CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                PRAGMA wal_checkpoint(TRUNCATE);
                """;
            await setup.ExecuteNonQueryAsync();
        }
        await using (var insert = writer.CreateCommand())
        {
            insert.CommandText = """
                INSERT INTO cursorDiskKV VALUES
                  ('bubbleId:wal-composer:bubble-1',
                   '{"tokenCount":{"inputTokens":11,"outputTokens":7}}'),
                  ('composerData:wal-composer',
                   '{"createdAt":1785067200000}');
                """;
            await insert.ExecuteNonQueryAsync();
        }

        Assert.True(File.Exists(databasePath + "-wal"));
        Assert.True(new FileInfo(databasePath + "-wal").Length > 0);
        await using (var checkpointOnly = new SqliteConnection(
            new SqliteConnectionStringBuilder
            {
                DataSource = new Uri(databasePath).AbsoluteUri + "?immutable=1",
                Mode = SqliteOpenMode.ReadOnly,
                Pooling = false
            }.ToString()))
        {
            await checkpointOnly.OpenAsync();
            await using var count = checkpointOnly.CreateCommand();
            count.CommandText = "SELECT COUNT(*) FROM cursorDiskKV";
            Assert.Equal(0L, Convert.ToInt64(await count.ExecuteScalarAsync()));
        }

        var result = await new CursorScanner(databasePath).ScanAsync(Context());

        Assert.True(result.ScanSucceeded);
        Assert.Equal(1, result.Sessions);
        Assert.Equal(18, result.Usage.TotalTokens);
        Assert.DoesNotContain("체크포인트된 DB만", result.Note);
    }

    private static async Task CreateDatabaseAsync(string path)
    {
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO cursorDiskKV VALUES
              ('bubbleId:composer-a:bubble-1','{"tokenCount":{"inputTokens":10,"outputTokens":3}}'),
              ('bubbleId:composer-a:bubble-2','{"tokenCount":{"inputTokens":5,"outputTokens":4}}'),
              ('bubbleId:composer-b:bubble-3','{"tokenCount":{"inputTokens":2,"outputTokens":1}}'),
              ('bubbleId:composer-b:zero','{"tokenCount":{"inputTokens":0,"outputTokens":0}}'),
              ('composerData:composer-a','{"createdAt":1785067200000}'),
              ('composerData:composer-b','{"createdAt":1784980800000}');
            """;
        await command.ExecuteNonQueryAsync();
    }

    private static async Task CreateCsvDatabaseAsync(string path, string token)
    {
        var oldTimestamp = DateTimeOffset.Parse("2026-06-01T10:00:00Z").ToUnixTimeMilliseconds();
        var windowTimestamp = DateTimeOffset.Parse("2026-07-20T10:00:00Z").ToUnixTimeMilliseconds();
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO cursorDiskKV VALUES
              ('bubbleId:composer-old:bubble-1','{"tokenCount":{"inputTokens":100,"outputTokens":10}}'),
              ('bubbleId:composer-window:bubble-2','{"tokenCount":{"inputTokens":20,"outputTokens":2}}'),
              ('composerData:composer-old',$oldComposer),
              ('composerData:composer-window',$windowComposer);
            INSERT INTO ItemTable VALUES('cursorAuth/accessToken',$token);
            """;
        command.Parameters.AddWithValue("$oldComposer", JsonSerializer.Serialize(new { createdAt = oldTimestamp }));
        command.Parameters.AddWithValue("$windowComposer", JsonSerializer.Serialize(new { createdAt = windowTimestamp }));
        command.Parameters.AddWithValue("$token", JsonSerializer.Serialize(token));
        await command.ExecuteNonQueryAsync();
    }

    private static string CreateJwt(string subject)
    {
        static string Base64Url(string value) =>
            Convert.ToBase64String(Encoding.UTF8.GetBytes(value))
                .TrimEnd('=')
                .Replace('+', '-')
                .Replace('/', '_');
        return $"{Base64Url("{}")}.{Base64Url(JsonSerializer.Serialize(new { sub = subject }))}.signature";
    }

    private static UsageScanContext Context() =>
        new(DateTimeOffset.Parse("2026-07-26T12:00:00Z"), TimeZoneInfo.Utc, 30);

    private static UsageScanContext Context(DateTimeOffset now) =>
        new(now, TimeZoneInfo.Utc, 30);

    private sealed class StubHandler(Func<HttpRequestMessage, HttpResponseMessage> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) =>
            Task.FromResult(send(request));
    }
}
