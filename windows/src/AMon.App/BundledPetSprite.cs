using System.IO;

namespace AMon.App;

public sealed record PetSpriteSelection(
    string Path,
    int Version,
    bool IsCustom);

/// <summary>
/// Resolves the sprite used for rendering without ever persisting the bundled
/// installation path in user settings.
/// </summary>
public static class BundledPetSprite
{
    public const string DisplayName = "amon";
    public const int Version = 3;

    public static string PathFromBaseDirectory(string? baseDirectory = null) =>
        Path.Combine(
            baseDirectory ?? AppContext.BaseDirectory,
            "Assets",
            "Pets",
            "Amon.webp");

    public static PetSpriteSelection? Resolve(
        string? customPath,
        int customVersion,
        string? bundledPath = null,
        Func<string?, int, bool>? isValid = null)
    {
        var validator = isValid ?? CodexPetAssetService.IsValidSprite;
        var normalizedCustomVersion =
            CodexPetSpriteLayout.NormalizeVersion(customVersion);
        if (!string.IsNullOrWhiteSpace(customPath)
            && validator(customPath, normalizedCustomVersion))
        {
            return new PetSpriteSelection(
                Path.GetFullPath(customPath),
                normalizedCustomVersion,
                IsCustom: true);
        }

        var candidate = string.IsNullOrWhiteSpace(bundledPath)
            ? PathFromBaseDirectory()
            : bundledPath;
        return validator(candidate, Version)
            ? new PetSpriteSelection(
                Path.GetFullPath(candidate),
                Version,
                IsCustom: false)
            : null;
    }
}
