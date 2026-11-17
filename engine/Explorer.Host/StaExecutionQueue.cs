using System.Collections.Concurrent;

namespace SafeJunkCleaner.Explorer.Host;

// All external execution work is serialized on one bounded STA thread.
// Queueing is not approval; the execution library still validates and claims its seal.
internal sealed class StaExecutionQueue : IDisposable
{
    private readonly BlockingCollection<IWork> queue = new(4);
    private readonly Thread thread;
    private int stopping;
    internal StaExecutionQueue()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("STA execution requires Windows");
        thread = new Thread(Run) { IsBackground = true, Name = "Explorer approved execution STA" };
        thread.SetApartmentState(ApartmentState.STA); thread.Start();
    }
    internal Task<T> Enqueue<T>(Func<CancellationToken, T> action, CancellationToken token)
    {
        if (Volatile.Read(ref stopping) != 0) throw new InvalidOperationException("ExecutionQueueStopping");
        var work = new Work<T>(action, token);
        try { if (!queue.TryAdd(work)) throw new InvalidOperationException("ExecutionQueueFull"); }
        catch (InvalidOperationException) { throw new InvalidOperationException("ExecutionQueueUnavailable"); }
        return work.Completion;
    }
    private void Run()
    {
        foreach (var work in queue.GetConsumingEnumerable()) work.Execute();
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref stopping, 1) != 0) return;
        queue.CompleteAdding();
        // The coordinator cancels owned operations before disposal. Never interrupt a
        // recycle call mid-side-effect or automatically retry its unknown outcome.
        thread.Join(); queue.Dispose();
    }
    private interface IWork { void Execute(); }
    private sealed class Work<T>(Func<CancellationToken, T> action, CancellationToken token) : IWork
    {
        private readonly TaskCompletionSource<T> result = new(TaskCreationOptions.RunContinuationsAsynchronously);
        internal Task<T> Completion => result.Task;
        public void Execute()
        {
            try { token.ThrowIfCancellationRequested(); result.TrySetResult(action(token)); }
            catch (OperationCanceledException) { result.TrySetCanceled(token); }
            catch (Exception ex) { result.TrySetException(ex); }
        }
    }
}
