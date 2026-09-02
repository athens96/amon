namespace AMon.Quotas.Providers.Devin;

/// Devin's quota lives behind the Codeium seat-management Connect RPC; the API key travels in the
/// request body's `metadata` object, not in a header.
public sealed class DevinUsageClient(IQuotaHttp http)
{
    public const string CloudService = "exa.seat_management_pb.SeatManagementService";
    public const string CloudCompatVersion = "1.108.2";

    public Task<QuotaHttpResponse> FetchUserStatusAsync(DevinAuth auth, string apiServerUrl, CancellationToken cancellationToken) =>
        http.SendAsync(
            QuotaHttpRequest.PostJson(
                $"{apiServerUrl}/{CloudService}/GetUserStatus",
                QuotaJson.Serialize(new
                {
                    metadata = new
                    {
                        apiKey = auth.ApiKey,
                        ideName = "devin",
                        ideVersion = CloudCompatVersion,
                        extensionName = "devin",
                        extensionVersion = CloudCompatVersion,
                        locale = "en",
                    },
                }),
                new Dictionary<string, string>
                {
                    ["Connect-Protocol-Version"] = "1",
                },
                TimeSpan.FromSeconds(15)),
            cancellationToken);
}
