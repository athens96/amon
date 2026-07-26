using System.Windows.Threading;
using AMon.Activity;
using AMon.App.ViewModels;

namespace AMon.App;

public sealed class SessionActivityConnector : IDisposable
{
    private readonly LiveActivityService _service;
    private readonly SessionHistoryViewModel _viewModel;
    private readonly Dispatcher _dispatcher;
    private bool _disposed;

    public SessionActivityConnector(
        LiveActivityService service,
        SessionHistoryViewModel viewModel,
        Dispatcher dispatcher)
    {
        _service = service;
        _viewModel = viewModel;
        _dispatcher = dispatcher;
        _service.SessionsChanged += OnSessionsChanged;
    }

    private void OnSessionsChanged(object? sender, IReadOnlyList<LiveSession> sessions)
    {
        if (_disposed || _dispatcher.HasShutdownStarted)
            return;
        _ = _dispatcher.InvokeAsync(
            () => _viewModel.ApplySessions(sessions),
            DispatcherPriority.DataBind);
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        _service.SessionsChanged -= OnSessionsChanged;
    }
}
