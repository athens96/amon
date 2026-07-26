using AMon.Activity;

namespace AMon.App;

public enum CodexPetAnimation
{
    Idle,
    RunningRight,
    RunningLeft,
    Waving,
    Jumping,
    Failed,
    Waiting,
    Running,
    Review,
}

public sealed record CodexPetStrip(int Row, int FrameCount);

public static class CodexPetSpriteLayout
{
    public const int SheetPixelWidth = 1536;
    public const int V1SheetPixelHeight = 1872;
    public const int V2SheetPixelHeight = 2288;
    public const int FramePixelWidth = 192;
    public const int FramePixelHeight = 208;
    public const int ColumnCount = 8;
    public const int V1RowCount = 9;
    public const int V2RowCount = 11;

    public static int NormalizeVersion(int version) => version == 2 ? 2 : 1;

    public static int SheetPixelHeightFor(int version) =>
        NormalizeVersion(version) == 2
            ? V2SheetPixelHeight
            : V1SheetPixelHeight;

    public static int RowCountFor(int version) =>
        NormalizeVersion(version) == 2 ? V2RowCount : V1RowCount;

    public static int? VersionForDimensions(int width, int height)
    {
        if (width != SheetPixelWidth)
            return null;
        return height switch
        {
            V1SheetPixelHeight => 1,
            V2SheetPixelHeight => 2,
            _ => null,
        };
    }

    public static IReadOnlyDictionary<CodexPetAnimation, CodexPetStrip> Strips { get; } =
        new Dictionary<CodexPetAnimation, CodexPetStrip>
        {
            [CodexPetAnimation.Idle] = new(0, 6),
            [CodexPetAnimation.RunningRight] = new(1, 8),
            [CodexPetAnimation.RunningLeft] = new(2, 8),
            [CodexPetAnimation.Waving] = new(3, 4),
            [CodexPetAnimation.Jumping] = new(4, 5),
            [CodexPetAnimation.Failed] = new(5, 8),
            [CodexPetAnimation.Waiting] = new(6, 6),
            [CodexPetAnimation.Running] = new(7, 6),
            [CodexPetAnimation.Review] = new(8, 6),
        };

    public static CodexPetAnimation AnimationFor(PetActivityStatus status) => status switch
    {
        PetActivityStatus.Idle => CodexPetAnimation.Idle,
        PetActivityStatus.Running => CodexPetAnimation.Running,
        PetActivityStatus.NeedsInput => CodexPetAnimation.Waiting,
        PetActivityStatus.Ready => CodexPetAnimation.Waving,
        PetActivityStatus.Blocked => CodexPetAnimation.Failed,
        _ => CodexPetAnimation.Idle,
    };

    public static IReadOnlyList<TimeSpan> FrameDurations(CodexPetAnimation animation)
    {
        if (!Strips.TryGetValue(animation, out var strip))
            return [];
        if (animation == CodexPetAnimation.Idle)
        {
            return
            [
                TimeSpan.FromSeconds(1.68),
                TimeSpan.FromSeconds(0.66),
                TimeSpan.FromSeconds(0.66),
                TimeSpan.FromSeconds(0.84),
                TimeSpan.FromSeconds(0.84),
                TimeSpan.FromSeconds(1.92),
            ];
        }

        var (regular, final) = animation switch
        {
            CodexPetAnimation.RunningRight
                or CodexPetAnimation.RunningLeft
                or CodexPetAnimation.Running => (0.12, 0.22),
            CodexPetAnimation.Waving
                or CodexPetAnimation.Jumping => (0.14, 0.28),
            CodexPetAnimation.Failed => (0.14, 0.24),
            CodexPetAnimation.Waiting => (0.15, 0.26),
            CodexPetAnimation.Review => (0.15, 0.28),
            _ => (0.15, 0.25),
        };
        return Enumerable.Range(0, strip.FrameCount)
            .Select(index => TimeSpan.FromSeconds(
                index == strip.FrameCount - 1 ? final : regular))
            .ToArray();
    }

    public static int FrameIndex(
        TimeSpan elapsed,
        CodexPetAnimation animation,
        bool reduceMotion)
    {
        var durations = FrameDurations(animation);
        if (durations.Count == 0 || reduceMotion)
            return 0;
        var cycle = durations.Sum(static duration => duration.TotalMilliseconds);
        var cursor = elapsed.TotalMilliseconds % cycle;
        for (var index = 0; index < durations.Count; index++)
        {
            if (cursor < durations[index].TotalMilliseconds)
                return index;
            cursor -= durations[index].TotalMilliseconds;
        }
        return durations.Count - 1;
    }
}
