namespace AMon.Quotas;

/// One row on a provider card, normalized into the small vocabulary the dashboard knows how to
/// render. Ported from the macOS `MetricLine`; the spend-trend chart variant is intentionally absent.
public abstract record QuotaMetricLine(string Label);

/// A bounded meter: `Used` against `Limit`. For `Percent` the limit is always 100 and `Used` is the
/// percentage itself; for `Dollars`/`Count` both are raw magnitudes.
public sealed record QuotaProgressLine(
    string Label,
    double Used,
    double Limit,
    QuotaMetricKind Kind,
    string? CountSuffix = null,
    DateTimeOffset? ResetsAt = null,
    long? PeriodMilliseconds = null) : QuotaMetricLine(Label)
{
    /// Fill ratio 0…1 — `Used / 100` for percent, `Used / Limit` otherwise.
    public double Fraction => Kind == QuotaMetricKind.Percent
        ? Math.Clamp(Used / 100, 0, 1)
        : Limit > 0 ? Math.Clamp(Used / Limit, 0, 1) : 0;

    public double UsedPercent => Fraction * 100;
}

/// One raw value on an unbounded row (a balance, a spend figure, an overage count).
public sealed record QuotaMetricValue(double Number, QuotaMetricKind Kind, string? Unit = null);

/// A row carrying one or more unbounded values ("$4.08 · 1.2M tokens").
public sealed record QuotaValuesLine(
    string Label,
    IReadOnlyList<QuotaMetricValue> Values,
    IReadOnlyList<DateTimeOffset>? ExpiresAt = null) : QuotaMetricLine(Label);

/// A short status pill ("Pay as you go: Disabled").
public sealed record QuotaBadgeLine(string Label, string Text) : QuotaMetricLine(Label);

/// A plain label/value row.
public sealed record QuotaTextLine(string Label, string Value) : QuotaMetricLine(Label);
