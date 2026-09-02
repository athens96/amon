using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;

namespace AMon.Quotas;

public sealed record QuotaHttpRequest(
    HttpMethod Method,
    string Url,
    IReadOnlyDictionary<string, string>? Headers = null,
    byte[]? Body = null,
    string? ContentType = null,
    TimeSpan? Timeout = null)
{
    public static QuotaHttpRequest Get(string url, IReadOnlyDictionary<string, string>? headers = null, TimeSpan? timeout = null) =>
        new(HttpMethod.Get, url, headers, null, null, timeout);

    public static QuotaHttpRequest PostJson(
        string url,
        string json,
        IReadOnlyDictionary<string, string>? headers = null,
        TimeSpan? timeout = null) =>
        new(HttpMethod.Post, url, headers, Encoding.UTF8.GetBytes(json), "application/json", timeout);

    public static QuotaHttpRequest PostForm(
        string url,
        string form,
        IReadOnlyDictionary<string, string>? headers = null,
        TimeSpan? timeout = null) =>
        new(HttpMethod.Post, url, headers, Encoding.UTF8.GetBytes(form), "application/x-www-form-urlencoded", timeout);
}

public sealed record QuotaHttpResponse(int StatusCode, string Body, IReadOnlyDictionary<string, string> Headers)
{
    public bool IsSuccess => StatusCode is >= 200 and < 300;
    public bool IsAuthFailure => StatusCode is 401 or 403;

    public string? Header(string name) =>
        Headers.TryGetValue(name.ToLowerInvariant(), out var value) ? value : null;
}

/// Transport seam every provider talks through, so mappers and orchestration test against canned
/// responses. Throws `HttpRequestException`/`TaskCanceledException` on transport failure; any HTTP
/// status (including 4xx/5xx) is returned, never thrown.
public interface IQuotaHttp
{
    Task<QuotaHttpResponse> SendAsync(QuotaHttpRequest request, CancellationToken cancellationToken);
}

/// `HttpClient`-backed transport. `allowInsecureLoopback` trusts a self-signed certificate on
/// `127.0.0.1` only (Antigravity's local language server); every other host keeps full validation.
public sealed class HttpClientQuotaHttp : IQuotaHttp, IDisposable
{
    private static readonly TimeSpan DefaultTimeout = TimeSpan.FromSeconds(15);
    private readonly HttpClient _client;

    public HttpClientQuotaHttp(bool allowInsecureLoopback = false)
    {
        var handler = new HttpClientHandler
        {
            AutomaticDecompression = DecompressionMethods.All,
        };
        if (allowInsecureLoopback)
        {
            handler.ServerCertificateCustomValidationCallback = static (message, _, _, errors) =>
                errors == System.Net.Security.SslPolicyErrors.None
                || string.Equals(message.RequestUri?.Host, "127.0.0.1", StringComparison.Ordinal);
        }
        _client = new HttpClient(handler)
        {
            // Per-request timeouts are applied through a linked token; keep the client's own generous.
            Timeout = TimeSpan.FromSeconds(60),
        };
    }

    public async Task<QuotaHttpResponse> SendAsync(QuotaHttpRequest request, CancellationToken cancellationToken)
    {
        if (!Uri.TryCreate(request.Url, UriKind.Absolute, out var uri) || (uri.Scheme != "https" && uri.Scheme != "http"))
            throw new HttpRequestException("The request URL is not a valid absolute HTTP URL.");
        using var message = new HttpRequestMessage(request.Method, uri);
        if (request.Body is not null)
        {
            var content = new ByteArrayContent(request.Body);
            if (request.ContentType is not null)
                content.Headers.ContentType = MediaTypeHeaderValue.Parse(request.ContentType);
            message.Content = content;
        }
        if (request.Headers is not null)
        {
            foreach (var (name, value) in request.Headers)
            {
                if (!message.Headers.TryAddWithoutValidation(name, value) && message.Content is not null)
                    message.Content.Headers.TryAddWithoutValidation(name, value);
            }
        }

        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(request.Timeout ?? DefaultTimeout);
        try
        {
            using var response = await _client.SendAsync(message, HttpCompletionOption.ResponseContentRead, timeout.Token);
            var body = await response.Content.ReadAsStringAsync(timeout.Token);
            var headers = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var header in response.Headers.Concat(response.Content.Headers))
                headers[header.Key.ToLowerInvariant()] = string.Join(", ", header.Value);
            return new QuotaHttpResponse((int)response.StatusCode, body, headers);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new HttpRequestException("The request timed out.");
        }
    }

    public void Dispose() => _client.Dispose();
}
