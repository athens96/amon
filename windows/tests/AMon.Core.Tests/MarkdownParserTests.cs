using AMon.Core.Markdown;
using Xunit;

namespace AMon.Core.Tests;

public sealed class MarkdownParserTests
{
    [Fact]
    public void ParsesTheBlockVocabulary()
    {
        var blocks = MarkdownParser.Parse(
            "# Title\n\nFirst line\nsecond line\n\n```sh\nnpm test\n\n```\n- one\n  - [x] done\n3) third\n> quoted\n---\nplain");

        Assert.Equal(new MarkdownHeading(1, "Title"), blocks[0]);
        Assert.Equal(new MarkdownParagraph("First line\nsecond line"), blocks[1]);
        Assert.Equal(new MarkdownCodeBlock("npm test"), blocks[2]);
        Assert.Equal(new MarkdownListItem("•", "one", 0), blocks[3]);
        Assert.Equal(new MarkdownListItem("☑", "done", 1), blocks[4]);
        Assert.Equal(new MarkdownListItem("3.", "third", 0), blocks[5]);
        Assert.Equal(new MarkdownQuote("quoted"), blocks[6]);
        Assert.IsType<MarkdownRule>(blocks[7]);
        Assert.Equal(new MarkdownParagraph("plain"), blocks[8]);
    }

    [Fact]
    public void ParsesGfmTablesWithAlignmentAndEscapedPipes()
    {
        var blocks = MarkdownParser.Parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | x \\| y |\n| 2 | 3 | 4 | extra |\nafter");

        var table = Assert.IsType<MarkdownTable>(blocks[0]);
        Assert.Equal(["a", "b", "c"], table.Headers);
        Assert.Equal([MarkdownColumnAlignment.Leading, MarkdownColumnAlignment.Center, MarkdownColumnAlignment.Trailing], table.Alignments);
        Assert.Equal(["1", "x | y", ""], table.Rows[0]);
        Assert.Equal(["2", "3", "4"], table.Rows[1]);
        Assert.Equal(new MarkdownParagraph("after"), blocks[1]);
    }

    [Fact]
    public void SingleColumnDashesAreARuleNotATable()
    {
        var blocks = MarkdownParser.Parse("a | b\n---\nc");

        Assert.Equal(new MarkdownParagraph("a | b"), blocks[0]);
        Assert.IsType<MarkdownRule>(blocks[1]);
    }

    [Fact]
    public void InlineRunsCoverEmphasisCodeLinksAndEscapes()
    {
        var runs = MarkdownParser.Inlines("Use **bold** and *it* with `code`, [docs](https://x.y) ~~old~~ snake_case \\*lit\\*");

        Assert.Equal(
        [
            new MarkdownInlineRun(MarkdownInlineKind.Text, "Use "),
            new MarkdownInlineRun(MarkdownInlineKind.Bold, "bold"),
            new MarkdownInlineRun(MarkdownInlineKind.Text, " and "),
            new MarkdownInlineRun(MarkdownInlineKind.Italic, "it"),
            new MarkdownInlineRun(MarkdownInlineKind.Text, " with "),
            new MarkdownInlineRun(MarkdownInlineKind.Code, "code"),
            new MarkdownInlineRun(MarkdownInlineKind.Text, ", "),
            new MarkdownInlineRun(MarkdownInlineKind.Link, "docs", "https://x.y"),
            new MarkdownInlineRun(MarkdownInlineKind.Text, " "),
            new MarkdownInlineRun(MarkdownInlineKind.Strikethrough, "old"),
            new MarkdownInlineRun(MarkdownInlineKind.Text, " snake_case *lit*"),
        ], runs);
    }

    [Fact]
    public void UnterminatedMarkersStayLiteral()
    {
        Assert.Equal([new MarkdownInlineRun(MarkdownInlineKind.Text, "a ** b `c [d](e")], MarkdownParser.Inlines("a ** b `c [d](e"));
        Assert.Empty(MarkdownParser.Parse(""));
        Assert.Empty(MarkdownParser.Inlines(null));
    }
}
