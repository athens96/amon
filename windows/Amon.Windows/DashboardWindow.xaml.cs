using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Forms = System.Windows.Forms;

namespace AMon;

public partial class DashboardWindow : Window
{
    public bool KeepOpenForDiagnostics { get; set; }

    public DashboardWindow(AppController controller)
    {
        InitializeComponent();
        DataContext = controller;
        Deactivated += (_, _) =>
        {
            if (!KeepOpenForDiagnostics) Hide();
        };
        SourceInitialized += (_, _) => ApplyWindowStyle();
    }

    public void ShowNearCursor()
    {
        var cursor = Forms.Cursor.Position;
        var screen = Forms.Screen.FromPoint(cursor);
        var dpi = VisualTreeHelper.GetDpi(this);
        var width = Width * dpi.DpiScaleX;
        var height = Height * dpi.DpiScaleY;
        var x = Math.Min(Math.Max(cursor.X - width + 24, screen.WorkingArea.Left + 8), screen.WorkingArea.Right - width - 8);
        var y = cursor.Y - height - 10;
        if (y < screen.WorkingArea.Top) y = cursor.Y + 14;
        Left = x / dpi.DpiScaleX;
        Top = y / dpi.DpiScaleY;
        Show();
        Activate();
    }

    private void ApplyWindowStyle()
    {
        var handle = new WindowInteropHelper(this).Handle;
        var dark = 1;
        var corner = 2;
        DwmSetWindowAttribute(handle, 20, ref dark, sizeof(int));
        DwmSetWindowAttribute(handle, 33, ref corner, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(nint window, int attribute, ref int value, int size);
}
