# A-mon Installers

## Windows

Windows artifacts are produced by `.github/workflows/windows.yml` for
`win-x64` and `win-arm64`. The workflow publishes self-contained WPF and updater
executables, requires Authenticode secrets, signs every executable, and verifies
the signatures before uploading artifacts.

A replacement per-user installer is still a separate packaging milestone; the
removed Go installer must not be used for the WPF release.

## macOS

```bash
cd macos
make installer
```

Output: `macos/dist/A-mon-<version>.pkg`

The package contains the universal `AIMonitor.app`, installs it into
`/Applications`, stops an older running copy, and clears quarantine metadata.
Release distribution should additionally use Developer ID signing and Apple
notarization.

The macOS PKG requires `swift`, `codesign`, and `pkgbuild`. Windows publishing
and runtime smoke tests require a Windows runner with .NET 10.
