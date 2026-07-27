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
    public void ActivityStatusUsesMacCompatibleAnimation(
        PetActivityStatus status,
        CodexPetAnimation expected)
    {
        Assert.Equal(expected, CodexPetSpriteLayout.AnimationFor(status));
    }

    [Fact]
    public void SpriteSheetLayoutMatchesCodexPetContract()
    {
        Assert.Equal(1536, CodexPetSpriteLayout.SheetPixelWidth);
        Assert.Equal(1872, CodexPetSpriteLayout.V1SheetPixelHeight);
        Assert.Equal(2288, CodexPetSpriteLayout.V2SheetPixelHeight);
        Assert.Equal(192, CodexPetSpriteLayout.FramePixelWidth);
        Assert.Equal(208, CodexPetSpriteLayout.FramePixelHeight);
        Assert.Equal(8, CodexPetSpriteLayout.ColumnCount);
        Assert.Equal(9, CodexPetSpriteLayout.V1RowCount);
        Assert.Equal(11, CodexPetSpriteLayout.V2RowCount);
        Assert.Equal(11, CodexPetSpriteLayout.Strips.Count);
        Assert.Equal(
            1,
            CodexPetSpriteLayout.VersionForDimensions(1536, 1872));
        Assert.Equal(
            2,
            CodexPetSpriteLayout.VersionForDimensions(1536, 2288));
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
