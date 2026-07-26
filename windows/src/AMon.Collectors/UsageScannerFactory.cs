using AMon.Collectors.Scanners;

namespace AMon.Collectors;

public sealed record UsageScannerPaths(
    string Claude = "",
    string Codex = "",
    string OpenCode = "",
    string Cursor = "",
    string Gemini = "",
    string Qwen = "",
    string Copilot = "");

public static class UsageScannerFactory
{
    public static IReadOnlyList<IUsageScanner> Create(UsageScannerPaths? paths = null)
    {
        paths ??= new UsageScannerPaths();
        return
        [
            string.IsNullOrWhiteSpace(paths.Claude)
                ? new ClaudeScanner()
                : new ClaudeScanner(paths.Claude),
            string.IsNullOrWhiteSpace(paths.Codex)
                ? new CodexScanner()
                : new CodexScanner(paths.Codex),
            string.IsNullOrWhiteSpace(paths.OpenCode)
                ? new OpenCodeScanner()
                : new OpenCodeScanner(paths.OpenCode),
            string.IsNullOrWhiteSpace(paths.Cursor)
                ? new CursorScanner()
                : new CursorScanner(paths.Cursor),
            string.IsNullOrWhiteSpace(paths.Gemini)
                ? new GeminiScanner()
                : new GeminiScanner(paths.Gemini),
            string.IsNullOrWhiteSpace(paths.Qwen)
                ? new QwenScanner()
                : new QwenScanner(paths.Qwen),
            string.IsNullOrWhiteSpace(paths.Copilot)
                ? new CopilotScanner()
                : new CopilotScanner(paths.Copilot),
        ];
    }
}
