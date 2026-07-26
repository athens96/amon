using System.Text;

namespace AMon.Activity;

internal static class LiveText
{
    public static string? FirstLine(string? value, int maxRunes)
    {
        if (string.IsNullOrWhiteSpace(value))
            return null;
        var line = value.Trim().Split(['\r', '\n'], 2)[0].Trim();
        if (line.Length == 0)
            return null;

        var builder = new StringBuilder();
        foreach (var rune in line.EnumerateRunes().Take(maxRunes))
            builder.Append(rune);
        return builder.Length == 0 ? null : builder.ToString();
    }

    public static bool IsCodexUserText(string? value)
    {
        var text = value?.Trim();
        if (string.IsNullOrEmpty(text))
            return false;
        string[] prefixes =
        [
            "# AGENTS.md instructions",
            "<INSTRUCTIONS>",
            "<environment_context>",
            "<permissions instructions>"
        ];
        return !prefixes.Any(text.StartsWith);
    }

    public static bool IsPlainAgentPreview(string? value)
    {
        var text = value?.TrimStart();
        return !string.IsNullOrEmpty(text) &&
               !text.StartsWith('{') &&
               !text.StartsWith('[');
    }
}
