using System.Windows.Media;

namespace AMon.App.Tests;

public sealed class WindowsThemeManagerTests
{
    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void PetTextMeetsNormalTextContrastInBothThemes(bool isLight)
    {
        var palette = WindowsThemeManager.PaletteFor(
            isLight,
            highContrast: false);

        Assert.True(
            ContrastRatio(palette.PetBubbleText, palette.PetBubble) >= 4.5);
        Assert.True(
            ContrastRatio(palette.PetBubbleMuted, palette.PetBubble) >= 4.5);
        Assert.True(
            ContrastRatio(palette.PetBadgeText, palette.PetBadge) >= 4.5);
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public void DashboardTextMeetsNormalTextContrastInBothThemes(bool isLight)
    {
        var palette = WindowsThemeManager.PaletteFor(
            isLight,
            highContrast: false);

        Assert.True(ContrastRatio(palette.Text, palette.Window) >= 4.5);
        Assert.True(ContrastRatio(palette.Text, palette.Surface) >= 4.5);
        Assert.True(ContrastRatio(palette.Muted, palette.Surface) >= 4.5);
        Assert.True(ContrastRatio(palette.AccentText, palette.Accent) >= 4.5);
    }

    private static double ContrastRatio(Color foreground, Color background)
    {
        var lighter = Math.Max(
            Luminance(foreground),
            Luminance(background));
        var darker = Math.Min(
            Luminance(foreground),
            Luminance(background));
        return (lighter + 0.05) / (darker + 0.05);
    }

    private static double Luminance(Color color) =>
        0.2126 * Linear(color.R / 255d)
        + 0.7152 * Linear(color.G / 255d)
        + 0.0722 * Linear(color.B / 255d);

    private static double Linear(double value) =>
        value <= 0.04045
            ? value / 12.92
            : Math.Pow((value + 0.055) / 1.055, 2.4);
}
