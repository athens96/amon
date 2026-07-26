using System.Text.Json;
using Xunit;

namespace AMon.Activity.Tests;

public sealed class ClaudeLiveSessionSourceTests
{
    [Fact]
    public async Task Reads_recent_snapshot_and_bounds_private_text()
    {
        var now = DateTimeOffset.Parse("2026-07-26T12:00:00Z");
        var directory = TestSupport.TempDirectory("claude-live");
        await File.WriteAllTextAsync(Path.Combine(directory, "live.json"), JsonSerializer.Serialize(new
        {
            provider = "claude",
            session_id = "session-1",
            project_label = "project",
            git_branch = "main",
            status = "active",
            agents = new[]
            {
                new
                {
                    tool_use_id = "tool-1",
                    agent_type = "Explore",
                    description = "검색 작업\n노출 금지",
                    started_at = now
                }
            },
            current_task = new string('입', 130) + "\n비공개 본문",
            last_result = new string('출', 210) + "\n비공개 본문",
            model = "claude-opus",
            input_tokens = 10,
            output_tokens = 5,
            cache_read_tokens = 7,
            cache_write_tokens = 3,
            started_at = now.AddMinutes(-2),
            updated_at = now
        }));
        await File.WriteAllTextAsync(Path.Combine(directory, "stale.json"), JsonSerializer.Serialize(new
        {
            session_id = "stale",
            project_label = "old",
            status = "active",
            agents = Array.Empty<object>(),
            started_at = now.AddHours(-1),
            updated_at = now.AddMinutes(-16)
        }));
        await File.WriteAllTextAsync(Path.Combine(directory, "broken.json"), "{");

        var sessions = await new ClaudeLiveSessionSource(directory)
            .PollAsync(new LivePollContext(new MutableTimeProvider(now)));

        var session = Assert.Single(sessions);
        Assert.Equal(120, session.CurrentTask!.EnumerateRunes().Count());
        Assert.Equal(200, session.LastResult!.EnumerateRunes().Count());
        Assert.Equal("검색 작업", Assert.Single(session.Agents).Description);
        Assert.Equal(LiveTokenScope.LatestMessage, session.Tokens.Scope);
        Assert.Equal(7, session.Tokens.CacheReadTokens);
        Assert.Equal(3, session.Tokens.CacheWriteTokens);
        Assert.Equal(25, session.Tokens.TotalTokens);
    }

    [Fact]
    public async Task Cleanup_removes_only_expired_snapshots_and_tombstones()
    {
        var now = DateTimeOffset.Parse("2026-07-26T12:00:00Z");
        var directory = TestSupport.TempDirectory("claude-retention");
        var expiredSnapshot = Path.Combine(directory, "expired.json");
        var recentStaleSnapshot = Path.Combine(directory, "recent-stale.json");
        var activeSnapshot = Path.Combine(directory, "active.json");
        var recentMalformedSnapshot = Path.Combine(directory, "recent-malformed.json");
        var unrelatedFile = Path.Combine(directory, "keep.private");

        await File.WriteAllTextAsync(
            expiredSnapshot,
            TestSupport.Json(new
            {
                session_id = "expired",
                current_task = "sensitive prompt",
                last_result = "sensitive response",
                transcript_path = @"C:\private\transcript.jsonl",
                started_at = now.AddHours(-2),
                updated_at = now.AddHours(-1)
            }));
        await File.WriteAllTextAsync(
            recentStaleSnapshot,
            TestSupport.Json(new
            {
                session_id = "recent-stale",
                current_task = "recently copied snapshot",
                started_at = now.AddHours(-2),
                updated_at = now.AddHours(-1)
            }));
        await File.WriteAllTextAsync(
            activeSnapshot,
            TestSupport.Json(new
            {
                session_id = "active",
                current_task = "still active",
                started_at = now.AddMinutes(-14),
                updated_at = now.AddMinutes(-14)
            }));
        await File.WriteAllTextAsync(recentMalformedSnapshot, "{");
        await File.WriteAllTextAsync(unrelatedFile, "not a live snapshot");

        File.SetLastWriteTimeUtc(
            expiredSnapshot,
            now.Subtract(ClaudeLiveSessionSource.CleanupRetention)
                .AddSeconds(-1).UtcDateTime);
        File.SetLastWriteTimeUtc(
            recentStaleSnapshot,
            now.AddMinutes(-5).UtcDateTime);
        File.SetLastWriteTimeUtc(
            activeSnapshot,
            now.Subtract(ClaudeLiveSessionSource.CleanupRetention)
                .AddSeconds(-1).UtcDateTime);
        File.SetLastWriteTimeUtc(
            recentMalformedSnapshot,
            now.AddMinutes(-5).UtcDateTime);
        File.SetLastWriteTimeUtc(
            unrelatedFile,
            now.AddDays(-1).UtcDateTime);

        var endedDirectory = Path.Combine(directory, ".ended");
        Directory.CreateDirectory(endedDirectory);
        var expiredTombstone = Path.Combine(endedDirectory, "expired.tombstone");
        var protectedTombstone = Path.Combine(endedDirectory, "protected.tombstone");
        var unrelatedEndedFile = Path.Combine(endedDirectory, "keep.txt");
        await File.WriteAllTextAsync(expiredTombstone, now.AddHours(-1).ToString("O"));
        await File.WriteAllTextAsync(protectedTombstone, now.AddSeconds(-31).ToString("O"));
        await File.WriteAllTextAsync(unrelatedEndedFile, "keep");
        File.SetLastWriteTimeUtc(
            expiredTombstone,
            now.Subtract(ClaudeLiveSessionSource.CleanupRetention)
                .AddSeconds(-1).UtcDateTime);
        File.SetLastWriteTimeUtc(
            protectedTombstone,
            now.AddSeconds(-31).UtcDateTime);
        File.SetLastWriteTimeUtc(
            unrelatedEndedFile,
            now.AddDays(-1).UtcDateTime);

        var sessions = await new ClaudeLiveSessionSource(directory)
            .PollAsync(new LivePollContext(new MutableTimeProvider(now)));

        Assert.Equal("active", Assert.Single(sessions).SessionId);
        Assert.False(File.Exists(expiredSnapshot));
        Assert.False(File.Exists(expiredTombstone));
        Assert.True(File.Exists(recentStaleSnapshot));
        Assert.True(File.Exists(activeSnapshot));
        Assert.True(File.Exists(recentMalformedSnapshot));
        Assert.True(File.Exists(protectedTombstone));
        Assert.True(File.Exists(unrelatedFile));
        Assert.True(File.Exists(unrelatedEndedFile));
    }

    [Fact]
    public async Task Valid_wrong_shapes_skip_only_their_files()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("claude-hostile");
        await File.WriteAllTextAsync(Path.Combine(directory, "array.json"), "[]");
        await File.WriteAllTextAsync(Path.Combine(directory, "scalar.json"), "42");
        await File.WriteAllTextAsync(
            Path.Combine(directory, "agents-object.json"),
            TestSupport.Json(new
            {
                session_id = "bad-agents-object",
                agents = new { invalid = true },
                started_at = now,
                updated_at = now
            }));
        await File.WriteAllTextAsync(
            Path.Combine(directory, "agent-scalar.json"),
            TestSupport.Json(new
            {
                session_id = "bad-agent-scalar",
                agents = new object[] { 1 },
                started_at = now,
                updated_at = now
            }));
        await File.WriteAllTextAsync(
            Path.Combine(directory, "valid.json"),
            TestSupport.Json(new
            {
                session_id = "valid",
                agents = Array.Empty<object>(),
                started_at = now.AddMinutes(-1),
                updated_at = now
            }));

        var sessions = await new ClaudeLiveSessionSource(directory)
            .PollAsync(new LivePollContext(new MutableTimeProvider(now)));

        Assert.Equal("valid", Assert.Single(sessions).SessionId);
    }
}
