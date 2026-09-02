namespace AMon.Quotas.Providers.Antigravity;

/// The four Antigravity metric labels, shared by `AntigravityUsageMapper` and the provider so both
/// sides of the exact-string label binding come from one place — label drift is a silent "No data".
///
/// Antigravity merged its quota pools on 2026-05-19: Gemini Pro and Flash draw from one shared pool,
/// every non-Gemini model (Claude, GPT-OSS) shares a second, and each pool has a rolling 5-hour
/// window plus a weekly window. The Gemini pool pair is titled "Session" / "Weekly" to match the
/// Claude/Codex rows; the non-Gemini pool keeps its "Claude" name.
public static class AntigravityMetric
{
    public const string SessionLabel = "Session";
    public const string WeeklyLabel = "Weekly";
    public const string ClaudeLabel = "Claude";
    public const string ClaudeWeeklyLabel = "Claude Weekly";
}
