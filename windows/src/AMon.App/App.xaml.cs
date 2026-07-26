using System.Drawing;
using System.Diagnostics;
using System.IO;
using System.Windows;
using AMon.Activity;
using AMon.App.Settings;
using AMon.App.ViewModels;
using AMon.ClaudeIntegration;
using AMon.Collectors;
using AMon.LocalData;
using AMon.WindowsPlatform;

namespace AMon.App;

public partial class App : System.Windows.Application
{
    private ISingleInstanceService? _singleInstance;
    private NotifyIconTrayService? _tray;
    private DashboardWindow? _dashboardWindow;
    private PetWindow? _petWindow;
    private UpdateCoordinator? _updateCoordinator;
    private UsageCollectionService? _usageCollectionService;
    private LiveActivityService? _liveActivityService;
    private PetActivityConnector? _petActivityConnector;
    private bool _isExiting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        _singleInstance = new SingleInstanceService();
        if (!_singleInstance.IsPrimaryInstance)
        {
            Shutdown();
            return;
        }

        _singleInstance.ActivationRequested += (_, _) =>
            Dispatcher.BeginInvoke(ShowDashboard);

        var configStore = new ConfigStore();
        var config = Task.Run(() => configStore.LoadAsync()).GetAwaiter().GetResult();
        var settingsStore = new LocalDataAppSettingsStore(configStore.Path);
        var settingsViewModel = new SettingsViewModel(settingsStore);
        var dashboardViewModel = new DashboardViewModel();
        var shellViewModel = new ShellViewModel(
            dashboardViewModel,
            settingsViewModel);
        var petConfig = config.Pet;
        var petViewModel = new PetViewModel(
            showsCurrentTask: petConfig.IsShowingCurrentTask);

        _dashboardWindow = new DashboardWindow
        {
            DataContext = shellViewModel,
            PetViewModel = petViewModel,
        };
        _dashboardWindow.Closing += OnDashboardClosing;

        _petWindow = new PetWindow(new NativeWindowStyleService())
        {
            DataContext = petViewModel,
        };
        _petWindow.DashboardToggleRequested += (_, _) => ToggleDashboard();
        _petWindow.ContextMenuRequested += (_, _) => _tray?.ShowContextMenu();

        using var iconStream = GetResourceStream(
            new Uri("pack://application:,,,/Assets/amon.ico"))?.Stream;
        if (iconStream is not null)
        {
            using var icon = new Icon(iconStream);
            _tray = new NotifyIconTrayService(icon);
            _tray.DashboardRequested += (_, _) => ToggleDashboard();
            _tray.PetVisibilityToggleRequested += (_, _) => TogglePet();
            _tray.ExitRequested += (_, _) => Shutdown();
            _tray.SetToolTip("A-mon · AI 작업 모니터");
            _tray.SetPetVisible(petConfig.IsEnabled);
        }

        if (petConfig.IsEnabled)
            _petWindow.ShowNearWorkingArea();

        TryConfigureClaudeLocalActivity(petConfig.IsLocalActivityEnabled);

        var paths = config.Paths;
        var scanners = UsageScannerFactory.Create(new UsageScannerPaths(
            paths.Claude,
            paths.Codex,
            paths.OpenCode,
            paths.Cursor,
            paths.Gemini,
            paths.Qwen,
            paths.Copilot));
        var dataDirectory = Path.GetDirectoryName(configStore.Path)
            ?? throw new InvalidOperationException("설정 파일의 상위 경로가 없습니다.");
        _usageCollectionService = new UsageCollectionService(
            new UsageScanCoordinator(scanners),
            dashboardViewModel,
            configStore,
            Path.Combine(dataDirectory, "usage.db"),
            Dispatcher);
        _usageCollectionService.Start();

        if (petConfig.IsLocalActivityEnabled)
        {
            _liveActivityService = new LiveActivityService(
            [
                new ClaudeLiveSessionSource(),
                new CodexLiveSessionSource(OptionalPath(paths.Codex)),
                new CursorLiveSessionSource(OptionalPath(paths.Cursor))
            ],
            pollInterval: TimeSpan.FromSeconds(5));
            _petActivityConnector = new PetActivityConnector(
                _liveActivityService,
                petViewModel,
                Dispatcher,
                localActivityEnabled: true,
                showsCurrentTask: petConfig.IsShowingCurrentTask);
            _petActivityConnector.Start();
        }

        _updateCoordinator = new UpdateCoordinator(() =>
        {
            Dispatcher.Invoke(() => Shutdown());
            return Task.CompletedTask;
        });
        _updateCoordinator.Start();

        if (e.Args.Contains("--show", StringComparer.OrdinalIgnoreCase))
        {
            ShowDashboard();
        }
    }

    private void ToggleDashboard()
    {
        if (_dashboardWindow is null)
        {
            return;
        }

        if (_dashboardWindow.IsVisible)
        {
            _dashboardWindow.Hide();
        }
        else
        {
            ShowDashboard();
        }
    }

    private void ShowDashboard()
    {
        if (_dashboardWindow is null)
        {
            return;
        }

        if (!_dashboardWindow.IsVisible)
        {
            _dashboardWindow.Show();
        }

        if (_dashboardWindow.WindowState == WindowState.Minimized)
        {
            _dashboardWindow.WindowState = WindowState.Normal;
        }

        _dashboardWindow.Activate();
    }

    private void TogglePet()
    {
        if (_petWindow is null)
        {
            return;
        }

        if (_petWindow.IsVisible)
        {
            _petWindow.Hide();
        }
        else
        {
            _petWindow.ShowNearWorkingArea();
        }

        _tray?.SetPetVisible(_petWindow.IsVisible);
    }

    private void OnDashboardClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        if (_isExiting)
        {
            return;
        }

        e.Cancel = true;
        _dashboardWindow?.Hide();
    }

    private static string? OptionalPath(string? path) =>
        string.IsNullOrWhiteSpace(path) ? null : path;

    private static void TryConfigureClaudeLocalActivity(bool enabled)
    {
        var helperPath = Path.Combine(
            AppContext.BaseDirectory,
            "Hooks",
            ClaudeHookInstaller.ManagedExecutableName);
        try
        {
            var result = new ClaudeLocalActivityController().Configure(
                enabled,
                helperPath);
            Trace.TraceInformation(
                "Claude local activity enabled={0}; hookChanged={1}; purged={2}",
                result.Enabled,
                result.HookChanged,
                result.PurgedFiles);
            foreach (var error in result.Errors)
                Trace.TraceWarning("Claude local activity setup skipped: {0}", error);
        }
        catch (Exception exception)
        {
            Trace.TraceWarning(
                "Claude local activity configuration skipped: {0}",
                exception.Message);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _isExiting = true;

        if (_dashboardWindow is not null)
        {
            _dashboardWindow.Closing -= OnDashboardClosing;
            _dashboardWindow.Close();
        }

        _petActivityConnector?.Dispose();
        _petWindow?.Close();
        _tray?.Dispose();
        _usageCollectionService?.Dispose();
        _updateCoordinator?.Dispose();
        _singleInstance?.Dispose();

        base.OnExit(e);
    }
}
