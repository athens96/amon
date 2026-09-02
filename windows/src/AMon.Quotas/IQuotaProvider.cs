namespace AMon.Quotas;

/// One AI provider whose remaining quota amon can read using credentials already on the machine.
/// Detect → fetch → normalize, never a login flow of its own. Mirrors the macOS `ProviderRuntime`.
public interface IQuotaProvider
{
    /// Stable identifier shared with the macOS client (`claude`, `codex`, `cursor`, `copilot`, …).
    string Id { get; }

    /// User-facing name shown on the card and in the tray picker.
    string DisplayName { get; }

    /// Cheap, local-only check (files, credential store — never the network) for whether this
    /// provider has anything to authenticate with. Only detected providers are refreshed or shown.
    Task<bool> HasLocalCredentialsAsync(CancellationToken cancellationToken);

    /// Fetch and normalize the latest quota. Never throws: failures become `QuotaSnapshot.Failure`.
    Task<QuotaSnapshot> RefreshAsync(CancellationToken cancellationToken);
}
