namespace AMon.Quotas;

/// How a metric's number is formatted. Mirrors the macOS `MetricKind` vocabulary so the two clients
/// render the same provider payloads the same way.
public enum QuotaMetricKind
{
    /// The number is a 0…100 percentage.
    Percent,
    /// The number is a USD amount.
    Dollars,
    /// The number is an absolute count, optionally with a unit suffix.
    Count,
}
