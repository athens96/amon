using System.Net.Http.Headers;
using System.Net.Http;
using System.Text;
using System.Text.Json;

namespace AMon;

public sealed class ProviderService : IDisposable
{
    private readonly HttpClient _http = new() { Timeout = TimeSpan.FromSeconds(12) };
    private IReadOnlyList<ProviderSnapshot> _cache = [];
    private DateTimeOffset _fetchedAt;

    public void Invalidate() => _fetchedAt = DateTimeOffset.MinValue;

    public async Task<IReadOnlyList<ProviderSnapshot>> FetchAsync(CancellationToken cancellationToken = default)
    {
        if (DateTimeOffset.Now - _fetchedAt < TimeSpan.FromMinutes(2)) return _cache;
        var tasks = new[] { FetchClaudeAsync(cancellationToken), FetchCodexAsync(cancellationToken) };
        var results = await Task.WhenAll(tasks);
        _cache = results.Where(snapshot => snapshot is not null).Cast<ProviderSnapshot>().ToArray();
        _fetchedAt = DateTimeOffset.Now;
        return _cache;
    }

    private async Task<ProviderSnapshot?> FetchCodexAsync(CancellationToken cancellationToken)
    {
        var path = CodexAuthPath();
        if (path is null) return null;
        JsonNodeDocument auth;
        try { auth = JsonNodeDocument.Parse(await File.ReadAllTextAsync(path, cancellationToken)); }
        catch { return null; }
        using (auth)
        {
            var token = auth.String("tokens", "access_token");
            var refresh = auth.String("tokens", "refresh_token");
            var account = auth.String("tokens", "account_id");
            if (token.Length == 0) return null;
            var snapshot = new ProviderSnapshot { Id = "codex", Name = "Codex" };
            if (JwtExpiresAt(token) is { } expires && expires - DateTimeOffset.Now <= TimeSpan.FromMinutes(5))
            {
                if (refresh.Length == 0) { snapshot.Status = "로그인이 만료되었습니다"; return snapshot; }
                try
                {
                    using var response = await _http.PostAsync("https://auth.openai.com/oauth/token", new FormUrlEncodedContent(new Dictionary<string, string>
                    {
                        ["grant_type"] = "refresh_token", ["client_id"] = "app_EMoamEEZ73f0CkXaXp7hrann", ["refresh_token"] = refresh
                    }), cancellationToken);
                    response.EnsureSuccessStatusCode();
                    using var body = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken));
                    token = Text(body.RootElement, "access_token");
                    var nextRefresh = Text(body.RootElement, "refresh_token");
                    if (token.Length == 0) throw new InvalidDataException();
                    auth.Set(token, "tokens", "access_token");
                    if (nextRefresh.Length > 0) auth.Set(nextRefresh, "tokens", "refresh_token");
                    auth.Set(DateTimeOffset.UtcNow.ToString("O"), "last_refresh");
                    await File.WriteAllTextAsync(path, auth.ToJson(), cancellationToken);
                }
                catch { snapshot.Status = "로그인을 갱신하지 못했습니다"; return snapshot; }
            }
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, "https://chatgpt.com/backend-api/wham/usage");
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
                request.Headers.UserAgent.ParseAdd("A-mon");
                if (account.Length > 0) request.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", account);
                using var response = await _http.SendAsync(request, cancellationToken);
                if (!response.IsSuccessStatusCode) { snapshot.Status = Status(response.StatusCode); return snapshot; }
                using var body = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken));
                snapshot.Plan = CodexPlan(Text(body.RootElement, "plan_type"));
                if (TryObject(body.RootElement, "rate_limit", out var rate))
                {
                    if (TryObject(rate, "primary_window", out var primary) && CodexMetric("세션", primary) is { } first) snapshot.Metrics.Add(first);
                    if (TryObject(rate, "secondary_window", out var secondary) && CodexMetric("주간", secondary) is { } second) snapshot.Metrics.Add(second);
                }
                if (snapshot.Metrics.Count == 0) snapshot.Status = "사용 한도 데이터가 없습니다";
                return snapshot;
            }
            catch { snapshot.Status = "네트워크 연결을 확인하세요"; return snapshot; }
        }
    }

    private async Task<ProviderSnapshot?> FetchClaudeAsync(CancellationToken cancellationToken)
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var basePath = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR") ?? Path.Combine(home, ".claude");
        var path = Path.Combine(basePath, ".credentials.json");
        if (!File.Exists(path)) return null;
        JsonNodeDocument credentials;
        try { credentials = JsonNodeDocument.Parse(await File.ReadAllTextAsync(path, cancellationToken)); }
        catch { return null; }
        using (credentials)
        {
            var token = credentials.String("claudeAiOauth", "accessToken");
            var refresh = credentials.String("claudeAiOauth", "refreshToken");
            if (token.Length == 0) return null;
            var snapshot = new ProviderSnapshot
            {
                Id = "claude", Name = "Claude",
                Plan = ClaudePlan(credentials.String("claudeAiOauth", "subscriptionType"), credentials.String("claudeAiOauth", "rateLimitTier"))
            };
            var expiresAt = credentials.Double("claudeAiOauth", "expiresAt");
            if (expiresAt > 0 && DateTimeOffset.FromUnixTimeMilliseconds((long)expiresAt) - DateTimeOffset.Now <= TimeSpan.FromMinutes(5))
            {
                if (refresh.Length == 0) { snapshot.Status = "로그인이 만료되었습니다"; return snapshot; }
                try
                {
                    var json = JsonSerializer.Serialize(new
                    {
                        grant_type = "refresh_token", refresh_token = refresh,
                        client_id = "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
                        scope = "user:profile user:inference user:sessions:claude_code user:mcp_servers user:file_upload"
                    });
                    using var response = await _http.PostAsync("https://platform.claude.com/v1/oauth/token", new StringContent(json, Encoding.UTF8, "application/json"), cancellationToken);
                    response.EnsureSuccessStatusCode();
                    using var body = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken));
                    token = Text(body.RootElement, "access_token");
                    var nextRefresh = Text(body.RootElement, "refresh_token");
                    var expiresIn = Number(body.RootElement, "expires_in");
                    if (token.Length == 0) throw new InvalidDataException();
                    credentials.Set(token, "claudeAiOauth", "accessToken");
                    if (nextRefresh.Length > 0) credentials.Set(nextRefresh, "claudeAiOauth", "refreshToken");
                    if (expiresIn > 0) credentials.Set(DateTimeOffset.Now.AddSeconds(expiresIn).ToUnixTimeMilliseconds(), "claudeAiOauth", "expiresAt");
                    await File.WriteAllTextAsync(path, credentials.ToJson(), cancellationToken);
                }
                catch { snapshot.Status = "로그인을 갱신하지 못했습니다"; return snapshot; }
            }
            try
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, "https://api.anthropic.com/api/oauth/usage");
                request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
                request.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
                request.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");
                request.Headers.UserAgent.ParseAdd("claude-code/2.1.69");
                using var response = await _http.SendAsync(request, cancellationToken);
                if (!response.IsSuccessStatusCode) { snapshot.Status = Status(response.StatusCode); return snapshot; }
                using var body = JsonDocument.Parse(await response.Content.ReadAsStreamAsync(cancellationToken));
                if (TryObject(body.RootElement, "five_hour", out var session) && ClaudeMetric("세션", session) is { } first) snapshot.Metrics.Add(first);
                if (TryObject(body.RootElement, "seven_day", out var weekly) && ClaudeMetric("주간", weekly) is { } second) snapshot.Metrics.Add(second);
                if (snapshot.Metrics.Count == 0) snapshot.Status = "사용 한도 데이터가 없습니다";
                return snapshot;
            }
            catch { snapshot.Status = "네트워크 연결을 확인하세요"; return snapshot; }
        }
    }

    private static QuotaMetric? CodexMetric(string fallback, JsonElement window)
    {
        var used = Number(window, "used_percent", double.NaN); if (double.IsNaN(used)) return null;
        var seconds = Number(window, "limit_window_seconds");
        var label = seconds is > 0 and <= 21600 ? "세션" : seconds is >= 518400 and <= 691200 ? "주간" : fallback;
        DateTimeOffset? reset = null;
        var at = Number(window, "reset_at"); var after = Number(window, "reset_after_seconds");
        if (at > 0) reset = DateTimeOffset.FromUnixTimeSeconds((long)at); else if (after > 0) reset = DateTimeOffset.Now.AddSeconds(after);
        return new QuotaMetric { Label = label, UsedPercent = Math.Clamp(used, 0, 100), ResetsAt = reset };
    }

    private static QuotaMetric? ClaudeMetric(string label, JsonElement window)
    {
        var used = Number(window, "utilization", double.NaN); if (double.IsNaN(used)) return null;
        DateTimeOffset? reset = DateTimeOffset.TryParse(Text(window, "resets_at"), out var parsed) ? parsed : null;
        return new QuotaMetric { Label = label, UsedPercent = Math.Clamp(used, 0, 100), ResetsAt = reset };
    }

    private static string? CodexAuthPath()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var custom = Environment.GetEnvironmentVariable("CODEX_HOME");
        var paths = custom is { Length: > 0 } ? new[] { Path.Combine(custom, "auth.json") } : new[] { Path.Combine(home, ".config", "codex", "auth.json"), Path.Combine(home, ".codex", "auth.json") };
        return paths.FirstOrDefault(File.Exists);
    }

    private static DateTimeOffset? JwtExpiresAt(string token)
    {
        try
        {
            var part = token.Split('.')[1].Replace('-', '+').Replace('_', '/');
            part = part.PadRight(part.Length + (4 - part.Length % 4) % 4, '=');
            using var json = JsonDocument.Parse(Convert.FromBase64String(part));
            var seconds = Number(json.RootElement, "exp");
            return seconds > 0 ? DateTimeOffset.FromUnixTimeSeconds((long)seconds) : null;
        }
        catch { return null; }
    }

    private static string CodexPlan(string raw) => raw.ToLowerInvariant() switch { "prolite" => "Pro 5x", "pro" => "Pro 20x", _ => raw.Replace('_', ' ') };
    private static string ClaudePlan(string subscription, string tier)
    {
        if (subscription.Length == 0) return "";
        var plan = char.ToUpperInvariant(subscription[0]) + subscription[1..].ToLowerInvariant();
        var multiplier = tier.Split(['_', '-']).FirstOrDefault(item => item.EndsWith('x') && int.TryParse(item[..^1], out _));
        return multiplier is null ? plan : $"{plan} {multiplier}";
    }
    private static string Status(System.Net.HttpStatusCode status) => status switch
    {
        System.Net.HttpStatusCode.Unauthorized or System.Net.HttpStatusCode.Forbidden => "로그인이 만료되었습니다",
        System.Net.HttpStatusCode.TooManyRequests => "잠시 후 다시 시도하세요",
        _ => $"조회 실패 (HTTP {(int)status})"
    };
	private static bool TryObject(JsonElement parent, string name, out JsonElement value)
	{
		value = default;
		return parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out value) && value.ValueKind == JsonValueKind.Object;
	}
    private static string Text(JsonElement parent, string name) => parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString()?.Trim() ?? "" : "";
    private static double Number(JsonElement parent, string name, double fallback = 0) => parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var value) ? value.ValueKind switch { JsonValueKind.Number => value.GetDouble(), JsonValueKind.String => double.TryParse(value.GetString(), out var n) ? n : fallback, _ => fallback } : fallback;
    public void Dispose() => _http.Dispose();
}

internal sealed class JsonNodeDocument : IDisposable
{
    private readonly System.Text.Json.Nodes.JsonNode _root;
    private JsonNodeDocument(System.Text.Json.Nodes.JsonNode root) => _root = root;
    public static JsonNodeDocument Parse(string json) => new(System.Text.Json.Nodes.JsonNode.Parse(json) ?? throw new JsonException());
    public string String(params string[] path) => Node(path)?.GetValue<string>() ?? "";
    public double Double(params string[] path) => Node(path)?.GetValue<double>() ?? 0;
    public void Set<T>(T value, params string[] path)
    {
        var parent = _root;
        foreach (var part in path[..^1]) parent = parent[part] ?? throw new JsonException();
        parent[path[^1]] = System.Text.Json.Nodes.JsonValue.Create(value);
    }
    public string ToJson() => _root.ToJsonString(new JsonSerializerOptions { WriteIndented = true });
    private System.Text.Json.Nodes.JsonNode? Node(string[] path) { System.Text.Json.Nodes.JsonNode? node = _root; foreach (var part in path) node = node?[part]; return node; }
    public void Dispose() { }
}
