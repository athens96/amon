using AMon.Core;
using Xunit;

namespace AMon.Reporting.Tests;

public sealed class ContentSignatureTests
{
    [Fact]
    public void Signature_is_order_independent_but_usage_sensitive()
    {
        var first = new ToolSummary("codex", "Codex", [Day(1)]);
        var second = new ToolSummary("claude", "Claude", [Day(2)]);

        Assert.Equal(
            ContentSignature.Compute([first, second]),
            ContentSignature.Compute([second, first]));
        Assert.NotEqual(
            ContentSignature.Compute([first]),
            ContentSignature.Compute([new ToolSummary("codex", "Codex", [Day(9)])]));
    }

    [Fact]
    public void Upload_signature_includes_user_key()
    {
        var one = ContentSignature.ComputeUploadSignature("https://amon.test/api", "one", "content");
        var two = ContentSignature.ComputeUploadSignature("https://amon.test/api", "two", "content");
        Assert.NotEqual(one, two);
    }

    [Fact]
    public void Content_signature_excludes_local_session_and_note_data()
    {
        var privateOne = new ToolSummary("codex", "Codex", [Day(1)], 1, Note: "secret-one");
        var privateTwo = new ToolSummary("codex", "Codex", [Day(1)], 999, Note: "secret-two");

        Assert.Equal(ContentSignature.Compute([privateOne]), ContentSignature.Compute([privateTwo]));
    }

    private static UsageDaily Day(long input) =>
        new(new DateOnly(2026, 7, 26), "model", new TokenUsage(input, 1));
}
