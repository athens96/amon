using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace AMon.Quotas.Providers.Antigravity;

/// One model's quota as returned by any source (LS, Cloud Code models, Cloud Code buckets),
/// normalized before pooling. `RemainingFraction` is 0…1 (1 = full); a model with no quota info is
/// treated as depleted (0 remaining).
public sealed record AntigravityModelConfig(
    string Label,
    string? ModelId,
    double RemainingFraction,
    DateTimeOffset? ResetTime);

/// LS `GetUserStatus`: the plan name plus the per-model configs on the same payload.
public sealed record AntigravityUserStatus(string? Plan, IReadOnlyList<AntigravityModelConfig> Configs);

/// Turns Antigravity's quota responses into the app's metric vocabulary.
///
/// The authoritative source is the `RetrieveUserQuotaSummary` RPC (`ParseQuotaSummary`): two pools
/// (Gemini, shown as "Session"/"Weekly"; Claude = every non-Gemini model incl. GPT-OSS), each with a
/// rolling 5-hour and a weekly window — up to four meters. Builds without that RPC fall back to the
/// legacy per-model endpoints, whose fine-grained models collapse into the two 5h pool meters
/// ("Session", "Claude"), each keeping the worst (lowest) remaining fraction in its pool; the legacy
/// data is 5h-only, so the weekly meters read "No data" there.
public static partial class AntigravityUsageMapper
{
    /// Internal/duplicate model IDs that should never surface as a meter. Matched against the model
    /// ID (LS `modelOrAlias.model`, Cloud Code `model`/key); the Cloud Code path also drops
    /// `isInternal`.
    public static readonly IReadOnlySet<string> ModelBlacklist = new HashSet<string>(StringComparer.Ordinal)
    {
        "MODEL_CHAT_20706", "MODEL_CHAT_23310",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH", "MODEL_GOOGLE_GEMINI_2_5_FLASH_THINKING",
        "MODEL_GOOGLE_GEMINI_2_5_FLASH_LITE", "MODEL_GOOGLE_GEMINI_2_5_PRO",
        "MODEL_PLACEHOLDER_M19", "MODEL_PLACEHOLDER_M9", "MODEL_PLACEHOLDER_M12",
    };

    /// The four pool buckets `RetrieveUserQuotaSummary` reports, matched by **exact `bucketId` only**
    /// — a future bucket (e.g. `gemini-image-5h`) must never silently join a pool, and pool identity
    /// is never inferred from `displayName`/`window`.
    public static readonly IReadOnlyList<(string BucketId, string Label, long PeriodMs)> SummaryBuckets =
    [
        ("gemini-5h", AntigravityMetric.SessionLabel, QuotaPeriod.SessionMs),
        ("gemini-weekly", AntigravityMetric.WeeklyLabel, QuotaPeriod.WeekMs),
        ("3p-5h", AntigravityMetric.ClaudeLabel, QuotaPeriod.SessionMs),
        ("3p-weekly", AntigravityMetric.ClaudeWeeklyLabel, QuotaPeriod.WeekMs),
    ];

    // MARK: - Quota summary (the authoritative source)

    /// `RetrieveUserQuotaSummary` → up to four pool meters, ordered Session, Weekly, Claude, Claude
    /// Weekly. Accepts both the LS envelope (`{"response": {"groups": …}}`) and the bare remote
    /// payload (`{"groups": …}`).
    ///
    /// Null means "not a summary" (undecodable body / no `groups` anywhere) and the caller may fall
    /// back to the legacy endpoints. A non-null result — even an empty one — is authoritative: the
    /// legacy path fabricates "fully used" from missing quota info, so a parsed summary must never
    /// fall through to it. Buckets decode leniently (one malformed bucket never voids the envelope);
    /// a bucket with a missing/unusable `remainingFraction` drops its line (the row reads "No data")
    /// rather than fabricating 0% or 100%.
    public static IReadOnlyList<QuotaMetricLine>? ParseQuotaSummary(string body)
    {
        using var document = QuotaJson.ParseObject(body);
        if (document is null)
            return null;
        var root = document.RootElement;
        var groups = QuotaJson.ObjectProperty(root, "response") is { } response
            ? QuotaJson.ArrayProperty(response, "groups") ?? QuotaJson.ArrayProperty(root, "groups")
            : QuotaJson.ArrayProperty(root, "groups");
        if (groups is not { } groupList)
            return null;

        var pooled = new Dictionary<string, (double Fraction, DateTimeOffset? ResetTime)>(StringComparer.Ordinal);
        foreach (var group in groupList.EnumerateArray())
        {
            if (QuotaJson.ArrayProperty(group, "buckets") is not { } buckets)
                continue;
            foreach (var bucket in buckets.EnumerateArray())
            {
                if (QuotaJson.String(bucket, "bucketId") is not { } id
                    || !SummaryBuckets.Any(spec => spec.BucketId == id))
                {
                    continue;
                }
                if (pooled.ContainsKey(id))
                    continue; // duplicate bucket id — first one wins
                if (QuotaJson.Number(bucket, "remainingFraction") is not { } fraction)
                    continue; // no usable fraction — drop the line rather than fabricate one
                pooled[id] = (fraction, QuotaTime.ParseIso8601(QuotaJson.String(bucket, "resetTime")));
            }
        }

        var lines = new List<QuotaMetricLine>();
        foreach (var spec in SummaryBuckets)
        {
            if (pooled.TryGetValue(spec.BucketId, out var entry))
                lines.Add(Line(spec.Label, entry.Fraction, entry.ResetTime, spec.PeriodMs));
        }
        return lines;
    }

    // MARK: - Response parsing (legacy per-model endpoints)

    /// LS `GetUserStatus` → plan name + model configs. Null when the body has no `userStatus`.
    public static AntigravityUserStatus? ParseUserStatus(string body)
    {
        using var document = QuotaJson.ParseObject(body);
        if (document is null || QuotaJson.ObjectProperty(document.RootElement, "userStatus") is not { } status)
            return null;
        // Prefer Google's own `userTier` over the Windsurf-inherited `planInfo.planName` (which reads
        // "Pro" for every paid tier).
        var tierName = QuotaJson.ObjectProperty(status, "userTier") is { } tier ? QuotaJson.String(tier, "name") : null;
        var planName = QuotaJson.ObjectProperty(status, "planStatus") is { } planStatus
            && QuotaJson.ObjectProperty(planStatus, "planInfo") is { } planInfo
            ? QuotaJson.String(planInfo, "planName")
            : null;
        var configs = QuotaJson.ObjectProperty(status, "cascadeModelConfigData") is { } cascade
            ? ConfigsFromLs(QuotaJson.ArrayProperty(cascade, "clientModelConfigs"))
            : [];
        return new AntigravityUserStatus(FormatPlan(tierName ?? planName), configs);
    }

    /// LS `GetCommandModelConfigs` fallback → model configs only (no plan). Null when absent.
    public static IReadOnlyList<AntigravityModelConfig>? ParseCommandModelConfigs(string body)
    {
        using var document = QuotaJson.ParseObject(body);
        if (document is null || QuotaJson.ArrayProperty(document.RootElement, "clientModelConfigs") is not { } configs)
            return null;
        return ConfigsFromLs(configs);
    }

    /// Cloud Code `fetchAvailableModels` → model configs (drops `isInternal`, empty-label models).
    public static IReadOnlyList<AntigravityModelConfig> ParseCloudCodeModels(string body)
    {
        using var document = QuotaJson.ParseObject(body);
        if (document is null || QuotaJson.ObjectProperty(document.RootElement, "models") is not { } models)
            return [];
        var configs = new List<AntigravityModelConfig>();
        foreach (var model in models.EnumerateObject())
        {
            if (model.Value.ValueKind != JsonValueKind.Object || QuotaJson.Bool(model.Value, "isInternal") == true)
                continue;
            var label = QuotaJson.String(model.Value, "displayName") ?? QuotaJson.String(model.Value, "label");
            if (Config(label, QuotaJson.String(model.Value, "model") ?? model.Name, QuotaJson.ObjectProperty(model.Value, "quotaInfo")) is { } config)
                configs.Add(config);
        }
        return configs;
    }

    /// Cloud Code `retrieveUserQuota` → buckets keyed by raw model id (e.g. `gemini-3-pro-preview`).
    public static IReadOnlyList<AntigravityModelConfig> ParseQuotaBuckets(string body)
    {
        using var document = QuotaJson.ParseObject(body);
        if (document is null || QuotaJson.ArrayProperty(document.RootElement, "buckets") is not { } buckets)
            return [];
        var configs = new List<AntigravityModelConfig>();
        foreach (var bucket in buckets.EnumerateArray())
        {
            if (QuotaJson.String(bucket, "modelId") is not { } id)
                continue;
            configs.Add(new AntigravityModelConfig(
                id,
                id,
                QuotaJson.Number(bucket, "remainingFraction") ?? 0,
                QuotaTime.ParseIso8601(QuotaJson.String(bucket, "resetTime"))));
        }
        return configs;
    }

    /// Cloud Code `loadCodeAssist` → plan name (paid tier preferred over current tier).
    public static string? ParseLoadCodeAssistPlan(string body)
    {
        using var document = QuotaJson.ParseObject(body);
        if (document is null)
            return null;
        var paid = QuotaJson.ObjectProperty(document.RootElement, "paidTier") is { } paidTier
            ? QuotaJson.String(paidTier, "name")
            : null;
        var current = QuotaJson.ObjectProperty(document.RootElement, "currentTier") is { } currentTier
            ? QuotaJson.String(currentTier, "name")
            : null;
        return FormatPlan(paid ?? current);
    }

    public static string? ParseProject(string body)
    {
        using var document = QuotaJson.ParseObject(body);
        return document is null ? null : QuotaJson.String(document.RootElement, "cloudaicompanionProject");
    }

    // MARK: - Line building (legacy pooling)

    /// Collapse model configs into the two quota-pool meters, keeping the worst fraction per pool and
    /// ordering the Gemini pool ("Session") before Claude. Blacklisted and empty-label models are
    /// dropped.
    public static IReadOnlyList<QuotaMetricLine> BuildLines(IReadOnlyList<AntigravityModelConfig> configs)
    {
        var pooled = new Dictionary<string, (double Fraction, DateTimeOffset? ResetTime)>(StringComparer.Ordinal);
        foreach (var config in configs)
        {
            var label = config.Label.Trim();
            if (label.Length == 0)
                continue;
            if (config.ModelId is { } id && ModelBlacklist.Contains(id))
                continue;

            var pool = PoolLabel(NormalizeLabel(label));
            // Worst-case wins; ties keep the first seen.
            if (!pooled.TryGetValue(pool, out var existing) || config.RemainingFraction < existing.Fraction)
                pooled[pool] = (config.RemainingFraction, config.ResetTime);
        }

        return pooled
            .OrderBy(entry => SortKey(entry.Key), StringComparer.Ordinal)
            .Select(entry => Line(entry.Key, entry.Value.Fraction, entry.Value.ResetTime, QuotaPeriod.SessionMs))
            .ToArray();
    }

    public static QuotaProgressLine Line(string pool, double fraction, DateTimeOffset? resetTime, long periodMs)
    {
        var clamped = double.IsFinite(fraction) ? Math.Clamp(fraction, 0, 1) : 0;
        // Keep whole percents so a fresh window reads 0 and "Not started" works.
        var used = Math.Round((1 - clamped) * 100, MidpointRounding.AwayFromZero);
        return new QuotaProgressLine(
            pool,
            used,
            100,
            QuotaMetricKind.Percent,
            ResetsAt: resetTime,
            PeriodMilliseconds: periodMs);
    }

    // MARK: - Pooling helpers (pure)

    /// "Gemini 3 Pro (High)" → "Gemini 3 Pro" — strip a trailing parenthetical variant.
    public static string NormalizeLabel(string label)
    {
        var match = TrailingParenthetical().Match(label);
        return (match.Success ? label[..match.Index] : label).Trim();
    }

    public static string PoolLabel(string normalizedLabel) =>
        // Pro and Flash draw from one shared pool since Antigravity's 2026-05-19 quota merge, so every
        // Gemini model (Pro, Flash, Ultra, bare names) maps to the single "Session" meter; Claude,
        // GPT-OSS, and any other non-Gemini model share the other pool.
        normalizedLabel.Contains("gemini", StringComparison.OrdinalIgnoreCase)
            ? AntigravityMetric.SessionLabel
            : AntigravityMetric.ClaudeLabel;

    /// The Gemini pool ("Session") before Claude, matching the widget declaration order.
    public static string SortKey(string poolLabel) =>
        poolLabel == AntigravityMetric.SessionLabel ? $"0_{poolLabel}" : $"1_{poolLabel}";

    /// Normalize a raw plan/tier string to a short label. LS returns "Google AI Pro" (strip the
    /// prefix, keep the tail); Cloud Code returns "Gemini Code Assist in Google One AI Pro" (pull the
    /// tier word).
    public static string? FormatPlan(string? raw)
    {
        var trimmed = raw?.Trim();
        if (string.IsNullOrEmpty(trimmed))
            return null;
        const string prefix = "Google AI ";
        if (trimmed.StartsWith(prefix, StringComparison.Ordinal))
            return TitleCased(trimmed[prefix.Length..]);
        foreach (var keyword in PlanKeywords)
        {
            if (trimmed.Contains(keyword, StringComparison.OrdinalIgnoreCase))
                return keyword;
        }
        return TitleCased(trimmed);
    }

    private static readonly string[] PlanKeywords = ["Ultra", "Pro", "Free"];

    /// Upper-case each whitespace-separated word's first character, preserve the tail, single-space join.
    private static string TitleCased(string value)
    {
        var builder = new StringBuilder();
        foreach (var word in value.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            if (builder.Length > 0)
                builder.Append(' ');
            builder.Append(char.ToUpperInvariant(word[0])).Append(word.AsSpan(1));
        }
        return builder.ToString();
    }

    private static IReadOnlyList<AntigravityModelConfig> ConfigsFromLs(JsonElement? array)
    {
        if (array is not { } models)
            return [];
        var configs = new List<AntigravityModelConfig>();
        foreach (var model in models.EnumerateArray())
        {
            if (model.ValueKind != JsonValueKind.Object)
                continue;
            var modelId = QuotaJson.ObjectProperty(model, "modelOrAlias") is { } alias ? QuotaJson.String(alias, "model") : null;
            if (Config(QuotaJson.String(model, "label"), modelId, QuotaJson.ObjectProperty(model, "quotaInfo")) is { } config)
                configs.Add(config);
        }
        return configs;
    }

    private static AntigravityModelConfig? Config(string? label, string? modelId, JsonElement? quota)
    {
        var trimmed = label?.Trim();
        if (string.IsNullOrEmpty(trimmed))
            return null;
        return new AntigravityModelConfig(
            trimmed,
            modelId,
            quota is { } info ? QuotaJson.Number(info, "remainingFraction") ?? 0 : 0,
            quota is { } withReset ? QuotaTime.ParseIso8601(QuotaJson.String(withReset, "resetTime")) : null);
    }

    [GeneratedRegex(@"\s*\([^)]*\)\s*$")]
    private static partial Regex TrailingParenthetical();
}
