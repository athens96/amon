using Xunit;

namespace AMon.Activity.Tests;

public sealed class PetStateAdapterTests
{
    [Theory]
    [InlineData("active", PetActivityStatus.Running)]
    [InlineData("in-progress", PetActivityStatus.Running)]
    [InlineData("Needs Input", PetActivityStatus.NeedsInput)]
    [InlineData("needsInput", PetActivityStatus.NeedsInput)]
    [InlineData("awaiting_approval", PetActivityStatus.NeedsInput)]
    [InlineData("awaitingApproval", PetActivityStatus.NeedsInput)]
    [InlineData("requiresAction", PetActivityStatus.NeedsInput)]
    [InlineData("waitingForInput", PetActivityStatus.NeedsInput)]
    [InlineData("inProgress", PetActivityStatus.Running)]
    [InlineData("reviewing", PetActivityStatus.Reviewing)]
    [InlineData("in-review", PetActivityStatus.Reviewing)]
    [InlineData("failed", PetActivityStatus.Blocked)]
    [InlineData("completed", PetActivityStatus.Ready)]
    [InlineData("future-state", PetActivityStatus.Idle)]
    public void MapsRawStatusesConservatively(
        string raw,
        PetActivityStatus expected)
    {
        Assert.Equal(expected, PetStateAdapter.StatusFrom(raw));
    }

    [Fact]
    public void ReviewingSessionRemainsVisibleAsActiveWork()
    {
        var selected = Assert.Single(PetStateAdapter.CreatePresentations(
        [
            Session("review", "reviewing", DateTimeOffset.UtcNow)
        ]));

        Assert.Equal(PetActivityStatus.Reviewing, selected.Status);
        Assert.Equal("검토 중", selected.StatusText);
    }

    [Fact]
    public void AttentionWinsAndNeedsInputWinsBlocked()
    {
        var now = DateTimeOffset.UtcNow;
        var values = PetStateAdapter.CreatePresentations(
        [
            Session("run", "active", now.AddMinutes(3), output: "running"),
            Session("blocked", "failed", now.AddMinutes(2)),
            Session("input", "awaiting_approval", now)
        ]);

        var selected = Assert.Single(values);
        Assert.Equal(PetActivityStatus.NeedsInput, selected.Status);
        Assert.Equal("input", selected.SessionId);
        Assert.Equal(1, selected.ActiveCount);
    }

    [Fact]
    public void CarouselContainsOnlyRunningAndHasStableOrder()
    {
        var now = DateTimeOffset.UtcNow;
        var values = PetStateAdapter.CreatePresentations(
        [
            Session("old", "active", now),
            Session("history", "idle", now.AddMinutes(5), output: "done"),
            Session("new-b", "running", now.AddMinutes(1), provider: "z"),
            Session("new-a", "running", now.AddMinutes(1), provider: "a"),
            Session("ready", "completed", now.AddMinutes(6), output: "ready")
        ]);

        Assert.Equal(
            ["a:new-a", "z:new-b", "codex:old"],
            values.Select(static value => value.SessionIdentity));
        Assert.All(values, static value =>
        {
            Assert.Equal(PetActivityStatus.Running, value.Status);
            Assert.Equal(3, value.ActiveCount);
        });
    }

    [Fact]
    public void LatestCompletedWithOutputIsSingleReadyFallback()
    {
        var now = DateTimeOffset.UtcNow;
        var values = PetStateAdapter.CreatePresentations(
        [
            Session("old", "idle", now, output: "old", updated: now),
            Session("new", "idle", now, output: "new", updated: now.AddMinutes(1)),
            Session("newest-no-output", "idle", now, updated: now.AddMinutes(2))
        ]);

        var selected = Assert.Single(values);
        Assert.Equal("new", selected.SessionId);
        Assert.Equal(PetActivityStatus.Ready, selected.Status);
        Assert.Equal(0, selected.ActiveCount);
    }

    [Fact]
    public void BoundsPreviewsAndPreservesNullableTokens()
    {
        var session = Session(
            "bounded",
            "active",
            DateTimeOffset.UtcNow,
            project: new string('p', 90),
            task: new string('t', 130) + "\nsecret",
            output: new string('o', 170) + "\nsecret",
            tokens: new LiveTokenSnapshot(12, null, null, null, null, 20, LiveTokenScope.Estimated));

        var selected = Assert.Single(PetStateAdapter.CreatePresentations([session]));

        Assert.Equal(80, selected.Title.Length);
        Assert.Equal(120, selected.InputPreview!.Length);
        Assert.Equal(160, selected.OutputPreview!.Length);
        Assert.DoesNotContain('\n', selected.InputPreview);
        Assert.Equal(12, selected.InputTokens);
        Assert.Null(selected.OutputTokens);
        Assert.Equal(20, selected.TotalTokens);
    }

    [Fact]
    public void DisabledOrNoUsefulSessionsProducesNoPresentations()
    {
        var idle = Session("idle", "idle", DateTimeOffset.UtcNow);
        Assert.Empty(PetStateAdapter.CreatePresentations([idle]));
        Assert.Empty(PetStateAdapter.CreatePresentations([idle], localActivityEnabled: false));
    }

    [Fact]
    public void HiddenCurrentTaskKeepsStatusCarouselAndTokensButDropsPreviews()
    {
        var now = DateTimeOffset.UtcNow;
        var values = PetStateAdapter.CreatePresentations(
        [
            Session(
                "first",
                "active",
                now,
                task: "private prompt",
                output: "private response",
                tokens: new LiveTokenSnapshot(
                    10, 5, null, null, null, 15, LiveTokenScope.LatestMessage)),
            Session(
                "second",
                "active",
                now.AddMinutes(1),
                task: "another prompt",
                output: "another response")
        ],
        showsCurrentTask: false);

        Assert.Equal(2, values.Count);
        Assert.All(values, presentation =>
        {
            Assert.Equal(PetActivityStatus.Running, presentation.Status);
            Assert.Equal(2, presentation.ActiveCount);
            Assert.Null(presentation.InputPreview);
            Assert.Null(presentation.OutputPreview);
        });
        Assert.Equal(10, values[1].InputTokens);
        Assert.Equal(5, values[1].OutputTokens);
        Assert.Equal(15, values[1].TotalTokens);
    }

    private static LiveSession Session(
        string id,
        string status,
        DateTimeOffset started,
        string provider = "codex",
        string project = "amon-dev",
        string? task = "task",
        string? output = null,
        DateTimeOffset? updated = null,
        LiveTokenSnapshot? tokens = null) =>
        new(
            provider,
            id,
            project,
            null,
            status,
            [],
            task,
            output,
            null,
            tokens ?? LiveTokenSnapshot.Unavailable,
            started,
            updated ?? started);
}
