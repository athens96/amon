using System.Collections.ObjectModel;
using System.Globalization;
using AMon.Quotas;

namespace AMon.App.ViewModels;

public sealed class ProviderQuotaViewModel
{
    private ProviderQuotaViewModel(
        string providerId,
        string provider,
        string? plan,
        string status,
        IReadOnlyList<ProviderQuotaMetricViewModel> metrics)
    {
        ProviderId = providerId;
        Provider = provider;
        Plan = plan ?? string.Empty;
        Status = status;
        Metrics = new ObservableCollection<ProviderQuotaMetricViewModel>(metrics);
    }

    /// Stable id shared with the macOS client (`claude`, `codex`, …).
    public string ProviderId { get; }

    public string Provider { get; }
    public string Plan { get; }
    public string Status { get; }
    public ObservableCollection<ProviderQuotaMetricViewModel> Metrics { get; }

    /// Only bounded meters participate in tray text, alerts, and auto-selection.
    public IEnumerable<ProviderQuotaMetricViewModel> ProgressMetrics =>
        Metrics.Where(static metric => metric.HasProgress);

    /// 이 프로바이더에서 가장 빡빡한 미터의 심각도 — 카드 머리의 점으로 표시한다.
    /// 카드를 열어보지 않아도 어디가 위험한지 알 수 있게 하는 신호다.
    public string Severity =>
        Metrics.Any(static metric => metric.Severity == "critical") ? "critical"
        : Metrics.Any(static metric => metric.Severity == "warning") ? "warning"
        : "normal";

    public bool HasAlert => Severity != "normal";

    public static ProviderQuotaViewModel FromSnapshot(QuotaSnapshot snapshot)
    {
        if (snapshot.IsError)
            return new(snapshot.ProviderId, snapshot.DisplayName, null, snapshot.ErrorMessage!, []);
        var metrics = snapshot.Lines.Select(ProviderQuotaMetricViewModel.FromLine).ToList();
        var status = snapshot.Warning
            ?? (metrics.Count == 0 ? "쿼터 정보 없음" : "방금 갱신");
        return new(snapshot.ProviderId, snapshot.DisplayName, snapshot.Plan, status, metrics);
    }

    public static ProviderQuotaViewModel Success(
        string provider,
        string? plan,
        IReadOnlyList<ProviderQuotaMetricViewModel> metrics) =>
        new(provider.ToLowerInvariant(), provider, plan, metrics.Count == 0 ? "쿼터 정보 없음" : "방금 갱신", metrics);

    public static ProviderQuotaViewModel SignedOut(string provider, string message) =>
        new(provider.ToLowerInvariant(), provider, null, message, []);

    public static ProviderQuotaViewModel Error(string provider, string message) =>
        new(provider.ToLowerInvariant(), provider, null, message, []);
}

/// One metric row. Bounded meters (`HasProgress`) carry a 0…100 fill; unbounded rows (balances,
/// spend figures, badges) show their value in `RemainingText` and render without a bar.
public sealed record ProviderQuotaMetricViewModel(
    string Label,
    string Kind,
    bool HasProgress,
    double UsedPercent,
    double RemainingPercent,
    string UsedText,
    string RemainingText,
    string? ResetText)
{
    /// 의미색 축 — 경고·위험일 때 막대가 프로바이더 색을 버리고 이 상태를 따른다.
    public string Severity =>
        !HasProgress ? "normal"
        : UsedPercent >= 90 ? "critical"
        : UsedPercent >= 75 ? "warning"
        : "normal";

    public static ProviderQuotaMetricViewModel Percent(string label, double used, DateTimeOffset? reset)
    {
        var normalized = Math.Clamp(used, 0, 100);
        return new(
            label,
            "percent",
            true,
            normalized,
            100 - normalized,
            $"{normalized:0.#}% 사용",
            $"{100 - normalized:0.#}% 남음",
            FormatReset(reset));
    }

    public static ProviderQuotaMetricViewModel FromLine(QuotaMetricLine line) => line switch
    {
        QuotaProgressLine { Kind: QuotaMetricKind.Percent } percent =>
            Percent(percent.Label, percent.Used, percent.ResetsAt),
        QuotaProgressLine { Kind: QuotaMetricKind.Dollars } dollars => new(
            dollars.Label,
            "dollars",
            true,
            dollars.UsedPercent,
            100 - dollars.UsedPercent,
            $"{QuotaMetricFormat.Dollars(dollars.Used)} / {QuotaMetricFormat.Dollars(dollars.Limit)}",
            $"{QuotaMetricFormat.Dollars(Math.Max(0, dollars.Limit - dollars.Used))} 남음",
            FormatReset(dollars.ResetsAt)),
        QuotaProgressLine count => new(
            count.Label,
            "count",
            true,
            count.UsedPercent,
            100 - count.UsedPercent,
            $"{QuotaMetricFormat.Count(count.Used)} / {QuotaMetricFormat.Count(count.Limit)}{Suffix(count.CountSuffix)}",
            $"{QuotaMetricFormat.Count(Math.Max(0, count.Limit - count.Used))}{Suffix(count.CountSuffix)} 남음",
            FormatReset(count.ResetsAt)),
        QuotaValuesLine values => new(
            values.Label,
            "values",
            false,
            0,
            100,
            string.Empty,
            QuotaMetricFormat.Values(values.Values),
            values.ExpiresAt is { Count: > 0 } expiries ? FormatReset(expiries.Min(), "만료") : null),
        QuotaBadgeLine badge => new(badge.Label, "badge", false, 0, 100, string.Empty, badge.Text, null),
        QuotaTextLine text => new(text.Label, "text", false, 0, 100, string.Empty, text.Value, null),
        _ => new(line.Label, "text", false, 0, 100, string.Empty, string.Empty, null),
    };

    private static string Suffix(string? suffix) =>
        string.IsNullOrWhiteSpace(suffix) ? string.Empty : $" {suffix}";

    private static string? FormatReset(DateTimeOffset? reset, string verb = "리셋")
    {
        if (reset is null)
            return null;
        var local = reset.Value.ToLocalTime();
        var remaining = reset.Value - DateTimeOffset.UtcNow;
        return remaining.TotalHours >= 24
            ? $"{local:MM/dd HH:mm} {verb}"
            : $"{Math.Max(0, (int)remaining.TotalHours)}시간 {Math.Max(0, remaining.Minutes)}분 후 {verb}";
    }
}

/// Display-edge number formatting, ported from the macOS `MetricFormat` so both clients abbreviate
/// the same way ("$4.08", "$1.2K", "12.4K searches").
public static class QuotaMetricFormat
{
    public static string Compact(double value)
    {
        var magnitude = Math.Abs(value);
        return magnitude switch
        {
            >= 1_000_000_000 => Trim(value / 1_000_000_000) + "B",
            >= 1_000_000 => Trim(value / 1_000_000) + "M",
            >= 1_000 => Trim(value / 1_000) + "K",
            _ => Math.Round(value).ToString(CultureInfo.InvariantCulture),
        };
    }

    public static string Dollars(double value) =>
        Math.Abs(value) >= 1000
            ? "$" + Compact(value)
            : value.ToString("$0.00", CultureInfo.InvariantCulture);

    public static string Count(double value) =>
        Math.Abs(value) >= 1000
            ? Compact(value)
            : Math.Round(value).ToString(CultureInfo.InvariantCulture);

    public static string Value(QuotaMetricValue value)
    {
        var text = value.Kind switch
        {
            QuotaMetricKind.Dollars => Dollars(value.Number),
            QuotaMetricKind.Percent => $"{Math.Round(value.Number)}%",
            _ => Count(value.Number),
        };
        return string.IsNullOrWhiteSpace(value.Unit) ? text : $"{text} {value.Unit}";
    }

    public static string Values(IReadOnlyList<QuotaMetricValue> values) =>
        string.Join(" · ", values.Select(Value));

    private static string Trim(double value)
    {
        var rounded = Math.Round(value * 10) / 10;
        return rounded == Math.Round(rounded)
            ? ((int)rounded).ToString(CultureInfo.InvariantCulture)
            : rounded.ToString("0.0", CultureInfo.InvariantCulture);
    }
}
