using System.Text;

namespace AMon.Quotas;

/// go-keyring wraps secrets it stores through the macOS `security` CLI as `go-keyring-base64:…`;
/// its Windows Credential Manager backend stores the raw bytes. Accept both so a value copied
/// between machines, or written by a tool that applies the wrapper unconditionally, still decodes.
public static class GoKeyring
{
    private const string Prefix = "go-keyring-base64:";

    public static string? Unwrap(string? raw)
    {
        if (raw is null)
            return null;
        var text = raw.Trim();
        if (text.StartsWith(Prefix, StringComparison.Ordinal))
        {
            var encoded = text[Prefix.Length..].Trim();
            try
            {
                text = Encoding.UTF8.GetString(Convert.FromBase64String(encoded)).Trim();
            }
            catch (FormatException)
            {
                return null;
            }
        }
        return text.Length == 0 ? null : text;
    }
}
