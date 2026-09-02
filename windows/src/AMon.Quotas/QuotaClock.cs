namespace AMon.Quotas;

/// Injectable "now" so expiry and reset arithmetic is testable.
public interface IQuotaClock
{
    DateTimeOffset Now { get; }
}

public sealed class SystemQuotaClock : IQuotaClock
{
    public DateTimeOffset Now => DateTimeOffset.UtcNow;
}

public sealed class FixedQuotaClock(DateTimeOffset now) : IQuotaClock
{
    public DateTimeOffset Now { get; set; } = now;
}
