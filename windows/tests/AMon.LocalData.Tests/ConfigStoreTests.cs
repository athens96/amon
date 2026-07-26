using System.Text.Json;
using AMon.LocalData;
using Xunit;

namespace AMon.LocalData.Tests;

public sealed class ConfigStoreTests
{
    [Fact]
    public async Task Load_and_save_preserves_unknown_fields_and_defaults_auto_update()
    {
        var directory = Path.Combine(Path.GetTempPath(), $"amon-config-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "config.json");
        await File.WriteAllTextAsync(path, """
            {"server_url":"http://localhost","future":{"answer":42},"paths":{"new_tool":"/logs"}}
            """);
        var store = new ConfigStore(path);

        var config = await store.LoadAsync();
        Assert.True(config.AutoUpdateEnabled);
        Assert.True(config.Pet.IsEnabled);
        Assert.True(config.Pet.IsLocalActivityEnabled);
        Assert.True(config.Pet.IsShowingCurrentTask);
        Assert.False(string.IsNullOrWhiteSpace(config.DeviceId));
        await store.SaveAsync(config);

        using var saved = JsonDocument.Parse(await File.ReadAllTextAsync(path));
        Assert.Equal(42, saved.RootElement.GetProperty("future").GetProperty("answer").GetInt32());
        Assert.Equal("/logs", saved.RootElement.GetProperty("paths").GetProperty("new_tool").GetString());
        Assert.True(File.Exists(store.BackupPath));
    }

    [Fact]
    public async Task Explicit_pet_privacy_settings_override_null_defaults()
    {
        var directory = Path.Combine(
            Path.GetTempPath(), $"amon-pet-config-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "config.json");
        await File.WriteAllTextAsync(path, """
            {
              "pet": {
                "enabled": false,
                "local_activity_enabled": false,
                "shows_current_task": false
              }
            }
            """);

        var config = await new ConfigStore(path).LoadAsync();

        Assert.False(config.Pet.IsEnabled);
        Assert.False(config.Pet.IsLocalActivityEnabled);
        Assert.False(config.Pet.IsShowingCurrentTask);
    }
}
