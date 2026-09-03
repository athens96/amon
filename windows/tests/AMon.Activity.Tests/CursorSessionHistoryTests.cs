using System.Text.Json;
using Microsoft.Data.Sqlite;
using Xunit;

namespace AMon.Activity.Tests;

public sealed class CursorSessionHistoryTests
{
    static CursorSessionHistoryTests() => SQLitePCL.Batteries_V2.Init();

    private static readonly DateTimeOffset Now = new(2026, 9, 3, 12, 0, 0, TimeSpan.Zero);

    private static async Task<string> BuildDatabaseAsync(string name, Action<SqliteConnection> populate)
    {
        // Mirror Cursor's real layout so workspace lookups (…/User/workspaceStorage) resolve
        // inside the temp directory rather than two levels above it.
        var directory = Path.Combine(TestSupport.TempDirectory(name), "User", "globalStorage");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "state.vscdb");
        await using var writer = new SqliteConnection($"Data Source={path};Pooling=False");
        await writer.OpenAsync();
        await using (var schema = writer.CreateCommand())
        {
            schema.CommandText = "CREATE TABLE cursorDiskKV(key TEXT PRIMARY KEY, value TEXT NOT NULL);";
            await schema.ExecuteNonQueryAsync();
        }
        populate(writer);
        return path;
    }

    private static void Put(SqliteConnection connection, string key, object value)
    {
        using var command = connection.CreateCommand();
        command.CommandText = "INSERT INTO cursorDiskKV(key, value) VALUES ($key, $value)";
        command.Parameters.AddWithValue("$key", key);
        command.Parameters.AddWithValue("$value", value is string text ? text : JsonSerializer.Serialize(value));
        command.ExecuteNonQuery();
    }

    private static long Ms(DateTimeOffset value) => value.ToUnixTimeMilliseconds();

    private static void SeedConversation(SqliteConnection connection, string id, DateTimeOffset updated, string? model = "claude-4-sonnet")
    {
        var created = updated.AddMinutes(-30);
        Put(connection, $"composerData:{id}", new
        {
            composerId = id,
            name = "Greeting conversation",
            createdAt = Ms(created),
            lastUpdatedAt = Ms(updated),
            modelConfig = new { modelName = model },
            subagentComposerIds = new[] { "sub-1", "sub-2" },
            fullConversationHeadersOnly = new object[]
            {
                new { bubbleId = "b1", type = 1, createdAt = created.ToString("O") },
                new { bubbleId = "b2", type = 2, createdAt = created.AddMinutes(1).ToString("O") },
                new { bubbleId = "b3", type = 2, createdAt = created.AddMinutes(2).ToString("O") },
                new { bubbleId = "b4", type = 1, createdAt = created.AddMinutes(3).ToString("O") },
                new { bubbleId = "b5", type = 2, createdAt = updated.ToString("O") },
            },
        });
        Put(connection, $"bubbleId:{id}:b1", new { text = "Fix the login bug\nwith details", createdAt = created.ToString("O") });
        Put(connection, $"bubbleId:{id}:b2", new
        {
            text = "",
            createdAt = created.AddMinutes(1).ToString("O"),
            toolFormerData = new { name = "read_file_v2", @params = """{"relativeWorkspacePath":"src/login.ts"}""" },
        });
        Put(connection, $"bubbleId:{id}:b3", new
        {
            text = "Looking at the file now.",
            createdAt = created.AddMinutes(2).ToString("O"),
            toolFormerData = new { name = "run_terminal_cmd", rawArgs = new { command = "npm test" } },
        });
        Put(connection, $"bubbleId:{id}:b4", new { text = "", createdAt = created.AddMinutes(3).ToString("O") });
        Put(connection, $"bubbleId:{id}:b5", new
        {
            text = "Done — the null check was missing.",
            createdAt = updated.ToString("O"),
            toolFormerData = new { name = "mcp_github_create_issue", @params = "{}" },
        });
    }

    [Fact]
    public async Task ScanReturnsEndedConversationsWithPromptsResultAndAgents()
    {
        var path = await BuildDatabaseAsync("cursor-history-scan", connection =>
        {
            SeedConversation(connection, "old", Now.AddHours(-2));
            SeedConversation(connection, "live", Now.AddMinutes(-5));
            Put(connection, "composerData:draft", new
            {
                composerId = "draft",
                createdAt = Ms(Now.AddDays(-1)),
                lastUpdatedAt = Ms(Now.AddDays(-1)),
                fullConversationHeadersOnly = Array.Empty<object>(),
            });
        });

        var summaries = CursorSessionHistory.Scan(path, Now);

        var summary = Assert.Single(summaries);
        Assert.Equal("old", summary.Id);
        Assert.Equal(["Fix the login bug"], summary.Prompts);
        Assert.Equal(1, summary.PromptCount);
        Assert.Equal("Done — the null check was missing.", summary.LastResult);
        Assert.Equal("claude-4-sonnet", summary.Model);
        Assert.Equal(2, summary.AgentCount);
        Assert.Equal(Now.AddHours(-2), summary.EndedAt);
        Assert.Equal(Now.AddHours(-2).AddMinutes(-30), summary.StartedAt);
        Assert.Null(summary.ProjectLabel);
        Assert.Equal(5, summary.BubbleTimes.Count);
        Assert.Equal(summary.StartedAt, summary.BubbleTimes[0]);
    }

    [Fact]
    public async Task DefaultModelPlaceholderIsDropped()
    {
        var path = await BuildDatabaseAsync("cursor-history-model", connection =>
            SeedConversation(connection, "c", Now.AddHours(-1), model: "default"));

        Assert.Null(Assert.Single(CursorSessionHistory.Scan(path, Now)).Model);
    }

    [Fact]
    public async Task TurnsSkipEmptyBubblesAndKeepNarrationSeparate()
    {
        var path = await BuildDatabaseAsync("cursor-history-turns", connection =>
            SeedConversation(connection, "c", Now.AddHours(-1)));

        var turns = CursorSessionHistory.ReadTurns(path, "c");

        Assert.Equal(3, turns.Count);
        Assert.True(turns[0].IsUser);
        Assert.Equal("Fix the login bug\nwith details", turns[0].Text);
        Assert.False(turns[1].IsUser);
        Assert.Equal("Looking at the file now.", turns[1].Text);
        Assert.Equal("Done — the null check was missing.", turns[2].Text);
        Assert.NotNull(turns[2].Timestamp);
    }

    [Fact]
    public async Task ToolCallsDecodeParamsAndRawArgs()
    {
        var path = await BuildDatabaseAsync("cursor-history-tools", connection =>
            SeedConversation(connection, "c", Now.AddHours(-1)));

        var calls = CursorSessionHistory.ReadToolCalls(path, "c");

        Assert.Equal(3, calls.Count);
        Assert.Equal("read_file_v2", calls[0].Name);
        Assert.Equal("src/login.ts", calls[0].Parameters!.Value.GetProperty("relativeWorkspacePath").GetString());
        Assert.Equal("run_terminal_cmd", calls[1].Name);
        Assert.Equal("npm test", calls[1].Parameters!.Value.GetProperty("command").GetString());
        Assert.Equal("mcp_github_create_issue", calls[2].Name);
    }

    [Fact]
    public async Task WorkspaceLabelComesFromWorkspaceStorage()
    {
        var path = await BuildDatabaseAsync("cursor-history-label", connection =>
            SeedConversation(connection, "c", Now.AddHours(-1)));
        // …/User/globalStorage/state.vscdb → …/User/workspaceStorage/<hash>/{state.vscdb, workspace.json}
        var userRoot = Path.GetDirectoryName(Path.GetDirectoryName(path))!;
        var workspace = Path.Combine(userRoot, "workspaceStorage", "abc123");
        Directory.CreateDirectory(workspace);
        await File.WriteAllTextAsync(Path.Combine(workspace, "workspace.json"), """{"folder":"file:///Users/dev/my%20project"}""");
        await using (var writer = new SqliteConnection($"Data Source={Path.Combine(workspace, "state.vscdb")};Pooling=False"))
        {
            await writer.OpenAsync();
            await using var command = writer.CreateCommand();
            command.CommandText = """
                CREATE TABLE ItemTable(key TEXT PRIMARY KEY, value TEXT NOT NULL);
                INSERT INTO ItemTable VALUES ('composer.composerData', '{"allComposers":[{"composerId":"c"}]}');
                """;
            await command.ExecuteNonQueryAsync();
        }

        var summary = Assert.Single(CursorSessionHistory.Scan(path, Now));

        Assert.Equal("my project", summary.ProjectLabel);
    }

    [Fact]
    public void MissingDatabaseIsEmptyNotAnError()
    {
        var missing = Path.Combine(TestSupport.TempDirectory("cursor-history-missing"), "state.vscdb");

        Assert.Empty(CursorSessionHistory.Scan(missing, Now));
        Assert.Empty(CursorSessionHistory.ReadTurns(missing, "c"));
        Assert.Empty(CursorSessionHistory.ReadToolCalls(missing, "c"));
        // A configured path that does not exist never resolves to itself (it may fall back to the
        // machine's default database, which is environment-dependent).
        Assert.NotEqual(missing, CursorSessionHistory.ResolveDatabasePath(missing));
    }
}
