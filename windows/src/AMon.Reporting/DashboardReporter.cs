using System.Net.Http.Headers;

namespace AMon.Reporting;

public sealed class DashboardReporter(HttpClient httpClient)
{
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
