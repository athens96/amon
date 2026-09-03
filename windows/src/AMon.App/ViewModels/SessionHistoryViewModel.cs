using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows.Input;
using AMon.Activity;

namespace AMon.App.ViewModels;

public sealed class SessionHistoryViewModel : ObservableObject
{
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web)
    {
        WriteIndented = true,
    };
    private readonly string _historyPath;
    private readonly Dictionary<string, LiveSession> _lastSessions = [];
    private string _statusText = "현재 활동을 확인하는 중입니다.";
    private SessionRowViewModel? _selectedSession;
    private string _detailStatus = string.Empty;
    private string? _claudeRoot;
    private string? _codexRoot;
    private string? _cursorRoot;
    private const int MaxTranscriptTurns = 200;

    public SessionHistoryViewModel(string historyPath)
    {
        _historyPath = historyPath;
        OpenSessionCommand = new RelayCommand<SessionRowViewModel>(
            session => _ = OpenSessionAsync(session));
        CloseSessionCommand = new RelayCommand(CloseSession);
        LoadHistory();
    }

    public ObservableCollection<SessionRowViewModel> ActiveSessions { get; } = [];
    public ObservableCollection<SessionRowViewModel> CompletedSessions { get; } = [];
    public ObservableCollection<SessionTurnViewModel> Transcript { get; } = [];
    public ObservableCollection<SessionFindingViewModel> Findings { get; } = [];
    public ObservableCollection<string> ShellCommands { get; } = [];
    public ObservableCollection<SessionFileAccessViewModel> FileAccesses { get; } = [];
    public ObservableCollection<string> Extensions { get; } = [];
    public ICommand OpenSessionCommand { get; }
    public ICommand CloseSessionCommand { get; }

    public SessionRowViewModel? SelectedSession
    {
        get => _selectedSession;
        private set
        {
            if (SetProperty(ref _selectedSession, value))
                OnPropertyChanged(nameof(IsDetailVisible));
        }
    }

    public bool IsDetailVisible => SelectedSession is not null;

    public string DetailStatus
    {
        get => _detailStatus;
        private set => SetProperty(ref _detailStatus, value);
    }

    public string AnalysisSummary { get; private set; } = string.Empty;
    public string AuditSummary { get; private set; } = string.Empty;

    public string StatusText
    {
        get => _statusText;
        private set => SetProperty(ref _statusText, value);
    }

    public bool HasActiveSessions => ActiveSessions.Count > 0;
    public bool HasCompletedSessions => CompletedSessions.Count > 0;

    public void ConfigureLogRoots(string? claudeRoot, string? codexRoot, string? cursorRoot = null)
    {
        _claudeRoot = claudeRoot;
        _codexRoot = codexRoot;
        _cursorRoot = cursorRoot;
    }

    public void ApplySessions(IReadOnlyList<LiveSession> sessions)
    {
        var current = sessions.ToDictionary(static session => session.Identity);
        foreach (var previous in _lastSessions.Values)
        {
            if (!current.ContainsKey(previous.Identity))
                AddCompleted(previous);
        }

        _lastSessions.Clear();
        foreach (var session in sessions)
            _lastSessions[session.Identity] = session;

        // A session filed as completed by an earlier scan that has since resumed (a Cursor composer
        // typed into again) must not be listed twice.
        foreach (var resumed in CompletedSessions.Where(row => current.ContainsKey(row.Identity)).ToArray())
            CompletedSessions.Remove(resumed);

        ActiveSessions.Clear();
        foreach (var session in sessions.OrderByDescending(static session => session.UpdatedAt))
            ActiveSessions.Add(SessionRowViewModel.FromLive(session));

        StatusText = sessions.Count == 0
            ? "현재 진행 중인 AI 세션이 없습니다."
            : $"{sessions.Count:N0}개의 세션이 진행 중입니다.";
        NotifyCollectionsChanged();
    }

    public void ApplyScannedHistory(IReadOnlyList<SessionRecord> records)
    {
        var existing = CompletedSessions.ToDictionary(static item => item.Identity);
        foreach (var record in records)
            existing[record.Identity] = SessionRowViewModel.FromRecord(record);
        CompletedSessions.Clear();
        foreach (var row in existing.Values
                     .OrderByDescending(static item => item.Record.EndedAt)
                     .Take(200))
            CompletedSessions.Add(row);
        SaveHistory();
        NotifyCollectionsChanged();
    }

    private async Task OpenSessionAsync(SessionRowViewModel session)
    {
        SelectedSession = session;
        Transcript.Clear();
        Findings.Clear();
        ShellCommands.Clear();
        FileAccesses.Clear();
        Extensions.Clear();
        DetailStatus = "원본 세션 로그를 분석하는 중입니다…";
        var result = await Task.Run(() =>
        {
            var sourcePath = session.Record.SourcePath
                ?? SessionLogHistoryService.FindSessionLogPath(
                    session.Record.Provider,
                    session.Record.SessionId,
                    _claudeRoot,
                    _codexRoot,
                    _cursorRoot);
            if (string.IsNullOrWhiteSpace(sourcePath))
                return (Turns: (IReadOnlyList<SessionTurnViewModel>)[], Audit: SessionAuditViewModel.Empty);
            return (
                Turns: SessionTranscriptParser.Parse(
                    sourcePath,
                    session.Record.Provider,
                    session.Record.SessionId),
                Audit: SessionTranscriptParser.Audit(
                    sourcePath,
                    session.Record.Provider,
                    session.Record.SessionId));
        });
        var turns = result.Turns;
        // Markdown rendering builds several elements per turn in a non-virtualized list; the newest
        // turns are what the detail view is for, so very long sessions are capped.
        foreach (var turn in turns.Count <= MaxTranscriptTurns ? turns : turns.Skip(turns.Count - MaxTranscriptTurns))
            Transcript.Add(turn);
        foreach (var finding in result.Audit.Findings)
            Findings.Add(finding);
        foreach (var command in result.Audit.ShellCommands.Take(50))
            ShellCommands.Add(command);
        foreach (var file in result.Audit.FileAccesses.Take(50))
            FileAccesses.Add(file);
        foreach (var extension in result.Audit.Extensions)
            Extensions.Add(extension);
        var userTurns = turns.Count(static turn => turn.Role == "사용자");
        var assistantTurns = turns.Count(static turn => turn.Role == "AI");
        var tokens = turns
            .Where(static turn => turn.Usage is not null)
            .Sum(static turn => turn.Usage!.TotalTokens);
        AnalysisSummary =
            $"사용자 요청 {userTurns:N0}회 · AI 응답 {assistantTurns:N0}회 · 분석된 토큰 {tokens:N0}";
        OnPropertyChanged(nameof(AnalysisSummary));
        AuditSummary = result.Audit.Summary;
        OnPropertyChanged(nameof(AuditSummary));
        DetailStatus = turns.Count == 0
            ? "원본 로그를 찾지 못했거나 표시할 대화가 없습니다."
            : turns.Count <= MaxTranscriptTurns
                ? $"{turns.Count:N0}개의 대화 항목"
                : $"{turns.Count:N0}개의 대화 항목 중 최근 {MaxTranscriptTurns:N0}개";
    }

    private void CloseSession()
    {
        SelectedSession = null;
        Transcript.Clear();
        Findings.Clear();
        ShellCommands.Clear();
        FileAccesses.Clear();
        Extensions.Clear();
        DetailStatus = string.Empty;
        AnalysisSummary = string.Empty;
        OnPropertyChanged(nameof(AnalysisSummary));
        AuditSummary = string.Empty;
        OnPropertyChanged(nameof(AuditSummary));
    }

    private void AddCompleted(LiveSession session)
    {
        var record = SessionRecord.FromLive(session);
        var existing = CompletedSessions.FirstOrDefault(item => item.Identity == record.Identity);
        if (existing is not null)
            CompletedSessions.Remove(existing);
        CompletedSessions.Insert(0, SessionRowViewModel.FromRecord(record));
        while (CompletedSessions.Count > 200)
            CompletedSessions.RemoveAt(CompletedSessions.Count - 1);
        SaveHistory();
    }

    private void LoadHistory()
    {
        try
        {
            if (!File.Exists(_historyPath))
                return;
            var records = JsonSerializer.Deserialize<List<SessionRecord>>(
                File.ReadAllText(_historyPath), JsonOptions) ?? [];
            foreach (var record in records.OrderByDescending(static item => item.EndedAt))
                CompletedSessions.Add(SessionRowViewModel.FromRecord(record));
            NotifyCollectionsChanged();
        }
        catch (IOException) { }
        catch (JsonException) { }
    }

    private void SaveHistory()
    {
        try
        {
            var directory = Path.GetDirectoryName(_historyPath);
            if (!string.IsNullOrEmpty(directory))
                Directory.CreateDirectory(directory);
            var records = CompletedSessions
                .Select(static item => item.Record)
                .ToArray();
            File.WriteAllText(_historyPath, JsonSerializer.Serialize(records, JsonOptions));
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private void NotifyCollectionsChanged()
    {
        OnPropertyChanged(nameof(HasActiveSessions));
        OnPropertyChanged(nameof(HasCompletedSessions));
    }
}

public sealed record SessionRecord(
    string Provider,
    string SessionId,
    string ProjectLabel,
    string? GitBranch,
    string Status,
    string? CurrentTask,
    string? LastResult,
    string? Model,
    long InputTokens,
    long OutputTokens,
    long CacheTokens,
    long TotalTokens,
    int AgentCount,
    DateTimeOffset StartedAt,
    DateTimeOffset EndedAt,
    string? SourcePath = null)
{
    public string Identity => $"{Provider}:{SessionId}";

    public static SessionRecord FromLive(LiveSession session) => new(
        session.Provider,
        session.SessionId,
        session.ProjectLabel,
        session.GitBranch,
        session.Status,
        session.CurrentTask,
        session.LastResult,
        session.Model,
        session.Tokens.InputTokens ?? 0,
        session.Tokens.OutputTokens ?? 0,
        checked((session.Tokens.CacheReadTokens ?? 0) + (session.Tokens.CacheWriteTokens ?? 0)),
        session.Tokens.TotalTokens ?? 0,
        session.Agents.Count,
        session.StartedAt,
        session.UpdatedAt);
}

public sealed class SessionRowViewModel
{
    private SessionRowViewModel(SessionRecord record, bool isLive)
    {
        Record = record;
        Identity = record.Identity;
        Provider = ProviderName(record.Provider);
        Project = string.IsNullOrWhiteSpace(record.GitBranch)
            ? record.ProjectLabel
            : $"{record.ProjectLabel} · {record.GitBranch}";
        Status = isLive ? $"진행 중 · {record.Status}" : "종료됨";
        Task = record.CurrentTask ?? record.LastResult ?? "작업 정보 없음";
        Model = string.IsNullOrWhiteSpace(record.Model) ? "모델 정보 없음" : record.Model;
        Tokens = Format(record.TotalTokens);
        Input = Format(record.InputTokens);
        Output = Format(record.OutputTokens);
        Cache = Format(record.CacheTokens);
        Agents = record.AgentCount > 0 ? $"에이전트 {record.AgentCount:N0}" : string.Empty;
        Time = isLive
            ? $"시작 {record.StartedAt.ToLocalTime():HH:mm} · 갱신 {record.EndedAt.ToLocalTime():HH:mm:ss}"
            : $"{record.EndedAt.ToLocalTime():yyyy-MM-dd HH:mm} · {Duration(record)}";
    }

    public SessionRecord Record { get; }
    public string Identity { get; }
    public string Provider { get; }
    public string Project { get; }
    public string Status { get; }
    public string Task { get; }
    public string Model { get; }
    public string Tokens { get; }
    public string Input { get; }
    public string Output { get; }
    public string Cache { get; }
    public string Agents { get; }
    public string Time { get; }

    public static SessionRowViewModel FromLive(LiveSession session) =>
        new(SessionRecord.FromLive(session), true);

    public static SessionRowViewModel FromRecord(SessionRecord record) =>
        new(record, false);

    private static string Format(long value) =>
        value.ToString("N0", CultureInfo.CurrentCulture);

    private static string Duration(SessionRecord record)
    {
        var duration = record.EndedAt - record.StartedAt;
        if (duration.TotalHours >= 1)
            return $"{(int)duration.TotalHours}시간 {duration.Minutes}분";
        return $"{Math.Max(0, duration.Minutes)}분";
    }

    private static string ProviderName(string provider) => provider.ToLowerInvariant() switch
    {
        "claude" => "Claude Code",
        "codex" => "Codex",
        "cursor" => "Cursor",
        _ => provider,
    };
}
