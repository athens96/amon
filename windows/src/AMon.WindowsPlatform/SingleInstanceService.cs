using System.Threading;

namespace AMon.WindowsPlatform;

public interface ISingleInstanceService : IDisposable
{
    bool IsPrimaryInstance { get; }

    event EventHandler? ActivationRequested;
}

public sealed class SingleInstanceService : ISingleInstanceService
{
    // These legacy names prevent old and new releases from running side by side.
    private const string MutexName = @"Local\A-mon.Wpf.Singleton";
    private const string ActivationEventName = @"Local\A-mon.Wpf.Activate";

    private readonly Mutex _mutex;
    private readonly EventWaitHandle? _activationEvent;
    private readonly RegisteredWaitHandle? _activationRegistration;
    private bool _disposed;

    public SingleInstanceService()
    {
        _mutex = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
        IsPrimaryInstance = createdNew;

        if (IsPrimaryInstance)
        {
            _activationEvent = new EventWaitHandle(
                initialState: false,
                EventResetMode.AutoReset,
                ActivationEventName);
            _activationRegistration = ThreadPool.RegisterWaitForSingleObject(
                _activationEvent,
                static (state, _) => ((SingleInstanceService)state!).OnActivationRequested(),
                this,
                Timeout.Infinite,
                executeOnlyOnce: false);
            return;
        }

        try
        {
            using var existingEvent = EventWaitHandle.OpenExisting(ActivationEventName);
            existingEvent.Set();
        }
        catch (WaitHandleCannotBeOpenedException)
        {
            // The primary process may still be starting. Exiting remains the safe behavior.
        }
    }

    public bool IsPrimaryInstance { get; }

    public event EventHandler? ActivationRequested;

    private void OnActivationRequested()
    {
        if (!_disposed)
        {
            ActivationRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _activationRegistration?.Unregister(null);
        _activationEvent?.Dispose();

        if (IsPrimaryInstance)
        {
            try
            {
                _mutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // The runtime already released ownership during shutdown.
            }
        }

        _mutex.Dispose();
    }
}
