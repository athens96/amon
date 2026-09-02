namespace AMon.Quotas;

/// Shared user-facing copy for the failure cases every provider otherwise repeats verbatim.
public static class ProviderErrorText
{
    public const string ConnectionFailed = "네트워크 연결을 확인해 주세요.";
    public const string InvalidResponse = "사용량 응답을 해석하지 못했습니다.";
    public const string LocalCredentialsUnreadable = "로컬 인증 정보를 읽지 못했습니다.";

    public static string RequestFailed(int statusCode) => $"사용량 조회 실패 ({statusCode})";
}
