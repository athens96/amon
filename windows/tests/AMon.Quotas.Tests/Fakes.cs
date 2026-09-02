using AMon.Quotas;

namespace AMon.Quotas.Tests;

/// In-memory file system keyed by absolute path.
public sealed class FakeFileSystem : IQuotaFileSystem
{
    public Dictionary<string, string> Files { get; } = new(StringComparer.Ordinal);

    public bool Exists(string path) => Files.ContainsKey(path);

    public string ReadText(string path) =>
        Files.TryGetValue(path, out var text) ? text : throw new FileNotFoundException(path);

    public void WriteText(string path, string text) => Files[path] = text;

    public void Delete(string path) => Files.Remove(path);
}

public sealed class FakeEnvironment : IQuotaEnvironment
{
    public Dictionary<string, string> Variables { get; } = new(StringComparer.OrdinalIgnoreCase);

    public string HomeDirectory { get; set; } = "/home/tester";

    public string ApplicationData { get; set; } = "/home/tester/AppData/Roaming";

    public string LocalApplicationData { get; set; } = "/home/tester/AppData/Local";

    public string? Variable(string name) =>
        Variables.TryGetValue(name, out var value) && !string.IsNullOrWhiteSpace(value) ? value.Trim() : null;
}

/// Scripted HTTP: responses are matched by URL substring in registration order; unmatched requests
/// throw `HttpRequestException` (a transport failure). Every request is recorded for assertions.
public sealed class FakeHttp : IQuotaHttp
{
    private readonly List<(Func<QuotaHttpRequest, bool> Match, Func<QuotaHttpRequest, QuotaHttpResponse> Respond)> _routes = [];

    public List<QuotaHttpRequest> Requests { get; } = [];

    public FakeHttp On(string urlContains, int status, string body) =>
        On(request => request.Url.Contains(urlContains, StringComparison.Ordinal), _ => Response(status, body));

    public FakeHttp On(Func<QuotaHttpRequest, bool> match, Func<QuotaHttpRequest, QuotaHttpResponse> respond)
    {
        _routes.Add((match, respond));
        return this;
    }

    public Task<QuotaHttpResponse> SendAsync(QuotaHttpRequest request, CancellationToken cancellationToken)
    {
        Requests.Add(request);
        foreach (var (match, respond) in _routes)
        {
            if (match(request))
                return Task.FromResult(respond(request));
        }
        throw new System.Net.Http.HttpRequestException($"No fake route for {request.Url}");
    }

    public static QuotaHttpResponse Response(int status, string body) =>
        new(status, body, new Dictionary<string, string>());
}

public sealed class FakeCredentialStore : IWindowsCredentialStore
{
    public Dictionary<string, string> Credentials { get; } = new(StringComparer.Ordinal);

    public string? ReadGenericCredential(string targetName) =>
        Credentials.TryGetValue(targetName, out var value) ? value : null;
}

public sealed class FakeProcessRunner : IProcessRunner
{
    public Dictionary<string, ProcessRunResult?> Results { get; } = new(StringComparer.Ordinal);

    public List<(string Executable, IReadOnlyList<string> Arguments)> Calls { get; } = [];

    public Task<ProcessRunResult?> RunAsync(string executable, IReadOnlyList<string> arguments, TimeSpan timeout, CancellationToken cancellationToken)
    {
        Calls.Add((executable, arguments));
        var key = Path.GetFileName(executable).ToLowerInvariant();
        return Task.FromResult(Results.TryGetValue(key, out var result) ? result : null);
    }
}
