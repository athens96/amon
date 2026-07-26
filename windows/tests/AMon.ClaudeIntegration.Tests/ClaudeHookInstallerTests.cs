using System.Text.Json.Nodes;
using AMon.ClaudeIntegration;

namespace AMon.ClaudeIntegration.Tests;

public sealed class ClaudeHookInstallerTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"amon-claude-installer-tests-{Guid.NewGuid():N}");

    [Fact]
    public void InstallIsIdempotentAndUsesExecFormForUnicodeSpacePath()
    {
        Directory.CreateDirectory(root);
        var settings = Path.Combine(root, "settings.json");
        File.WriteAllText(settings, """
            {
              "theme": "dark",
              "hooks": {
                "Stop": [{
                  "hooks": [{
                    "type": "command",
                    "command": "other.exe",
                    "args": []
                  }]
                }]
              }
            }
            """);
        var executable = Path.Combine(root, "한글 폴더", "AMon.ClaudeHook.exe");
        var installer = new ClaudeHookInstaller(settings, managedSettingsPath: null);

        var first = installer.Install(executable);
        var firstText = File.ReadAllText(settings);
        var second = installer.Install(executable);

        Assert.True(first.Changed);
        Assert.False(second.Changed);
        Assert.Equal(firstText, File.ReadAllText(settings));
        Assert.NotNull(first.BackupPath);
        var parsed = JsonNode.Parse(firstText)!;
        Assert.Equal("dark", parsed["theme"]!.GetValue<string>());
        var installedCommand = parsed["hooks"]!["SessionStart"]![0]!["hooks"]![0]![
            "command"]!.GetValue<string>();
        Assert.Equal(executable, installedCommand);
        Assert.Contains("\"args\": []", firstText);
        Assert.DoesNotContain("\"async\"", firstText);
        Assert.Contains("other.exe", firstText);
    }

    [Fact]
    public void UninstallRemovesOnlyManagedHandlers()
    {
        Directory.CreateDirectory(root);
        var settings = Path.Combine(root, "settings.json");
        var executable = Path.Combine(root, "AMon.ClaudeHook.exe");
        var installer = new ClaudeHookInstaller(settings, managedSettingsPath: null);
        installer.Install(executable);

        var rootObject = JsonNode.Parse(File.ReadAllText(settings))!.AsObject();
        rootObject["custom"] = 42;
        rootObject["hooks"]!["Stop"]!.AsArray().Add(JsonNode.Parse("""
            {"hooks":[{"type":"command","command":"mine.exe","args":[]}]}
            """));
        File.WriteAllText(settings, rootObject.ToJsonString());

        var result = installer.Uninstall();
        var text = File.ReadAllText(settings);

        Assert.True(result.Changed);
        Assert.DoesNotContain(ClaudeHookInstaller.ManagedMarker, text);
        Assert.Contains("mine.exe", text);
        Assert.Equal(42, JsonNode.Parse(text)!["custom"]!.GetValue<int>());
    }

    [Fact]
    public void BrokenJsonAbortsWithoutBackupOrModification()
    {
        Directory.CreateDirectory(root);
        var settings = Path.Combine(root, "settings.json");
        File.WriteAllText(settings, "{ broken");
        var installer = new ClaudeHookInstaller(settings, managedSettingsPath: null);

        Assert.Throws<ClaudeHookInstallException>(() =>
            installer.Install(Path.Combine(root, "AMon.ClaudeHook.exe")));
        Assert.Equal("{ broken", File.ReadAllText(settings));
        Assert.False(File.Exists($"{settings}.amon.bak"));
    }

    [Fact]
    public void ReportsUserAndManagedDisabledStates()
    {
        Directory.CreateDirectory(root);
        var settings = Path.Combine(root, "settings.json");
        var managed = Path.Combine(root, "managed-settings.json");
        var executable = Path.Combine(root, "AMon.ClaudeHook.exe");
        File.WriteAllText(settings, """{"disableAllHooks":true}""");
        File.WriteAllText(managed, """{"allowManagedHooksOnly":true}""");

        var userDisabled = new ClaudeHookInstaller(settings, managedSettingsPath: null)
            .Install(executable);
        Assert.Equal(ClaudeHookAvailability.DisabledBySettings, userDisabled.Availability);

        File.WriteAllText(settings, "{}");
        var managedDisabled = new ClaudeHookInstaller(settings, managed).Install(executable);
        Assert.Equal(
            ClaudeHookAvailability.DisabledByManagedPolicy,
            managedDisabled.Availability);
    }

    public void Dispose()
    {
        if (Directory.Exists(root))
        {
            Directory.Delete(root, recursive: true);
        }
    }
}
