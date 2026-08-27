using System.Text.Json.Serialization;

namespace AMon.ClaudeIntegration;

public sealed record ClaudeLiveAgent
{
    [JsonPropertyName("tool_use_id")]
    public required string ToolUseId { get; init; }

    [JsonPropertyName("agent_type")]
    public string? AgentType { get; init; }

    [JsonPropertyName("description")]
    public string? Description { get; init; }

    [JsonPropertyName("started_at")]
    public required DateTimeOffset StartedAt { get; init; }
}

public sealed record ClaudeLiveSession
{
    [JsonPropertyName("provider")]
    public string Provider { get; init; } = "claude";

    [JsonPropertyName("session_id")]
    public required string SessionId { get; init; }

    [JsonPropertyName("cwd")]
    public required string WorkingDirectory { get; init; }

    [JsonPropertyName("project_label")]
    public required string ProjectLabel { get; init; }

    [JsonPropertyName("git_branch")]
    public string? GitBranch { get; init; }

    [JsonPropertyName("status")]
    public required string Status { get; set; }

    [JsonPropertyName("current_task")]
    public string? CurrentTask { get; set; }

    [JsonPropertyName("last_result")]
    public string? LastResult { get; set; }

    // Why the session is waiting, from the Notification hook. Cleared as soon as anything
    // else happens. Claude writes this text, so it is never the user's prompt.
    [JsonPropertyName("notice")]
    public string? Notice { get; set; }

    [JsonPropertyName("attention_kind")]
    public string? AttentionKind { get; set; }

    [JsonPropertyName("agents")]
    public List<ClaudeLiveAgent> Agents { get; init; } = [];

    [JsonPropertyName("model")]
    public string? Model { get; set; }

    [JsonPropertyName("input_tokens")]
    public long? InputTokens { get; set; }

    [JsonPropertyName("output_tokens")]
    public long? OutputTokens { get; set; }

    [JsonPropertyName("cache_read_tokens")]
    public long? CacheReadTokens { get; set; }

    [JsonPropertyName("cache_write_tokens")]
    public long? CacheWriteTokens { get; set; }

    [JsonPropertyName("total_tokens")]
    public long? TotalTokens { get; set; }

    [JsonPropertyName("transcript_path")]
    public string? TranscriptPath { get; set; }

    [JsonPropertyName("started_at")]
    public required DateTimeOffset StartedAt { get; init; }

    [JsonPropertyName("updated_at")]
    public required DateTimeOffset UpdatedAt { get; set; }
}
