using AMon.Core;
using AMon.LocalData;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AMon.LocalData.Tests;

public sealed class UsageDatabaseTests
{
    [Fact]
    public async Task Failed_scan_does_not_replace_last_known_good_rows()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"amon-db-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var source = Path.Combine(directory, "usage.db");
        var database = new UsageDatabase(source);
        var metadata = new UsageDatabaseMetadata(
            "machine",
            "1.0",
            "device",
            new DateTimeOffset(2026, 7, 26, 12, 0, 0, TimeSpan.Zero));

        await database.SaveAsync(
            [new ToolSummary("codex", "Codex",
                [new UsageDaily(new DateOnly(2026, 7, 26), "gpt", new TokenUsage(10, 5))])],
            metadata);
        await database.SaveAsync(
            [new ToolSummary(
                "codex",
                "Codex",
                [],
                Note: "스캔 실패",
                ScanSucceeded: false)],
            metadata);

        await using var connection = new SqliteConnection($"Data Source={source};Pooling=False");
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT input,output FROM usage_daily WHERE tool='codex'";
        await using var reader = await command.ExecuteReaderAsync();
        Assert.True(await reader.ReadAsync());
        Assert.Equal(10, reader.GetInt64(0));
        Assert.Equal(5, reader.GetInt64(1));
    }

    [Fact]
    public async Task Save_refreshes_recent_window_without_deleting_older_history()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"amon-db-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var source = Path.Combine(directory, "usage.db");
        var database = new UsageDatabase(source);
        var generatedAt = new DateTimeOffset(2026, 7, 26, 12, 0, 0, TimeSpan.Zero);

        await database.SaveAsync(
            [new ToolSummary("codex", "Codex",
            [
                new UsageDaily(new DateOnly(2026, 6, 1), "gpt", new TokenUsage(3, 1)),
                new UsageDaily(new DateOnly(2026, 7, 25), "gpt", new TokenUsage(10, 5)),
            ])],
            new UsageDatabaseMetadata("machine", "1.0", "device", generatedAt));
        await database.SaveAsync(
            [new ToolSummary("codex", "Codex",
            [
                new UsageDaily(new DateOnly(2026, 7, 25), "gpt", new TokenUsage(20, 5)),
            ])],
            new UsageDatabaseMetadata("machine", "1.0", "device", generatedAt));

        await using var connection = new SqliteConnection($"Data Source={source};Pooling=False");
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT date,input FROM usage_daily ORDER BY date";
        await using var reader = await command.ExecuteReaderAsync();
        var rows = new List<(string Date, long Input)>();
        while (await reader.ReadAsync())
            rows.Add((reader.GetString(0), reader.GetInt64(1)));

        Assert.Equal(
            [("2026-06-01", 3L), ("2026-07-25", 20L)],
            rows);
    }

    [Fact]
    public async Task Upload_snapshot_contains_only_allowlisted_tables()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"amon-db-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var source = Path.Combine(directory, "usage.db");
        var snapshot = Path.Combine(directory, "upload.db");
        var database = new UsageDatabase(source);
        await database.SaveAsync(
            [new ToolSummary("codex", "Codex", [new UsageDaily(new DateOnly(2026, 7, 26), "gpt", new TokenUsage(10, 5))])],
            new UsageDatabaseMetadata("machine", "1.0", "device", DateTimeOffset.UtcNow));

        await database.CreateUploadSnapshotAsync(snapshot);

        await using var connection = new SqliteConnection($"Data Source={snapshot};Pooling=False");
        await connection.OpenAsync();
        await using var command = connection.CreateCommand();
        command.CommandText = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name";
        await using var reader = await command.ExecuteReaderAsync();
        var tables = new List<string>();
        while (await reader.ReadAsync())
            tables.Add(reader.GetString(0));
        Assert.Equal(["meta", "usage_daily"], tables);
    }
}
