namespace AMon.Quotas;

/// Canonical usage-window lengths in milliseconds, shared by every provider mapper.
public static class QuotaPeriod
{
    public const long SessionMs = 5L * 60 * 60 * 1000;
    public const long DayMs = 24L * 60 * 60 * 1000;
    public const long WeekMs = 7 * DayMs;
    public const long MonthMs = 30 * DayMs;
}
