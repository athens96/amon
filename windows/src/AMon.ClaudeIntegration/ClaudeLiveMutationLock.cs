using System.Security.Cryptography;
using System.Text;

namespace AMon.ClaudeIntegration;

internal sealed class ClaudeLiveMutationLock : IDisposable
{
    private readonly Mutex mutex;
    private bool ownsMutex;

    private ClaudeLiveMutationLock(Mutex mutex, bool ownsMutex)
    {
        this.mutex = mutex;
        this.ownsMutex = ownsMutex;
    }

    public static ClaudeLiveMutationLock? TryAcquire(
        string liveDirectory,
        TimeSpan timeout)
    {
        var canonicalPath = Path.GetFullPath(liveDirectory).ToUpperInvariant();
        var digest = Convert.ToHexString(
            SHA256.HashData(Encoding.UTF8.GetBytes(canonicalPath)))[..24];
        var mutex = new Mutex(false, $"AMon.ClaudeLiveMutation.{digest}");
        try
        {
            try
            {
                if (!mutex.WaitOne(timeout))
                {
                    mutex.Dispose();
                    return null;
                }
            }
            catch (AbandonedMutexException)
            {
                // The previous writer terminated. We now own the mutex.
            }

            return new ClaudeLiveMutationLock(mutex, ownsMutex: true);
        }
        catch
        {
            mutex.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        if (ownsMutex)
        {
            ownsMutex = false;
            mutex.ReleaseMutex();
        }
        mutex.Dispose();
    }
}
