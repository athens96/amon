using AMon.Activity;
using AMon.App.ViewModels;

namespace AMon.App.Tests;

public sealed class PetHistoryViewModelTests
{
    private static PetPresentation Session(string identity, string provider, string? transcript) => new(
        PetActivityStatus.Running,
        "작업",
        "입력",
        "출력",
        provider,
        identity.Split(':')[1],
        identity,
        10,
        5,
        15,
        DateTimeOffset.UtcNow,
        1,
        TranscriptPath: transcript,
        HostApp: "WindowsTerminal",
        HostProcessId: 77);

    [Fact]
    public async Task ToggleLoadsTurnsNewestFirstAndClosesCleanly()
    {
        var loads = 0;
        var viewModel = new PetViewModel(
            [Session("claude:a", "claude", "C:\\t.jsonl")],
            historyLoader: (_, _) =>
            {
                loads++;
                return Task.FromResult<IReadOnlyList<PetHistoryTurn>>(
                [
                    new PetHistoryTurn(0, "first", "one", null, 1000, 20),
                    new PetHistoryTurn(1, "second", null, null, null, null),
                ]);
            });

        Assert.True(viewModel.HasHistorySource);
        Assert.True(viewModel.ToggleHistoryCommand.CanExecute(null));
        viewModel.ToggleHistoryCommand.Execute(null);
        await Task.Delay(50);

        Assert.True(viewModel.ShowsHistory);
        Assert.Equal(1, loads);
        Assert.Equal(["second", "first"], viewModel.HistoryTurns.Select(static turn => turn.Prompt).ToArray());
        Assert.Equal("작업 중", viewModel.HistoryTurns[0].StatusText);
        Assert.Equal("IN 1K · OUT 20", viewModel.HistoryTurns[1].TokenText);
        Assert.Equal("최근 2턴", viewModel.HistoryStatusText);

        viewModel.ToggleHistoryCommand.Execute(null);
        Assert.False(viewModel.ShowsHistory);
        Assert.Empty(viewModel.HistoryTurns);
    }

    [Fact]
    public void CursorAndIdleHaveNoHistorySource()
    {
        var cursor = new PetViewModel([Session("cursor:c", "cursor", null)], historyLoader: (_, _) => Task.FromResult<IReadOnlyList<PetHistoryTurn>>([]));
        var idle = new PetViewModel([], historyLoader: (_, _) => Task.FromResult<IReadOnlyList<PetHistoryTurn>>([]));

        Assert.False(cursor.HasHistorySource);
        Assert.False(idle.HasHistorySource);
        Assert.False(cursor.ToggleHistoryCommand.CanExecute(null));
    }

    [Fact]
    public void HostJumpAndTooltipFollowTheRecordedHost()
    {
        var viewModel = new PetViewModel([Session("claude:a", "claude", "C:\\t.jsonl")]);

        Assert.True(viewModel.HasHostJump);
        Assert.Equal("클릭하여 WindowsTerminal 로 이동", viewModel.BubbleToolTip);
        Assert.Equal("클릭하여 현재 세션 열기", new PetViewModel([]).BubbleToolTip);
    }
}
