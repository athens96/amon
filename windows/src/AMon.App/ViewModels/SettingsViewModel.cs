using AMon.App.Settings;

namespace AMon.App.ViewModels;

public sealed class SettingsViewModel : ObservableObject
{
    private readonly IAppSettingsStore _settingsStore;
    private AppSettingsState _settings;
    private bool _autoUpdateEnabled;

    public SettingsViewModel(IAppSettingsStore settingsStore)
    {
        _settingsStore = settingsStore ?? throw new ArgumentNullException(nameof(settingsStore));
        _settings = _settingsStore.Load();
        _autoUpdateEnabled = _settings.AutoUpdateEnabled;
    }

    public bool AutoUpdateEnabled
    {
        get => _autoUpdateEnabled;
        set
        {
            if (!SetProperty(ref _autoUpdateEnabled, value))
            {
                return;
            }

            _settings = _settings with { AutoUpdateEnabled = value };
            _settingsStore.Save(_settings);
        }
    }
}
