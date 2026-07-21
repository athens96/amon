using System.Drawing;
using System.Threading;
using System.Windows;
using Forms = System.Windows.Forms;

namespace AMon;

public partial class App : System.Windows.Application
{
    private Mutex? _mutex;
    private Forms.NotifyIcon? _tray;
    private DashboardWindow? _window;
    private AppController? _controller;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _mutex = new Mutex(true, "Local\\A-mon.Windows", out var created);
        if (!created)
        {
            Shutdown();
            return;
        }

        _controller = new AppController();
        _window = new DashboardWindow(_controller);
        _tray = new Forms.NotifyIcon
        {
            Icon = new Icon(GetResourceStream(new Uri("pack://application:,,,/Assets/amon.ico"))!.Stream),
            Text = "A-mon",
            Visible = true
        };
        _tray.MouseClick += (_, args) =>
        {
            if (args.Button is Forms.MouseButtons.Left or Forms.MouseButtons.Right)
                ToggleWindow();
        };
        _controller.Changed += (_, _) => Dispatcher.Invoke(UpdateTray);
        _controller.ExitRequested += (_, _) => Shutdown();

		if (e.Args.Contains("--show", StringComparer.OrdinalIgnoreCase))
		{
			_window.KeepOpenForDiagnostics = true;
			_window.ShowNearCursor();
		}
        await _controller.InitializeAsync();
        UpdateTray();
    }

    private void ToggleWindow()
    {
        if (_window is null) return;
        if (_window.IsVisible)
        {
            _window.Hide();
            return;
        }
        _window.ShowNearCursor();
    }

    private void UpdateTray()
    {
        if (_tray is null || _controller is null) return;
        var text = _controller.TrayTooltip;
        _tray.Text = text.Length <= 63 ? text : text[..63];
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _controller?.Dispose();
        if (_tray is not null)
        {
            _tray.Visible = false;
            _tray.Dispose();
        }
        _mutex?.Dispose();
        base.OnExit(e);
    }
}
