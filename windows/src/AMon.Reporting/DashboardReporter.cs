using System.Net.Http.Headers;

namespace AMon.Reporting;

public sealed class DashboardReporter(HttpClient httpClient)
{
    public static TimeSpan RetryDelay(int attempt)
    {
        var exponent = Math.Clamp(attempt - 1, 0, 5);
        return TimeSpan.FromSeconds(Math.Min(15 * Math.Pow(2, exponent), 300));
    }

    public static bool IsRetryableStatus(System.Net.HttpStatusCode status)
    {
        var code = (int)status;
        return code is 408 or 425 or 429 || code is >= 500 and <= 599;
    }

    public static bool IsRetryableException(Exception exception) =>
        exception is HttpRequestException or IOException or TaskCanceledException;

    public async Task<HttpResponseMessage> UploadAsync(
        Uri server,
        string userKey,
        string snapshotPath,
        CancellationToken cancellationToken = default)
    {
        var endpoint = new Uri(server, "/api/v1/ai-agents/report");
        using var content = new MultipartFormDataContent();
        content.Add(new StringContent(userKey.Trim()), "user_key");
        await using var file = File.OpenRead(snapshotPath);
        using var database = new StreamContent(file);
        database.Headers.ContentType = new MediaTypeHeaderValue("application/vnd.sqlite3");
        content.Add(database, "db", "usage-upload.db");
        return await httpClient.PostAsync(endpoint, content, cancellationToken);
    }
}
