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
    private WindowsThemeManager? _themeManager;
    private NotifyIconTrayService? _tray;
    private DashboardWindow? _dashboardWindow;
    private PetWindow? _petWindow;
    private UpdateCoordinator? _updateCoordinator;
    private UsageCollectionService? _usageCollectionService;
    private ProviderQuotaService? _providerQuotaService;
    private LiveActivityService? _liveActivityService;
    private PetActivityConnector? _petActivityConnector;
    private SessionActivityConnector? _sessionActivityConnector;
    private readonly LaunchAtLoginService _launchAtLogin = new();
    private readonly HashSet<string> _sentQuotaAlerts = new(StringComparer.Ordinal);
    private IReadOnlyList<ProviderQuotaViewModel> _latestQuotas = [];
    private AppSettingsState? _runtimeSettings;
    private PetViewModel? _petViewModel;
    private SessionHistoryViewModel? _sessionHistoryViewModel;
    private string? _claudeActivityPath;
    private string? _codexActivityPath;
    private string? _cursorActivityPath;
    private bool _isExiting;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        _themeManager = new WindowsThemeManager(this);

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
        var sessionHistoryViewModel = new SessionHistoryViewModel(
            Path.Combine(
                Path.GetDirectoryName(configStore.Path)
                    ?? throw new InvalidOperationException("설정 파일의 상위 경로가 없습니다."),
                "sessions.json"));
        var shellViewModel = new ShellViewModel(
            dashboardViewModel,
            sessionHistoryViewModel,
            settingsViewModel);
        var petConfig = config.Pet;
        var petViewModel = new PetViewModel(
            showsCurrentTask: petConfig.IsShowingCurrentTask);
        petViewModel.ConfigureAppearance(
            petConfig.IsShowingCurrentTask,
            petConfig.SpritePath,
            petConfig.SpriteVersion);
        _petViewModel = petViewModel;
        _sessionHistoryViewModel = sessionHistoryViewModel;

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
            _tray.SetToolTip("amon · AI 작업 모니터");
            _tray.SetPetVisible(petConfig.IsEnabled);
        }

        settingsViewModel.ConfigureRuntimeSettings(ApplyRuntimeSettings);

        if (petConfig.IsEnabled)
            _petWindow.ShowNearWorkingArea();

        var paths = config.Paths;
        sessionHistoryViewModel.ConfigureLogRoots(paths.Claude, paths.Codex);
        _claudeActivityPath = paths.Claude;
        _codexActivityPath = paths.Codex;
        _cursorActivityPath = paths.Cursor;
        _ = LoadSessionHistoryAsync(
            sessionHistoryViewModel,
            paths.Claude,
            paths.Codex);
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
            settingsViewModel,
            Dispatcher);
        settingsViewModel.ConfigureSend(_usageCollectionService.SendNowAsync);
        settingsViewModel.ConfigureRefresh(_usageCollectionService.RefreshNowAsync);
        _usageCollectionService.Start();
        _providerQuotaService = new ProviderQuotaService(
            dashboardViewModel,
            Dispatcher,
            quotas => ApplyProviderQuotaRuntime(quotas));
        _providerQuotaService.Start();

        ConfigureLiveActivity(
            petConfig.IsLocalActivityEnabled,
            petConfig.IsShowingCurrentTask);

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

    private async Task LoadSessionHistoryAsync(
        SessionHistoryViewModel viewModel,
        string? claudePath,
        string? codexPath)
    {
        try
        {
            var records = await new SessionLogHistoryService().ScanAsync(
                claudePath,
                codexPath);
            await Dispatcher.InvokeAsync(() => viewModel.ApplyScannedHistory(records));
        }
        catch (Exception exception)
        {
            Trace.TraceWarning("Session history scan skipped: {0}", exception.Message);
        }
    }

    private void ApplyRuntimeSettings(AppSettingsState settings)
    {
        var previous = _runtimeSettings;
        _runtimeSettings = settings;
        var executablePath = Environment.ProcessPath;
        if (!string.IsNullOrWhiteSpace(executablePath)
            && (previous is null
                || previous.LaunchAtLoginEnabled != settings.LaunchAtLoginEnabled))
        {
            try
            {
                _launchAtLogin.SetEnabled(settings.LaunchAtLoginEnabled, executablePath);
            }
            catch (Exception exception)
            {
                Trace.TraceWarning(
                    "Launch-at-login configuration skipped: {0}",
                    exception.Message);
            }
        }

        if (_petWindow is not null
            && (previous is null || previous.PetEnabled != settings.PetEnabled)
            && _petWindow.IsVisible != settings.PetEnabled)
        {
            if (settings.PetEnabled)
                _petWindow.ShowNearWorkingArea();
            else
                _petWindow.Hide();
            _tray?.SetPetVisible(settings.PetEnabled);
        }

        ApplyProviderQuotaRuntime(_latestQuotas, allowAlerts: false);
        _petViewModel?.ConfigureAppearance(
            settings.ShowsCurrentTask,
            settings.PetSpritePath,
            settings.PetSpriteVersion);
        if (previous is not null
            && (previous.LocalActivityEnabled != settings.LocalActivityEnabled
                || previous.ShowsCurrentTask != settings.ShowsCurrentTask))
        {
            ConfigureLiveActivity(
                settings.LocalActivityEnabled,
                settings.ShowsCurrentTask);
        }

        if (previous is not null && PathsChanged(previous, settings))
        {
            _usageCollectionService?.UpdatePaths(settings);
            _sessionHistoryViewModel?.ConfigureLogRoots(
                settings.ClaudePath,
                settings.CodexPath);
            _claudeActivityPath = settings.ClaudePath;
            _codexActivityPath = settings.CodexPath;
            _cursorActivityPath = settings.CursorPath;
            ConfigureLiveActivity(
                settings.LocalActivityEnabled,
                settings.ShowsCurrentTask);
            if (_sessionHistoryViewModel is not null)
            {
                _ = LoadSessionHistoryAsync(
                    _sessionHistoryViewModel,
                    settings.ClaudePath,
                    settings.CodexPath);
            }
        }
    }

    private static bool PathsChanged(AppSettingsState left, AppSettingsState right) =>
        !string.Equals(left.ClaudePath, right.ClaudePath, StringComparison.Ordinal)
        || !string.Equals(left.CodexPath, right.CodexPath, StringComparison.Ordinal)
        || !string.Equals(left.CursorPath, right.CursorPath, StringComparison.Ordinal)
        || !string.Equals(left.OpenCodePath, right.OpenCodePath, StringComparison.Ordinal)
        || !string.Equals(left.GeminiPath, right.GeminiPath, StringComparison.Ordinal)
        || !string.Equals(left.QwenPath, right.QwenPath, StringComparison.Ordinal)
        || !string.Equals(left.CopilotPath, right.CopilotPath, StringComparison.Ordinal);

    private void ConfigureLiveActivity(bool enabled, bool showsCurrentTask)
    {
        if (_petViewModel is null
            || _sessionHistoryViewModel is null
            || _codexActivityPath is null
            || _cursorActivityPath is null)
            return;

        _petActivityConnector?.Dispose();
        _sessionActivityConnector?.Dispose();
        _petActivityConnector = null;
        _sessionActivityConnector = null;
        _liveActivityService = null;
        TryConfigureClaudeLocalActivity(enabled);

        if (!enabled)
        {
            _petViewModel.UpdatePresentations([]);
            _sessionHistoryViewModel.ApplySessions([]);
            return;
        }

        _liveActivityService = new LiveActivityService(
        [
            new ClaudeLiveSessionSource(),
            new CodexLiveSessionSource(OptionalPath(_codexActivityPath)),
            new CursorLiveSessionSource(OptionalPath(_cursorActivityPath))
        ],
        pollInterval: TimeSpan.FromSeconds(5));
        _petActivityConnector = new PetActivityConnector(
            _liveActivityService,
            _petViewModel,
            Dispatcher,
            localActivityEnabled: true,
            showsCurrentTask: showsCurrentTask);
        _sessionActivityConnector = new SessionActivityConnector(
            _liveActivityService,
            _sessionHistoryViewModel,
            Dispatcher);
        _petActivityConnector.Start();
    }

    private void ApplyProviderQuotaRuntime(
        IReadOnlyList<ProviderQuotaViewModel> quotas,
        bool allowAlerts = true)
    {
        _latestQuotas = quotas;
        var settings = _runtimeSettings;
        if (settings is null || _tray is null)
            return;

        if (!settings.TrayQuotaEnabled || quotas.Count == 0)
        {
            _tray.SetToolTip("amon · AI 작업 모니터");
        }
        else
        {
            var provider = SelectTrayProvider(quotas, settings.TrayQuotaProvider);
            if (provider is null || provider.Metrics.Count == 0)
            {
                _tray.SetToolTip("amon · 할당량 정보 없음");
            }
            else
            {
                var meters = provider.Metrics
                    .Take(2)
                    .Select(metric => settings.TrayQuotaShowsRemaining
                        ? $"{metric.Label} {metric.RemainingPercent:0.#}% 남음"
                        : $"{metric.Label} {metric.UsedPercent:0.#}% 사용")
                    .ToArray();
                _tray.SetToolTip($"{provider.Provider} · {string.Join(" · ", meters)}");
            }
        }

        foreach (var provider in quotas)
        {
            foreach (var metric in provider.Metrics)
            {
                var alertKey = $"{provider.Provider}\n{metric.Label}";
                if (metric.RemainingPercent > 15)
                    _sentQuotaAlerts.Remove(alertKey);
                if (allowAlerts
                    && settings.QuotaAlertsEnabled
                    && metric.RemainingPercent <= 10
                    && _sentQuotaAlerts.Add(alertKey))
                {
                    _tray.ShowQuotaAlert(
                        provider.Provider,
                        metric.Label,
                        metric.RemainingPercent);
                }
            }
        }
    }

    private static ProviderQuotaViewModel? SelectTrayProvider(
        IReadOnlyList<ProviderQuotaViewModel> quotas,
        string configuredProvider)
    {
        if (!string.IsNullOrWhiteSpace(configuredProvider))
        {
            return quotas.FirstOrDefault(provider =>
                string.Equals(
                    provider.Provider,
                    configuredProvider,
                    StringComparison.OrdinalIgnoreCase));
        }

        return quotas
            .Where(static provider => provider.Metrics.Count > 0)
            .OrderBy(static provider =>
                provider.Metrics.Min(static metric => metric.RemainingPercent))
            .FirstOrDefault();
    }

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
        _sessionActivityConnector?.Dispose();
        _petWindow?.Close();
        _tray?.Dispose();
        _usageCollectionService?.Dispose();
        _providerQuotaService?.Dispose();
        _updateCoordinator?.Dispose();
        _singleInstance?.Dispose();
        _themeManager?.Dispose();

        base.OnExit(e);
    }
}
