using AMon.Collectors;
using AMon.Collectors.Scanners;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AMon.Collectors.Tests;

public sealed class OpenCodeScannerTests
{
    static OpenCodeScannerTests() => SQLitePCL.Batteries_V2.Init();

    [Fact]
    public async Task Database_takes_priority_over_legacy_files_and_includes_cost()
    {
        var directory = CreateDirectory();
        var databasePath = Path.Combine(directory, "opencode.db");
        await CreateDatabaseAsync(databasePath, """
            {"role":"assistant","modelID":"gpt-5","sessionID":"session-db","cost":1.25,
             "tokens":{"input":10,"output":4,"reasoning":2,"cache":{"read":3,"write":1}},
             "time":{"created":1785067200000}}
            """);
        var legacyDirectory = Path.Combine(directory, "storage", "message", "legacy-session");
        Directory.CreateDirectory(legacyDirectory);
        await File.WriteAllTextAsync(Path.Combine(legacyDirectory, "message.json"), """
            {"role":"assistant","sessionID":"legacy-session",
             "tokens":{"input":9999,"output":9999},"time":{"created":1785067200000}}
            """);

        var result = await new OpenCodeScanner(directory).ScanAsync(Context());

        Assert.Equal(1, result.Sessions);
        Assert.Equal(10, result.Usage.InputTokens);
        Assert.Equal(4, result.Usage.OutputTokens);
        Assert.Equal(3, result.Usage.CacheReadTokens);
        Assert.Equal(1, result.Usage.CacheWriteTokens);
        Assert.Equal(18, result.Usage.TotalTokens);
        Assert.Equal(1.25m, result.CostUsd);
        Assert.Equal(18, result.ModelTotals["gpt-5"]);
        Assert.Single(result.Daily);
    }

    [Fact]
    public async Task Legacy_storage_is_used_when_database_is_absent()
    {
        var directory = CreateDirectory();
        var sessionDirectory = Path.Combine(directory, "storage", "message", "session-file");
        Directory.CreateDirectory(sessionDirectory);
        await File.WriteAllTextAsync(Path.Combine(sessionDirectory, "assistant.json"), """
            {"role":"assistant","modelID":"claude","sessionID":"session-file","cost":"0.50",
             "tokens":{"input":7,"output":2,"cache":{"read":1,"write":0}},
             "time":{"created":1785067200000}}
            """);
        await File.WriteAllTextAsync(Path.Combine(sessionDirectory, "user.json"), """
            {"role":"user","tokens":{"input":500}}
            """);

        var result = await new OpenCodeScanner(
            getEnvironmentVariable: name => name == "OPENCODE_DATA_DIR" ? directory : null)
            .ScanAsync(Context());

        Assert.Equal(1, result.Sessions);
        Assert.Equal(10, result.Usage.TotalTokens);
        Assert.Equal(0.50m, result.CostUsd);
        Assert.Equal(10, result.ModelTotals["claude"]);
    }

    [Fact]
    public async Task Database_scan_reads_latest_message_that_exists_only_in_wal()
    {
        var directory = CreateDirectory();
        var databasePath = Path.Combine(directory, "opencode.db");
        await using var writer = new SqliteConnection(
            $"Data Source={databasePath};Pooling=False");
        await writer.OpenAsync();
        await using (var setup = writer.CreateCommand())
        {
            setup.CommandText = """
                PRAGMA journal_mode=WAL;
                CREATE TABLE message(
                    id TEXT PRIMARY KEY,
                    time_created INTEGER,
                    time_updated INTEGER,
                    data TEXT);
                PRAGMA wal_checkpoint(TRUNCATE);
                """;
            await setup.ExecuteNonQueryAsync();
        }
        await using (var insert = writer.CreateCommand())
        {
            insert.CommandText = """
                INSERT INTO message(id,time_created,time_updated,data)
                VALUES('wal-only',1785067200000,1785067200000,$data);
                """;
            insert.Parameters.AddWithValue("$data", """
                {"role":"assistant","modelID":"gpt-wal","sessionID":"wal-session",
                 "tokens":{"input":13,"output":5}}
                """);
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
            count.CommandText = "SELECT COUNT(*) FROM message";
            Assert.Equal(0L, Convert.ToInt64(await count.ExecuteScalarAsync()));
        }

        var result = await new OpenCodeScanner(directory).ScanAsync(Context());

        Assert.True(result.ScanSucceeded);
        Assert.Equal(1, result.Sessions);
        Assert.Equal(18, result.Usage.TotalTokens);
        Assert.Equal(18, result.ModelTotals["gpt-wal"]);
        Assert.DoesNotContain("체크포인트된 DB만", result.Note);
    }

    [Fact]
    public async Task Malformed_legacy_json_change_keeps_last_good_until_recovery()
    {
        var directory = CreateDirectory();
        var sessionDirectory = Path.Combine(
            directory,
            "storage",
            "message",
            "live-session");
        Directory.CreateDirectory(sessionDirectory);
        var path = Path.Combine(sessionDirectory, "assistant.json");
        await File.WriteAllTextAsync(path, """
            {"role":"assistant","modelID":"gpt-live","sessionID":"live-session",
             "tokens":{"input":7,"output":3},"time":{"created":1785067200000}}
            """);
        var scanner = new OpenCodeScanner(directory);

        var fresh = await scanner.ScanAsync(Context());
        await File.WriteAllTextAsync(
            path,
            """{"role":"assistant","modelID":"partial","tokens":{"input":999""");
        var stale = await scanner.ScanAsync(Context());

        Assert.Equal(fresh.Usage, stale.Usage);
        Assert.Equal(1, scanner.CachedLegacyFileParseCount);

        await File.WriteAllTextAsync(path, """
            {"role":"assistant","modelID":"gpt-live","sessionID":"live-session",
             "tokens":{"input":15,"output":5},"time":{"created":1785067200000}}
            """);
        var recovered = await scanner.ScanAsync(Context());

        Assert.Equal(20, recovered.Usage.TotalTokens);
        Assert.Equal(2, scanner.CachedLegacyFileParseCount);
    }

    private static async Task CreateDatabaseAsync(string path, string messageJson)
    {
        await using var connection = new SqliteConnection($"Data Source={path};Pooling=False");
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = """
            CREATE TABLE message(id TEXT PRIMARY KEY, time_created INTEGER, time_updated INTEGER, data TEXT);
            INSERT INTO message(id,time_created,time_updated,data) VALUES('m1',1785067200000,1785067200000,$data);
            """;
        command.Parameters.AddWithValue("$data", messageJson);
        await command.ExecuteNonQueryAsync();
    }

    private static UsageScanContext Context() =>
        new(DateTimeOffset.Parse("2026-07-26T12:00:00Z"), TimeZoneInfo.Utc, 30);

    private static string CreateDirectory()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"amon-opencode-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        return directory;
    }
}
