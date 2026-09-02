namespace AMon.Quotas;

/// Environment seam: variables plus the well-known per-user folders the credential stores probe.
public interface IQuotaEnvironment
{
    string? Variable(string name);
    /// `%USERPROFILE%` — the user's home; `~/…` paths from the macOS client resolve here.
    string HomeDirectory { get; }
    /// `%APPDATA%` (roaming).
    string ApplicationData { get; }
    /// `%LOCALAPPDATA%`.
    string LocalApplicationData { get; }
}

public sealed class SystemQuotaEnvironment : IQuotaEnvironment
{
    public string? Variable(string name)
    {
        var value = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(value) ? null : value.Trim();
    }

    public string HomeDirectory =>
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

    public string ApplicationData =>
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);

    public string LocalApplicationData =>
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
}

public static class QuotaEnvironmentExtensions
{
    /// Resolve a `~`-relative POSIX-style path from the macOS client against the user's home.
    public static string Home(this IQuotaEnvironment environment, params string[] segments) =>
        Path.Combine([environment.HomeDirectory, .. segments]);

    public static string AppData(this IQuotaEnvironment environment, params string[] segments) =>
        Path.Combine([environment.ApplicationData, .. segments]);

    public static string LocalAppData(this IQuotaEnvironment environment, params string[] segments) =>
        Path.Combine([environment.LocalApplicationData, .. segments]);
}
