using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using MediaColor = System.Windows.Media.Color;
using MediaColors = System.Windows.Media.Colors;

namespace AMon.App;

internal static class WindowsWindowStyle
{
    private const int UseImmersiveDarkMode = 20;
    private const int WindowCornerPreference = 33;
    private const int CaptionColor = 35;
    private const int TextColor = 36;
    private const int RoundCorner = 2;

    public static void Apply(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);
        if (SystemParameters.HighContrast)
            return;

        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero)
            return;

        var windowColor = ResourceColor("WindowColor", MediaColors.White);
        var textColor = ResourceColor("TextColor", MediaColors.Black);
        var dark = RelativeLuminance(windowColor) < 0.5 ? 1 : 0;
        _ = DwmSetWindowAttribute(
            handle,
            UseImmersiveDarkMode,
            ref dark,
            Marshal.SizeOf<int>());

        if (!OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000))
            return;

        var corners = RoundCorner;
        var caption = ColorReference(windowColor);
        var text = ColorReference(textColor);
        _ = DwmSetWindowAttribute(
            handle,
            WindowCornerPreference,
            ref corners,
            Marshal.SizeOf<int>());
        _ = DwmSetWindowAttribute(
            handle,
            CaptionColor,
            ref caption,
            Marshal.SizeOf<int>());
        _ = DwmSetWindowAttribute(
            handle,
            TextColor,
            ref text,
            Marshal.SizeOf<int>());
    }

    private static MediaColor ResourceColor(string key, MediaColor fallback) =>
        System.Windows.Application.Current.Resources[key] is MediaColor color
            ? color
            : fallback;

    private static int ColorReference(MediaColor color) =>
        color.R | color.G << 8 | color.B << 16;

    private static double RelativeLuminance(MediaColor color) =>
        0.2126 * Linear(color.R / 255d)
        + 0.7152 * Linear(color.G / 255d)
        + 0.0722 * Linear(color.B / 255d);

    private static double Linear(double value) =>
        value <= 0.04045
            ? value / 12.92
            : Math.Pow((value + 0.055) / 1.055, 2.4);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        IntPtr window,
        int attribute,
        ref int value,
        int valueSize);
}
