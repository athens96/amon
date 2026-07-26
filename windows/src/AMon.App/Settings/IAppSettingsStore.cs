namespace AMon.App.Settings;

public sealed record AppSettingsState(bool AutoUpdateEnabled);

public interface IAppSettingsStore
{
    AppSettingsState Load();

    void Save(AppSettingsState settings);
}
