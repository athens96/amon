using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AMon;

public sealed class ToolPaths
{
    [JsonPropertyName("claude")] public string Claude { get; set; } = "";
    [JsonPropertyName("codex")] public string Codex { get; set; } = "";
    [JsonPropertyName("opencode")] public string OpenCode { get; set; } = "";
    [JsonPropertyName("cursor")] public string Cursor { get; set; } = "";
    [JsonPropertyName("gemini")] public string Gemini { get; set; } = "";
    [JsonPropertyName("qwen")] public string Qwen { get; set; } = "";
    [JsonPropertyName("copilot")] public string Copilot { get; set; } = "";
}

public sealed class AppConfig
{
    [JsonPropertyName("server_url")] public string ServerUrl { get; set; } = "";
    [JsonPropertyName("user_key")] public string UserKey { get; set; } = "";
    [JsonPropertyName("paths")] public ToolPaths Paths { get; set; } = new();
    [JsonPropertyName("auto_update")] public bool AutoUpdate { get; set; } = true;
    [JsonPropertyName("device_id")] public string DeviceId { get; set; } = "";
}

public sealed class ConfigService
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower,
        WriteIndented = true,
        PropertyNameCaseInsensitive = true
    };

    public string DirectoryPath { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "A-mon");
    public string ConfigPath => Path.Combine(DirectoryPath, "config.json");

    public AppConfig Load()
    {
        Directory.CreateDirectory(DirectoryPath);
        AppConfig config;
        try
        {
            config = File.Exists(ConfigPath)
                ? JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(ConfigPath), JsonOptions) ?? new AppConfig()
                : new AppConfig();
        }
        catch
        {
            config = new AppConfig();
        }
        if (string.IsNullOrWhiteSpace(config.DeviceId))
        {
            config.DeviceId = Convert.ToHexString(RandomNumberGenerator.GetBytes(16)).ToLowerInvariant();
            Save(config);
        }
        return config;
    }

    public void Save(AppConfig config)
    {
        Directory.CreateDirectory(DirectoryPath);
        File.WriteAllText(ConfigPath, JsonSerializer.Serialize(config, JsonOptions));
    }

    public ToolPaths ResolvePaths(ToolPaths configured)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        return new ToolPaths
        {
            Claude = Value(configured.Claude, Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") is { Length: > 0 } ch ? Path.Combine(ch, "projects") : Path.Combine(home, ".claude", "projects")),
            Codex = Value(configured.Codex, Environment.GetEnvironmentVariable("CODEX_HOME") is { Length: > 0 } co ? Path.Combine(co, "sessions") : Path.Combine(home, ".codex", "sessions")),
            OpenCode = Value(configured.OpenCode, FindOpenCode(home, appData, local)),
            Cursor = Value(configured.Cursor, Path.Combine(appData, "Cursor", "User", "globalStorage", "state.vscdb")),
            Gemini = Value(configured.Gemini, Path.Combine(Environment.GetEnvironmentVariable("GEMINI_DIR") ?? Path.Combine(home, ".gemini"), "tmp")),
            Qwen = Value(configured.Qwen, Path.Combine(Environment.GetEnvironmentVariable("QWEN_DIR") ?? Path.Combine(home, ".qwen"), "projects")),
            Copilot = Value(configured.Copilot, Path.Combine(Environment.GetEnvironmentVariable("COPILOT_DIR") ?? Path.Combine(home, ".copilot"), "session-state"))
        };
    }

    private static string Value(string configured, string fallback) => string.IsNullOrWhiteSpace(configured) ? fallback : configured;

    private static string FindOpenCode(string home, string appData, string local)
    {
        var explicitDb = Environment.GetEnvironmentVariable("OPENCODE_DB");
        if (!string.IsNullOrWhiteSpace(explicitDb)) return explicitDb;
        var explicitDir = Environment.GetEnvironmentVariable("OPENCODE_DATA_DIR");
        if (!string.IsNullOrWhiteSpace(explicitDir)) return explicitDir;
        string[] candidates =
        [
            Path.Combine(local, "opencode", "data"),
            Path.Combine(local, "ai.opencode.desktop", "opencode"),
            Path.Combine(appData, "opencode"),
            Path.Combine(home, ".local", "share", "opencode")
        ];
        return candidates.FirstOrDefault(path => File.Exists(Path.Combine(path, "opencode.db")) || Directory.Exists(Path.Combine(path, "storage", "message"))) ?? candidates[0];
    }
}
