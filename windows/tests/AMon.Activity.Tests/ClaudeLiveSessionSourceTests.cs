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
    public async Task LatestAssistantTailOverridesCompletedHookResult()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("claude-live-tail");
        var transcript = Path.Combine(directory, "transcript.jsonl");
        await File.WriteAllLinesAsync(transcript,
        [
            """{"type":"user","promptSource":"sdk","message":{"content":"새 작업"}}""",
            """{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"비공개"},{"type":"text","text":"현재 출력\n비공개 본문"}]}}""",
            """{"type":"assistant","isSidechain":true,"message":{"content":"서브에이전트 비밀"}}""",
            """{"type":"user","promptSource":"sdk","message":{"content":"<task-notification>완료"}}""",
        ]);
        await File.WriteAllTextAsync(
            Path.Combine(directory, "live.json"),
            TestSupport.Json(new
            {
                session_id = "live-tail",
                status = "active",
                agents = Array.Empty<object>(),
                transcript_path = transcript,
                last_result = "지난 턴 출력",
                started_at = now.AddMinutes(-1),
                updated_at = now,
            }));

        var session = Assert.Single(await new ClaudeLiveSessionSource(directory)
            .PollAsync(new LivePollContext(new MutableTimeProvider(now))));

        Assert.Equal("현재 출력", session.LastResult);
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

    // The hook only writes the session file at turn boundaries and around subagent calls,
    // so a long tool-only turn used to trip the 15 minute stale rule and vanish. The
    // transcript keeps growing throughout, so its write time is the better liveness signal.
    [Fact]
    public async Task Long_tool_only_turn_survives_while_transcript_still_grows()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("claude-liveness");
        var transcript = Path.Combine(directory, "transcript.jsonl");
        await File.WriteAllTextAsync(transcript, "{}\n");
        File.SetLastWriteTimeUtc(transcript, now.AddSeconds(-30).UtcDateTime);

        await File.WriteAllTextAsync(
            Path.Combine(directory, "long-turn.json"),
            TestSupport.Json(new
            {
                session_id = "long-turn",
                agents = Array.Empty<object>(),
                started_at = now.AddHours(-1),
                updated_at = now.AddMinutes(-40),
                transcript_path = transcript
            }));

        var session = Assert.Single(await new ClaudeLiveSessionSource(directory)
            .PollAsync(new LivePollContext(new MutableTimeProvider(now))));

        Assert.Equal("long-turn", session.SessionId);
        // "몇 분째 작업 중" 이 맞으려면 훅 기록이 아니라 실제 활동 시각이어야 한다.
        Assert.True((now - session.UpdatedAt) < TimeSpan.FromMinutes(1));
    }

    [Fact]
    public async Task Dead_session_is_still_dropped_when_transcript_is_also_stale()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("claude-zombie");
        var transcript = Path.Combine(directory, "transcript.jsonl");
        await File.WriteAllTextAsync(transcript, "{}\n");
        File.SetLastWriteTimeUtc(transcript, now.AddMinutes(-40).UtcDateTime);

        await File.WriteAllTextAsync(
            Path.Combine(directory, "zombie.json"),
            TestSupport.Json(new
            {
                session_id = "zombie",
                agents = Array.Empty<object>(),
                started_at = now.AddHours(-1),
                updated_at = now.AddMinutes(-40),
                transcript_path = transcript
            }));

        Assert.Empty(await new ClaudeLiveSessionSource(directory)
            .PollAsync(new LivePollContext(new MutableTimeProvider(now))));
    }

    [Fact]
    public async Task Missing_transcript_falls_back_to_the_hook_timestamp()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("claude-no-transcript");
        await File.WriteAllTextAsync(
            Path.Combine(directory, "gone.json"),
            TestSupport.Json(new
            {
                session_id = "gone",
                agents = Array.Empty<object>(),
                started_at = now.AddHours(-1),
                updated_at = now.AddMinutes(-40),
                transcript_path = Path.Combine(directory, "does-not-exist.jsonl")
            }));
        await File.WriteAllTextAsync(
            Path.Combine(directory, "fresh.json"),
            TestSupport.Json(new
            {
                session_id = "fresh",
                agents = Array.Empty<object>(),
                started_at = now.AddMinutes(-2),
                updated_at = now
            }));

        var sessions = await new ClaudeLiveSessionSource(directory)
            .PollAsync(new LivePollContext(new MutableTimeProvider(now)));

        Assert.Equal("fresh", Assert.Single(sessions).SessionId);
    }

    [Fact]
    public async Task Reads_the_wait_reason_for_a_waiting_session()
    {
        var now = DateTimeOffset.UtcNow;
        var directory = TestSupport.TempDirectory("claude-waiting");
        await File.WriteAllTextAsync(
            Path.Combine(directory, "waiting.json"),
            TestSupport.Json(new
            {
                session_id = "waiting",
                status = "needs_input",
                agents = Array.Empty<object>(),
                started_at = now.AddMinutes(-2),
                updated_at = now,
                notice = "Claude needs your permission to use Bash"
            }));

        var session = Assert.Single(await new ClaudeLiveSessionSource(directory)
            .PollAsync(new LivePollContext(new MutableTimeProvider(now))));

        Assert.Equal("needs_input", session.Status);
        Assert.Equal("Claude needs your permission to use Bash", session.Notice);
    }
}
