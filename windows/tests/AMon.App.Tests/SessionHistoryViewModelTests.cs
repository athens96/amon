using AMon.Activity;
using AMon.App.ViewModels;

namespace AMon.App.Tests;

public sealed class SessionHistoryViewModelTests
{
    [Fact]
    public void DisappearingLiveSessionIsMovedToHistory()
    {
        var path = Path.Combine(Path.GetTempPath(), $"amon-sessions-{Guid.NewGuid():N}.json");
        try
        {
            var viewModel = new SessionHistoryViewModel(path);
            viewModel.ApplySessions([CreateSession()]);

            Assert.True(viewModel.HasActiveSessions);
            Assert.Single(viewModel.ActiveSessions);

            viewModel.ApplySessions([]);

            Assert.False(viewModel.HasActiveSessions);
            var completed = Assert.Single(viewModel.CompletedSessions);
            Assert.Equal("Codex", completed.Provider);
            Assert.Equal("1,000", completed.Tokens);
            Assert.True(File.Exists(path));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void SavedHistoryIsLoadedOnNextStart()
    {
        var path = Path.Combine(Path.GetTempPath(), $"amon-sessions-{Guid.NewGuid():N}.json");
        try
        {
            var first = new SessionHistoryViewModel(path);
            first.ApplySessions([CreateSession()]);
            first.ApplySessions([]);

            var second = new SessionHistoryViewModel(path);

            Assert.True(second.HasCompletedSessions);
            Assert.Single(second.CompletedSessions);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public async Task LiveSessionDetailFindsTranscriptFromConfiguredLogRoot()
    {
        var directory = Path.Combine(
            Path.GetTempPath(),
            $"amon-live-detail-{Guid.NewGuid():N}");
        var historyPath = Path.Combine(directory, "history.json");
        var logDirectory = Path.Combine(directory, "2026", "07", "26");
        Directory.CreateDirectory(logDirectory);
        var logPath = Path.Combine(
            logDirectory,
            "rollout-2026-07-26T16-15-24-session-1.jsonl");
        try
        {
            File.WriteAllLines(logPath,
            [
                """{"type":"event_msg","timestamp":"2026-07-26T07:15:24Z","payload":{"type":"user_message","message":"Show session detail"}}""",
                """{"type":"response_item","timestamp":"2026-07-26T07:15:25Z","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Detail is ready"}]}}"""
            ]);
            var viewModel = new SessionHistoryViewModel(historyPath);
            viewModel.ConfigureLogRoots(null, directory);
            viewModel.ApplySessions([CreateSession()]);

            viewModel.OpenSessionCommand.Execute(viewModel.ActiveSessions[0]);
            for (var attempt = 0;
                 attempt < 40
                 && viewModel.DetailStatus.Contains("분석하는 중", StringComparison.Ordinal);
                 attempt++)
            {
                await Task.Delay(25);
            }

            Assert.True(viewModel.IsDetailVisible);
            Assert.Equal(2, viewModel.Transcript.Count);
            Assert.Contains("2", viewModel.DetailStatus);
        }
        finally
        {
            Directory.Delete(directory, recursive: true);
        }
    }

    private static LiveSession CreateSession()
    {
        var now = DateTimeOffset.UtcNow;
        return new LiveSession(
            "codex",
            "session-1",
            "amon",
            "main",
            "working",
            [],
            "Windows UI port",
            null,
            "gpt-5",
            new LiveTokenSnapshot(600, 400, 0, 0, 0, 1000, LiveTokenScope.SessionCumulative),
            now.AddMinutes(-5),
            now);
    }
}
