using System.IO;
using Microsoft.Win32;

namespace AMon.WindowsPlatform;

public sealed class LaunchAtLoginService
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    // Preserve the existing Run value so upgrades do not leave duplicate entries.
    private const string ValueName = "A-mon";

    public void SetEnabled(bool enabled, string executablePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executablePath);

        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true)
            ?? throw new InvalidOperationException("Windows 시작 프로그램 레지스트리를 열 수 없습니다.");
        if (enabled)
        {
            key.SetValue(
                ValueName,
                $"\"{Path.GetFullPath(executablePath)}\"",
                RegistryValueKind.String);
        }
        else
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }
}
