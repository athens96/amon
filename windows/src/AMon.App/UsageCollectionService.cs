using System.Reflection;
using System.Net.Http;
using System.IO;
using System.Windows.Threading;
using AMon.App.Settings;
using AMon.App.ViewModels;
using AMon.Collectors;
using AMon.Core;
using AMon.LocalData;
using AMon.Reporting;

namespace AMon.App;

public sealed class UsageCollectionService : IDisposable
{
    private static readonly TimeSpan ScanInterval = TimeSpan.FromMinutes(10);
    private UsageScanCoordinator _coordinator;
    private readonly DashboardViewModel _dashboard;
    private readonly ConfigStore _configStore;
    private readonly UsageDatabase _database;
    private readonly string _databasePath;
    private readonly SettingsViewModel _settings;
    private readonly HttpClient _httpClient = new() { Timeout = TimeSpan.FromSeconds(20) };
    private readonly SemaphoreSlim _sendGate = new(1, 1);
    private readonly Dispatcher _dispatcher;
    private readonly CancellationTokenSource _cancellation = new();
    private Task? _loop;

    public UsageCollectionService(
        UsageScanCoordinator coordinator,
        DashboardViewModel dashboard,
        ConfigStore configStore,
        string databasePath,
        SettingsViewModel settings,
        Dispatcher dispatcher)
    {
        _coordinator = coordinator;
        _dashboard = dashboard;
        _configStore = configStore;
        _databasePath = databasePath;
        _database = new UsageDatabase(databasePath);
        _settings = settings;
        _dispatcher = dispatcher;
    }

    public void Start() => _loop ??= Task.Run(() => RunAsync(_cancellation.Token));

    public void UpdatePaths(AppSettingsState settings)
    {
        ArgumentNullException.ThrowIfNull(settings);
        Volatile.Write(
            ref _coordinator,
            new UsageScanCoordinator(UsageScannerFactory.Create(new UsageScannerPaths(
                settings.ClaudePath,
                settings.CodexPath,
                settings.OpenCodePath,
                settings.CursorPath,
                settings.GeminiPath,
                settings.QwenPath,
                settings.CopilotPath))));
    }

    public Task RefreshNowAsync() => ScanOnceAsync(_cancellation.Token);

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                await ScanOnceAsync(cancellationToken);
                await Task.Delay(ScanInterval, cancellationToken);
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
    }

    private async Task ScanOnceAsync(CancellationToken cancellationToken)
    {
        try
        {
            await _dispatcher.InvokeAsync(_dashboard.MarkScanning);
            var now = DateTimeOffset.Now;
            var timeZone = TimeZoneInfo.Local;
            var context = new UsageScanContext(now, timeZone);
            var coordinator = Volatile.Read(ref _coordinator);
            var summaries = await coordinator.ScanAsync(context, cancellationToken);
            var config = await _configStore.LoadAsync(cancellationToken);
            var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "0.0.0";
            await _database.SaveAsync(
                summaries,
                new UsageDatabaseMetadata(
                    Environment.MachineName,
                    version,
                    config.DeviceId,
                    now),
                cancellationToken);
            await _dispatcher.InvokeAsync(() =>
                _dashboard.ApplySummaries(summaries, now, timeZone));
            await UploadIfConfiguredAsync(summaries, force: false, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
        }
        catch (Exception exception)
        {
            await _dispatcher.InvokeAsync(() =>
                _dashboard.MarkFailed(exception.Message));
        }
    }

    public async Task SendNowAsync()
    {
        var now = DateTimeOffset.Now;
        var coordinator = Volatile.Read(ref _coordinator);
        var summaries = await coordinator.ScanAsync(
            new UsageScanContext(now, TimeZoneInfo.Local),
            _cancellation.Token);
        var config = await _configStore.LoadAsync(_cancellation.Token);
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "0.0.0";
        await _database.SaveAsync(
            summaries,
            new UsageDatabaseMetadata(
                Environment.MachineName,
                version,
                config.DeviceId,
                now),
            _cancellation.Token);
        await UploadIfConfiguredAsync(summaries, force: true, _cancellation.Token);
    }

    private async Task UploadIfConfiguredAsync(
        IReadOnlyList<ToolSummary> summaries,
        bool force,
        CancellationToken cancellationToken)
    {
        var config = await _configStore.LoadAsync(cancellationToken);
        if (!Uri.TryCreate(config.ServerUrl.Trim(), UriKind.Absolute, out var server)
            || string.IsNullOrWhiteSpace(config.UserKey))
        {
            await SetReportStatusAsync("서버 URL과 유저 키를 입력하면 집계 사용량을 자동 전송합니다.");
            return;
        }

        var contentSignature = ContentSignature.Compute(summaries);
        var uploadSignature = ContentSignature.ComputeUploadSignature(
            new Uri(server, "/api/v1/ai-agents/report").AbsoluteUri,
            config.UserKey,
            contentSignature);
        if (!force && string.Equals(
                config.LastUploadSignature,
                uploadSignature,
                StringComparison.Ordinal))
        {
            await SetReportStatusAsync("변경된 사용량이 없어 전송을 건너뛰었습니다.");
            return;
        }

        await _sendGate.WaitAsync(cancellationToken);
        try
        {
            var snapshotPath = Path.Combine(
                Path.GetDirectoryName(_databasePath) ?? ".",
                "usage-upload.db");
            await _database.CreateUploadSnapshotAsync(snapshotPath, cancellationToken);
            using var response = await new DashboardReporter(_httpClient).UploadAsync(
                server,
                config.UserKey,
                snapshotPath,
                cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                var message = response.StatusCode switch
                {
                    System.Net.HttpStatusCode.Unauthorized => "유저 키가 올바르지 않습니다.",
                    System.Net.HttpStatusCode.RequestEntityTooLarge => "업로드 파일이 서버 제한을 초과했습니다.",
                    _ => $"서버 전송 실패 ({(int)response.StatusCode})",
                };
                await SetReportStatusAsync(message);
                return;
            }

            config.LastUploadSignature = uploadSignature;
            await _configStore.SaveAsync(config, cancellationToken);
            await SetReportStatusAsync($"마지막 전송 {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        }
        catch (Exception exception) when (
            exception is HttpRequestException or IOException or InvalidOperationException)
        {
            await SetReportStatusAsync($"전송 실패 · {exception.Message}");
        }
        finally
        {
            _sendGate.Release();
        }
    }

    private Task SetReportStatusAsync(string status) =>
        _dispatcher.InvokeAsync(() => _settings.SetReportStatus(status)).Task;

    public void Dispose()
    {
        _cancellation.Cancel();
        _httpClient.Dispose();
        _sendGate.Dispose();
    }
}
