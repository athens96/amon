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
                ColorFrom("#F5F5F5"),
                ColorFrom("#FFFFFF"),
                ColorFrom("#F0EFED"),
                ColorFrom("#F0EFED"),
                ColorFrom("#E2DFDC"),
                ColorFrom("#0C0A09"),
                ColorFrom("#4E4E4E"),
                ColorFrom("#6F6962"),
                ColorFrom("#292524"),
                Colors.White,
                ColorFrom("#15803D"),
                ColorFrom("#B91C1C"),
                ColorFrom("#F7FFFFFF"),
                ColorFrom("#FFF4F2EF"),
                ColorFrom("#330C0A09"),
                ColorFrom("#1C1917"),
                ColorFrom("#625C56"),
                ColorFrom("#5B21B6"),
                ColorFrom("#292524"),
                Colors.White)
            : new WindowsThemePalette(
                ColorFrom("#171717"),
                ColorFrom("#222222"),
                ColorFrom("#2D2D2D"),
                ColorFrom("#292929"),
                ColorFrom("#3F3F46"),
                ColorFrom("#FAFAF9"),
                ColorFrom("#D6D3D1"),
                ColorFrom("#AAA49D"),
                ColorFrom("#F5F5F4"),
                ColorFrom("#1C1917"),
                ColorFrom("#4ADE80"),
                ColorFrom("#F87171"),
                ColorFrom("#F21F2029"),
                ColorFrom("#FF2A2C39"),
                ColorFrom("#4DFFFFFF"),
                ColorFrom("#FAFAF9"),
                ColorFrom("#C9C5C0"),
                ColorFrom("#C4B5FD"),
                ColorFrom("#E7E5E4"),
                ColorFrom("#1C1917"));
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
