using AMon.Activity;

namespace AMon.App.Tests;

public sealed class CodexPetSpriteLayoutTests
{
    [Theory]
    [InlineData(PetActivityStatus.Idle, CodexPetAnimation.Idle)]
    [InlineData(PetActivityStatus.Running, CodexPetAnimation.Running)]
    [InlineData(PetActivityStatus.NeedsInput, CodexPetAnimation.Waiting)]
    [InlineData(PetActivityStatus.Ready, CodexPetAnimation.Waving)]
    [InlineData(PetActivityStatus.Blocked, CodexPetAnimation.Failed)]
    [InlineData(PetActivityStatus.Reviewing, CodexPetAnimation.Review)]
    public void ActivityStatusUsesMacCompatibleAnimation(
        PetActivityStatus status,
        CodexPetAnimation expected)
    {
        Assert.Equal(expected, CodexPetSpriteLayout.AnimationFor(status));
    }

    [Theory]
    [InlineData(-1, CodexPetAnimation.RunningLeft)]
    [InlineData(1, CodexPetAnimation.RunningRight)]
    public void DragDirectionUsesDirectionalRunningRows(
        int direction,
        CodexPetAnimation expected)
    {
        Assert.Equal(
            expected,
            CodexPetSpriteLayout.AnimationFor(
                PetActivityStatus.Idle,
                dragDirection: direction));
    }

    [Fact]
    public void ReadyTransitionJumpsOnceThenWaves()
    {
        var jumpDuration =
            CodexPetSpriteLayout.CycleDuration(CodexPetAnimation.Jumping);

        Assert.Equal(
            CodexPetAnimation.Jumping,
            CodexPetSpriteLayout.AnimationFor(
                PetActivityStatus.Ready,
                readyTransitionElapsed: TimeSpan.Zero));
        Assert.Equal(
            CodexPetAnimation.Waving,
            CodexPetSpriteLayout.AnimationFor(
                PetActivityStatus.Ready,
                readyTransitionElapsed: jumpDuration));
        Assert.Equal(
            CodexPetAnimation.Waving,
            CodexPetSpriteLayout.AnimationFor(
                PetActivityStatus.Ready,
                readyTransitionElapsed: TimeSpan.Zero,
                reduceMotion: true));
    }

    [Fact]
    public void V3ReadyTransitionJumpsThenRunsAwayOnceThenWaves()
    {
        var jumpDuration =
            CodexPetSpriteLayout.CycleDuration(CodexPetAnimation.Jumping);
        var runningAwayDuration =
            CodexPetSpriteLayout.CycleDuration(CodexPetAnimation.RunningAway);

        Assert.Equal(
            CodexPetAnimation.Jumping,
            CodexPetSpriteLayout.AnimationFor(
                PetActivityStatus.Ready,
                spriteVersion: 3,
                readyTransitionElapsed: TimeSpan.Zero));
        Assert.Equal(
            CodexPetAnimation.RunningAway,
            CodexPetSpriteLayout.AnimationFor(
                PetActivityStatus.Ready,
                spriteVersion: 3,
                readyTransitionElapsed: jumpDuration));
        Assert.Equal(
            CodexPetAnimation.Waving,
            CodexPetSpriteLayout.AnimationFor(
                PetActivityStatus.Ready,
                spriteVersion: 3,
                readyTransitionElapsed: jumpDuration + runningAwayDuration));
        Assert.Equal(
            TimeSpan.Zero,
            CodexPetSpriteLayout.PlaybackElapsedFor(
                PetActivityStatus.Ready,
                3,
                jumpDuration,
                reduceMotion: false));
        Assert.Equal(
            CodexPetAnimation.Waving,
            CodexPetSpriteLayout.AnimationFor(
                PetActivityStatus.Ready,
                spriteVersion: 3,
                readyTransitionElapsed: TimeSpan.Zero,
                reduceMotion: true));
    }

    [Fact]
    public void SpriteSheetLayoutMatchesCodexPetContract()
    {
        Assert.Equal(1536, CodexPetSpriteLayout.SheetPixelWidth);
        Assert.Equal(1872, CodexPetSpriteLayout.V1SheetPixelHeight);
        Assert.Equal(2288, CodexPetSpriteLayout.V2SheetPixelHeight);
        Assert.Equal(2496, CodexPetSpriteLayout.V3SheetPixelHeight);
        Assert.Equal(192, CodexPetSpriteLayout.FramePixelWidth);
        Assert.Equal(208, CodexPetSpriteLayout.FramePixelHeight);
        Assert.Equal(8, CodexPetSpriteLayout.ColumnCount);
        Assert.Equal(9, CodexPetSpriteLayout.V1RowCount);
        Assert.Equal(11, CodexPetSpriteLayout.V2RowCount);
        Assert.Equal(12, CodexPetSpriteLayout.V3RowCount);
        Assert.Equal(12, CodexPetSpriteLayout.Strips.Count);
        Assert.Equal(
            1,
            CodexPetSpriteLayout.VersionForDimensions(1536, 1872));
        Assert.Equal(
            2,
            CodexPetSpriteLayout.VersionForDimensions(1536, 2288));
        Assert.Equal(
            3,
            CodexPetSpriteLayout.VersionForDimensions(1536, 2496));
        Assert.Equal(
            new CodexPetStrip(11, 8),
            CodexPetSpriteLayout.Strips[CodexPetAnimation.RunningAway]);
    }

    [Theory]
    [InlineData(-1, CodexPetAnimation.LookingLeft)]
    [InlineData(1, CodexPetAnimation.LookingRight)]
    public void V2IdleUsesDirectionalGazeAnimation(
        int gazeDirection,
        CodexPetAnimation expected)
    {
        Assert.Equal(
            expected,
            CodexPetSpriteLayout.AnimationFor(
                PetActivityStatus.Idle,
                spriteVersion: 2,
                gazeDirection));
        Assert.Equal(
            CodexPetAnimation.Idle,
            CodexPetSpriteLayout.AnimationFor(
                PetActivityStatus.Idle,
                spriteVersion: 1,
                gazeDirection));
    }

    [Fact]
    public void ReducedMotionAlwaysUsesFirstFrame()
    {
        var frame = CodexPetSpriteLayout.FrameIndex(
            TimeSpan.FromMinutes(10),
            CodexPetAnimation.Running,
            reduceMotion: true);

        Assert.Equal(0, frame);
    }

    [Fact]
    public void FrameIndexAdvancesAndLoops()
    {
        Assert.Equal(
            0,
            CodexPetSpriteLayout.FrameIndex(
                TimeSpan.Zero,
                CodexPetAnimation.Running,
                reduceMotion: false));
        Assert.Equal(
            1,
            CodexPetSpriteLayout.FrameIndex(
                TimeSpan.FromSeconds(0.121),
                CodexPetAnimation.Running,
                reduceMotion: false));
        Assert.Equal(
            0,
            CodexPetSpriteLayout.FrameIndex(
                TimeSpan.FromSeconds(0.83),
                CodexPetAnimation.Running,
                reduceMotion: false));
    }
}
