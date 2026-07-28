namespace AMon.Activity;

public enum PetActivityStatus
{
    Idle,
    Running,
    NeedsInput,
    Ready,
    Blocked,
    Reviewing
}

public sealed record PetPresentation(
    PetActivityStatus Status,
    string Title,
    string? InputPreview,
    string? OutputPreview,
    string? Provider,
    string? SessionId,
    string? SessionIdentity,
    long? InputTokens,
    long? OutputTokens,
    long? TotalTokens,
    DateTimeOffset? UpdatedAt,
    int ActiveCount)
{
    public static PetPresentation Idle { get; } = new(
        PetActivityStatus.Idle,
        "새 작업을 기다리는 중",
        null,
        null,
        "amon",
        null,
        null,
        null,
        null,
        null,
        null,
        0);

    public string StatusText => Status switch
    {
        PetActivityStatus.Idle => "대기 중",
        PetActivityStatus.Running => "작업 중",
        PetActivityStatus.NeedsInput => "입력 필요",
        PetActivityStatus.Ready => "완료",
        PetActivityStatus.Blocked => "문제 발생",
        PetActivityStatus.Reviewing => "검토 중",
        _ => "대기 중"
    };

    public string InputText =>
        string.IsNullOrWhiteSpace(InputPreview) ? "입력 내용 없음" : InputPreview;

    public string OutputText =>
        string.IsNullOrWhiteSpace(OutputPreview)
            ? Status == PetActivityStatus.Running ? "응답 생성 중…" : "출력 내용 없음"
            : OutputPreview;

    public bool IsAttention =>
        Status is PetActivityStatus.NeedsInput or PetActivityStatus.Blocked;
}
