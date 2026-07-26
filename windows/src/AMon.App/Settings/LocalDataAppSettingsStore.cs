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
            return new AppSettingsState(_loadedConfig.AutoUpdateEnabled);
        }
    }

    public void Save(AppSettingsState settings)
    {
        ArgumentNullException.ThrowIfNull(settings);

        lock (_gate)
        {
            _loadedConfig ??= RunSynchronously(() => _configStore.LoadAsync());
            _loadedConfig.AutoUpdate = settings.AutoUpdateEnabled;
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
