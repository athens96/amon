using AMon.LocalData;

namespace AMon.App.Settings;

public sealed class LocalDataAppSettingsStore : IAppSettingsStore
{
    private readonly Lock _gate = new();
    private readonly ConfigStore _configStore;
    private AppConfig? _loadedConfig;

    public LocalDataAppSettingsStore(string? path = null)
    {
        _configStore = new ConfigStore(path);
    }

    public AppSettingsState Load()
    {
        lock (_gate)
        {
            _loadedConfig ??= RunSynchronously(() => _configStore.LoadAsync());
            var paths = _loadedConfig.Paths;
            var pet = _loadedConfig.Pet;
            return new AppSettingsState(
                _loadedConfig.AutoUpdateEnabled,
                _loadedConfig.LaunchAtLoginEnabled,
                _loadedConfig.QuotaAlertsEnabled,
                _loadedConfig.TrayQuota.IsEnabled,
                _loadedConfig.TrayQuota.IsShowingRemaining,
                _loadedConfig.TrayQuota.Provider,
                _loadedConfig.ServerUrl,
                _loadedConfig.UserKey,
                pet.IsEnabled,
                pet.IsLocalActivityEnabled,
                pet.IsShowingCurrentTask,
                pet.SpritePath,
                CodexPetSpriteLayout.NormalizeVersion(pet.SpriteVersion),
                paths.Claude,
                paths.Codex,
                paths.Cursor,
                paths.OpenCode,
                paths.Gemini,
                paths.Qwen,
                paths.Copilot);
        }
    }

    public void Save(AppSettingsState settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        lock (_gate)
        {
            _loadedConfig ??= RunSynchronously(() => _configStore.LoadAsync());
            _loadedConfig.AutoUpdate = settings.AutoUpdateEnabled;
            _loadedConfig.LaunchAtLogin = settings.LaunchAtLoginEnabled;
            _loadedConfig.QuotaAlerts = settings.QuotaAlertsEnabled;
            _loadedConfig.TrayQuota.Enabled = settings.TrayQuotaEnabled;
            _loadedConfig.TrayQuota.ShowsRemaining = settings.TrayQuotaShowsRemaining;
            _loadedConfig.TrayQuota.Provider = settings.TrayQuotaProvider.Trim();
            _loadedConfig.ServerUrl = settings.ServerUrl.Trim();
            _loadedConfig.UserKey = settings.UserKey.Trim();
            _loadedConfig.Pet.Enabled = settings.PetEnabled;
            _loadedConfig.Pet.LocalActivityEnabled = settings.LocalActivityEnabled;
            _loadedConfig.Pet.ShowsCurrentTask = settings.ShowsCurrentTask;
            _loadedConfig.Pet.SpritePath = settings.PetSpritePath.Trim();
            _loadedConfig.Pet.SpriteVersion =
                CodexPetSpriteLayout.NormalizeVersion(settings.PetSpriteVersion);
            _loadedConfig.Paths.Claude = settings.ClaudePath.Trim();
            _loadedConfig.Paths.Codex = settings.CodexPath.Trim();
            _loadedConfig.Paths.Cursor = settings.CursorPath.Trim();
            _loadedConfig.Paths.OpenCode = settings.OpenCodePath.Trim();
            _loadedConfig.Paths.Gemini = settings.GeminiPath.Trim();
            _loadedConfig.Paths.Qwen = settings.QwenPath.Trim();
            _loadedConfig.Paths.Copilot = settings.CopilotPath.Trim();
            RunSynchronously(() => _configStore.SaveAsync(_loadedConfig));
        }
    }

    private static T RunSynchronously<T>(Func<Task<T>> operation)
    {
        return Task.Run(operation).GetAwaiter().GetResult();
    }

    private static void RunSynchronously(Func<Task> operation)
    {
        Task.Run(operation).GetAwaiter().GetResult();
    }
}
