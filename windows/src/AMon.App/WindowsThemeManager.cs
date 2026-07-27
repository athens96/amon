using System.ComponentModel;
using System.IO;
using System.Windows;
using System.Windows.Media;
using Microsoft.Win32;
using Application = System.Windows.Application;
using Color = System.Windows.Media.Color;
using ColorConverter = System.Windows.Media.ColorConverter;
using Colors = System.Windows.Media.Colors;
using WpfSystemColors = System.Windows.SystemColors;

namespace AMon.App;

public sealed record WindowsThemePalette(
    Color Window,
    Color Surface,
    Color SurfaceHover,
    Color SurfaceStrong,
    Color Line,
    Color Text,
    Color Body,
    Color Muted,
    Color Accent,
    Color AccentText,
    Color Success,
    Color Error,
    Color PetBubble,
    Color PetBubbleSubtle,
    Color PetBubbleBorder,
    Color PetBubbleText,
    Color PetBubbleMuted,
    Color PetBubbleAccent,
    Color PetBadge,
    Color PetBadgeText);

public sealed class WindowsThemeManager : IDisposable
{
    private const string PersonalizeRegistryPath =
        @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
    private readonly Application _application;
    private bool _disposed;

    public WindowsThemeManager(Application application)
    {
        _application = application
            ?? throw new ArgumentNullException(nameof(application));
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
        SystemParameters.StaticPropertyChanged += OnSystemParametersChanged;
        ApplyCurrentTheme();
    }

    public bool IsDarkTheme { get; private set; }

    public event EventHandler? ThemeChanged;

    public void ApplyCurrentTheme()
    {
        if (!_application.Dispatcher.CheckAccess())
        {
            _application.Dispatcher.BeginInvoke(ApplyCurrentTheme);
            return;
        }

        IsDarkTheme = !ReadAppsUseLightTheme();
        var palette = PaletteFor(
            isLight: !IsDarkTheme,
            highContrast: SystemParameters.HighContrast);
        ApplyColor("WindowColor", palette.Window);
        ApplyColor("SurfaceColor", palette.Surface);
        ApplyColor("SurfaceHoverColor", palette.SurfaceHover);
        ApplyColor("SurfaceStrongColor", palette.SurfaceStrong);
        ApplyColor("LineColor", palette.Line);
        ApplyColor("TextColor", palette.Text);
        ApplyColor("BodyColor", palette.Body);
        ApplyColor("MutedColor", palette.Muted);
        ApplyColor("AccentColor", palette.Accent);
        ApplyColor("AccentTextColor", palette.AccentText);
        ApplyColor("SuccessColor", palette.Success);
        ApplyColor("ErrorColor", palette.Error);
        ApplyColor("PetBubbleColor", palette.PetBubble);
        ApplyColor("PetBubbleSubtleColor", palette.PetBubbleSubtle);
        ApplyColor("PetBubbleBorderColor", palette.PetBubbleBorder);
        ApplyColor("PetBubbleTextColor", palette.PetBubbleText);
        ApplyColor("PetBubbleMutedColor", palette.PetBubbleMuted);
        ApplyColor("PetBubbleAccentColor", palette.PetBubbleAccent);
        ApplyColor("PetBadgeColor", palette.PetBadge);
        ApplyColor("PetBadgeTextColor", palette.PetBadgeText);
        ThemeChanged?.Invoke(this, EventArgs.Empty);
    }

    public static WindowsThemePalette PaletteFor(
        bool isLight,
        bool highContrast)
    {
        if (highContrast)
        {
            return new WindowsThemePalette(
                WpfSystemColors.WindowColor,
                WpfSystemColors.WindowColor,
                WpfSystemColors.ControlColor,
                WpfSystemColors.ControlColor,
                WpfSystemColors.WindowTextColor,
                WpfSystemColors.WindowTextColor,
                WpfSystemColors.WindowTextColor,
                WpfSystemColors.GrayTextColor,
                WpfSystemColors.HighlightColor,
                WpfSystemColors.HighlightTextColor,
                WpfSystemColors.HighlightColor,
                WpfSystemColors.HighlightColor,
                WpfSystemColors.WindowColor,
                WpfSystemColors.ControlColor,
                WpfSystemColors.WindowTextColor,
                WpfSystemColors.WindowTextColor,
                WpfSystemColors.GrayTextColor,
                WpfSystemColors.HighlightColor,
                WpfSystemColors.HighlightColor,
                WpfSystemColors.HighlightTextColor);
        }

        return isLight
            ? new WindowsThemePalette(
                ColorFrom("#F3F3F3"),
                ColorFrom("#FBFBFB"),
                ColorFrom("#F0F0F0"),
                ColorFrom("#F7F7F7"),
                ColorFrom("#E5E5E5"),
                ColorFrom("#1A1A1A"),
                ColorFrom("#3B3B3B"),
                ColorFrom("#616161"),
                ColorFrom("#0067C0"),
                Colors.White,
                ColorFrom("#0F7B0F"),
                ColorFrom("#C42B1C"),
                ColorFrom("#FAFBFBFB"),
                ColorFrom("#FFF3F3F3"),
                ColorFrom("#19000000"),
                ColorFrom("#1A1A1A"),
                ColorFrom("#616161"),
                ColorFrom("#0067C0"),
                ColorFrom("#0067C0"),
                Colors.White)
            : new WindowsThemePalette(
                ColorFrom("#202020"),
                ColorFrom("#2B2B2B"),
                ColorFrom("#323232"),
                ColorFrom("#2D2D2D"),
                ColorFrom("#3D3D3D"),
                Colors.White,
                ColorFrom("#E0E0E0"),
                ColorFrom("#ADADAD"),
                ColorFrom("#60CDFF"),
                ColorFrom("#003E5C"),
                ColorFrom("#6CCB5F"),
                ColorFrom("#FF99A4"),
                ColorFrom("#FA2B2B2B"),
                ColorFrom("#FF323232"),
                ColorFrom("#33FFFFFF"),
                Colors.White,
                ColorFrom("#C8C8C8"),
                ColorFrom("#60CDFF"),
                ColorFrom("#60CDFF"),
                ColorFrom("#003E5C"));
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        SystemParameters.StaticPropertyChanged -= OnSystemParametersChanged;
    }

    private void ApplyColor(string key, Color color) =>
        _application.Resources[key] = color;

    private static bool ReadAppsUseLightTheme()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                PersonalizeRegistryPath,
                writable: false);
            return key?.GetValue("AppsUseLightTheme") is not int value
                || value != 0;
        }
        catch (Exception exception) when (
            exception is IOException
                or UnauthorizedAccessException
                or System.Security.SecurityException)
        {
            return true;
        }
    }

    private void OnUserPreferenceChanged(
        object sender,
        UserPreferenceChangedEventArgs e)
    {
        if (e.Category is UserPreferenceCategory.Color
            or UserPreferenceCategory.General
            or UserPreferenceCategory.VisualStyle)
        {
            ApplyCurrentTheme();
        }
    }

    private void OnSystemParametersChanged(
        object? sender,
        PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(SystemParameters.HighContrast))
            ApplyCurrentTheme();
    }

    private static Color ColorFrom(string value) =>
        (Color)ColorConverter.ConvertFromString(value);
}
