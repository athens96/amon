using AMon.Core;

namespace AMon.Collectors;

public sealed class ScannerResultBuilder
{
    private readonly string _tool;
    private readonly string _displayName;
    private readonly bool _pathExists;
    private readonly UsageScanContext _context;
    private readonly Dictionary<(DateOnly Date, string Model), DailyBucket> _daily = [];
    private readonly Dictionary<string, long> _models = new(StringComparer.OrdinalIgnoreCase);
    private TokenUsage _total;
    private decimal _totalCostUsd;

    public ScannerResultBuilder(
        string tool,
        string displayName,
        bool pathExists,
        UsageScanContext context)
    {
        _tool = tool;
        _displayName = displayName;
        _pathExists = pathExists;
        _context = context;
    }

    public void Add(
        TokenUsage usage,
        DateTimeOffset? timestamp,
        string? model,
        decimal costUsd = 0,
        bool includeModelTotal = true)
    {
        AddTotal(usage, model, costUsd, includeModelTotal);
        if (timestamp is not null)
            AddDaily(usage, timestamp.Value, model, costUsd);
    }

    public void AddTotal(
        TokenUsage usage,
        string? model,
        decimal costUsd = 0,
        bool includeModelTotal = true)
    {
        _total = _total.Add(usage);
        _totalCostUsd += costUsd;
        if (includeModelTotal)
        {
            var normalizedModel = NormalizeModel(model);
            _models[normalizedModel] = checked(
                _models.GetValueOrDefault(normalizedModel) + usage.TotalTokens);
        }
    }

    public void AddDaily(
        TokenUsage usage,
        DateTimeOffset timestamp,
        string? model,
        decimal costUsd = 0)
    {
        var date = _context.LocalDate(timestamp);
        if (date < _context.WindowStart || date > _context.Today)
            return;

        var key = (date, NormalizeModel(model));
        var previous = _daily.GetValueOrDefault(key);
        _daily[key] = new DailyBucket(
            previous.Usage.Add(usage),
            previous.CostUsd + costUsd);
    }

    public ToolSummary Build(
        long sessions,
        DateTimeOffset? lastActivity,
        string? note = null,
        bool scanSucceeded = true) =>
        new(
            _tool,
            _displayName,
            _daily
                .OrderBy(static pair => pair.Key.Date)
                .ThenBy(static pair => pair.Key.Model, StringComparer.OrdinalIgnoreCase)
                .Select(static pair => new UsageDaily(
                    pair.Key.Date,
                    pair.Key.Model,
                    pair.Value.Usage,
                    pair.Value.CostUsd))
                .ToArray(),
            sessions,
            lastActivity,
            note,
            _pathExists,
            _total,
            _totalCostUsd,
            new Dictionary<string, long>(_models, StringComparer.OrdinalIgnoreCase),
            scanSucceeded);

    private static string NormalizeModel(string? model) =>
        string.IsNullOrWhiteSpace(model) ? "unknown" : model.Trim();

    private readonly record struct DailyBucket(TokenUsage Usage, decimal CostUsd);
}
