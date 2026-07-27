namespace AMon.Reporting;

public static class ServerEndpoint
{
    public static bool TryNormalize(string? value, out Uri? server)
    {
        var candidate = value?.Trim() ?? string.Empty;
        if (candidate.StartsWith("127.0.0.1:", StringComparison.OrdinalIgnoreCase)
            || candidate.StartsWith("localhost:", StringComparison.OrdinalIgnoreCase)
            || candidate.StartsWith("[::1]:", StringComparison.OrdinalIgnoreCase))
        {
            candidate = $"http://{candidate}";
        }

        if (Uri.TryCreate(candidate, UriKind.Absolute, out var parsed)
            && (parsed.Scheme == Uri.UriSchemeHttp || parsed.Scheme == Uri.UriSchemeHttps)
            && !string.IsNullOrWhiteSpace(parsed.Host))
        {
            server = parsed;
            return true;
        }

        server = null;
        return false;
    }
}
