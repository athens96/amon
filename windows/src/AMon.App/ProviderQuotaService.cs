using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Windows.Threading;
using AMon.App.ViewModels;
using Microsoft.Data.Sqlite;

namespace AMon.App;

public sealed class ProviderQuotaService : IDisposable
{
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(5);
    private readonly DashboardViewModel _dashboard;
    private readonly Dispatcher _dispatcher;
    private readonly HttpClient _httpClient;
    private readonly Action<IReadOnlyList<ProviderQuotaViewModel>>? _quotasUpdated;
    private readonly CancellationTokenSource _cancellation = new();
    private Task? _loop;

    public ProviderQuotaService(
        DashboardViewModel dashboard,
        Dispatcher dispatcher,
        Action<IReadOnlyList<ProviderQuotaViewModel>>? quotasUpdated = null)
    {
        _dashboard = dashboard;
        _dispatcher = dispatcher;
        _quotasUpdated = quotasUpdated;
        _httpClient = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
    }

    public void Start() => _loop ??= Task.Run(() => RunAsync(_cancellation.Token));

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var quotas = await Task.WhenAll(
                    FetchClaudeAsync(cancellationToken),
                    FetchCodexAsync(cancellationToken),
                    FetchCursorAsync(cancellationToken));
                await _dispatcher.InvokeAsync(
                    () =>
                    {
                        _dashboard.ApplyProviderQuotas(quotas);
                        _quotasUpdated?.Invoke(quotas);
                    },
                    DispatcherPriority.DataBind);
                await Task.Delay(RefreshInterval, cancellationToken);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private async Task<ProviderQuotaViewModel> FetchClaudeAsync(CancellationToken cancellationToken)
    {
        const string provider = "Claude Code";
        try
        {
            var configuredHome = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
            var home = string.IsNullOrWhiteSpace(configuredHome)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude")
                : Environment.ExpandEnvironmentVariables(configuredHome);
            var path = Path.Combine(home, ".credentials.json");
            if (!File.Exists(path))
                return ProviderQuotaViewModel.SignedOut(provider, "Claude CLI 로그인이 필요합니다.");

            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(path, cancellationToken));
            if (!TryProperty(document.RootElement, "claudeAiOauth", out var oauth)
                || !Text(oauth, "accessToken", out var token))
                return ProviderQuotaViewModel.SignedOut(provider, "Claude OAuth 토큰을 찾지 못했습니다.");

            using var request = new HttpRequestMessage(
                HttpMethod.Get,
                "https://api.anthropic.com/api/oauth/usage");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.ParseAdd("application/json");
            request.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");
            request.Headers.UserAgent.ParseAdd("claude-code/2.1.69");
            using var response = await _httpClient.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode)
                return ProviderQuotaViewModel.Error(provider, $"사용량 조회 실패 ({(int)response.StatusCode})");

            using var usage = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            var metrics = new List<ProviderQuotaMetricViewModel>();
            AddPercentWindow(metrics, usage.RootElement, "five_hour", "세션");
            AddPercentWindow(metrics, usage.RootElement, "seven_day", "주간");
            AddPercentWindow(metrics, usage.RootElement, "seven_day_sonnet", "Sonnet");
            var plan = ReadString(oauth, "subscriptionType");
            return ProviderQuotaViewModel.Success(provider, PlanName(plan), metrics);
        }
        catch (Exception exception) when (exception is IOException or JsonException or HttpRequestException)
        {
            return ProviderQuotaViewModel.Error(provider, FriendlyError(exception));
        }
    }

    private async Task<ProviderQuotaViewModel> FetchCodexAsync(CancellationToken cancellationToken)
    {
        const string provider = "Codex";
        try
        {
            var configuredHome = Environment.GetEnvironmentVariable("CODEX_HOME");
            var home = string.IsNullOrWhiteSpace(configuredHome)
                ? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex")
                : Environment.ExpandEnvironmentVariables(configuredHome);
            var path = Path.Combine(home, "auth.json");
            if (!File.Exists(path))
                return ProviderQuotaViewModel.SignedOut(provider, "Codex 로그인이 필요합니다.");

            using var document = JsonDocument.Parse(await File.ReadAllTextAsync(path, cancellationToken));
            if (!TryProperty(document.RootElement, "tokens", out var tokens)
                || !Text(tokens, "access_token", out var token))
                return ProviderQuotaViewModel.SignedOut(provider, "Codex OAuth 토큰을 찾지 못했습니다.");

            using var request = new HttpRequestMessage(
                HttpMethod.Get,
                "https://chatgpt.com/backend-api/wham/usage");
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token);
            request.Headers.Accept.ParseAdd("application/json");
            request.Headers.UserAgent.ParseAdd("amon");
            if (Text(tokens, "account_id", out var accountId))
                request.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", accountId);
            using var response = await _httpClient.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode)
                return ProviderQuotaViewModel.Error(provider, $"사용량 조회 실패 ({(int)response.StatusCode})");

            using var usage = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            var metrics = new List<ProviderQuotaMetricViewModel>();
            if (TryProperty(usage.RootElement, "rate_limit", out var rateLimit))
            {
                AddCodexWindow(metrics, rateLimit, "primary_window", "세션");
                AddCodexWindow(metrics, rateLimit, "secondary_window", "주간");
            }
            var plan = ReadString(usage.RootElement, "plan_type");
            return ProviderQuotaViewModel.Success(provider, PlanName(plan), metrics);
        }
        catch (Exception exception) when (exception is IOException or JsonException or HttpRequestException)
        {
            return ProviderQuotaViewModel.Error(provider, FriendlyError(exception));
        }
    }

    private async Task<ProviderQuotaViewModel> FetchCursorAsync(CancellationToken cancellationToken)
    {
        const string provider = "Cursor";
        try
        {
            var databasePath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "Cursor", "User", "globalStorage", "state.vscdb");
            if (!File.Exists(databasePath))
                return ProviderQuotaViewModel.SignedOut(provider, "Cursor 로그인이 필요합니다.");
            var auth = await ReadCursorAuthAsync(databasePath, cancellationToken);
            var token = auth.AccessToken;
            if (string.IsNullOrWhiteSpace(token) && !string.IsNullOrWhiteSpace(auth.RefreshToken))
                token = await RefreshCursorTokenAsync(auth.RefreshToken, cancellationToken);
            if (string.IsNullOrWhiteSpace(token))
                return ProviderQuotaViewModel.SignedOut(provider, "Cursor 인증 토큰을 찾지 못했습니다.");

            using var initialResponse = await SendCursorUsageRequestAsync(token, cancellationToken);
            HttpResponseMessage response = initialResponse;
            HttpResponseMessage? retryResponse = null;
            if (initialResponse.StatusCode == System.Net.HttpStatusCode.Unauthorized
                && !string.IsNullOrWhiteSpace(auth.RefreshToken))
            {
                var refreshedToken = await RefreshCursorTokenAsync(
                    auth.RefreshToken,
                    cancellationToken);
                if (!string.IsNullOrWhiteSpace(refreshedToken))
                {
                    await TryPersistCursorTokenAsync(
                        databasePath,
                        refreshedToken,
                        cancellationToken);
                    retryResponse = await SendCursorUsageRequestAsync(
                        refreshedToken,
                        cancellationToken);
                    response = retryResponse;
                }
            }
            using (retryResponse)
            {
            if (!response.IsSuccessStatusCode)
            {
                if (response.StatusCode == System.Net.HttpStatusCode.Unauthorized)
                {
                    return ProviderQuotaViewModel.SignedOut(
                        provider,
                        "Cursor 세션이 만료되었습니다. Cursor 앱에서 다시 로그인해 주세요.");
                }
                return ProviderQuotaViewModel.Error(provider, $"사용량 조회 실패 ({(int)response.StatusCode})");
            }

            using var usage = JsonDocument.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            var metrics = new List<ProviderQuotaMetricViewModel>();
            if (TryProperty(usage.RootElement, "planUsage", out var planUsage))
            {
                if (ReadDouble(planUsage, "totalPercentUsed") is { } total)
                    metrics.Add(ProviderQuotaMetricViewModel.Percent("전체 사용량", total, null));
                else if (ReadDouble(planUsage, "limit") is { } limit && limit > 0)
                {
                    var spent = ReadDouble(planUsage, "totalSpend")
                        ?? Math.Max(0, limit - (ReadDouble(planUsage, "remaining") ?? limit));
                    metrics.Add(ProviderQuotaMetricViewModel.Percent(
                        "전체 사용량",
                        spent / limit * 100,
                        null));
                }
                if (ReadDouble(planUsage, "autoPercentUsed") is { } auto)
                    metrics.Add(ProviderQuotaMetricViewModel.Percent("Auto", auto, null));
                if (ReadDouble(planUsage, "apiPercentUsed") is { } api)
                    metrics.Add(ProviderQuotaMetricViewModel.Percent("API", api, null));
            }
            var reset = ReadEpochMilliseconds(usage.RootElement, "billingCycleEnd");
            if (reset is not null)
            {
                for (var index = 0; index < metrics.Count; index++)
                    metrics[index] = metrics[index] with { ResetText = ResetText(reset) };
            }
            return ProviderQuotaViewModel.Success(provider, null, metrics);
            }
        }
        catch (Exception exception) when (
            exception is IOException or JsonException or HttpRequestException or SqliteException)
        {
            return ProviderQuotaViewModel.Error(provider, FriendlyError(exception));
        }
    }

    private static async Task<CursorAuthTokens> ReadCursorAuthAsync(
        string databasePath,
        CancellationToken cancellationToken)
    {
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = databasePath,
            Mode = SqliteOpenMode.ReadOnly,
            Cache = SqliteCacheMode.Shared,
        };
        await using var connection = new SqliteConnection(builder.ToString());
        await connection.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();
        command.CommandText = """
            SELECT key, value
            FROM ItemTable
            WHERE key IN ('cursorAuth/accessToken', 'cursorAuth/refreshToken');
            """;
        string? accessToken = null;
        string? refreshToken = null;
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            var key = reader.GetString(0);
            var value = DecodeCursorStateValue(reader.GetString(1));
            if (key == "cursorAuth/accessToken")
                accessToken = value;
            else if (key == "cursorAuth/refreshToken")
                refreshToken = value;
        }
        return new CursorAuthTokens(accessToken, refreshToken);
    }

    private static string? DecodeCursorStateValue(string? value)
    {
        if (string.IsNullOrWhiteSpace(value))
            return null;
        try
        {
            return JsonSerializer.Deserialize<string>(value) ?? value;
        }
        catch (JsonException)
        {
            return value;
        }
    }

    private async Task<HttpResponseMessage> SendCursorUsageRequestAsync(
        string accessToken,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
        request.Headers.TryAddWithoutValidation("Connect-Protocol-Version", "1");
        request.Content = new StringContent("{}", Encoding.UTF8, "application/json");
        return await _httpClient.SendAsync(request, cancellationToken);
    }

    private async Task<string?> RefreshCursorTokenAsync(
        string refreshToken,
        CancellationToken cancellationToken)
    {
        using var request = new HttpRequestMessage(
            HttpMethod.Post,
            "https://api2.cursor.sh/oauth/token");
        request.Content = new StringContent(
            JsonSerializer.Serialize(new
            {
                grant_type = "refresh_token",
                client_id = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB",
                refresh_token = refreshToken,
            }),
            Encoding.UTF8,
            "application/json");
        using var response = await _httpClient.SendAsync(request, cancellationToken);
        if (!response.IsSuccessStatusCode)
            return null;
        using var body = JsonDocument.Parse(
            await response.Content.ReadAsStringAsync(cancellationToken));
        return ReadString(body.RootElement, "access_token");
    }

    private static async Task TryPersistCursorTokenAsync(
        string databasePath,
        string accessToken,
        CancellationToken cancellationToken)
    {
        try
        {
            var builder = new SqliteConnectionStringBuilder
            {
                DataSource = databasePath,
                Mode = SqliteOpenMode.ReadWrite,
                Cache = SqliteCacheMode.Shared,
            };
            await using var connection = new SqliteConnection(builder.ToString());
            await connection.OpenAsync(cancellationToken);
            await using var command = connection.CreateCommand();
            command.CommandText = """
                UPDATE ItemTable
                SET value = $value
                WHERE key = 'cursorAuth/accessToken';
                """;
            command.Parameters.AddWithValue("$value", JsonSerializer.Serialize(accessToken));
            await command.ExecuteNonQueryAsync(cancellationToken);
        }
        catch (SqliteException)
        {
            // The refreshed token still works for this process if Cursor has its DB locked.
        }
    }

    private static void AddPercentWindow(
        ICollection<ProviderQuotaMetricViewModel> metrics,
        JsonElement root,
        string property,
        string label)
    {
        if (!TryProperty(root, property, out var window)
            || ReadDouble(window, "utilization") is not { } used)
            return;
        metrics.Add(ProviderQuotaMetricViewModel.Percent(
            label,
            used,
            ReadDate(window, "resets_at")));
    }

    private static void AddCodexWindow(
        ICollection<ProviderQuotaMetricViewModel> metrics,
        JsonElement rateLimit,
        string property,
        string label)
    {
        if (!TryProperty(rateLimit, property, out var window)
            || ReadDouble(window, "used_percent") is not { } used)
            return;
        var reset = ReadEpochSeconds(window, "reset_at")
            ?? ReadEpochSeconds(window, "resets_at");
        metrics.Add(ProviderQuotaMetricViewModel.Percent(label, used, reset));
    }

    private static bool TryProperty(JsonElement element, string name, out JsonElement value)
    {
        if (element.ValueKind == JsonValueKind.Object
            && element.TryGetProperty(name, out value))
            return true;
        value = default;
        return false;
    }

    private static bool Text(JsonElement element, string name, out string value)
    {
        value = ReadString(element, name) ?? string.Empty;
        return !string.IsNullOrWhiteSpace(value);
    }

    private static string? ReadString(JsonElement element, string name) =>
        TryProperty(element, name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static double? ReadDouble(JsonElement element, string name)
    {
        if (!TryProperty(element, name, out var value))
            return null;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number))
            return number;
        return value.ValueKind == JsonValueKind.String
            && double.TryParse(value.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out number)
                ? number
                : null;
    }

    private static DateTimeOffset? ReadDate(JsonElement element, string name) =>
        ReadString(element, name) is { } text
        && DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date)
            ? date
            : null;

    private static DateTimeOffset? ReadEpochSeconds(JsonElement element, string name) =>
        ReadDouble(element, name) is { } seconds
            ? DateTimeOffset.FromUnixTimeSeconds((long)seconds)
            : null;

    private static DateTimeOffset? ReadEpochMilliseconds(JsonElement element, string name) =>
        ReadDouble(element, name) is { } milliseconds
            ? DateTimeOffset.FromUnixTimeMilliseconds((long)milliseconds)
            : null;

    private static string? ResetText(DateTimeOffset? reset)
    {
        if (reset is null)
            return null;
        var local = reset.Value.ToLocalTime();
        var remaining = reset.Value - DateTimeOffset.UtcNow;
        return remaining.TotalHours >= 24
            ? $"{local:MM/dd HH:mm} 리셋"
            : $"{Math.Max(0, (int)remaining.TotalHours)}시간 {Math.Max(0, remaining.Minutes)}분 후 리셋";
    }

    private static string? PlanName(string? plan) =>
        string.IsNullOrWhiteSpace(plan)
            ? null
            : CultureInfo.CurrentCulture.TextInfo.ToTitleCase(plan.Replace('_', ' '));

    private static string FriendlyError(Exception exception) => exception switch
    {
        HttpRequestException => "네트워크 연결을 확인해 주세요.",
        JsonException => "사용량 응답을 해석하지 못했습니다.",
        _ => "로컬 인증 정보를 읽지 못했습니다.",
    };

    private sealed record CursorAuthTokens(
        string? AccessToken,
        string? RefreshToken);

    public void Dispose()
    {
        _cancellation.Cancel();
        _httpClient.Dispose();
        _cancellation.Dispose();
    }
}

public sealed class ProviderQuotaViewModel
{
    private ProviderQuotaViewModel(
        string provider,
        string? plan,
        string status,
        IReadOnlyList<ProviderQuotaMetricViewModel> metrics)
    {
        Provider = provider;
        Plan = plan ?? string.Empty;
        Status = status;
        Metrics = new ObservableCollection<ProviderQuotaMetricViewModel>(metrics);
    }

    public string Provider { get; }
    public string Plan { get; }
    public string Status { get; }
    public ObservableCollection<ProviderQuotaMetricViewModel> Metrics { get; }

    /// 이 프로바이더에서 가장 빡빡한 미터의 심각도 — 카드 머리의 점으로 표시한다.
    /// 카드를 열어보지 않아도 어디가 위험한지 알 수 있게 하는 신호다.
    public string Severity =>
        Metrics.Any(static metric => metric.Severity == "critical") ? "critical"
        : Metrics.Any(static metric => metric.Severity == "warning") ? "warning"
        : "normal";

    public bool HasAlert => Severity != "normal";

    public static ProviderQuotaViewModel Success(
        string provider,
        string? plan,
        IReadOnlyList<ProviderQuotaMetricViewModel> metrics) =>
        new(provider, plan, metrics.Count == 0 ? "쿼터 정보 없음" : "방금 갱신", metrics);

    public static ProviderQuotaViewModel SignedOut(string provider, string message) =>
        new(provider, null, message, []);

    public static ProviderQuotaViewModel Error(string provider, string message) =>
        new(provider, null, message, []);
}

public sealed record ProviderQuotaMetricViewModel(
    string Label,
    double UsedPercent,
    double RemainingPercent,
    string UsedText,
    string RemainingText,
    string? ResetText)
{
    /// 의미색 축 — 경고·위험일 때 막대가 프로바이더 색을 버리고 이 상태를 따른다.
    public string Severity =>
        UsedPercent >= 90 ? "critical"
        : UsedPercent >= 75 ? "warning"
        : "normal";

    public static ProviderQuotaMetricViewModel Percent(
        string label,
        double used,
        DateTimeOffset? reset)
    {
        var normalized = Math.Clamp(used, 0, 100);
        return new(
            label,
            normalized,
            100 - normalized,
            $"{normalized:0.#}% 사용",
            $"{100 - normalized:0.#}% 남음",
            ProviderQuotaServiceResetText(reset));
    }

    private static string? ProviderQuotaServiceResetText(DateTimeOffset? reset)
    {
        if (reset is null)
            return null;
        var local = reset.Value.ToLocalTime();
        var remaining = reset.Value - DateTimeOffset.UtcNow;
        return remaining.TotalHours >= 24
            ? $"{local:MM/dd HH:mm} 리셋"
            : $"{Math.Max(0, (int)remaining.TotalHours)}시간 {Math.Max(0, remaining.Minutes)}분 후 리셋";
    }
}
