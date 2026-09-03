using System.Text;

namespace AMon.Core.Markdown;

public enum MarkdownColumnAlignment
{
    Leading,
    Center,
    Trailing,
}

/// Block-level Markdown vocabulary for the session transcript viewer. Ported from the macOS
/// `MarkdownBlock`: headings, paragraphs, fenced code, list items (with checklist markers), quotes,
/// rules, and GFM pipe tables. Anything else flows through as a paragraph, so nothing is lost.
public abstract record MarkdownBlock;

public sealed record MarkdownHeading(int Level, string Content) : MarkdownBlock;

public sealed record MarkdownParagraph(string Content) : MarkdownBlock;

public sealed record MarkdownCodeBlock(string Code) : MarkdownBlock;

/// `Marker` is `•`, `☐`, `☑`, or an ordinal like `3.`; `Indent` is 0…4 (two spaces per level).
public sealed record MarkdownListItem(string Marker, string Content, int Indent) : MarkdownBlock;

public sealed record MarkdownQuote(string Content) : MarkdownBlock;

public sealed record MarkdownRule : MarkdownBlock;

public sealed record MarkdownTable(
    IReadOnlyList<string> Headers,
    IReadOnlyList<MarkdownColumnAlignment> Alignments,
    IReadOnlyList<IReadOnlyList<string>> Rows) : MarkdownBlock;

public enum MarkdownInlineKind
{
    Text,
    Bold,
    Italic,
    Code,
    Strikethrough,
    Link,
}

/// One inline run. `Url` is set for links only.
public sealed record MarkdownInlineRun(MarkdownInlineKind Kind, string Text, string? Url = null);

/// Dependency-free block parser — a line-for-line port of the macOS `MarkdownParser`.
public static class MarkdownParser
{
    public static IReadOnlyList<MarkdownBlock> Parse(string? text)
    {
        var blocks = new List<MarkdownBlock>();
        if (string.IsNullOrEmpty(text))
            return blocks;
        var lines = text.Replace("\r\n", "\n").Split('\n');
        var paragraph = new List<string>();

        void FlushParagraph()
        {
            var joined = string.Join("\n", paragraph).Trim();
            if (joined.Length > 0)
                blocks.Add(new MarkdownParagraph(joined));
            paragraph.Clear();
        }

        var index = 0;
        while (index < lines.Length)
        {
            var line = lines[index];
            var trimmed = line.Trim(' ');

            if (FenceMarker(trimmed) is { } fence)
            {
                FlushParagraph();
                var code = new List<string>();
                index++;
                while (index < lines.Length)
                {
                    var inner = lines[index].Trim(' ');
                    if (inner.StartsWith(fence, StringComparison.Ordinal) && FenceMarker(inner) is not null)
                    {
                        index++;
                        break;
                    }
                    code.Add(lines[index]);
                    index++;
                }
                while (code.Count > 0 && code[^1].Trim(' ').Length == 0)
                    code.RemoveAt(code.Count - 1);
                blocks.Add(new MarkdownCodeBlock(string.Join("\n", code)));
                continue;
            }

            if (trimmed.Length == 0)
            {
                FlushParagraph();
                index++;
                continue;
            }

            if (IsHorizontalRule(trimmed))
            {
                FlushParagraph();
                blocks.Add(new MarkdownRule());
                index++;
                continue;
            }

            if (Heading(trimmed) is { } heading)
            {
                FlushParagraph();
                blocks.Add(heading);
                index++;
                continue;
            }

            if (trimmed.StartsWith('>'))
            {
                FlushParagraph();
                blocks.Add(new MarkdownQuote(trimmed[1..].Trim(' ')));
                index++;
                continue;
            }

            if (trimmed.Contains('|') && index + 1 < lines.Length && IsTableSeparator(lines[index + 1]))
            {
                FlushParagraph();
                var headers = SplitTableRow(line);
                var alignments = TableAlignments(lines[index + 1], headers.Count);
                index += 2;
                var rows = new List<IReadOnlyList<string>>();
                while (index < lines.Length)
                {
                    var rowLine = lines[index];
                    var rowTrimmed = rowLine.Trim(' ');
                    if (rowTrimmed.Length == 0 || !rowTrimmed.Contains('|'))
                        break;
                    var cells = SplitTableRow(rowLine).ToList();
                    if (cells.Count < headers.Count)
                        cells.AddRange(Enumerable.Repeat(string.Empty, headers.Count - cells.Count));
                    else if (cells.Count > headers.Count)
                        cells = cells.Take(headers.Count).ToList();
                    rows.Add(cells);
                    index++;
                }
                blocks.Add(new MarkdownTable(headers, alignments, rows));
                continue;
            }

            if (ListItem(line) is { } item)
            {
                FlushParagraph();
                blocks.Add(item);
                index++;
                continue;
            }

            paragraph.Add(line);
            index++;
        }
        FlushParagraph();
        return blocks;
    }

    /// Inline runs of a paragraph/heading/list/quote body: `**bold**`, `__bold__`, `*italic*`,
    /// `_italic_`, `` `code` ``, `~~strike~~`, and `[text](url)`. Unterminated markers stay literal.
    public static IReadOnlyList<MarkdownInlineRun> Inlines(string? text)
    {
        var runs = new List<MarkdownInlineRun>();
        if (string.IsNullOrEmpty(text))
            return runs;
        var literal = new StringBuilder();
        void FlushLiteral()
        {
            if (literal.Length > 0)
            {
                runs.Add(new MarkdownInlineRun(MarkdownInlineKind.Text, literal.ToString()));
                literal.Clear();
            }
        }

        var index = 0;
        while (index < text.Length)
        {
            var ch = text[index];
            if (ch == '\\' && index + 1 < text.Length && "\\`*_~[]()".Contains(text[index + 1]))
            {
                literal.Append(text[index + 1]);
                index += 2;
                continue;
            }
            if (ch == '`')
            {
                var close = text.IndexOf('`', index + 1);
                if (close > index + 1)
                {
                    FlushLiteral();
                    runs.Add(new MarkdownInlineRun(MarkdownInlineKind.Code, text[(index + 1)..close]));
                    index = close + 1;
                    continue;
                }
            }
            if (ch == '[')
            {
                var closeBracket = text.IndexOf(']', index + 1);
                if (closeBracket > index + 1 && closeBracket + 1 < text.Length && text[closeBracket + 1] == '(')
                {
                    var closeParen = text.IndexOf(')', closeBracket + 2);
                    if (closeParen > closeBracket + 2)
                    {
                        FlushLiteral();
                        runs.Add(new MarkdownInlineRun(MarkdownInlineKind.Link, text[(index + 1)..closeBracket], text[(closeBracket + 2)..closeParen].Trim()));
                        index = closeParen + 1;
                        continue;
                    }
                }
            }
            if (TryDelimited(text, index, "**", MarkdownInlineKind.Bold, out var run, out var next)
                || TryDelimited(text, index, "__", MarkdownInlineKind.Bold, out run, out next)
                || TryDelimited(text, index, "~~", MarkdownInlineKind.Strikethrough, out run, out next)
                || TryDelimited(text, index, "*", MarkdownInlineKind.Italic, out run, out next)
                || TryDelimited(text, index, "_", MarkdownInlineKind.Italic, out run, out next))
            {
                FlushLiteral();
                runs.Add(run!);
                index = next;
                continue;
            }
            literal.Append(ch);
            index++;
        }
        FlushLiteral();
        return runs;
    }

    private static bool TryDelimited(string text, int index, string delimiter, MarkdownInlineKind kind, out MarkdownInlineRun? run, out int next)
    {
        run = null;
        next = index;
        if (string.CompareOrdinal(text, index, delimiter, 0, delimiter.Length) != 0)
            return false;
        var contentStart = index + delimiter.Length;
        if (contentStart >= text.Length || char.IsWhiteSpace(text[contentStart]))
            return false;
        // A single `_` inside a word (snake_case) is not emphasis.
        if (delimiter == "_" && index > 0 && char.IsLetterOrDigit(text[index - 1]))
            return false;
        var close = text.IndexOf(delimiter, contentStart, StringComparison.Ordinal);
        while (close > contentStart && delimiter.Length == 1 && close + 1 < text.Length && text[close + 1] == delimiter[0])
            close = text.IndexOf(delimiter, close + 2, StringComparison.Ordinal);
        if (close <= contentStart || char.IsWhiteSpace(text[close - 1]))
            return false;
        run = new MarkdownInlineRun(kind, text[contentStart..close]);
        next = close + delimiter.Length;
        return true;
    }

    private static string? FenceMarker(string trimmed) =>
        trimmed.StartsWith("```", StringComparison.Ordinal) ? "```"
        : trimmed.StartsWith("~~~", StringComparison.Ordinal) ? "~~~"
        : null;

    private static MarkdownHeading? Heading(string trimmed)
    {
        var level = 0;
        while (level < trimmed.Length && trimmed[level] == '#')
            level++;
        if (level is < 1 or > 6 || level >= trimmed.Length || trimmed[level] != ' ')
            return null;
        return new MarkdownHeading(level, trimmed[level..].Trim(' '));
    }

    private static bool IsHorizontalRule(string trimmed) =>
        trimmed.Length >= 3 && (trimmed.All(static c => c == '-') || trimmed.All(static c => c == '*') || trimmed.All(static c => c == '_'));

    private static MarkdownListItem? ListItem(string raw)
    {
        var leadingSpaces = raw.TakeWhile(static c => c == ' ').Count();
        var indent = Math.Min(leadingSpaces / 2, 4);
        var trimmed = raw.Trim(' ');
        foreach (var bullet in new[] { "- ", "* ", "+ " })
        {
            if (!trimmed.StartsWith(bullet, StringComparison.Ordinal))
                continue;
            var content = trimmed[bullet.Length..];
            if (content.StartsWith("[ ] ", StringComparison.Ordinal))
                return new MarkdownListItem("☐", content[4..], indent);
            if (content.StartsWith("[x] ", StringComparison.Ordinal) || content.StartsWith("[X] ", StringComparison.Ordinal))
                return new MarkdownListItem("☑", content[4..], indent);
            return new MarkdownListItem("•", content, indent);
        }
        var digits = 0;
        while (digits < trimmed.Length && char.IsDigit(trimmed[digits]))
            digits++;
        if (digits == 0 || digits + 1 >= trimmed.Length || trimmed[digits] is not ('.' or ')') || trimmed[digits + 1] != ' ')
            return null;
        return new MarkdownListItem(trimmed[..digits] + ".", trimmed[(digits + 1)..].Trim(' '), indent);
    }

    /// A separator row: two or more `|`-split cells each matching `:?-+:?`.
    public static bool IsTableSeparator(string line)
    {
        var cells = SplitTableRow(line);
        if (cells.Count < 2)
            return false;
        foreach (var cell in cells)
        {
            var body = cell.Trim(' ');
            if (body.Length == 0)
                return false;
            if (body.StartsWith(':'))
                body = body[1..];
            if (body.EndsWith(':'))
                body = body[..^1];
            if (body.Length == 0 || !body.All(static c => c == '-'))
                return false;
        }
        return true;
    }

    public static IReadOnlyList<MarkdownColumnAlignment> TableAlignments(string line, int columns)
    {
        var cells = SplitTableRow(line);
        var alignments = new List<MarkdownColumnAlignment>(columns);
        for (var column = 0; column < columns; column++)
        {
            var cell = column < cells.Count ? cells[column].Trim(' ') : string.Empty;
            var left = cell.StartsWith(':');
            var right = cell.EndsWith(':');
            alignments.Add(left && right ? MarkdownColumnAlignment.Center : right ? MarkdownColumnAlignment.Trailing : MarkdownColumnAlignment.Leading);
        }
        return alignments;
    }

    /// Split a row into cells: outer pipes dropped, `\|` kept as a literal pipe.
    public static IReadOnlyList<string> SplitTableRow(string line)
    {
        var trimmed = line.Trim(' ');
        if (trimmed.StartsWith('|'))
            trimmed = trimmed[1..];
        if (trimmed.EndsWith('|') && !trimmed.EndsWith("\\|", StringComparison.Ordinal))
            trimmed = trimmed[..^1];
        var cells = new List<string>();
        var current = new StringBuilder();
        for (var index = 0; index < trimmed.Length; index++)
        {
            var ch = trimmed[index];
            if (ch == '\\')
            {
                if (index + 1 < trimmed.Length)
                {
                    var after = trimmed[index + 1];
                    if (after == '|')
                        current.Append('|');
                    else
                        current.Append('\\').Append(after);
                    index++;
                }
                else
                {
                    current.Append('\\');
                }
            }
            else if (ch == '|')
            {
                cells.Add(current.ToString().Trim(' '));
                current.Clear();
            }
            else
            {
                current.Append(ch);
            }
        }
        cells.Add(current.ToString().Trim(' '));
        return cells;
    }
}
