using System.Reflection;
using System.Windows.Threading;
using AMon.App.ViewModels;
using AMon.Collectors;
using AMon.Core;
using AMon.LocalData;

namespace AMon.App;

public sealed class UsageCollectionService : IDisposable
{
    private static readonly TimeSpan ScanInterval = TimeSpan.FromMinutes(10);
    private readonly UsageScanCoordinator _coordinator;
    private readonly DashboardViewModel _dashboard;
    private readonly ConfigStore _configStore;
    private readonly UsageDatabase _database;
    private readonly Dispatcher _dispatcher;
    private readonly CancellationTokenSource _cancellation = new();
    private Task? _loop;

    public UsageCollectionService(
        UsageScanCoordinator coordinator,
        DashboardViewModel dashboard,
        ConfigStore configStore,
        string databasePath,
        Dispatcher dispatcher)
    {
        _coordinator = coordinator;
        _dashboard = dashboard;
        _configStore = configStore;
        _database = new UsageDatabase(databasePath);
        _dispatcher = dispatcher;
    }

    public void Start() => _loop ??= Task.Run(() => RunAsync(_cancellation.Token));

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
            var summaries = await _coordinator.ScanAsync(context, cancellationToken);
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

    public void Dispose()
    {
        _cancellation.Cancel();
    }
}
