using System.Collections.ObjectModel;
using System.Diagnostics;
using System.Windows.Input;

namespace AMon;

public sealed class AppController : ObservableObject, IDisposable
{
    private readonly ConfigService _configService = new();
    private readonly LocalUsageScanner _scanner = new();
    private readonly ProviderService _providers = new();
    private readonly SessionService _sessions;
    private readonly UsageStore _store;
    private readonly SemaphoreSlim _refreshLock = new(1, 1);
    private readonly System.Threading.Timer _timer;
    private AppConfig _config;
    private bool _isBusy;
    private bool _settingsVisible;
    private string _today = "0";
    private string _allTime = "0";
    private string _input = "0";
    private string _output = "0";
    private string _cache = "0";
    private string _status = "불러오는 중";

    public AppController()
    {
        _config = _configService.Load();
        _sessions = new SessionService(_configService.DirectoryPath);
        _store = new UsageStore(_configService.DirectoryPath);
        RefreshCommand = new AsyncCommand(() => RefreshAsync(true), () => !IsBusy);
        ShowDashboardCommand = new RelayCommand(() => SettingsVisible = false);
        ShowSettingsCommand = new RelayCommand(() => SettingsVisible = true);
        SaveSettingsCommand = new RelayCommand(SaveSettings);
        OpenConfigCommand = new RelayCommand(OpenConfig);
        ExitCommand = new RelayCommand(() => ExitRequested?.Invoke(this, EventArgs.Empty));
        _timer = new System.Threading.Timer(async _ => await RefreshAsync(false), null, Timeout.Infinite, Timeout.Infinite);
    }

    public event EventHandler? Changed;
    public event EventHandler? ExitRequested;
    public ObservableCollection<ProviderSnapshot> ProviderSnapshots { get; } = [];
    public ObservableCollection<ToolRow> Tools { get; } = [];
    public ObservableCollection<SessionRow> RecentSessions { get; } = [];
    public ICommand RefreshCommand { get; }
    public ICommand ShowDashboardCommand { get; }
    public ICommand ShowSettingsCommand { get; }
    public ICommand SaveSettingsCommand { get; }
    public ICommand OpenConfigCommand { get; }
    public ICommand ExitCommand { get; }
    public string Today { get => _today; private set => Set(ref _today, value); }
    public string AllTime { get => _allTime; private set => Set(ref _allTime, value); }
    public string Input { get => _input; private set => Set(ref _input, value); }
    public string Output { get => _output; private set => Set(ref _output, value); }
    public string Cache { get => _cache; private set => Set(ref _cache, value); }
    public string Status { get => _status; private set => Set(ref _status, value); }
    public bool IsBusy { get => _isBusy; private set { if (Set(ref _isBusy, value)) (RefreshCommand as AsyncCommand)?.RaiseCanExecuteChanged(); } }
    public bool SettingsVisible { get => _settingsVisible; set => Set(ref _settingsVisible, value); }
    public bool AutoUpdate { get => _config.AutoUpdate; set { _config.AutoUpdate = value; Raise(); } }
    public bool ShareSessions { get => _config.ShareSessions; set { _config.ShareSessions = value; Raise(); } }
    public bool AutomaticPaths
    {
        get => string.IsNullOrWhiteSpace(_config.Paths.Claude) && string.IsNullOrWhiteSpace(_config.Paths.Codex) && string.IsNullOrWhiteSpace(_config.Paths.OpenCode) && string.IsNullOrWhiteSpace(_config.Paths.Cursor);
        set { if (value) _config.Paths = new ToolPaths(); Raise(); }
    }
    public bool ServerConnected => !string.IsNullOrWhiteSpace(_config.ServerUrl) && !string.IsNullOrWhiteSpace(_config.UserKey);
    public string ServerStatus => ServerConnected ? "서버 연결됨" : "로컬 전용";
    public string TrayTooltip
    {
        get
        {
            var quota = ProviderSnapshots.SelectMany(provider => provider.Metrics.Select(metric => (provider.Name, metric))).OrderBy(item => item.metric.RemainingPercent).FirstOrDefault();
            return quota.metric is null ? $"A-mon | 오늘 {Today} tokens" : $"A-mon | {quota.Name} {quota.metric.Label} {quota.metric.RemainingText}";
        }
    }

    public async Task InitializeAsync()
    {
        await RefreshAsync(false);
        _timer.Change(TimeSpan.FromMinutes(10), TimeSpan.FromMinutes(10));
    }

    private async Task RefreshAsync(bool forceProviders)
    {
        if (!await _refreshLock.WaitAsync(0)) return;
        try
        {
            IsBusy = true;
            Status = "업데이트 중";
            if (forceProviders) _providers.Invalidate();
            var paths = _configService.ResolvePaths(_config.Paths);
            var scanTask = _scanner.ScanAllAsync(paths);
            var sessionTask = _sessions.ScanAsync(paths);
            var providerTask = _providers.FetchAsync();
            await Task.WhenAll(scanTask, sessionTask, providerTask);
            var summaries = await scanTask;
            var sessions = await sessionTask;
            var providers = await providerTask;
            _store.Save(summaries, sessions, _config);
            await System.Windows.Application.Current.Dispatcher.InvokeAsync(() => UpdateCollections(summaries, sessions, providers));
            Status = "업데이트 " + DateTime.Now.ToString("HH:mm");
            Changed?.Invoke(this, EventArgs.Empty);
        }
        catch
        {
            Status = "일부 데이터를 읽지 못했습니다";
        }
        finally
        {
            IsBusy = false;
            _refreshLock.Release();
        }
    }

    private void UpdateCollections(IReadOnlyList<ToolSummary> summaries, IReadOnlyList<SessionRecord> sessions, IReadOnlyList<ProviderSnapshot> providers)
    {
        var today = new TokenUsage(); var total = new TokenUsage();
        foreach (var summary in summaries) { today.Add(summary.Today); total.Add(summary.Usage); }
        Today = Compact(today.Total); AllTime = Compact(total.Total); Input = Compact(today.Input); Output = Compact(today.Output); Cache = Compact(today.CacheRead + today.CacheWrite);
        Replace(ProviderSnapshots, providers);
        Replace(Tools, summaries.Select(summary => new ToolRow { Name = summary.DisplayName, Today = Compact(summary.Today.Total), Total = Compact(summary.Usage.Total) }));
        Replace(RecentSessions, sessions.Take(4).Select(record => new SessionRow
        {
            Label = string.IsNullOrWhiteSpace(record.ProjectLabel) ? "프로젝트 미상" : record.ProjectLabel,
            Provider = record.Provider, Time = IsActive(record) ? "진행 중" : Relative(record.EndedAt), Active = IsActive(record)
        }));
        Raise(nameof(TrayTooltip));
    }

    private void SaveSettings()
    {
        _configService.Save(_config);
        SettingsVisible = false;
        _ = RefreshAsync(false);
    }

    private void OpenConfig()
    {
        _configService.Save(_config);
        Process.Start(new ProcessStartInfo(_configService.ConfigPath) { UseShellExecute = true });
    }

    private static bool IsActive(SessionRecord record)
    {
        try { return record.SourcePath.Length > 0 && DateTime.Now - File.GetLastWriteTime(record.SourcePath) <= TimeSpan.FromMinutes(15); }
        catch { return false; }
    }
    private static string Relative(DateTimeOffset value)
    {
        var elapsed = DateTimeOffset.Now - value;
        if (elapsed < TimeSpan.FromMinutes(1)) return "방금";
        if (elapsed < TimeSpan.FromHours(1)) return $"{(int)elapsed.TotalMinutes}분 전";
        if (elapsed < TimeSpan.FromDays(1)) return $"{(int)elapsed.TotalHours}시간 전";
        return $"{(int)elapsed.TotalDays}일 전";
    }
    private static string Compact(long value) => value switch
    {
        >= 1_000_000_000 => $"{value / 1_000_000_000d:0.##}B",
        >= 1_000_000 => $"{value / 1_000_000d:0.##}M",
        >= 1_000 => $"{value / 1_000d:0.##}K",
        _ => value.ToString("N0")
    };
    private static void Replace<T>(ObservableCollection<T> target, IEnumerable<T> values) { target.Clear(); foreach (var value in values) target.Add(value); }
    public void Dispose() { _timer.Dispose(); _providers.Dispose(); _refreshLock.Dispose(); }
}

public sealed class RelayCommand(Action execute, Func<bool>? canExecute = null) : ICommand
{
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => canExecute?.Invoke() ?? true;
    public void Execute(object? parameter) => execute();
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}

public sealed class AsyncCommand(Func<Task> execute, Func<bool>? canExecute = null) : ICommand
{
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => canExecute?.Invoke() ?? true;
    public async void Execute(object? parameter) { if (CanExecute(parameter)) await execute(); }
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
