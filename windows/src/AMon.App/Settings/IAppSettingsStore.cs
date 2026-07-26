namespace AMon.App.Settings;

public sealed record AppSettingsState(
    bool AutoUpdateEnabled,
    bool LaunchAtLoginEnabled = false,
    bool QuotaAlertsEnabled = true,
    bool TrayQuotaEnabled = true,
    bool TrayQuotaShowsRemaining = true,
    string TrayQuotaProvider = "",
    string ServerUrl = "",
    string UserKey = "",
    bool PetEnabled = true,
    bool LocalActivityEnabled = true,
    bool ShowsCurrentTask = true,
    string PetSpritePath = "",
    int PetSpriteVersion = 1,
    string ClaudePath = "",
    string CodexPath = "",
    string CursorPath = "",
    string OpenCodePath = "",
    string GeminiPath = "",
    string QwenPath = "",
    string CopilotPath = "");

public interface IAppSettingsStore
{
    AppSettingsState Load();

    void Save(AppSettingsState settings);
}
