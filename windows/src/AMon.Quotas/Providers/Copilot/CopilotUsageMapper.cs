using System.Text;
using System.Text.Json;

namespace AMon.Quotas.Providers.Copilot;

/// The mapped payload, or the user-facing reason it could not be mapped. An error here is terminal
/// for the candidate token: unlike a 401 it will not get better by trying the next one.
public sealed record CopilotMappedUsage(string? Plan, IReadOnlyList<QuotaMetricLine> Lines, string? ErrorMessage = null)
{
    public bool IsError => ErrorMessage is not null;

    public static CopilotMappedUsage Failure(string message) => new(null, [], message);
}

/// Normalizes the `/copilot_internal/user` response into meters. Since 2026-06-01 every plan is on
/// usage-based billing (AI Credits), so the `premium_interactions` bucket is surfaced as **Credits**
/// (used % of the monthly allotment), with **Extra Usage** carrying overage beyond it. Paid plans
/// report `chat`/`completions` as the `-1` "unlimited" sentinel (suppressed); free plans carry real
/// `chat` and `completions` counts — either inside `quota_snapshots` (current) or, on older
/// responses, as `limited_user_quotas` against `monthly_quotas`. Zero-entitlement placeholder
/// snapshots — what GitHub returns for Copilot Business token-based-billing seats — carry no real
/// signal and are suppressed rather than rendered as a misleading "0% used" bar.
public static class CopilotUsageMapper
{
    public const long PeriodMs = QuotaPeriod.MonthMs;

    public const string SubscriptionEnded = "Copilot 구독이 종료된 계정입니다.";
    public const string QuotaUnavailable = "이 계정의 Copilot 사용량 정보를 가져올 수 없습니다.";

    public static CopilotMappedUsage Map(JsonElement root)
    {
        var plan = PlanLabel(QuotaJson.String(root, "copilot_plan"));
        var resetsAt = ParseResetDate(QuotaJson.String(root, "quota_reset_date"))
            ?? ParseResetDate(QuotaJson.String(root, "limited_user_reset_date"));

        var lines = new List<QuotaMetricLine>();

        // The metered premium pool is shown as "Credits"; overage beyond it as "Extra Usage".
        var snapshots = QuotaJson.ObjectProperty(root, "quota_snapshots");
        var premium = snapshots is { } snapshotObject ? QuotaJson.ObjectProperty(snapshotObject, "premium_interactions") : null;
        AddIfPresent(lines, SnapshotLine("Credits", premium, resetsAt));
        AddIfPresent(lines, OverageLine(premium));

        // Chat + completions: real per-bucket counts on free; the `-1` "unlimited" sentinel on paid
        // (suppressed by `SnapshotLine`). Older free responses without `quota_snapshots` fall back to
        // `limited_user_quotas` / `monthly_quotas` below.
        AddIfPresent(lines, SnapshotLine("Chat", Bucket(snapshots, "chat"), resetsAt));
        AddIfPresent(lines, SnapshotLine("Completions", Bucket(snapshots, "completions"), resetsAt));

        // Legacy free-tier shape (predates `quota_snapshots`): remaining counts against monthly limits.
        // Gated on nothing else having been produced — otherwise a paid account (Credits present,
        // chat/completions suppressed as unlimited) that still carried `limited_user_quotas` would
        // wrongly show free-tier meters alongside Credits.
        if (lines.Count == 0)
        {
            var limited = QuotaJson.ObjectProperty(root, "limited_user_quotas");
            var monthly = QuotaJson.ObjectProperty(root, "monthly_quotas");
            AddIfPresent(lines, LimitedLine("Chat", Value(limited, "chat"), Value(monthly, "chat"), resetsAt));
            AddIfPresent(lines, LimitedLine("Completions", Value(limited, "completions"), Value(monthly, "completions"), resetsAt));
        }

        if (lines.Count > 0)
            return new CopilotMappedUsage(plan, lines);

        // Copilot Business / token-based-billing seats expose no per-seat quota — a legitimate empty
        // state, not a failure. Surface the plan with empty meters so the dashboard still identifies
        // the plan, instead of a loud error that drops it. A genuinely empty or garbled payload (no
        // token-based-billing marker) is a real problem and fails loudly.
        if (QuotaJson.Bool(root, "token_based_billing") == true)
            return new CopilotMappedUsage(plan, []);
        // 구독이 끝난 계정은 쿼터 스냅샷이 아예 없다 — 일반 "unavailable" 대신 만료 상태를 그대로
        // 알려 재시도해 봐야 소용없음을 드러낸다.
        if (QuotaJson.String(root, "access_type_sku") == "subscription_ended")
            return CopilotMappedUsage.Failure(SubscriptionEnded);
        return CopilotMappedUsage.Failure(QuotaUnavailable);
    }

    /// A `quota_snapshots` bucket → percent-used meter, or `null` to suppress. Suppressed for: a
    /// missing bucket; an `unlimited` bucket or the `-1` entitlement/remaining sentinel (paid chat &
    /// completions under usage-based billing carry no real meter, so they're hidden rather than shown
    /// as a misleading 0%); and a zero-entitlement placeholder (e.g. Credits on a free account, which
    /// has no allotment).
    private static QuotaMetricLine? SnapshotLine(string label, JsonElement? raw, DateTimeOffset? resetsAt)
    {
        if (raw is not { } snapshot)
            return null;

        var entitlement = QuotaJson.Number(snapshot, "entitlement");
        var remaining = QuotaJson.Number(snapshot, "remaining");

        // Unlimited: the explicit flag, or GitHub's `-1` sentinel on entitlement/remaining. Suppress.
        if (QuotaJson.Bool(snapshot, "unlimited") == true || entitlement == -1 || remaining == -1)
            return null;
        // Zero entitlement = no real allotment (token-based-billing placeholder, or Credits on free).
        if (entitlement == 0)
            return null;

        double usedPercent;
        if (QuotaJson.Number(snapshot, "percent_remaining") is { } percentRemaining)
        {
            usedPercent = QuotaJson.ClampPercent(100 - percentRemaining);
        }
        else if (entitlement is { } total && total > 0 && remaining is { } left)
        {
            usedPercent = QuotaJson.ClampPercent(100 - (left / total * 100));
        }
        else
        {
            return null;
        }

        return new QuotaProgressLine(
            label,
            usedPercent,
            100,
            QuotaMetricKind.Percent,
            ResetsAt: resetsAt,
            PeriodMilliseconds: PeriodMs);
    }

    /// "Extra Usage" — premium interactions consumed beyond the included Credits pool. Surfaced only
    /// once the user has enabled additional (overage) spend (`overage_permitted`); a real zero is then
    /// shown ("0"), per the show-real-zeros rule. When overage isn't enabled it's genuinely N/A →
    /// `null` ("No data"). No spending cap is exposed on this endpoint, so this is an unbounded count,
    /// not a meter.
    private static QuotaMetricLine? OverageLine(JsonElement? raw)
    {
        if (raw is not { } snapshot || QuotaJson.Bool(snapshot, "overage_permitted") != true)
            return null;
        var overage = Math.Max(0, QuotaJson.Number(snapshot, "overage_count") ?? 0);
        return new QuotaValuesLine("Extra Usage", [new QuotaMetricValue(overage, QuotaMetricKind.Count)]);
    }

    /// A free-tier bucket: `remaining` against a `total` monthly limit → percent-used meter. `null`
    /// unless both a positive limit and a remaining count are present (no denominator → no honest
    /// percentage).
    private static QuotaMetricLine? LimitedLine(string label, double? remaining, double? total, DateTimeOffset? resetsAt)
    {
        if (total is not { } limit || limit <= 0 || remaining is not { } left)
            return null;
        var used = Math.Max(0, limit - left);
        return new QuotaProgressLine(
            label,
            QuotaJson.ClampPercent(used / limit * 100),
            100,
            QuotaMetricKind.Percent,
            ResetsAt: resetsAt,
            PeriodMilliseconds: PeriodMs);
    }

    private static JsonElement? Bucket(JsonElement? snapshots, string name) =>
        snapshots is { } element ? QuotaJson.ObjectProperty(element, name) : null;

    private static double? Value(JsonElement? element, string name) =>
        element is { } value ? QuotaJson.Number(value, name) : null;

    private static void AddIfPresent(ICollection<QuotaMetricLine> lines, QuotaMetricLine? line)
    {
        if (line is not null)
            lines.Add(line);
    }

    /// "copilot_pro_plus" → "Copilot Pro Plus": split on `_`, ` ` and `-`, upper-case each word's
    /// first character, lower-case the tail, re-join with single spaces.
    private static string? PlanLabel(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
            return null;
        var builder = new StringBuilder();
        foreach (var word in raw.Trim().Split(['_', ' ', '-'], StringSplitOptions.RemoveEmptyEntries))
        {
            if (builder.Length > 0)
                builder.Append(' ');
            builder.Append(char.ToUpperInvariant(word[0]));
            builder.Append(word[1..].ToLowerInvariant());
        }
        return builder.ToString();
    }

    /// Paid tier sends an ISO-8601 datetime (`quota_reset_date`, sometimes with fractional seconds);
    /// free tier sends a bare `yyyy-MM-dd` date (`limited_user_reset_date`).
    private static DateTimeOffset? ParseResetDate(string? raw) =>
        QuotaTime.ParseIso8601(raw) ?? QuotaTime.ParseDateOnly(raw);
}
