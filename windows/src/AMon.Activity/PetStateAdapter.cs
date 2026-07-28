namespace AMon.Activity;

public static class PetStateAdapter
{
    public static IReadOnlyList<PetPresentation> CreatePresentations(
        IEnumerable<LiveSession> sessions,
        bool localActivityEnabled = true,
        bool showsCurrentTask = true)
    {
        ArgumentNullException.ThrowIfNull(sessions);
        if (!localActivityEnabled)
            return [];

        var candidates = sessions.Select(static session => new Candidate(
            session,
            StatusFrom(session.Status),
            LiveText.FirstLine(session.ProjectLabel, 80)
                ?? ProviderTitle(session.Provider),
            LiveText.FirstLine(session.CurrentTask, 120))).ToArray();

        var attention = candidates
            .Where(static candidate =>
                candidate.Status is PetActivityStatus.NeedsInput or PetActivityStatus.Blocked)
            .OrderByDescending(static candidate => Priority(candidate.Status))
            .ThenByDescending(static candidate => candidate.Session.StartedAt)
            .ThenBy(static candidate => candidate.Session.Identity, StringComparer.Ordinal)
            .FirstOrDefault();
        if (attention is not null)
            return [CreatePresentation(attention, 1, showsCurrentTask)];

        var running = candidates
            .Where(static candidate =>
                candidate.Status is PetActivityStatus.Running
                    or PetActivityStatus.Reviewing)
            .OrderByDescending(static candidate => candidate.Session.StartedAt)
            .ThenBy(static candidate => candidate.Session.Identity, StringComparer.Ordinal)
            .ToArray();
        if (running.Length > 0)
            return running.Select(candidate =>
                CreatePresentation(candidate, running.Length, showsCurrentTask)).ToArray();

        var completed = candidates
            .Where(static candidate =>
                LiveText.FirstLine(candidate.Session.LastResult, 160) is not null)
            .OrderByDescending(static candidate => candidate.Session.UpdatedAt)
            .ThenBy(static candidate => candidate.Session.Identity, StringComparer.Ordinal)
            .FirstOrDefault();
        if (completed is null)
            return [];

        return
        [
            CreatePresentation(
                completed with { Status = PetActivityStatus.Ready },
                activeCount: 0,
                showsCurrentTask)
        ];
    }

    public static PetActivityStatus StatusFrom(string? rawStatus)
    {
        var normalized = (rawStatus ?? string.Empty)
            .Trim()
            .ToLowerInvariant()
            .Replace('-', '_')
            .Replace(' ', '_');
        return normalized switch
        {
            "needsinput" or "needs_input"
                or "inputrequired" or "input_required"
                or "awaitinginput" or "awaiting_input"
                or "waitingforinput" or "waiting_for_input"
                or "awaitingapproval" or "awaiting_approval"
                or "requiresapproval" or "requires_approval"
                or "requiresaction" or "requires_action" =>
                PetActivityStatus.NeedsInput,
            "blocked" or "error" or "failed" or "failure" =>
                PetActivityStatus.Blocked,
            "ready" or "complete" or "completed" or "done"
                or "success" or "succeeded" =>
                PetActivityStatus.Ready,
            "review" or "reviewing" or "in_review" or "inreview" =>
                PetActivityStatus.Reviewing,
            "active" or "running" or "working" or "in_progress"
                or "inprogress" or "busy" =>
                PetActivityStatus.Running,
            _ => PetActivityStatus.Idle
        };
    }

    private static PetPresentation CreatePresentation(
        Candidate candidate,
        int activeCount,
        bool showsCurrentTask)
    {
        var tokens = candidate.Session.Tokens;
        return new PetPresentation(
            candidate.Status,
            candidate.Title,
            showsCurrentTask ? candidate.InputPreview : null,
            showsCurrentTask
                ? LiveText.FirstLine(candidate.Session.LastResult, 160)
                : null,
            LiveText.FirstLine(candidate.Session.Provider, 32),
            candidate.Session.SessionId,
            candidate.Session.Identity,
            tokens.InputTokens,
            tokens.OutputTokens,
            tokens.TotalTokens,
            candidate.Session.UpdatedAt,
            activeCount);
    }

    private static int Priority(PetActivityStatus status) => status switch
    {
        PetActivityStatus.NeedsInput => 4,
        PetActivityStatus.Blocked => 3,
        PetActivityStatus.Ready => 2,
        PetActivityStatus.Reviewing => 1,
        PetActivityStatus.Running => 1,
        _ => 0
    };

    private static string ProviderTitle(string provider)
    {
        var normalized = provider.Trim();
        return normalized.Length == 0
            ? "amon"
            : char.ToUpperInvariant(normalized[0]) + normalized[1..];
    }

    private sealed record Candidate(
        LiveSession Session,
        PetActivityStatus Status,
        string Title,
        string? InputPreview);
}
