using System.Text.Json;
using AMon.ClaudeIntegration;

namespace AMon.ClaudeIntegration.Tests;

public sealed class ClaudeHookProcessorTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"amon-claude-hook-tests-{Guid.NewGuid():N}");

    [Fact]
    public void SequenceTracksResumePromptAgentStopAndEnd()
    {
        var processor = new ClaudeHookProcessor(root);

        processor.Process(Event("SessionStart", cwd: @"C:\작업 폴더"));
        processor.Process(Event("SessionStart", cwd: @"C:\temporary"));
        processor.Process(Event("UserPromptSubmit", extra: """
            "prompt": "첫 작업입니다\n전체 본문은 저장하지 않음"
            """));
        processor.Process(Event("PreToolUse", extra: """
            "tool_name": "Agent",
            "tool_use_id": "agent-1",
            "tool_input": {
              "subagent_type": "Explore",
              "description": "코드 조사\n두 번째 줄",
              "prompt": "절대로 저장하면 안 되는 비밀"
            }
            """));

        var active = Read(processor.GetSessionPath("session/one"));
        Assert.Equal(@"C:\작업 폴더", active.WorkingDirectory);
        Assert.Equal("첫 작업입니다", active.CurrentTask);
        Assert.Single(active.Agents);
        Assert.Equal("코드 조사", active.Agents[0].Description);

        var raw = File.ReadAllText(processor.GetSessionPath("session/one"));
        Assert.DoesNotContain("비밀", raw);
        Assert.DoesNotContain("전체 본문", raw);

        processor.Process(Event("PostToolUse", extra: """
            "tool_name": "Agent",
            "tool_use_id": "agent-1"
            """));
        processor.Process(Event("Stop", extra: """
            "last_assistant_message": "완료했습니다\n상세 출력"
            """));

        var stopped = Read(processor.GetSessionPath("session/one"));
        Assert.Equal("idle", stopped.Status);
        Assert.Equal("완료했습니다", stopped.LastResult);
        Assert.Empty(stopped.Agents);

        processor.Process(Event("SessionEnd"));
        Assert.False(File.Exists(processor.GetSessionPath("session/one")));
    }

    [Fact]
    public void MalformedAndUnknownPayloadsDoNothing()
    {
        var processor = new ClaudeHookProcessor(root);
        processor.Process("{");
        processor.Process("""{"hook_event_name":"Unknown","session_id":"x"}""");
        Assert.False(Directory.Exists(root));
    }

    [Fact]
    public void SessionEndTombstoneRejectsLateQueuedEvents()
    {
        var clock = new ManualTimeProvider(
            new DateTimeOffset(2026, 7, 26, 0, 0, 0, TimeSpan.Zero));
        var processor = new ClaudeHookProcessor(root, clock);
        processor.Process(Event(
            "SessionStart",
            extra: """
                "source": "startup"
                """));
        processor.Process(Event("SessionEnd"));

        processor.Process(Event(
            "Stop",
            extra: """
                "last_assistant_message": "late output"
                """));
        processor.Process(Event(
            "UserPromptSubmit",
            extra: """
                "prompt": "late prompt"
                """));
        processor.Process(Event(
            "SessionStart",
            extra: """
                "source": "startup"
                """));
        processor.Process(Event("SessionStart"));

        Assert.False(File.Exists(processor.GetSessionPath("session/one")));
        Assert.True(File.Exists(processor.GetTombstonePath("session/one")));

        clock.Advance(TimeSpan.FromSeconds(31));
        processor.Process(Event("SessionStart"));
        Assert.True(File.Exists(processor.GetSessionPath("session/one")));
        Assert.False(File.Exists(processor.GetTombstonePath("session/one")));
    }

    [Fact]
    public void ResumeSessionStartImmediatelyReplacesEndedSession()
    {
        var initial = new DateTimeOffset(2026, 7, 26, 1, 0, 0, TimeSpan.Zero);
        var clock = new ManualTimeProvider(initial);
        var processor = new ClaudeHookProcessor(root, clock);
        processor.Process(Event(
            "SessionStart",
            extra: """
                "source": "startup"
                """));
        processor.Process(Event("SessionEnd"));

        clock.Advance(TimeSpan.FromSeconds(1));
        processor.Process(Event(
            "SessionStart",
            cwd: @"C:\resumed",
            extra: """
                "source": "resume"
                """));
        processor.Process(Event(
            "UserPromptSubmit",
            extra: """
                "prompt": "재개 직후 작업"
                """));
        processor.Process(Event(
            "Stop",
            extra: """
                "last_assistant_message": "재개 작업 완료"
                """));

        var resumed = Read(processor.GetSessionPath("session/one"));
        Assert.Equal(initial.AddSeconds(1), resumed.StartedAt);
        Assert.Equal(@"C:\resumed", resumed.WorkingDirectory);
        Assert.Equal("재개 직후 작업", resumed.CurrentTask);
        Assert.Equal("재개 작업 완료", resumed.LastResult);
        Assert.Equal("idle", resumed.Status);
        Assert.False(File.Exists(processor.GetTombstonePath("session/one")));
    }

    [Fact]
    public void SanitizedSessionIdsWithSamePrefixRemainIndependent()
    {
        var processor = new ClaudeHookProcessor(root);
        processor.Process(Event(
            "UserPromptSubmit",
            sessionId: "a/b",
            extra: """
                "prompt": "slash session"
                """));
        processor.Process(Event(
            "UserPromptSubmit",
            sessionId: "a?b",
            extra: """
                "prompt": "question session"
                """));

        var slashPath = processor.GetSessionPath("a/b");
        var questionPath = processor.GetSessionPath("a?b");
        Assert.NotEqual(slashPath, questionPath);
        Assert.Equal("slash session", Read(slashPath).CurrentTask);
        Assert.Equal("question session", Read(questionPath).CurrentTask);
    }

    [Fact]
    public void TranscriptTailKeepsOnlyBoundedPreviewsAndLatestUsage()
    {
        Directory.CreateDirectory(root);
        var transcript = Path.Combine(root, "세션 기록.jsonl");
        File.WriteAllLines(transcript,
        [
            """{"type":"user","promptSource":"typed","message":{"content":"실제 최신 작업\n저장 금지 상세"}}""",
            """{"type":"user","promptSource":"system","message":{"content":"<system-reminder>비밀 시스템 문구"}}""",
            """{"type":"user","message":{"content":[{"type":"tool_result","content":"도구 원문 비밀"}]}}""",
            """{"type":"assistant","message":{"model":"claude-sonnet","content":[{"type":"thinking","thinking":"비밀 추론"},{"type":"text","text":"최종 답변입니다\n출력 상세 비밀"}],"usage":{"input_tokens":10,"output_tokens":20,"cache_read_input_tokens":30,"cache_creation_input_tokens":40}}}""",
            """{"type":"assistant","isSidechain":true,"message":{"model":"sidechain-secret","content":"서브에이전트 비밀","usage":{"input_tokens":999}}}""",
        ]);
        var processor = new ClaudeHookProcessor(Path.Combine(root, "live"));

        processor.Process(Event(
            "UserPromptSubmit",
            transcriptPath: transcript,
            extra: """
                "prompt": ""
                """));
        processor.Process(Event(
            "Stop",
            transcriptPath: transcript,
            extra: """
                "last_assistant_message": ""
                """));

        var session = Read(processor.GetSessionPath("session/one"));
        Assert.Equal("claude", session.Provider);
        Assert.Equal("repo", session.ProjectLabel);
        Assert.Equal("실제 최신 작업", session.CurrentTask);
        Assert.Equal("최종 답변입니다", session.LastResult);
        Assert.Equal("claude-sonnet", session.Model);
        Assert.Equal(10, session.InputTokens);
        Assert.Equal(20, session.OutputTokens);
        Assert.Equal(30, session.CacheReadTokens);
        Assert.Equal(40, session.CacheWriteTokens);
        Assert.Equal(100, session.TotalTokens);

        var raw = File.ReadAllText(processor.GetSessionPath("session/one"));
        Assert.DoesNotContain("비밀", raw);
        Assert.DoesNotContain("sidechain-secret", raw);
        Assert.DoesNotContain("tool_result", raw);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }

    [Fact]
    public void NotificationMarksTheSessionAsWaitingWithItsReason()
    {
        var processor = new ClaudeHookProcessor(root);
        processor.Process(Event("SessionStart", cwd: @"C:\작업 폴더", extra: """
            "source": "startup"
            """));
        processor.Process(Event("UserPromptSubmit", extra: """
            "prompt": "펫 UI 구현"
            """));
        processor.Process(Event("Notification", extra: """
            "message": "Claude needs your permission to use Bash\n두 번째 줄"
            """));

        var waiting = Read(processor.GetSessionPath("session/one"));
        Assert.Equal("needs_input", waiting.Status);
        Assert.Equal("Claude needs your permission to use Bash", waiting.Notice);
        Assert.Equal("펫 UI 구현", waiting.CurrentTask);
    }

    [Theory]
    [InlineData("PreToolUse", """
        "tool_name": "Agent",
        "tool_use_id": "agent-1",
        "tool_input": { "subagent_type": "Explore", "description": "조사" }
        """)]
    [InlineData("Stop", """
        "last_assistant_message": "완료했습니다"
        """)]
    [InlineData("UserPromptSubmit", """
        "prompt": "계속 진행해"
        """)]
    public void AnyLaterEventReleasesTheWait(string eventName, string extra)
    {
        // Notification has no matching "no longer waiting" event, so the next event of any
        // kind has to clear it. Otherwise the pet sticks on needs_input forever.
        var processor = new ClaudeHookProcessor(root);
        processor.Process(Event("SessionStart", cwd: @"C:\작업 폴더", extra: """
            "source": "startup"
            """));
        processor.Process(Event("Notification", extra: """
            "message": "권한 승인 필요"
            """));
        Assert.Equal("needs_input", Read(processor.GetSessionPath("session/one")).Status);

        processor.Process(Event(eventName, extra: extra));

        var released = Read(processor.GetSessionPath("session/one"));
        Assert.Null(released.Notice);
        Assert.NotEqual("needs_input", released.Status);
    }

    [Fact]
    public void ClearResetsTheTaskSoTheFinishedWorkStopsShowing()
    {
        var processor = new ClaudeHookProcessor(root);
        processor.Process(Event("SessionStart", cwd: @"C:\작업 폴더", extra: """
            "source": "startup"
            """));
        processor.Process(Event("UserPromptSubmit", extra: """
            "prompt": "긴 작업 하나 해줘"
            """));
        processor.Process(Event("PreToolUse", extra: """
            "tool_name": "Agent",
            "tool_use_id": "agent-1",
            "tool_input": { "subagent_type": "Explore", "description": "조사" }
            """));

        processor.Process(Event("SessionStart", extra: """
            "source": "clear"
            """));

        var cleared = Read(processor.GetSessionPath("session/one"));
        Assert.Null(cleared.CurrentTask);
        Assert.Null(cleared.LastResult);
        Assert.Empty(cleared.Agents);
        Assert.Equal("idle", cleared.Status);
    }

    [Theory]
    [InlineData("compact")]
    [InlineData("resume")]
    public void CompactAndResumeKeepTheTaskGoing(string source)
    {
        var processor = new ClaudeHookProcessor(root);
        processor.Process(Event("SessionStart", cwd: @"C:\작업 폴더", extra: """
            "source": "startup"
            """));
        processor.Process(Event("UserPromptSubmit", extra: """
            "prompt": "이어서 할 작업"
            """));

        processor.Process(Event("SessionStart", extra: $"""
            "source": "{source}"
            """));

        var resumed = Read(processor.GetSessionPath("session/one"));
        Assert.Equal("이어서 할 작업", resumed.CurrentTask);
        Assert.Equal("active", resumed.Status);
    }

    [Theory]
    [InlineData("/clear", null)]
    [InlineData("/compact", null)]
    [InlineData("/COST", null)]
    [InlineData("/compact 지금까지 요약", null)]
    [InlineData("/", null)]
    [InlineData("/oh-my-claudecode:autopilot", "/oh-my-claudecode:autopilot")]
    [InlineData("/review src/app.js", "/review src/app.js")]
    [InlineData("일반 프롬프트", "일반 프롬프트")]
    public void BuiltInSlashCommandsAreNotRecordedAsTasks(string prompt, string? expected)
    {
        var processor = new ClaudeHookProcessor(root);
        processor.Process(Event("SessionStart", cwd: @"C:\작업 폴더", extra: """
            "source": "startup"
            """));

        processor.Process(Event("UserPromptSubmit", extra: $"""
            "prompt": {JsonSerializer.Serialize(prompt)}
            """));

        Assert.Equal(expected, Read(processor.GetSessionPath("session/one")).CurrentTask);
    }

    [Fact]
    public void UpgradingAnOlderInstallRegistersTheNotificationHook()
    {
        // Existing installs registered four matcher-less events. Startup reinstalls, so the
        // upgrade has to add Notification to what is already there — otherwise the pet never
        // learns that Claude is waiting.
        Directory.CreateDirectory(root);
        var settingsPath = Path.Combine(root, "settings.json");
        var executable = Path.Combine(root, ClaudeHookInstaller.ManagedExecutableName);
        File.WriteAllText(executable, string.Empty);
        new ClaudeHookInstaller(settingsPath, managedSettingsPath: null).Install(executable);
        Assert.Contains("Notification", File.ReadAllText(settingsPath));

        // A second run stays idempotent rather than stacking duplicate entries.
        new ClaudeHookInstaller(settingsPath, managedSettingsPath: null).Install(executable);

        using var document = JsonDocument.Parse(File.ReadAllText(settingsPath));
        var groups = document.RootElement
            .GetProperty("hooks")
            .GetProperty("Notification");
        Assert.Equal(1, groups.GetArrayLength());
    }

    private static ClaudeLiveSession Read(string path) =>
        JsonSerializer.Deserialize<ClaudeLiveSession>(File.ReadAllText(path))!;

    private static string Event(
        string eventName,
        string? cwd = null,
        string? transcriptPath = null,
        string sessionId = "session/one",
        string? extra = null)
    {
        var fields = new List<string>();
        if (!string.IsNullOrWhiteSpace(transcriptPath))
        {
            fields.Add($"""
                "transcript_path": {JsonSerializer.Serialize(transcriptPath)}
                """);
        }
        if (!string.IsNullOrWhiteSpace(extra))
        {
            fields.Add(extra);
        }

        var suffix = fields.Count == 0
            ? string.Empty
            : $",\n{string.Join(",\n", fields)}";
        return $$"""
            {
              "hook_event_name": "{{eventName}}",
              "session_id": {{JsonSerializer.Serialize(sessionId)}},
              "cwd": {{JsonSerializer.Serialize(cwd ?? @"C:\repo")}}
              {{suffix}}
            }
            """;
    }

    private sealed class ManualTimeProvider(DateTimeOffset current) : TimeProvider
    {
        public DateTimeOffset Current { get; private set; } = current;

        public override DateTimeOffset GetUtcNow() => Current;

        public void Advance(TimeSpan elapsed)
        {
            Current += elapsed;
        }
    }
}
