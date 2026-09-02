using AMon.Quotas.Providers.Antigravity;
using AMon.Quotas.Providers.Claude;
using AMon.Quotas.Providers.Codex;
using AMon.Quotas.Providers.Copilot;
using AMon.Quotas.Providers.Cursor;
using AMon.Quotas.Providers.Devin;
using AMon.Quotas.Providers.Grok;
using AMon.Quotas.Providers.OpenRouter;
using AMon.Quotas.Providers.ZAI;

namespace AMon.Quotas;

/// The nine providers in display order, composed over the real file system, environment,
/// credential store, and HTTP transport. Mirrors the macOS `LiveProviderRegistry.all()`.
public static class QuotaProviderRegistry
{
    /// The providers plus the transports they share; disposing the set releases the `HttpClient`s.
    public static QuotaProviderSet CreateDefault()
    {
        var files = new LocalQuotaFileSystem();
        var environment = new SystemQuotaEnvironment();
        var clock = new SystemQuotaClock();
        var http = new HttpClientQuotaHttp();
        var loopbackHttp = new HttpClientQuotaHttp(allowInsecureLoopback: true);
        var providers = Create(files, environment, clock, http, loopbackHttp, new WindowsCredentialStore(), new SystemProcessRunner());
        return new QuotaProviderSet(providers, [http, loopbackHttp]);
    }

    /// `loopbackHttp` must trust `127.0.0.1` self-signed certificates (Antigravity's local language
    /// server); `http` keeps full validation for every remote endpoint.
    public static IReadOnlyList<IQuotaProvider> Create(
        IQuotaFileSystem files,
        IQuotaEnvironment environment,
        IQuotaClock clock,
        IQuotaHttp http,
        IQuotaHttp loopbackHttp,
        IWindowsCredentialStore credentialStore,
        IProcessRunner processRunner)
    {
        return
        [
            new ClaudeQuotaProvider(new ClaudeAuthStore(files, environment), new ClaudeUsageClient(http), clock),
            new CodexQuotaProvider(new CodexAuthStore(files, environment), new CodexUsageClient(http), clock),
            new CursorQuotaProvider(new CursorStateStore(environment, files), new CursorUsageClient(http), clock),
            new CopilotQuotaProvider(new CopilotAuthStore(files, environment, credentialStore), new CopilotUsageClient(http), clock),
            new AntigravityQuotaProvider(
                new AntigravityAuthStore(credentialStore, files, environment, clock),
                new AntigravityUsageClient(loopbackHttp, http, environment),
                new LanguageServerDiscovery(processRunner),
                clock),
            new DevinQuotaProvider(new DevinAuthStore(files, environment, new SqliteDevinStateReader()), new DevinUsageClient(http), clock),
            new GrokQuotaProvider(new GrokAuthStore(files, environment, clock), new GrokUsageClient(http), clock),
            new OpenRouterQuotaProvider(new OpenRouterAuthStore(files, environment), new OpenRouterUsageClient(http), clock),
            new ZaiQuotaProvider(new ZaiAuthStore(files, environment), new ZaiUsageClient(http), clock),
        ];
    }
}

/// Providers together with the disposable resources they were composed over.
public sealed class QuotaProviderSet(IReadOnlyList<IQuotaProvider> providers, IReadOnlyList<IDisposable> resources) : IDisposable
{
    public IReadOnlyList<IQuotaProvider> Providers { get; } = providers;

    public void Dispose()
    {
        foreach (var resource in resources)
            resource.Dispose();
    }
}
