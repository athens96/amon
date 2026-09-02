using System.Windows.Threading;
using AMon.App.ViewModels;
using AMon.Quotas;

namespace AMon.App;

/// Refreshes every provider with detected local credentials every five minutes and publishes the
/// normalized snapshots to the dashboard. Providers without credentials are neither called nor
/// shown, matching the macOS client. Live quota is display-only and never persisted.
public sealed class ProviderQuotaService : IDisposable
{
    private static readonly TimeSpan RefreshInterval = TimeSpan.FromMinutes(5);
    private readonly IReadOnlyList<IQuotaProvider> _providers;
    private readonly IDisposable? _resources;
    private readonly DashboardViewModel _dashboard;
    private readonly Dispatcher _dispatcher;
    private readonly Action<IReadOnlyList<ProviderQuotaViewModel>>? _quotasUpdated;
    private readonly CancellationTokenSource _cancellation = new();
    private Task? _loop;

    public ProviderQuotaService(
        QuotaProviderSet providerSet,
        DashboardViewModel dashboard,
        Dispatcher dispatcher,
        Action<IReadOnlyList<ProviderQuotaViewModel>>? quotasUpdated = null)
        : this(providerSet.Providers, dashboard, dispatcher, quotasUpdated)
    {
        _resources = providerSet;
    }

    public ProviderQuotaService(
        IReadOnlyList<IQuotaProvider> providers,
        DashboardViewModel dashboard,
        Dispatcher dispatcher,
        Action<IReadOnlyList<ProviderQuotaViewModel>>? quotasUpdated = null)
    {
        _providers = providers;
        _dashboard = dashboard;
        _dispatcher = dispatcher;
        _quotasUpdated = quotasUpdated;
    }

    public void Start() => _loop ??= Task.Run(() => RunAsync(_cancellation.Token));

    /// One detection + refresh pass over every provider, in registry (display) order.
    public static async Task<IReadOnlyList<ProviderQuotaViewModel>> RefreshAllAsync(
        IReadOnlyList<IQuotaProvider> providers,
        CancellationToken cancellationToken)
    {
        var detected = new List<IQuotaProvider>();
        foreach (var provider in providers)
        {
            try
            {
                if (await provider.HasLocalCredentialsAsync(cancellationToken))
                    detected.Add(provider);
            }
            catch (Exception exception) when (exception is not OperationCanceledException)
            {
                // Detection is best-effort local I/O; a failing probe simply hides the card.
            }
        }

        var snapshots = await Task.WhenAll(detected.Select(provider => RefreshOneAsync(provider, cancellationToken)));
        return snapshots.Select(ProviderQuotaViewModel.FromSnapshot).ToList();
    }

    private static async Task<QuotaSnapshot> RefreshOneAsync(IQuotaProvider provider, CancellationToken cancellationToken)
    {
        try
        {
            return await provider.RefreshAsync(cancellationToken);
        }
        catch (Exception exception) when (exception is not OperationCanceledException)
        {
            return QuotaSnapshot.Failure(provider, ProviderErrorText.InvalidResponse, DateTimeOffset.UtcNow);
        }
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var quotas = await RefreshAllAsync(_providers, cancellationToken);
                await _dispatcher.InvokeAsync(
                    () =>
                    {
                        // A refresh that finishes during shutdown must not touch a disposed tray/window.
                        if (cancellationToken.IsCancellationRequested)
                            return;
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

    public void Dispose()
    {
        _cancellation.Cancel();
        _resources?.Dispose();
        _cancellation.Dispose();
    }
}
