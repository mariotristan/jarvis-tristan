# CI and releases

Three GitHub Actions workflows.

| Workflow | File | Trigger | What it does |
|----------|------|---------|--------------|
| CI | `.github/workflows/ci.yml` | Push to `main`, pull requests | Runs the tests, builds the app and a DMG, checks the signature, uploads the DMG as an artifact |
| Secret scan | `.github/workflows/secret-scan.yml` | Push to `main`, pull requests, every Monday, and called by Release | Runs gitleaks over the full git history and fails on any leaked credential |
| Release | `.github/workflows/release.yml` | Push a tag `v*` | Runs the secret scan first, then the tests, builds `Tristan-<version>.dmg`, publishes a GitHub Release with generated notes, the DMG and its SHA-256 |

CI has two jobs. `build-and-test` is the Mac app (above). `ios` builds the iPhone and iPad app in `ios/` and runs its tests on an iPhone simulator. The iOS job uses the **newest Xcode 16.x** on the runner rather than 16.2: the `macos-15` image has no simulator runtime matching Xcode 16.2 (it reports "iOS 18.2 is not installed"), while Xcode 16.4 has the iOS 18.5 runtime. The generated `ios/TristanIOS.xcodeproj` is committed, so CI does not need XcodeGen; regenerate it with `cd ios && xcodegen generate` after editing `ios/project.yml`.

Every CI run leaves a `Tristan-dmg` artifact on the run page, so any build can be installed for testing without a release.

## Publishing a release

```bash
# 1. Make sure CI is green on main.
# 2. Tag the commit you want to ship. The tag is the version (v1.2.3 gives version 1.2.3).
git tag v1.2.3
git push origin v1.2.3
```

The release appears under **Releases** in about three minutes. Also bump the `VERSION` file when you cut a release so local builds report the same number.

## Building locally

```bash
scripts/bundle.sh       # Tristan.app, with icon, version and an ad-hoc signature
scripts/make-dmg.sh     # dist/Tristan-<version>.dmg and a .sha256 next to it
scripts/install.sh      # build from source, install into /Applications and launch
scripts/install-voices.sh # not part of releases: opens Settings to download an Enhanced voice (the built-in compact ones can crackle)
scripts/setup-ollama.sh # not part of releases: sets up Ollama for local models (see docs/ollama.md)
scripts/setup-ollama.sh --start-only   # only starts Ollama if installed; the app bundles and runs this for the offline fallback
VERSION=2.0.0 scripts/make-dmg.sh   # override the version
```

## What the build does

1. `swift build -c release`.
2. Renders the app icon from the arc reactor (`Tristan --make-icon`), then builds `AppIcon.icns` with `sips` and `iconutil`. A failure here only warns, it never fails the build.
3. Writes `Info.plist` with the version, a build number from the commit count, the usage descriptions for the microphone, speech recognition, notifications and Spotify control, and `LSUIElement` (no Dock icon).
4. Ad-hoc signs with `codesign --sign -`.
5. For the DMG: stages the app next to an `/Applications` shortcut and compresses it with `hdiutil` (UDZO).

## Key constraints

- **Not notarized.** The app is only ad-hoc signed, because notarization needs a paid Apple Developer account. Downloaded copies are quarantined by macOS, so first launch needs the steps in the README. Adding a Developer ID certificate and notarization later would remove them.
- **Xcode is required to build**, even though the project is a Swift package, because SwiftUI's macros are not in the command line tools. The Mac job pins Xcode 16.2 on the `macos-15` runner; the iOS job uses the newest Xcode 16.x (see above).
- **macOS 14 or later** is required to run it.
