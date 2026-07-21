# A-mon Installers

## Windows

```bash
cd windows
make installer
```

Output: `windows/dist/A-mon-Setup-<version>.exe`

The installer runs without administrator privileges and installs into
`%LOCALAPPDATA%\Programs\A-mon`. It creates Start Menu and startup shortcuts,
registers A-mon in the Windows installed-app list, and includes `Uninstall.exe`.
Pass `--silent` for unattended installation or removal.

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

## Combined target

On a macOS build machine, `make installer` at the repository root produces
both platform installers. The macOS PKG requires `swift`, `codesign`, and
`pkgbuild`; the Windows installer requires Go only.
