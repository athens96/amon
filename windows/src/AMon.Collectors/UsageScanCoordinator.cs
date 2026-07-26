using AMon.Core;

namespace AMon.Collectors;

public sealed class UsageScanCoordinator
{
    private readonly IReadOnlyList<IUsageScanner> _scanners;

    public UsageScanCoordinator(IEnumerable<IUsageScanner> scanners) =>
        _scanners = scanners.ToArray();

    public async Task<IReadOnlyList<ToolSummary>> ScanAsync(
        UsageScanContext context,
        CancellationToken cancellationToken = default)
    {
        var tasks = _scanners.Select(scanner =>
            ScanSafelyAsync(scanner, context, cancellationToken));
        return await Task.WhenAll(tasks);
    }

    private static async Task<ToolSummary> ScanSafelyAsync(
        IUsageScanner scanner,
        UsageScanContext context,
        CancellationToken cancellationToken)
    {
        try
        {
            return await scanner.ScanAsync(context, cancellationToken);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception exception)
        {
            return new ToolSummary(
                scanner.Tool,
                scanner.Tool,
                [],
                Note: $"스캔 실패: {exception.Message}",
                ScanSucceeded: false);
        }
    }
}
