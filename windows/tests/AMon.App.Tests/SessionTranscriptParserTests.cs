using AMon.App;

namespace AMon.App.Tests;

public sealed class SessionTranscriptParserTests
{
    [Fact]
    public void ClaudeTranscriptIncludesHumanAssistantAndUsage()
    {
        var path = Path.Combine(Path.GetTempPath(), $"claude-{Guid.NewGuid():N}.jsonl");
        try
        {
            File.WriteAllLines(path,
            [
                """{"type":"user","promptSource":"typed","timestamp":"2026-01-01T00:00:00Z","message":{"content":"Fix the bug"}}""",
                """{"type":"assistant","timestamp":"2026-01-01T00:00:01Z","message":{"model":"claude-sonnet","content":[{"type":"text","text":"Done"}],"usage":{"input_tokens":10,"output_tokens":5,"cache_read_input_tokens":2,"cache_creation_input_tokens":1}}}"""
            ]);

            var turns = SessionTranscriptParser.Parse(path, "claude");

            Assert.Equal(2, turns.Count);
            Assert.Equal("사용자", turns[0].Role);
            Assert.Equal("AI", turns[1].Role);
            Assert.Equal(18, turns[1].Usage?.TotalTokens);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void CodexTranscriptCanBeReadWhileCodexKeepsLogOpenForWriting()
    {
        var path = Path.Combine(Path.GetTempPath(), $"codex-{Guid.NewGuid():N}.jsonl");
        try
        {
            File.WriteAllLines(path,
            [
                """{"type":"event_msg","timestamp":"2026-01-01T00:00:00Z","payload":{"type":"user_message","message":"Show details"}}""",
                """{"type":"response_item","timestamp":"2026-01-01T00:00:01Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Ready"}]}}"""
            ]);
            using var writer = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Write,
                FileShare.ReadWrite | FileShare.Delete);

            var turns = SessionTranscriptParser.Parse(path, "codex");

            Assert.Equal(2, turns.Count);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void AuditFindsShellFileAccessAndRiskSignals()
    {
        var path = Path.Combine(Path.GetTempPath(), $"audit-{Guid.NewGuid():N}.jsonl");
        try
        {
            File.WriteAllLines(path,
            [
                """{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git reset --hard"}},{"type":"tool_use","name":"Write","input":{"file_path":"/repo/.env"}}]}}"""
            ]);

            var audit = SessionTranscriptParser.Audit(path, "claude");

            Assert.Single(audit.ShellCommands);
            Assert.Single(audit.FileAccesses);
            Assert.Equal(2, audit.Findings.Count);
            Assert.Contains(audit.Findings, finding => finding.Title.Contains("Git"));
            Assert.Contains(audit.Findings, finding => finding.Title.Contains("민감한"));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void FindsLiveCodexLogBySessionIdWhenHistoryHasNoSourcePath()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            $"amon-session-path-{Guid.NewGuid():N}");
        var nested = Path.Combine(root, "2026", "07", "26");
        Directory.CreateDirectory(nested);
        var sessionId = "019f9d47-50d0-7d12-a92a-93e7fad087a0";
        var expected = Path.Combine(
            nested,
            $"rollout-2026-07-26T16-15-24-{sessionId}.jsonl");
        try
        {
            File.WriteAllText(expected, "{}");

            var actual = SessionLogHistoryService.FindSessionLogPath(
                "codex",
                sessionId,
                codexRoot: root);

            Assert.Equal(expected, actual);
        }
        finally
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
