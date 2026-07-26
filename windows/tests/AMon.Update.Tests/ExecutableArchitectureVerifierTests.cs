using System.Runtime.InteropServices;
using AMon.Update;

namespace AMon.Update.Tests;

public sealed class ExecutableArchitectureVerifierTests
{
    [Theory]
    [InlineData(Architecture.X64, 0x8664)]
    [InlineData(Architecture.Arm64, 0xAA64)]
    public void AcceptsOnlyTheExpectedPeMachine(
        Architecture architecture,
        int machine)
    {
        var path = WritePe((ushort)machine);
        try
        {
            ExecutableArchitectureVerifier.Verify(path, architecture);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void RejectsAnotherWindowsArchitecture()
    {
        var path = WritePe(0xAA64);
        try
        {
            Assert.Throws<InvalidDataException>(() =>
                ExecutableArchitectureVerifier.Verify(path, Architecture.X64));
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void RejectsMalformedExecutables()
    {
        var path = Path.GetTempFileName();
        try
        {
            File.WriteAllText(path, "not a PE");
            Assert.Throws<InvalidDataException>(() =>
                ExecutableArchitectureVerifier.Verify(path, Architecture.X64));
        }
        finally
        {
            File.Delete(path);
        }
    }

    private static string WritePe(ushort machine)
    {
        var path = Path.GetTempFileName();
        var bytes = new byte[128];
        bytes[0] = (byte)'M';
        bytes[1] = (byte)'Z';
        BitConverter.GetBytes(64).CopyTo(bytes, 0x3C);
        bytes[64] = (byte)'P';
        bytes[65] = (byte)'E';
        BitConverter.GetBytes(machine).CopyTo(bytes, 68);
        File.WriteAllBytes(path, bytes);
        return path;
    }
}
