using System.Text.Json;

namespace AMon.Activity.Tests;

internal sealed class MutableTimeProvider(DateTimeOffset now) : TimeProvider
{
    public DateTimeOffset Now { get; set; } = now;
    public override DateTimeOffset GetUtcNow() => Now;
}

internal static class TestSupport
{
    public static string TempDirectory(string name)
    {
        var path = Path.Combine(Path.GetTempPath(), $"amon-{name}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        return path;
    }

    public static string Json(object value) => JsonSerializer.Serialize(value);
}
