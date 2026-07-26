using System.Windows.Threading;
using AMon.Activity;
using AMon.App.ViewModels;

namespace AMon.App;

public sealed class PetActivityConnector : IDisposable
{
    private readonly LiveActivityService _service;
    private readonly PetViewModel _viewModel;
    private readonly Dispatcher _dispatcher;
    private readonly bool _localActivityEnabled;
    private readonly bool _showsCurrentTask;
    private readonly CancellationTokenSource _cancellation = new();
    private Task? _loop;
    private long _generation;
    private bool _disposed;

    public PetActivityConnector(
        LiveActivityService service,
        PetViewModel viewModel,
        Dispatcher dispatcher,
        bool localActivityEnabled,
        bool showsCurrentTask = true)
    {
        _service = service ?? throw new ArgumentNullException(nameof(service));
        _viewModel = viewModel ?? throw new ArgumentNullException(nameof(viewModel));
        _dispatcher = dispatcher ?? throw new ArgumentNullException(nameof(dispatcher));
        _localActivityEnabled = localActivityEnabled;
        _showsCurrentTask = showsCurrentTask;
    }

    public void Start()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (!_localActivityEnabled)
            return;
        if (_loop is not null)
            return;
        _service.SessionsChanged += OnSessionsChanged;
        _loop = Task.Run(() => _service.RunAsync(_cancellation.Token));
    }

    private void OnSessionsChanged(
        object? sender,
        IReadOnlyList<LiveSession> sessions)
    {
        if (_disposed || _dispatcher.HasShutdownStarted)
            return;

        var generation = Interlocked.Increment(ref _generation);
        var presentations = PetStateAdapter.CreatePresentations(
            sessions,
            _localActivityEnabled,
            _showsCurrentTask);
        _ = _dispatcher.InvokeAsync(
            () =>
            {
                if (!_disposed && generation == Volatile.Read(ref _generation))
                    _viewModel.UpdatePresentations(presentations);
            },
            DispatcherPriority.DataBind);
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _service.SessionsChanged -= OnSessionsChanged;
        _cancellation.Cancel();
        if (_loop is null)
        {
            _cancellation.Dispose();
            return;
        }
        _ = _loop.ContinueWith(
            static (task, state) =>
            {
                _ = task.Exception;
                ((CancellationTokenSource)state!).Dispose();
            },
            _cancellation,
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }
}
