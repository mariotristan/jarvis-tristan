# CI and releases

Four GitHub Actions workflows.

| Workflow | File | Trigger | What it does |
|----------|------|---------|--------------|
| CI | `.github/workflows/ci.yml` | Push to `main`, pull requests | Runs the tests, builds the app and a DMG, checks the signature, uploads the DMG as an artifact |
| Secret scan | `.github/workflows/secret-scan.yml` | Push to `main`, pull requests, every Monday, and called by Release | Runs gitleaks over the full git history and fails on any leaked credential |
| Windows | `.github/workflows/windows.yml` | Push to `main` or `windows-cli`, pull requests, manual | Builds and tests the core and the `tristan` command on `windows-latest`, runs `tristan.exe` against fake provider CLIs and a mocked Ollama, packages and uploads the Windows zip |
| Release | `.github/workflows/release.yml` | Push a tag `v*` | Runs the secret scan first; then the Windows job (tests, `Tristan-<version>-windows-x64.zip`) and the Mac job (tests, `Tristan-<version>.dmg`); publishes one GitHub Release with generated notes, the DMG, the zip and a SHA-256 for each |

CI has two jobs. `build-and-test` is the Mac app (above). `ios` builds the iPhone and iPad app in `ios/` and runs its tests on an iPhone simulator. The iOS job uses the **newest Xcode 16.x** on the runner rather than 16.2: the `macos-15` image has no simulator runtime matching Xcode 16.2 (it reports "iOS 18.2 is not installed"), while Xcode 16.4 has the iOS 18.5 runtime. The generated `ios/TristanIOS.xcodeproj` is committed, so CI does not need XcodeGen; regenerate it with `cd ios && xcodegen generate` after editing `ios/project.yml`.

Every CI run leaves a `Tristan-dmg` artifact on the run page, so any build can be installed for testing without a release.

## Windows

The `windows` job of `.github/workflows/windows.yml` runs on `windows-latest` with Swift 6.4.2 (`compnerd/gha-setup-swift`, pinned by commit). It builds `TristanCore` and `tristan`, runs `swift test --filter TristanCoreTests` and `--filter TristanCLITests`, then drives the built `tristan.exe`:

- against the fake `claude`, `copilot`, `aws` and `az` CLIs in `scripts/ci/fakes` (no real account or secret);
- against `scripts/ci/mock-ollama.ps1`, a stand-in for Ollama on `127.0.0.1` that streams a two-chunk answer. The exe is pointed at it only with `tristan config set ollama.host` and `ollama.model`, `tristan providers` must report Ollama ready, and `tristan run --provider ollama "hello"` must exit 0 with the mock's answer.

`scripts/package-windows.ps1 -Version <version>` then builds `tristan.exe` in release, stamps the version into `Sources/TristanCLICore/BuildVersion.swift` for the build (so `tristan --version` prints it; development builds print `0.0.0-dev`), ships next to it every DLL it needs that Windows does not have (found with `dumpbin /dependents`: the Swift runtime and Foundation DLLs, about 60 MB with ICU, and the Visual C++ runtime; a `-static-stdlib` link fails because the Swift 6.4.2 Windows SDK has no static `curl.lib`), and writes `dist/Tristan-<version>-windows-x64.zip` (`tristan.exe`, those DLLs, `LICENSE.txt`, `THIRD-PARTY-NOTICES.txt`, `README.txt`) and `dist/Tristan-<version>-windows-x64.zip.sha256`. `THIRD-PARTY-NOTICES.txt` is the committed `scripts/THIRD-PARTY-NOTICES.windows.txt`: the licences of the Swift runtime and Foundation, ICU 76, curl 8.9.1, zlib 1.3.1 and Brotli 1.2.0 (linked into `FoundationNetworking.dll`), Swift Crypto with BoringSSL and Swift Argument Parser, each copied verbatim with its source and version. Update it when the Swift toolchain or a package version changes; the packaging script refuses to build without it and CI checks the zip carries it. CI packages version `0.0.0-ci` and uploads both files as the `tristan-windows` artifact, then extracts the zip into an empty folder and runs `tristan --version` and `tristan providers` with only the Windows system folders on `PATH`, and checks the SHA-256. A last step packages with made-up tags (`v9.9.9-test`, `v1.2`, `v1.2.3_rc1`) using the same lines the release uses to turn a tag into a version, and checks each zip name, `tristan --version` and checksum.

In `release.yml` the `windows` job (read-only token) runs the same tests and the packaging script with the version from the tag, extracts the zip and checks `tristan --version` and the SHA-256, and uploads the zip as an artifact. The Mac `release` job waits for it (`needs: [secret-scan, windows]`), downloads the zip and attaches it with its `.sha256` in the same `gh release create` as the DMG, so one release carries both and a failed Windows build stops the release. Any `v*` tag works, as for the DMG: the leading `v` is dropped and every character other than a letter, digit, dot or dash becomes a dash (`v1.2.3` gives `1.2.3`, `v1.2` gives `1.2`, `v1.2.3_rc1` gives `1.2.3-rc1`, a bare `v` gives `0.0.0`). Only a version that still does not start with a letter or digit (for example the tag `v-1`) stops the Windows job, and with it the release.

## Publishing a release

```bash
# 1. Make sure CI is green on main.
# 2. Tag the commit you want to ship. The tag is the version (v1.2.3 gives version 1.2.3).
git tag v1.2.3
git push origin v1.2.3
```

The release appears under **Releases** once both the Mac and the Windows jobs have finished (the Windows build and tests take longer than the Mac ones). Also bump the `VERSION` file when you cut a release so local builds report the same number.

## Building locally

```bash
scripts/bundle.sh       # Tristan.app, with icon, version and an ad-hoc signature
scripts/make-dmg.sh     # dist/Tristan-<version>.dmg and a .sha256 next to it
scripts/install.sh      # build from source, install into /Applications and launch
scripts/uninstall.sh    # quit and remove installed copies; --purge adds settings, history and Keychain items, --build removes build output, --dry-run only lists
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
