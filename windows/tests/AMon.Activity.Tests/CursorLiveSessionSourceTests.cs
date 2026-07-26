using System.Text.Json;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AMon.Activity.Tests;

public sealed class CursorLiveSessionSourceTests
{
    static CursorLiveSessionSourceTests() => SQLitePCL.Batteries_V2.Init();

    [Fact]
    public async Task Reads_wal_composer_and_cache_recalculates_status_and_stale()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("cursor-live");
        var path = Path.Combine(directory, "state.vscdb");
        await using var writer = new SqliteConnection($"Data Source={path};Pooling=False");
        await writer.OpenAsync();
        await using (var schema = writer.CreateCommand())
        {
            schema.CommandText = """
                PRAGMA journal_mode=WAL;
                CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                PRAGMA wal_checkpoint(TRUNCATE);
                """;
            await schema.ExecuteNonQueryAsync();
        }
        var composer = new
        {
            composerId = "composer-1",
            name = "Composer",
            createdAt = now.AddMinutes(-1).ToUnixTimeMilliseconds(),
            lastUpdatedAt = now.ToUnixTimeMilliseconds(),
            modelConfig = new { modelName = "gpt-5" },
            fullConversationHeadersOnly = new object[]
            {
                42,
                new { bubbleId = "wrong-type", type = "1", createdAt = now.AddSeconds(-40).ToString("O") },
                new { bubbleId = "malformed-time", type = 1, createdAt = "not-a-timestamp" },
                new { bubbleId = "overflow", type = 1, createdAt = long.MaxValue },
                new { bubbleId = "u1", type = 1, createdAt = now.AddSeconds(-30).ToString("O") },
                new { bubbleId = "bad-bubble", type = 1, createdAt = now.AddSeconds(-20).ToString("O") },
                new { bubbleId = "a1", type = 2, createdAt = now.AddSeconds(-10).ToString("O") }
            }
        };
        var badHeadersComposer = new
        {
            composerId = "bad-headers",
            name = "bad",
            createdAt = now.AddMinutes(-1).ToUnixTimeMilliseconds(),
            lastUpdatedAt = now.ToUnixTimeMilliseconds(),
            fullConversationHeadersOnly = new { invalid = true }
        };
        var outOfRangeComposer = new
        {
            composerId = "out-of-range",
            name = "bad",
            createdAt = now.AddMinutes(-1).ToUnixTimeMilliseconds(),
            lastUpdatedAt = long.MaxValue
        };
        await using (var insert = writer.CreateCommand())
        {
            insert.CommandText = """
                INSERT INTO cursorDiskKV VALUES('composerData:composer-1',$composer);
                INSERT INTO cursorDiskKV VALUES('composerData:bad-root',$badRoot);
                INSERT INTO cursorDiskKV VALUES('composerData:bad-headers',$badHeaders);
                INSERT INTO cursorDiskKV VALUES('composerData:out-of-range',$outOfRange);
                INSERT INTO cursorDiskKV VALUES('bubbleId:composer-1:u1',$user);
                INSERT INTO cursorDiskKV VALUES('bubbleId:composer-1:bad-bubble',$badBubble);
                INSERT INTO cursorDiskKV VALUES('bubbleId:composer-1:a1',$assistant);
                """;
            insert.Parameters.AddWithValue("$composer", JsonSerializer.Serialize(composer));
            insert.Parameters.AddWithValue("$badRoot", JsonSerializer.Serialize("scalar"));
            insert.Parameters.AddWithValue(
                "$badHeaders",
                JsonSerializer.Serialize(badHeadersComposer));
            insert.Parameters.AddWithValue(
                "$outOfRange",
                JsonSerializer.Serialize(outOfRangeComposer));
            insert.Parameters.AddWithValue("$user", JsonSerializer.Serialize(new { text = "사용자 작업\n비공개" }));
            insert.Parameters.AddWithValue("$badBubble", JsonSerializer.Serialize(42));
            insert.Parameters.AddWithValue("$assistant", JsonSerializer.Serialize(new { text = "응답 결과\n비공개" }));
            await insert.ExecuteNonQueryAsync();
        }

        var source = new CursorLiveSessionSource(path);
        var active = Assert.Single(await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now))));
        var idle = Assert.Single(await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now.AddSeconds(91)))));
        var stale = await source.PollAsync(
            new LivePollContext(new MutableTimeProvider(now.AddMinutes(16))));

        Assert.Equal("active", active.Status);
        Assert.Equal("idle", idle.Status);
        Assert.Empty(stale);
        Assert.Equal("사용자 작업", active.CurrentTask);
        Assert.Equal("응답 결과", active.LastResult);
        Assert.Equal("gpt-5", active.Model);
        Assert.Equal(LiveTokenScope.Unavailable, active.Tokens.Scope);
        Assert.True(File.Exists(path + "-wal"));
    }

    [Fact]
    public async Task Configured_path_trims_and_expands_environment_variables()
    {
        var now = DateTimeOffset.FromUnixTimeMilliseconds(
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        var directory = TestSupport.TempDirectory("cursor-expanded-path");
        var path = Path.Combine(directory, "state.vscdb");
        await using var writer = new SqliteConnection($"Data Source={path};Pooling=False");
        await writer.OpenAsync();
        await using (var schema = writer.CreateCommand())
        {
            schema.CommandText =
                "CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value TEXT NOT NULL);";
            await schema.ExecuteNonQueryAsync();
        }
        await using (var insert = writer.CreateCommand())
        {
            insert.CommandText =
                "INSERT INTO cursorDiskKV VALUES('composerData:expanded',$composer);";
            insert.Parameters.AddWithValue(
                "$composer",
                JsonSerializer.Serialize(new
                {
                    composerId = "expanded",
                    name = "Expanded",
                    createdAt = now.AddMinutes(-1).ToUnixTimeMilliseconds(),
                    lastUpdatedAt = now.ToUnixTimeMilliseconds()
                }));
            await insert.ExecuteNonQueryAsync();
        }

        var variable = $"AMON_CURSOR_PATH_{Guid.NewGuid():N}";
        var previous = Environment.GetEnvironmentVariable(variable);
        Environment.SetEnvironmentVariable(variable, directory);
        try
        {
            var configured =
                $"  %{variable}%{Path.DirectorySeparatorChar}state.vscdb  ";
            var session = Assert.Single(await new CursorLiveSessionSource(configured)
                .PollAsync(new LivePollContext(new MutableTimeProvider(now))));

            Assert.Equal("expanded", session.SessionId);
        }
        finally
        {
            Environment.SetEnvironmentVariable(variable, previous);
        }
    }

    [Fact]
    public async Task Allows_missing_null_and_zero_created_at_with_updated_at_fallback()
    {
        var now = DateTimeOffset.FromUnixTimeMilliseconds(
            DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
        var directory = TestSupport.TempDirectory("cursor-unknown-created");
        var path = Path.Combine(directory, "state.vscdb");
        await using var writer = new SqliteConnection($"Data Source={path};Pooling=False");
        await writer.OpenAsync();
        await using (var schema = writer.CreateCommand())
        {
            schema.CommandText =
                "CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value TEXT NOT NULL);";
            await schema.ExecuteNonQueryAsync();
        }

        var variants = new (string Id, bool IncludeCreatedAt, object? CreatedAt)[]
        {
            ("missing", false, null),
            ("null", true, null),
            ("zero", true, 0)
        };
        foreach (var variant in variants)
        {
            var header = new Dictionary<string, object?>
            {
                ["bubbleId"] = "user",
                ["type"] = 1
            };
            var composer = new Dictionary<string, object?>
            {
                ["composerId"] = variant.Id,
                ["lastUpdatedAt"] = now.ToUnixTimeMilliseconds(),
                ["fullConversationHeadersOnly"] = new object[] { header }
            };
            if (variant.IncludeCreatedAt)
            {
                composer["createdAt"] = variant.CreatedAt;
                header["createdAt"] = variant.CreatedAt;
            }

            await using var insert = writer.CreateCommand();
            insert.CommandText = """
                INSERT INTO cursorDiskKV VALUES($composerKey,$composer);
                INSERT INTO cursorDiskKV VALUES($bubbleKey,$bubble);
                """;
            insert.Parameters.AddWithValue("$composerKey", "composerData:" + variant.Id);
            insert.Parameters.AddWithValue("$composer", JsonSerializer.Serialize(composer));
            insert.Parameters.AddWithValue(
                "$bubbleKey",
                $"bubbleId:{variant.Id}:user");
            insert.Parameters.AddWithValue(
                "$bubble",
                JsonSerializer.Serialize(new { text = "작업-" + variant.Id }));
            await insert.ExecuteNonQueryAsync();
        }

        var sessions = await new CursorLiveSessionSource(path)
            .PollAsync(new LivePollContext(new MutableTimeProvider(now)));

        Assert.Equal(3, sessions.Count);
        Assert.All(sessions, session => Assert.Equal(now, session.StartedAt));
        var tasks = sessions
            .Select(static session => Assert.IsType<string>(session.CurrentTask))
            .Order(StringComparer.Ordinal)
            .ToArray();
        Assert.Equal(
            ["작업-missing", "작업-null", "작업-zero"],
            tasks);
    }
}
