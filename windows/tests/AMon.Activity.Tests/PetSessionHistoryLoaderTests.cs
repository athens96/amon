using Xunit;

namespace AMon.Activity.Tests;

public sealed class PetSessionHistoryLoaderTests
{
    [Fact]
    public void ClaudeTurnsPairPromptsWithLastReplyAndTokens()
    {
        var turns = PetSessionHistoryLoader.ClaudeTurns(
        [
            """{"type":"user","promptSource":"typed","timestamp":"2026-09-03T01:00:00Z","message":{"content":"Fix the bug\nmore"}}""",
            """{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}],"usage":{"input_tokens":5,"cache_read_input_tokens":1000,"output_tokens":20}}}""",
            """{"type":"assistant","message":{"content":[{"type":"text","text":"Fixed it."}],"usage":{"input_tokens":7,"cache_read_input_tokens":1200,"output_tokens":30}}}""",
            """{"type":"user","promptSource":"typed","message":{"content":[{"type":"tool_result","content":"ok"}]}}""",
            """{"type":"user","isSidechain":true,"promptSource":"typed","message":{"content":"subagent prompt"}}""",
            """{"type":"user","promptSource":"sdk","timestamp":"2026-09-03T01:05:00Z","message":{"content":[{"type":"text","text":"Now add tests"}]}}""",
            """{"type":"user","promptSource":"typed","message":{"content":"<task-notification>injected</task-notification>"}}""",
        ]);

        Assert.Equal(2, turns.Count);
        Assert.Equal("Fix the bug", turns[0].Prompt);
        Assert.Equal("Fixed it.", turns[0].Reply);
        Assert.Equal(1207, turns[0].InputTokens);
        Assert.Equal(50, turns[0].OutputTokens);
        Assert.Equal(new DateTimeOffset(2026, 9, 3, 1, 0, 0, TimeSpan.Zero), turns[0].Timestamp);
        Assert.Equal("Now add tests", turns[1].Prompt);
        Assert.Null(turns[1].Reply);
    }

    [Fact]
    public void CodexTurnsUseCumulativeTokenDeltas()
    {
        var turns = PetSessionHistoryLoader.CodexTurns(
        [
            """{"type":"event_msg","timestamp":"2026-09-03T02:00:00Z","payload":{"type":"user_message","message":"First"}}""",
            """{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1100,"cached_input_tokens":100,"output_tokens":40}}}}""",
            """{"type":"event_msg","payload":{"type":"agent_message","message":"Done one"}}""",
            """{"type":"event_msg","payload":{"type":"user_message","message":"Second"}}""",
            """{"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":2600,"cached_input_tokens":100,"output_tokens":90}}}}""",
        ]);

        Assert.Equal(2, turns.Count);
        Assert.Equal(1000, turns[0].InputTokens);
        Assert.Equal(40, turns[0].OutputTokens);
        Assert.Equal("Done one", turns[0].Reply);
        Assert.Equal(1500, turns[1].InputTokens);
        Assert.Equal(50, turns[1].OutputTokens);
        Assert.Null(turns[1].Reply);
    }

    [Fact]
    public void CodexFallsBackToResponseItemsWhenNoEvents()
    {
        var turns = PetSessionHistoryLoader.CodexTurns(
        [
            """{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"# AGENTS.md instructions\nskip"}]}}""",
            """{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Real ask"}]}}""",
            """{"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Answer"}]}}""",
        ]);

        var turn = Assert.Single(turns);
        Assert.Equal("Real ask", turn.Prompt);
        Assert.Equal("Answer", turn.Reply);
        Assert.Null(turn.InputTokens);
    }

    [Fact]
    public void LoadReadsTheTailOfALargeTranscript()
    {
        var path = Path.Combine(TestSupport.TempDirectory("pet-history"), "transcript.jsonl");
        var filler = """{"type":"assistant","message":{"content":[{"type":"text","text":"padding"}]}}""";
        using (var writer = new StreamWriter(path))
        {
            writer.WriteLine("""{"type":"user","promptSource":"typed","message":{"content":"Ancient prompt"}}""");
            for (var index = 0; index < 60_000; index++)
                writer.WriteLine(filler);
            writer.WriteLine("""{"type":"user","promptSource":"typed","message":{"content":"Recent prompt"}}""");
            writer.WriteLine("""{"type":"assistant","message":{"content":[{"type":"text","text":"Recent reply"}]}}""");
        }

        var turns = PetSessionHistoryLoader.Load("claude", path);

        Assert.Equal("Recent prompt", turns[^1].Prompt);
        Assert.Equal("Recent reply", turns[^1].Reply);
        Assert.Empty(PetSessionHistoryLoader.Load("cursor", path));
        Assert.Empty(PetSessionHistoryLoader.Load("claude", Path.Combine(Path.GetDirectoryName(path)!, "missing.jsonl")));
    }

    [Fact]
    public void HistoryCapsAtFiftyNewestTurns()
    {
        var lines = Enumerable.Range(0, 60).Select(index =>
            $$$"""{"type":"user","promptSource":"typed","message":{"content":"Prompt {{{index}}}"}}""");

        var turns = PetSessionHistoryLoader.ClaudeTurns(lines);

        Assert.Equal(PetSessionHistoryLoader.MaxTurns, turns.Count);
        Assert.Equal("Prompt 59", turns[^1].Prompt);
    }
}
