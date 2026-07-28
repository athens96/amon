namespace AMon.App.Tests;

public sealed class BundledPetSpriteTests
{
    [Fact]
    public void CustomWinsThenBundledThenShapeFallback()
    {
        var custom = Path.GetFullPath("custom.webp");
        var bundled = Path.GetFullPath("Assets/Pets/Amon.webp");

        Assert.Equal(
            new PetSpriteSelection(custom, 2, IsCustom: true),
            BundledPetSprite.Resolve(
                custom,
                customVersion: 2,
                bundledPath: bundled,
                isValid: (path, _) => path == custom || path == bundled));
        Assert.Equal(
            new PetSpriteSelection(
                bundled,
                BundledPetSprite.Version,
                IsCustom: false),
            BundledPetSprite.Resolve(
                custom,
                customVersion: 2,
                bundledPath: bundled,
                isValid: (path, _) => path == bundled));
        Assert.Null(
            BundledPetSprite.Resolve(
                custom,
                customVersion: 2,
                bundledPath: bundled,
                isValid: static (_, _) => false));
    }

    [Fact]
    public void BundledPathUsesStableOutputRelativeContract()
    {
        var baseDirectory = Path.GetFullPath("publish");
        Assert.Equal(
            Path.Combine(baseDirectory, "Assets", "Pets", "Amon.webp"),
            BundledPetSprite.PathFromBaseDirectory(baseDirectory));
    }
}
