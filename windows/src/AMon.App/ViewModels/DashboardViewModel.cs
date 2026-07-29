using System.Collections.ObjectModel;
using System.Globalization;
using AMon.Core;

namespace AMon.App.ViewModels;

public sealed class DashboardViewModel : ObservableObject
{
    private string _statusText = "로컬 AI 도구를 확인하는 중입니다…";
    private string _totalTokens = "0";
    private string _todayTokens = "0";
    private string _todayInput = "0";
    private string _todayOutput = "0";
    private string _todayCache = "0";
    private bool _isScanning = true;

    public string Title => "AI 사용량";

    public ObservableCollection<ToolUsageCardViewModel> Tools { get; } = [];

    public ObservableCollection<ProviderQuotaViewModel> ProviderQuotas { get; } = [];

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

    // 히어로 하단 4칸 스트립 — 전체/입력/출력/캐시. macOS 히어로와 같은 열 구성.
    public string TodayInput
    {
        get => _todayInput;
        private set => SetProperty(ref _todayInput, value);
    }

    public string TodayOutput
    {
        get => _todayOutput;
        private set => SetProperty(ref _todayOutput, value);
    }

    public string TodayCache
    {
        get => _todayCache;
        private set => SetProperty(ref _todayCache, value);
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

        var todayRows = summaries
            .SelectMany(static summary => summary.Daily)
            .Where(day => day.Date == today)
            .ToArray();
        TodayTokens = Format(todayRows.Sum(static day => day.Usage.TotalTokens));
        TodayInput = Format(todayRows.Sum(static day => day.Usage.InputTokens));
        TodayOutput = Format(todayRows.Sum(static day => day.Usage.OutputTokens));
        TodayCache = Format(todayRows.Sum(static day =>
            day.Usage.CacheReadTokens + day.Usage.CacheWriteTokens));

        IsScanning = false;
        StatusText = visible.Length == 0
            ? "아직 발견된 로컬 AI 도구 로그가 없습니다."
            : $"{TimeZoneInfo.ConvertTime(scannedAt, timeZone):yyyy-MM-dd HH:mm} 기준 · 10분마다 자동 갱신";
        OnPropertyChanged(nameof(HasTools));
    }

    public void ApplyProviderQuotas(IReadOnlyList<ProviderQuotaViewModel> quotas)
    {
        ProviderQuotas.Clear();
        foreach (var quota in quotas)
            ProviderQuotas.Add(quota);
    }

    public void MarkFailed(string message)
    {
        IsScanning = false;
        StatusText = $"수집 실패 · {message}";
    }

    private static string Format(long value) =>
        value.ToString("N0", CultureInfo.CurrentCulture);
}

public sealed class ToolUsageCardViewModel : ObservableObject
{
    private bool _isExpanded;

    public ToolUsageCardViewModel(ToolSummary summary, DateOnly today)
    {
        Name = summary.DisplayName;
        Total = Format(summary.Usage.TotalTokens);

        // 오늘 행도 누적 행과 같은 4열(입력/출력/캐시/합계)을 채운다.
        var todayRows = summary.Daily.Where(day => day.Date == today).ToArray();
        Today = Format(todayRows.Sum(static day => day.Usage.TotalTokens));
        TodayInput = Format(todayRows.Sum(static day => day.Usage.InputTokens));
        TodayOutput = Format(todayRows.Sum(static day => day.Usage.OutputTokens));
        TodayCache = Format(todayRows.Sum(static day =>
            day.Usage.CacheReadTokens + day.Usage.CacheWriteTokens));

        Input = Format(summary.Usage.InputTokens);
        Output = Format(summary.Usage.OutputTokens);
        Cache = Format(checked(
            summary.Usage.CacheReadTokens + summary.Usage.CacheWriteTokens));
        Sessions = summary.Sessions.ToString("N0", CultureInfo.CurrentCulture);
        Note = summary.Note ?? string.Empty;
        LastActivity = summary.LastActivity is null
            ? "최근 활동 정보 없음"
            : $"최근 활동 {summary.LastActivity.Value.ToLocalTime():yyyy-MM-dd HH:mm}";
        Models = summary.Models is null || summary.Models.Count == 0
            ? "모델 정보 없음"
            : string.Join(
                " · ",
                summary.Models
                    .OrderByDescending(static pair => pair.Value)
                    .Take(3)
                    .Select(pair => $"{ShortModelName(pair.Key)} {Format(pair.Value)}"));
        RecentDays = new ObservableCollection<DailyUsageRowViewModel>(
            summary.Daily
                .GroupBy(static day => day.Date)
                .Select(group => new
                {
                    Date = group.Key,
                    Tokens = group.Sum(static day => day.Usage.TotalTokens),
                })
                .OrderByDescending(static day => day.Date)
                .Take(7)
                .Select(day => new DailyUsageRowViewModel(
                    day.Date.ToString("MM/dd", CultureInfo.CurrentCulture),
                    Format(day.Tokens))));
    }

    public string Name { get; }
    public string Total { get; }
    public string Today { get; }
    public string TodayInput { get; }
    public string TodayOutput { get; }
    public string TodayCache { get; }
    public string Input { get; }
    public string Output { get; }
    public string Cache { get; }
    public string Sessions { get; }
    public string Note { get; }
    public string LastActivity { get; }
    public string Models { get; }
    public ObservableCollection<DailyUsageRowViewModel> RecentDays { get; }

    /// 카드를 제자리에서 펼친다 — 모델별 누적과 최근 7일이 드러난다.
    /// Windows 는 두 열 레이아웃이라 전체/개별 모드 전환이 필요 없고,
    /// 여러 카드를 동시에 펼칠 수 있다.
    public bool IsExpanded
    {
        get => _isExpanded;
        set => SetProperty(ref _isExpanded, value);
    }

    private static string Format(long value) =>
        value.ToString("N0", CultureInfo.CurrentCulture);

    private static string ShortModelName(string model)
    {
        var slash = model.LastIndexOf('/');
        return slash >= 0 ? model[(slash + 1)..] : model;
    }

}

public sealed record DailyUsageRowViewModel(string Date, string Tokens);
