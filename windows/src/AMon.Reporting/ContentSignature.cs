using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using AMon.Core;

namespace AMon.Reporting;

public static class ContentSignature
{
    public static string Compute(IEnumerable<ToolSummary> summaries)
    {
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        foreach (var item in summaries
                     .SelectMany(summary => summary.Daily.Select(day => (summary.Tool, Day: day)))
                     .OrderBy(static item => item.Tool, StringComparer.Ordinal)
                     .ThenBy(static item => item.Day.Date)
                     .ThenBy(static item => item.Day.Model, StringComparer.Ordinal))
        {
            var usage = item.Day.Usage;
            Append(item.Tool);
            Append(item.Day.Date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture));
            Append(item.Day.Model);
            Append(usage.InputTokens.ToString(CultureInfo.InvariantCulture));
            Append(usage.OutputTokens.ToString(CultureInfo.InvariantCulture));
            Append(usage.CacheReadTokens.ToString(CultureInfo.InvariantCulture));
            Append(usage.CacheWriteTokens.ToString(CultureInfo.InvariantCulture));
            Append(usage.ReasoningTokens.ToString(CultureInfo.InvariantCulture));
            Append(item.Day.CostUsd.ToString(CultureInfo.InvariantCulture));
        }

        return Convert.ToHexStringLower(hash.GetHashAndReset());

        void Append(string value)
        {
            hash.AppendData(Encoding.UTF8.GetBytes(value));
            hash.AppendData([0]);
        }
    }

    public static string ComputeUploadSignature(string endpoint, string userKey, string contentSignature)
    {
        var value = $"{endpoint.TrimEnd('/')}\0{userKey.Trim()}\0{contentSignature}";
        return Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    }
}
