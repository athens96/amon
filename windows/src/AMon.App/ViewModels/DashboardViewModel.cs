using System.Collections.ObjectModel;
using System.Globalization;
using AMon.Core;

namespace AMon.App.ViewModels;

public sealed class DashboardViewModel : ObservableObject
{
    private string _statusText = "로컬 AI 도구를 확인하는 중입니다…";
    private string _totalTokens = "0";
    private string _todayTokens = "0";
    private bool _isScanning = true;

    public string Title => "AI 사용량";

    public ObservableCollection<ToolUsageCardViewModel> Tools { get; } = [];

    public string StatusText
    {
        get => _statusText;
        private set => SetProperty(ref _statusText, value);
    }

    public string TotalTokens
    {
        get => _totalTokens;
        private set => SetProperty(ref _totalTokens, value);
    }

    public string TodayTokens
    {
        get => _todayTokens;
        private set => SetProperty(ref _todayTokens, value);
    }

    public bool IsScanning
    {
        get => _isScanning;
        private set => SetProperty(ref _isScanning, value);
    }

    public bool HasTools => Tools.Count > 0;

    public void MarkScanning()
    {
        IsScanning = true;
        StatusText = "로컬 AI 도구를 확인하는 중입니다…";
    }

    public void ApplySummaries(
        IReadOnlyList<ToolSummary> summaries,
        DateTimeOffset scannedAt,
        TimeZoneInfo timeZone)
    {
        var today = DateOnly.FromDateTime(
            TimeZoneInfo.ConvertTime(scannedAt, timeZone).DateTime);
        var visible = summaries
            .Where(static summary =>
                summary.PathExists ||
                summary.Usage.TotalTokens > 0 ||
                !summary.ScanSucceeded)
            .OrderByDescending(static summary => summary.Usage.TotalTokens)
            .ThenBy(static summary => summary.DisplayName, StringComparer.CurrentCultureIgnoreCase)
            .Select(summary => new ToolUsageCardViewModel(summary, today))
            .ToArray();

        Tools.Clear();
        foreach (var tool in visible)
            Tools.Add(tool);

        TotalTokens = Format(summaries.Sum(static summary => summary.Usage.TotalTokens));
        TodayTokens = Format(summaries
            .SelectMany(static summary => summary.Daily)
            .Where(day => day.Date == today)
            .Sum(static day => day.Usage.TotalTokens));
        IsScanning = false;
        StatusText = visible.Length == 0
            ? "아직 발견된 로컬 AI 도구 로그가 없습니다."
            : $"{TimeZoneInfo.ConvertTime(scannedAt, timeZone):yyyy-MM-dd HH:mm} 기준 · 10분마다 자동 갱신";
        OnPropertyChanged(nameof(HasTools));
    }

    public void MarkFailed(string message)
    {
        IsScanning = false;
        StatusText = $"수집 실패 · {message}";
    }

    private static string Format(long value) =>
        value.ToString("N0", CultureInfo.CurrentCulture);
}

public sealed class ToolUsageCardViewModel
{
    public ToolUsageCardViewModel(ToolSummary summary, DateOnly today)
    {
        Name = summary.DisplayName;
        Total = Format(summary.Usage.TotalTokens);
        Today = Format(summary.Daily
            .Where(day => day.Date == today)
            .Sum(static day => day.Usage.TotalTokens));
        Input = Format(summary.Usage.InputTokens);
        Output = Format(summary.Usage.OutputTokens);
        Cache = Format(checked(
            summary.Usage.CacheReadTokens + summary.Usage.CacheWriteTokens));
        Sessions = summary.Sessions.ToString("N0", CultureInfo.CurrentCulture);
        Note = summary.Note ?? string.Empty;
    }

    public string Name { get; }
    public string Total { get; }
    public string Today { get; }
    public string Input { get; }
    public string Output { get; }
    public string Cache { get; }
    public string Sessions { get; }
    public string Note { get; }

    private static string Format(long value) =>
        value.ToString("N0", CultureInfo.CurrentCulture);
}
