using System.IO;
using System.Text.Json;
using AMon.App.Settings;

namespace AMon.App.Tests;

public sealed class LocalDataAppSettingsStoreTests : IDisposable
{
    private readonly string _directory = Path.Combine(
        Path.GetTempPath(),
        $"amon-settings-tests-{Guid.NewGuid():N}");

    [Fact]
    public void MissingFileUsesAutoUpdateOnDefault()
    {
        var store = new LocalDataAppSettingsStore(Path.Combine(_directory, "config.json"));

        Assert.True(store.Load().AutoUpdateEnabled);
    }

    [Fact]
    public void SavedValueRoundTrips()
    {
        var store = new LocalDataAppSettingsStore(Path.Combine(_directory, "config.json"));

        store.Save(new AppSettingsState(AutoUpdateEnabled: false));

        Assert.False(store.Load().AutoUpdateEnabled);
    }

    [Fact]
    public void UsesSnakeCaseAndPreservesUnknownFields()
    {
        Directory.CreateDirectory(_directory);
        var path = Path.Combine(_directory, "config.json");
        File.WriteAllText(path, """
            {
              "auto_update": true,
              "future_option": {
                "enabled": "later"
              }
            }
            """);
        var store = new LocalDataAppSettingsStore(path);

        var settings = store.Load();
        store.Save(settings with { AutoUpdateEnabled = false });

        using var document = JsonDocument.Parse(File.ReadAllText(path));
        Assert.False(document.RootElement.GetProperty("auto_update").GetBoolean());
        Assert.Equal(
            "later",
            document.RootElement.GetProperty("future_option").GetProperty("enabled").GetString());
    }

    [Fact]
    public void ServerPrivacyAndPathsRoundTrip()
    {
        var path = Path.Combine(_directory, "config.json");
        var store = new LocalDataAppSettingsStore(path);
        var settings = new AppSettingsState(
            AutoUpdateEnabled: false,
            LaunchAtLoginEnabled: true,
            QuotaAlertsEnabled: false,
            TrayQuotaEnabled: true,
            TrayQuotaShowsRemaining: false,
            TrayQuotaProvider: "Codex",
            ServerUrl: "https://monitor.example.com",
            UserKey: "user-key",
            PetEnabled: false,
            LocalActivityEnabled: true,
            ShowsCurrentTask: false,
            PetSpritePath: @"C:\pets\amon.png",
            PetSpriteVersion: 3,
            ClaudePath: @"C:\logs\claude",
            CodexPath: @"C:\logs\codex");

        store.Save(settings);
        var loaded = store.Load();

        Assert.Equal(settings, loaded);
    }

    public void Dispose()
    {
        if (Directory.Exists(_directory))
        {
            Directory.Delete(_directory, recursive: true);
        }
    }
}
