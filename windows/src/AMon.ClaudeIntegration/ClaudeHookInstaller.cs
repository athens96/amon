using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace AMon.ClaudeIntegration;

public enum ClaudeHookAvailability
{
    /// <summary>
    /// The user settings permit the hook and no locally readable file policy blocks it.
    /// Remote policy and registry policy may still override this on Windows.
    /// </summary>
    LocallyEnabled,
    DisabledBySettings,
    DisabledByManagedPolicy,
}

public sealed record ClaudeHookInstallResult(
    bool Changed,
    ClaudeHookAvailability Availability,
    string SettingsPath,
    string? BackupPath);

public sealed class ClaudeHookInstallException(string message, Exception? innerException = null)
    : Exception(message, innerException);

public sealed class ClaudeHookInstaller
{
    public const string ManagedMarker = "A-mon local live activity";
    public const string ManagedExecutableName = "AMon.ClaudeHook.exe";

    private static readonly string[] EventsWithoutMatcher =
        ["SessionStart", "UserPromptSubmit", "Stop", "SessionEnd"];
    private static readonly string[] AgentToolEvents = ["PreToolUse", "PostToolUse"];
    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };

    private readonly string settingsPath;
    private readonly string? managedSettingsPath;

    public ClaudeHookInstaller(string? settingsPath = null, string? managedSettingsPath = null)
    {
        this.settingsPath = settingsPath ?? ResolveSettingsPath();
        this.managedSettingsPath = managedSettingsPath ?? ResolveManagedSettingsPath();
    }

    public ClaudeHookInstallResult Install(string executablePath) =>
        Update(executablePath, install: true);

    public ClaudeHookInstallResult Uninstall() =>
        Update(executablePath: null, install: false);

    public static string ResolveSettingsPath()
    {
        var configDirectory = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
        if (string.IsNullOrWhiteSpace(configDirectory))
        {
            configDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".claude");
        }

        return Path.Combine(configDirectory, "settings.json");
    }

    private ClaudeHookInstallResult Update(string? executablePath, bool install)
    {
        if (install)
        {
            if (string.IsNullOrWhiteSpace(executablePath) ||
                !Path.IsPathFullyQualified(executablePath) ||
                !string.Equals(Path.GetExtension(executablePath), ".exe", StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException(
                    "The Claude hook must be an absolute .exe path.",
                    nameof(executablePath));
            }

            executablePath = Path.GetFullPath(executablePath);
        }

        using var mutex = CreateSettingsMutex(settingsPath);
        try
        {
            if (!mutex.WaitOne(TimeSpan.FromSeconds(10)))
            {
                throw new ClaudeHookInstallException("Timed out waiting for Claude settings.");
            }
        }
        catch (AbandonedMutexException)
        {
            // We now own the mutex and can recover from an interrupted update.
        }

        try
        {
            var root = ReadObject(settingsPath);
            var before = root.ToJsonString(WriteOptions);
            RemoveManagedHandlers(root);
            if (install)
            {
                AddManagedHandlers(root, executablePath!);
            }

            var after = root.ToJsonString(WriteOptions);
            var changed = !string.Equals(before, after, StringComparison.Ordinal);
            string? backupPath = null;
            if (changed)
            {
                backupPath = WriteAtomicWithBackup(settingsPath, after);
            }

            return new ClaudeHookInstallResult(
                changed,
                DetectAvailability(root, managedSettingsPath),
                settingsPath,
                backupPath);
        }
        finally
        {
            mutex.ReleaseMutex();
        }
    }

    private static void AddManagedHandlers(JsonObject root, string executablePath)
    {
        var hooks = GetOrCreateHooks(root);
        foreach (var eventName in EventsWithoutMatcher)
        {
            GetOrCreateEvent(hooks, eventName).Add(CreateGroup(executablePath, matcher: null));
        }

        foreach (var eventName in AgentToolEvents)
        {
            GetOrCreateEvent(hooks, eventName).Add(CreateGroup(executablePath, "Agent|Task"));
        }
    }

    private static JsonObject CreateGroup(string executablePath, string? matcher)
    {
        var handler = new JsonObject
        {
            ["type"] = "command",
            ["command"] = executablePath,
            ["args"] = new JsonArray(),
            ["timeout"] = 5,
            ["statusMessage"] = ManagedMarker,
        };
        var group = new JsonObject
        {
            ["hooks"] = new JsonArray(handler),
        };
        if (matcher is not null)
        {
            group["matcher"] = matcher;
        }

        return group;
    }

    private static void RemoveManagedHandlers(JsonObject root)
    {
        if (root["hooks"] is null)
        {
            return;
        }

        if (root["hooks"] is not JsonObject hooks)
        {
            throw new ClaudeHookInstallException("Claude settings 'hooks' must be an object.");
        }

        foreach (var eventName in EventsWithoutMatcher.Concat(AgentToolEvents))
        {
            if (hooks[eventName] is null)
            {
                continue;
            }

            if (hooks[eventName] is not JsonArray groups)
            {
                throw new ClaudeHookInstallException(
                    $"Claude settings hook event '{eventName}' must be an array.");
            }

            for (var groupIndex = groups.Count - 1; groupIndex >= 0; groupIndex--)
            {
                if (groups[groupIndex] is not JsonObject group ||
                    group["hooks"] is not JsonArray handlers)
                {
                    continue;
                }

                for (var handlerIndex = handlers.Count - 1; handlerIndex >= 0; handlerIndex--)
                {
                    if (IsManagedHandler(handlers[handlerIndex]))
                    {
                        handlers.RemoveAt(handlerIndex);
                    }
                }

                if (handlers.Count == 0)
                {
                    groups.RemoveAt(groupIndex);
                }
            }

            if (groups.Count == 0)
            {
                hooks.Remove(eventName);
            }
        }

        if (hooks.Count == 0)
        {
            root.Remove("hooks");
        }
    }

    private static bool IsManagedHandler(JsonNode? node)
    {
        if (node is not JsonObject handler ||
            !string.Equals(
                handler["statusMessage"]?.GetValue<string>(),
                ManagedMarker,
                StringComparison.Ordinal))
        {
            return false;
        }

        var command = handler["command"]?.GetValue<string>();
        return !string.IsNullOrWhiteSpace(command) &&
            command.Replace('\\', '/').EndsWith(
                $"/{ManagedExecutableName}",
                StringComparison.OrdinalIgnoreCase);
    }

    private static JsonObject GetOrCreateHooks(JsonObject root)
    {
        if (root["hooks"] is null)
        {
            var hooks = new JsonObject();
            root["hooks"] = hooks;
            return hooks;
        }

        return root["hooks"] as JsonObject
            ?? throw new ClaudeHookInstallException("Claude settings 'hooks' must be an object.");
    }

    private static JsonArray GetOrCreateEvent(JsonObject hooks, string eventName)
    {
        if (hooks[eventName] is null)
        {
            var groups = new JsonArray();
            hooks[eventName] = groups;
            return groups;
        }

        return hooks[eventName] as JsonArray
            ?? throw new ClaudeHookInstallException(
                $"Claude settings hook event '{eventName}' must be an array.");
    }

    private static JsonObject ReadObject(string path)
    {
        if (!File.Exists(path))
        {
            return new JsonObject();
        }

        try
        {
            var text = File.ReadAllText(path, Encoding.UTF8);
            if (string.IsNullOrWhiteSpace(text))
            {
                return new JsonObject();
            }

            return JsonNode.Parse(text) as JsonObject
                ?? throw new ClaudeHookInstallException(
                    "Claude settings must contain a JSON object.");
        }
        catch (JsonException exception)
        {
            throw new ClaudeHookInstallException(
                "Claude settings contain invalid JSON; no changes were made.",
                exception);
        }
        catch (IOException exception)
        {
            throw new ClaudeHookInstallException(
                "Claude settings could not be read; no changes were made.",
                exception);
        }
    }

    private static string? WriteAtomicWithBackup(string path, string json)
    {
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        string? backupPath = null;
        if (File.Exists(path))
        {
            backupPath = $"{path}.amon.bak";
            File.Copy(path, backupPath, overwrite: true);
        }

        var temporaryPath = Path.Combine(
            directory,
            $".{Path.GetFileName(path)}.{Environment.ProcessId}.{Guid.NewGuid():N}.tmp");
        try
        {
            using (var stream = new FileStream(
                temporaryPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                4096,
                FileOptions.WriteThrough))
            using (var writer = new StreamWriter(
                stream,
                new UTF8Encoding(encoderShouldEmitUTF8Identifier: false)))
            {
                writer.Write(json);
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }

            File.Move(temporaryPath, path, overwrite: true);
            return backupPath;
        }
        catch (Exception exception) when (
            exception is IOException or UnauthorizedAccessException)
        {
            throw new ClaudeHookInstallException("Claude settings could not be saved.", exception);
        }
        finally
        {
            try
            {
                File.Delete(temporaryPath);
            }
            catch (IOException)
            {
            }
        }
    }

    private static ClaudeHookAvailability DetectAvailability(
        JsonObject userSettings,
        string? managedPath)
    {
        if (userSettings["disableAllHooks"]?.GetValue<bool>() == true)
        {
            return ClaudeHookAvailability.DisabledBySettings;
        }

        if (!string.IsNullOrEmpty(managedPath) && File.Exists(managedPath))
        {
            var managed = ReadObject(managedPath);
            if (managed["disableAllHooks"]?.GetValue<bool>() == true ||
                managed["allowManagedHooksOnly"]?.GetValue<bool>() == true)
            {
                return ClaudeHookAvailability.DisabledByManagedPolicy;
            }
        }

        return ClaudeHookAvailability.LocallyEnabled;
    }

    private static string? ResolveManagedSettingsPath()
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }

        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        return string.IsNullOrEmpty(programFiles)
            ? null
            : Path.Combine(programFiles, "ClaudeCode", "managed-settings.json");
    }

    private static Mutex CreateSettingsMutex(string path)
    {
        var canonicalPath = Path.GetFullPath(path).ToUpperInvariant();
        var digest = Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(canonicalPath)))[..24];
        return new Mutex(false, $"AMon.ClaudeSettings.{digest}");
    }
}
