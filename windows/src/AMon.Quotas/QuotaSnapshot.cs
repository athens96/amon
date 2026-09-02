namespace AMon.Quotas;

/// The normalized result of one provider refresh. A failed refresh carries `ErrorMessage` and no
/// lines; a successful refresh may legitimately carry zero lines (a plan with nothing to meter).
public sealed record QuotaSnapshot(
    string ProviderId,
    string DisplayName,
    string? Plan,
    IReadOnlyList<QuotaMetricLine> Lines,
    DateTimeOffset RefreshedAt,
    string? ErrorMessage = null,
    string? Warning = null)
{
    public bool IsError => ErrorMessage is not null;

    public static QuotaSnapshot Success(
        IQuotaProvider provider,
        string? plan,
        IReadOnlyList<QuotaMetricLine> lines,
        DateTimeOffset refreshedAt,
        string? warning = null) =>
        new(provider.Id, provider.DisplayName, plan, lines, refreshedAt, null, warning);

    public static QuotaSnapshot Failure(IQuotaProvider provider, string message, DateTimeOffset refreshedAt) =>
        new(provider.Id, provider.DisplayName, null, [], refreshedAt, message);
}
