namespace AMon.Activity;

public enum LiveTokenScope
{
    Unavailable,
    LatestMessage,
    SessionCumulative,
    Estimated
}

public sealed record LiveTokenSnapshot(
    long? InputTokens,
    long? OutputTokens,
    long? CacheReadTokens,
    long? CacheWriteTokens,
    long? ReasoningTokens,
    long? TotalTokens,
    LiveTokenScope Scope)
{
    public static LiveTokenSnapshot Unavailable { get; } =
        new(null, null, null, null, null, null, LiveTokenScope.Unavailable);
}

public sealed record LiveAgent(
    string ToolUseId,
    string AgentType,
    string Description,
    DateTimeOffset StartedAt);

public sealed record LiveSession(
    string Provider,
    string SessionId,
    string ProjectLabel,
    string? GitBranch,
    string Status,
    IReadOnlyList<LiveAgent> Agents,
    string? CurrentTask,
    string? LastResult,
    string? Model,
    LiveTokenSnapshot Tokens,
    DateTimeOffset StartedAt,
    DateTimeOffset UpdatedAt,
    // Why the session is waiting (a tool permission prompt, for example). Only set when
    // Status is "needs_input". Claude writes this text, so it is never the user's prompt.
    // Local display only — it is not part of any upload payload.
    string? Notice = null,
    // The session's transcript/rollout file, for the pet's recent-turn history. Local only.
    string? TranscriptPath = null,
    // The CLI's working directory, used to re-detect the host app. Local only.
    string? WorkingDirectory = null,
    // The GUI app that launched the CLI (recorded by the hook), for the bubble's host jump.
    string? HostApp = null,
    int? HostProcessId = null)
{
    public string Identity => $"{Provider}:{SessionId}";
}

public sealed record LivePollContext(TimeProvider TimeProvider)
{
    public DateTimeOffset Now => TimeProvider.GetUtcNow();
}

public interface ILiveSessionSource
{
    string Provider { get; }

    Task<IReadOnlyList<LiveSession>> PollAsync(
        LivePollContext context,
        CancellationToken cancellationToken = default);
}
