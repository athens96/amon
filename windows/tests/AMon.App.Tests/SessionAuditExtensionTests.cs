using AMon.App;

namespace AMon.App.Tests;

public sealed class SessionAuditExtensionTests
{
    [Theory]
    [InlineData("mcp__github__create_issue", "github")]
    [InlineData("mcp__plugin_oh-my-claudecode_t__lsp_hover", "oh-my-claudecode")]
    [InlineData("mcp__solo", "solo")]
    [InlineData("mcp_github_create_issue", "github")]
    [InlineData("Bash", null)]
    [InlineData("", null)]
    public void McpServerNameFollowsClaudeAndCursorConventions(string tool, string? expected) =>
        Assert.Equal(expected, SessionTranscriptParser.McpServerName(tool));

    [Fact]
    public void ClaudeAuditCountsSkillsAndPlugins()
    {
        var path = Path.Combine(Path.GetTempPath(), $"claude-audit-{Guid.NewGuid():N}.jsonl");
        try
        {
            File.WriteAllLines(path,
            [
                """{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"code-review"}},{"type":"tool_use","name":"mcp__github__create_issue","input":{}}]}}""",
                """{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"code-review"}},{"type":"tool_use","name":"mcp__plugin_oh-my-claudecode_t__lsp_hover","input":{}},{"type":"tool_use","name":"Read","input":{"file_path":"a.txt"}}]}}""",
            ]);

            var audit = SessionTranscriptParser.Audit(path, "claude");

            Assert.Equal(["code-review ×2"], audit.Skills);
            Assert.Equal(["github ×1", "oh-my-claudecode ×1"], audit.Plugins);
            Assert.Contains("스킬 code-review ×2", audit.Extensions);
            Assert.Contains("MCP github ×1", audit.Extensions);
            Assert.Single(audit.FileAccesses);
            Assert.Contains("스킬 1", audit.Summary);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void CodexAuditCountsMcpCallsOnEitherCallType()
    {
        var path = Path.Combine(Path.GetTempPath(), $"codex-audit-{Guid.NewGuid():N}.jsonl");
        try
        {
            File.WriteAllLines(path,
            [
                """{"type":"response_item","payload":{"type":"function_call","name":"mcp__jira__search","arguments":"{}"}}""",
                """{"type":"response_item","payload":{"type":"custom_tool_call","name":"mcp__jira__get","input":"{}"}}""",
                """{"type":"response_item","payload":{"type":"function_call","name":"shell","arguments":"{\"command\":[\"git\",\"status\"]}"}}""",
            ]);

            var audit = SessionTranscriptParser.Audit(path, "codex");

            Assert.Equal(["jira ×2"], audit.Plugins);
            Assert.Empty(audit.Skills);
            Assert.Equal(["git status"], audit.ShellCommands);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void CursorSessionsResolveToTheGlobalDatabase()
    {
        var missing = Path.Combine(Path.GetTempPath(), $"cursor-{Guid.NewGuid():N}", "state.vscdb");

        // A configured path that does not exist never resolves to itself.
        Assert.NotEqual(missing, SessionLogHistoryService.FindSessionLogPath("cursor", "composer-1", cursorRoot: missing));
        Assert.Empty(SessionTranscriptParser.Parse(missing, "cursor", "composer-1"));
        Assert.Equal(SessionAuditViewModel.Empty, SessionTranscriptParser.Audit(missing, "cursor", "composer-1"));
    }
}
