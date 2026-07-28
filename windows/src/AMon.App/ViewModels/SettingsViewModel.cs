using System.Windows.Input;
using AMon.App.Settings;
using AMon.Reporting;

namespace AMon.App.ViewModels;

public sealed class SettingsViewModel : ObservableObject
{
    private readonly IAppSettingsStore _settingsStore;
    private AppSettingsState _settings;
    private Func<Task>? _sendNow;
    private Func<Task>? _refreshNow;
    private Action<AppSettingsState>? _runtimeSettingsChanged;
    private bool _isSending;
    private string _petImportStatus = "Codex 호환 펫 ZIP 또는 스프라이트시트를 가져올 수 있습니다.";
    private bool _petImportFailed;
    private string _reportStatus = "서버 URL과 유저 키를 입력하면 집계 사용량을 자동 전송합니다.";

    public SettingsViewModel(IAppSettingsStore settingsStore)
    {
        _settingsStore = settingsStore ?? throw new ArgumentNullException(nameof(settingsStore));
        _settings = _settingsStore.Load();
        SendNowCommand = new RelayCommand(
            () => _ = SendNowAsync(),
            () => ReportConfigured && !_isSending && _sendNow is not null);
        RefreshNowCommand = new RelayCommand(
            () => _ = _refreshNow?.Invoke(),
            () => _refreshNow is not null);
    }

    public ICommand SendNowCommand { get; }

    public ICommand RefreshNowCommand { get; }

    public IReadOnlyList<string> TrayQuotaProviders { get; } =
        ["자동 선택", "Claude Code", "Codex", "Cursor"];

    public IReadOnlyList<int> PetSpriteVersions { get; } = [1, 2, 3];

    public bool AutoUpdateEnabled
    {
        get => _settings.AutoUpdateEnabled;
        set => Update(_settings with { AutoUpdateEnabled = value }, nameof(AutoUpdateEnabled));
    }

    public bool LaunchAtLoginEnabled
    {
        get => _settings.LaunchAtLoginEnabled;
        set => Update(_settings with { LaunchAtLoginEnabled = value }, nameof(LaunchAtLoginEnabled));
    }

    public bool QuotaAlertsEnabled
    {
        get => _settings.QuotaAlertsEnabled;
        set => Update(_settings with { QuotaAlertsEnabled = value }, nameof(QuotaAlertsEnabled));
    }

    public bool TrayQuotaEnabled
    {
        get => _settings.TrayQuotaEnabled;
        set => Update(_settings with { TrayQuotaEnabled = value }, nameof(TrayQuotaEnabled));
    }

    public bool TrayQuotaShowsRemaining
    {
        get => _settings.TrayQuotaShowsRemaining;
        set => Update(
            _settings with { TrayQuotaShowsRemaining = value },
            nameof(TrayQuotaShowsRemaining));
    }

    public string SelectedTrayQuotaProvider
    {
        get => string.IsNullOrWhiteSpace(_settings.TrayQuotaProvider)
            ? "자동 선택"
            : _settings.TrayQuotaProvider;
        set => Update(
            _settings with
            {
                TrayQuotaProvider = value == "자동 선택" ? string.Empty : value,
            },
            nameof(SelectedTrayQuotaProvider));
    }

    public string ServerUrl
    {
        get => _settings.ServerUrl;
        set => Update(_settings with { ServerUrl = value }, nameof(ServerUrl), nameof(ReportConfigured));
    }

    public string UserKey
    {
        get => _settings.UserKey;
        set => Update(_settings with { UserKey = value }, nameof(UserKey), nameof(ReportConfigured));
    }

    public bool PetEnabled
    {
        get => _settings.PetEnabled;
        set => Update(_settings with { PetEnabled = value }, nameof(PetEnabled));
    }

    public bool LocalActivityEnabled
    {
        get => _settings.LocalActivityEnabled;
        set => Update(_settings with { LocalActivityEnabled = value }, nameof(LocalActivityEnabled));
    }

    public bool ShowsCurrentTask
    {
        get => _settings.ShowsCurrentTask;
        set => Update(_settings with { ShowsCurrentTask = value }, nameof(ShowsCurrentTask));
    }

    public string PetSpritePath
    {
        get => _settings.PetSpritePath;
        set => Update(_settings with { PetSpritePath = value }, nameof(PetSpritePath));
    }

    public int PetSpriteVersion
    {
        get => _settings.PetSpriteVersion;
        set => Update(
            _settings with
            {
                PetSpriteVersion = CodexPetSpriteLayout.NormalizeVersion(value),
            },
            nameof(PetSpriteVersion));
    }

    public string PetImportStatus
    {
        get => _petImportStatus;
        private set => SetProperty(ref _petImportStatus, value);
    }

    public bool PetImportFailed
    {
        get => _petImportFailed;
        private set => SetProperty(ref _petImportFailed, value);
    }

    public void ApplyImportedPet(CodexPetImportResult result)
    {
        PetSpriteVersion = result.Metadata.SpriteVersion;
        PetSpritePath = result.InstalledPath;
        PetEnabled = true;
        PetImportFailed = false;
        var name = string.IsNullOrWhiteSpace(result.DisplayName)
            ? string.Empty
            : $"{result.DisplayName} · ";
        PetImportStatus =
            $"{name}{result.Metadata.PixelWidth}×{result.Metadata.PixelHeight} "
            + $"{result.Metadata.Format} 펫을 적용했습니다.";
    }

    public void ResetPet()
    {
        PetSpritePath = string.Empty;
        PetImportFailed = false;
        PetImportStatus = "amon 기본 펫을 사용합니다.";
    }

    public void SetPetImportError(string message)
    {
        PetImportFailed = true;
        PetImportStatus = message;
    }

    public string ClaudePath
    {
        get => _settings.ClaudePath;
        set => Update(_settings with { ClaudePath = value }, nameof(ClaudePath));
    }

    public string CodexPath
    {
        get => _settings.CodexPath;
        set => Update(_settings with { CodexPath = value }, nameof(CodexPath));
    }

    public string CursorPath
    {
        get => _settings.CursorPath;
        set => Update(_settings with { CursorPath = value }, nameof(CursorPath));
    }

    public string OpenCodePath
    {
        get => _settings.OpenCodePath;
        set => Update(_settings with { OpenCodePath = value }, nameof(OpenCodePath));
    }

    public string GeminiPath
    {
        get => _settings.GeminiPath;
        set => Update(_settings with { GeminiPath = value }, nameof(GeminiPath));
    }

    public string QwenPath
    {
        get => _settings.QwenPath;
        set => Update(_settings with { QwenPath = value }, nameof(QwenPath));
    }

    public string CopilotPath
    {
        get => _settings.CopilotPath;
        set => Update(_settings with { CopilotPath = value }, nameof(CopilotPath));
    }

    public bool ReportConfigured =>
        ServerEndpoint.TryNormalize(ServerUrl, out _)
        && !string.IsNullOrWhiteSpace(UserKey);

    public bool IsSending
    {
        get => _isSending;
        private set
        {
            if (SetProperty(ref _isSending, value))
                NotifySendCanExecute();
        }
    }

    public string ReportStatus
    {
        get => _reportStatus;
        private set => SetProperty(ref _reportStatus, value);
    }

    public void ConfigureSend(Func<Task> sendNow)
    {
        _sendNow = sendNow;
        NotifySendCanExecute();
    }

    public void ConfigureRefresh(Func<Task> refreshNow)
    {
        _refreshNow = refreshNow;
        if (RefreshNowCommand is RelayCommand command)
            command.NotifyCanExecuteChanged();
    }

    public void ConfigureRuntimeSettings(Action<AppSettingsState> settingsChanged)
    {
        _runtimeSettingsChanged = settingsChanged;
        _runtimeSettingsChanged(_settings);
    }

    public void SetReportStatus(string status) => ReportStatus = status;

    private async Task SendNowAsync()
    {
        if (_sendNow is null || IsSending)
            return;
        IsSending = true;
        ReportStatus = "집계 사용량을 전송하는 중입니다…";
        try
        {
            await _sendNow();
        }
        finally
        {
            IsSending = false;
        }
    }

    private void Update(AppSettingsState next, params string[] propertyNames)
    {
        if (_settings == next)
            return;
        _settings = next;
        _settingsStore.Save(_settings);
        _runtimeSettingsChanged?.Invoke(_settings);
        foreach (var propertyName in propertyNames)
            OnPropertyChanged(propertyName);
        NotifySendCanExecute();
    }

    private void NotifySendCanExecute()
    {
        if (SendNowCommand is RelayCommand command)
            command.NotifyCanExecuteChanged();
    }
}
