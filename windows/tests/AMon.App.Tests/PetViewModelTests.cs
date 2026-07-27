using AMon.Activity;
using AMon.App.ViewModels;

namespace AMon.App.Tests;

public sealed class PetViewModelTests
{
    [Fact]
    public void BubbleTextCompactsMultilineOutputForOverlay()
    {
        var presentation = First with
        {
            OutputPreview = "첫 줄\r\n\r\n두 번째   줄",
            Title = new string('가', 90),
        };
        var viewModel = new PetViewModel([presentation]);

        Assert.Equal("첫 줄 두 번째 줄", viewModel.BubbleText);
        Assert.Equal("첫 번째 입력", viewModel.InputBubbleText);
        Assert.Equal("첫 줄 두 번째 줄", viewModel.OutputBubbleText);
        Assert.EndsWith("…", viewModel.TaskText);
        Assert.Equal(72, viewModel.TaskText.Length);
    }

    private static readonly PetPresentation First = Presentation(
        "codex:first", "Codex", "첫 번째 작업", 1_200, 340, 1_800);
    private static readonly PetPresentation Second = Presentation(
        "claude:second", "Claude", "두 번째 작업", 2_000, 500, 3_000);

    [Fact]
    public void MultipleRunningPresentationsExposeCarouselAndPreviews()
    {
        var viewModel = new PetViewModel([First, Second]);

        Assert.True(viewModel.HasRunningCarousel);
        Assert.Equal("1/2", viewModel.CounterText);
        Assert.Equal("첫 번째 입력", viewModel.Current.InputText);
        Assert.Equal("첫 번째 출력", viewModel.Current.OutputText);
        Assert.Equal("INPUT 1.2K", viewModel.InputTokenText);
        Assert.Equal("OUTPUT 340", viewModel.OutputTokenText);
        Assert.Contains("2개 동시 세션 중 1번째", viewModel.AccessiblePositionText);
    }

    [Fact]
    public void NextPreviousWrapAndSelectionIdentitySurvivesReorder()
    {
        var viewModel = new PetViewModel([First, Second]);
        viewModel.NextCommand.Execute(null);
        Assert.Equal(Second.SessionIdentity, viewModel.SelectedSessionIdentity);

        viewModel.UpdatePresentations([Second with { Title = "갱신됨" }, First]);

        Assert.Equal(0, viewModel.CurrentIndex);
        Assert.Equal(Second.SessionIdentity, viewModel.SelectedSessionIdentity);
        Assert.Equal("갱신됨", viewModel.Current.Title);

        viewModel.PreviousCommand.Execute(null);
        Assert.Equal(First.SessionIdentity, viewModel.SelectedSessionIdentity);
        viewModel.NextCommand.Execute(null);
        Assert.Equal(Second.SessionIdentity, viewModel.SelectedSessionIdentity);
    }

    [Fact]
    public void RemovedSelectionClampsPreviousIndex()
    {
        var third = Presentation("cursor:third", "Cursor", "세 번째", 1, 1, 2);
        var viewModel = new PetViewModel([First, Second, third]);
        viewModel.NextCommand.Execute(null);
        viewModel.NextCommand.Execute(null);
        Assert.Equal(2, viewModel.CurrentIndex);

        viewModel.UpdatePresentations([First, Second]);

        Assert.Equal(1, viewModel.CurrentIndex);
        Assert.Equal(Second.SessionIdentity, viewModel.SelectedSessionIdentity);
    }

    [Fact]
    public void CounterIsOnlyForMultipleRunningSessions()
    {
        var attention = First with
        {
            Status = PetActivityStatus.NeedsInput,
            ActiveCount = 1
        };
        var viewModel = new PetViewModel([attention]);

        Assert.False(viewModel.HasRunningCarousel);
        Assert.Equal(string.Empty, viewModel.CounterText);
        Assert.False(viewModel.NextCommand.CanExecute(null));

        viewModel.UpdatePresentations([First, Second]);
        Assert.True(viewModel.NextCommand.CanExecute(null));
    }

    [Fact]
    public void TokenFractionsAreNullableRemainderAwareAndOverflowSafe()
    {
        var viewModel = new PetViewModel(
        [
            First with
            {
                InputTokens = long.MaxValue,
                OutputTokens = long.MaxValue,
                TotalTokens = long.MaxValue
            }
        ]);

        Assert.Equal(0.5, viewModel.InputFraction, 6);
        Assert.Equal(0.5, viewModel.OutputFraction, 6);
        Assert.Equal(0, viewModel.RemainderFraction, 6);

        viewModel.UpdatePresentations(
        [
            First with { InputTokens = 20, OutputTokens = 10, TotalTokens = 100 }
        ]);
        Assert.Equal(0.2, viewModel.InputFraction, 6);
        Assert.Equal(0.1, viewModel.OutputFraction, 6);
        Assert.Equal(0.7, viewModel.RemainderFraction, 6);

        viewModel.UpdatePresentations(
        [
            First with { InputTokens = null, OutputTokens = null, TotalTokens = 42 }
        ]);
        Assert.False(viewModel.HasTokenBreakdown);
        Assert.Equal("INPUT —", viewModel.InputTokenText);
        Assert.Equal("OUTPUT —", viewModel.OutputTokenText);
        Assert.Equal("합계 42", viewModel.TotalTokenText);
    }

    [Fact]
    public void EmptyCollectionFallsBackToAccessibleIdlePresentation()
    {
        var viewModel = new PetViewModel([]);

        Assert.Equal(PetPresentation.Idle, viewModel.Current);
        Assert.False(viewModel.HasRunningCarousel);
        Assert.Equal(string.Empty, viewModel.CounterText);
        Assert.Contains("대기 중", viewModel.AccessibilityDescription);
    }

    [Fact]
    public void HiddenCurrentTaskStillExposesSessionAndTokenState()
    {
        var hidden = First with { InputPreview = null, OutputPreview = null };
        var viewModel = new PetViewModel(
            [hidden, Second with { InputPreview = null, OutputPreview = null }],
            showsCurrentTask: false);

        Assert.False(viewModel.ShowsCurrentTask);
        Assert.True(viewModel.HasRunningCarousel);
        Assert.Equal("1/2", viewModel.CounterText);
        Assert.Equal("INPUT 1.2K", viewModel.InputTokenText);
        Assert.Equal("OUTPUT 340", viewModel.OutputTokenText);
        Assert.Null(viewModel.Current.InputPreview);
        Assert.Null(viewModel.Current.OutputPreview);
    }

    private static PetPresentation Presentation(
        string identity,
        string provider,
        string title,
        long? input,
        long? output,
        long? total) =>
        new(
            PetActivityStatus.Running,
            title,
            title.Replace("작업", "입력"),
            title.Replace("작업", "출력"),
            provider,
            identity[(identity.IndexOf(':') + 1)..],
            identity,
            input,
            output,
            total,
            DateTimeOffset.UtcNow,
            2);
}
