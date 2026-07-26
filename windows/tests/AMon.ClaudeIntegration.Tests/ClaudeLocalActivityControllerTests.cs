using System.Text.Json.Nodes;
using AMon.ClaudeIntegration;

namespace AMon.ClaudeIntegration.Tests;

public sealed class ClaudeLocalActivityControllerTests : IDisposable
{
    private readonly string root = Path.Combine(
        Path.GetTempPath(),
        $"amon-local-activity-tests-{Guid.NewGuid():N}");

    [Fact]
    public void DisableRemovesOwnHookPurgesManagedFilesAndBlocksLoadedHook()
    {
        Directory.CreateDirectory(root);
        var settings = Path.Combine(root, "settings.json");
        var live = Path.Combine(root, "live");
        var helper = Path.Combine(root, ClaudeHookInstaller.ManagedExecutableName);
        File.WriteAllText(helper, "helper");
        File.WriteAllText(settings, """
            {
              "hooks": {
                "Stop": [{
                  "hooks": [{
                    "type": "command",
                    "command": "custom.exe",
                    "args": []
                  }]
                }]
              }
            }
            """);

        var installer = new ClaudeHookInstaller(settings, managedSettingsPath: null);
        installer.Install(helper);
        var processor = new ClaudeHookProcessor(live);
        processor.Process(Payload("active", "SessionStart"));
        processor.Process(Payload("ended", "SessionEnd"));
        var activePath = processor.GetSessionPath("active");
        var tombstonePath = processor.GetTombstonePath("ended");
        var malformedSensitivePath = processor.GetSessionPath("malformed-sensitive");
        Assert.True(File.Exists(activePath));
        Assert.True(File.Exists(tombstonePath));
        File.WriteAllText(
            malformedSensitivePath,
            """{"current_task":"sensitive prompt","last_result":""");
        var abandonedSensitiveTemporary = Path.Combine(
            live,
            $".{Path.GetFileName(activePath)}.123.{Guid.NewGuid():N}.tmp");
        File.WriteAllText(abandonedSensitiveTemporary, "sensitive prompt");

        var unrelatedSnapshot = Path.Combine(live, "unrelated.json");
        var unrelatedTombstone = Path.Combine(live, ".ended", "keep.tombstone");
        File.WriteAllText(unrelatedSnapshot, """{"provider":"other"}""");
        File.WriteAllText(unrelatedTombstone, "do not delete");

        var result = new ClaudeLocalActivityController(
            installer,
            new ClaudeLiveDataStore(live)).Configure(false, helper);

        Assert.False(result.Enabled);
        Assert.True(result.HookChanged);
        Assert.Equal(4, result.PurgedFiles);
        Assert.Empty(result.Errors);
        Assert.False(File.Exists(activePath));
        Assert.False(File.Exists(tombstonePath));
        Assert.False(File.Exists(malformedSensitivePath));
        Assert.False(File.Exists(abandonedSensitiveTemporary));
        Assert.True(File.Exists(unrelatedSnapshot));
        Assert.True(File.Exists(unrelatedTombstone));
        Assert.True(File.Exists(Path.Combine(
            live, ClaudeLiveDataStore.DisabledMarkerName)));

        var settingsRoot = JsonNode.Parse(File.ReadAllText(settings))!;
        Assert.Contains(
            "custom.exe",
            settingsRoot["hooks"]!["Stop"]!.ToJsonString());
        Assert.DoesNotContain(
            ClaudeHookInstaller.ManagedMarker,
            settingsRoot.ToJsonString());

        processor.Process(Payload("late", "SessionStart"));
        Assert.False(File.Exists(processor.GetSessionPath("late")));
    }

    [Fact]
    public void ReenableRemovesOptOutAndRestoresManagedHookAndSnapshots()
    {
        Directory.CreateDirectory(root);
        var settings = Path.Combine(root, "settings.json");
        var live = Path.Combine(root, "live");
        var helper = Path.Combine(root, ClaudeHookInstaller.ManagedExecutableName);
        File.WriteAllText(helper, "helper");
        var data = new ClaudeLiveDataStore(live);
        data.DisableAndPurge();
        var controller = new ClaudeLocalActivityController(
            new ClaudeHookInstaller(settings, managedSettingsPath: null),
            data);

        var result = controller.Configure(true, helper);

        Assert.True(result.Enabled);
        Assert.True(result.HookChanged);
        Assert.Empty(result.Errors);
        Assert.False(data.IsDisabled);
        Assert.Contains(
            ClaudeHookInstaller.ManagedMarker,
            File.ReadAllText(settings));

        var processor = new ClaudeHookProcessor(live);
        processor.Process(Payload("resumed", "SessionStart"));
        Assert.True(File.Exists(processor.GetSessionPath("resumed")));
    }

    [Fact]
    public void BrokenSettingsDoesNotPreventPrivacyMarkerOrPurge()
    {
        Directory.CreateDirectory(root);
        var settings = Path.Combine(root, "settings.json");
        var live = Path.Combine(root, "live");
        File.WriteAllText(settings, "{ broken");
        var processor = new ClaudeHookProcessor(live);
        processor.Process(Payload("active", "SessionStart"));
        var activePath = processor.GetSessionPath("active");

        var result = new ClaudeLocalActivityController(
            new ClaudeHookInstaller(settings, managedSettingsPath: null),
            new ClaudeLiveDataStore(live)).Configure(false, null);

        Assert.Single(result.Errors);
        Assert.Equal(1, result.PurgedFiles);
        Assert.False(File.Exists(activePath));
        Assert.True(File.Exists(Path.Combine(
            live, ClaudeLiveDataStore.DisabledMarkerName)));
        Assert.Equal("{ broken", File.ReadAllText(settings));
    }

    [Fact]
    public async Task DisableSerializesAfterAnInFlightWriteAndPurgesItsSnapshot()
    {
        Directory.CreateDirectory(root);
        var live = Path.Combine(root, "live");
        var data = new ClaudeLiveDataStore(live);
        var processor = new ClaudeHookProcessor(live);
        var writerHasLock = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        using var allowWrite = new ManualResetEventSlim();
        var writer = Task.Run(() =>
        {
            using var mutation = ClaudeLiveMutationLock.TryAcquire(
                live,
                TimeSpan.FromSeconds(1))!;
            writerHasLock.SetResult();
            allowWrite.Wait();
            processor.Process(Payload("racing", "SessionStart"));
            Assert.True(File.Exists(processor.GetSessionPath("racing")));
        });
        await writerHasLock.Task;

        var disableStarted = new TaskCompletionSource(
            TaskCreationOptions.RunContinuationsAsynchronously);
        var disable = Task.Run(() =>
        {
            disableStarted.SetResult();
            return data.DisableAndPurge();
        });
        await disableStarted.Task;
        Assert.False(disable.IsCompleted);
        allowWrite.Set();
        await writer;

        // Disable acquires the mutation lock after the in-flight write and then
        // creates the marker before purging, so no sensitive snapshot survives.
        Assert.Equal(1, await disable);
        Assert.True(data.IsDisabled);
        Assert.False(File.Exists(processor.GetSessionPath("racing")));
    }

    private static string Payload(string sessionId, string eventName) => $$"""
        {
          "session_id": "{{sessionId}}",
          "hook_event_name": "{{eventName}}",
          "cwd": "C:\\Work\\amon"
        }
        """;

    public void Dispose()
    {
        if (Directory.Exists(root))
            Directory.Delete(root, recursive: true);
    }
}
