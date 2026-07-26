using System.Text.Json;
using System.Text.Json.Serialization;

namespace AMon.LocalData;

public sealed class AppConfig
{
    [JsonPropertyName("server_url")]
    public string ServerUrl { get; set; } = string.Empty;

    [JsonPropertyName("user_key")]
    public string UserKey { get; set; } = string.Empty;

    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = string.Empty;

    [JsonPropertyName("auto_update")]
    public bool? AutoUpdate { get; set; }

    [JsonIgnore]
    public bool AutoUpdateEnabled => AutoUpdate ?? true;

    [JsonPropertyName("paths")]
    public ToolPaths Paths { get; set; } = new();

    [JsonPropertyName("pet")]
    public PetConfig Pet { get; set; } = new();

    [JsonExtensionData]
    public Dictionary<string, JsonElement> Extra { get; set; } = [];
}

public sealed class ToolPaths
{
    [JsonPropertyName("claude")]
    public string Claude { get; set; } = string.Empty;

    [JsonPropertyName("codex")]
    public string Codex { get; set; } = string.Empty;

    [JsonPropertyName("opencode")]
    public string OpenCode { get; set; } = string.Empty;

    [JsonPropertyName("cursor")]
    public string Cursor { get; set; } = string.Empty;

    [JsonPropertyName("gemini")]
    public string Gemini { get; set; } = string.Empty;

    [JsonPropertyName("qwen")]
    public string Qwen { get; set; } = string.Empty;

    [JsonPropertyName("copilot")]
    public string Copilot { get; set; } = string.Empty;

    [JsonExtensionData]
    public Dictionary<string, JsonElement> Extra { get; set; } = [];
}

public sealed class PetConfig
{
    [JsonPropertyName("enabled")]
    public bool? Enabled { get; set; }

    [JsonIgnore]
    public bool IsEnabled => Enabled ?? true;

    [JsonPropertyName("local_activity_enabled")]
    public bool? LocalActivityEnabled { get; set; }

    [JsonIgnore]
    public bool IsLocalActivityEnabled => LocalActivityEnabled ?? true;

    [JsonPropertyName("shows_current_task")]
    public bool? ShowsCurrentTask { get; set; }

    [JsonIgnore]
    public bool IsShowingCurrentTask => ShowsCurrentTask ?? true;

    [JsonPropertyName("sprite_path")]
    public string SpritePath { get; set; } = string.Empty;

    [JsonPropertyName("sprite_version")]
    public int SpriteVersion { get; set; }

    [JsonPropertyName("position_x")]
    public double? PositionX { get; set; }

    [JsonPropertyName("position_y")]
    public double? PositionY { get; set; }

    [JsonExtensionData]
    public Dictionary<string, JsonElement> Extra { get; set; } = [];
}
