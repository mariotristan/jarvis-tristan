# CI and releases

Four GitHub Actions workflows.

| Workflow | File | Trigger | What it does |
|----------|------|---------|--------------|
| CI | `.github/workflows/ci.yml` | Push to `main`, pull requests | Runs the tests, builds the app and a DMG, checks the signature, uploads the DMG as an artifact |
| Secret scan | `.github/workflows/secret-scan.yml` | Push to `main`, pull requests, every Monday, and called by Release | Runs gitleaks over the full git history and fails on any leaked credential |
| Windows | `.github/workflows/windows.yml` | Push to `main`, pull requests, manual | Checks `scripts/setup-ollama.ps1`, builds and tests the core and the `tristan` command on `windows-latest`, runs `tristan.exe` against fake provider CLIs and a mocked Ollama, packages the Windows zip, builds and tests the installer, uploads both |
| Release | `.github/workflows/release.yml` | Push a tag `v*` | Runs the secret scan first; then the Windows job (tests, `Tristan-<version>-windows-x64.zip`, `Tristan-<version>-windows-x64-setup.exe`) and the Mac job (tests, `Tristan-<version>.dmg`); publishes one GitHub Release with generated notes, the DMG, the zip, the installer and a SHA-256 for each |

CI has two jobs. `build-and-test` is the Mac app (above). `ios` builds the iPhone and iPad app in `ios/` and runs its tests on an iPhone simulator. The iOS job uses the **newest Xcode 16.x** on the runner rather than 16.2: the `macos-15` image has no simulator runtime matching Xcode 16.2 (it reports "iOS 18.2 is not installed"), while Xcode 16.4 has the iOS 18.5 runtime. The generated `ios/TristanIOS.xcodeproj` is committed; regenerate it with `cd ios && xcodegen generate` after editing `ios/project.yml` or adding or removing a file under `Sources/TristanCore` or `Sources/Tristan/Shared`. Before building, the `ios` job installs XcodeGen, regenerates the project and fails if the result differs from the committed one, with a message saying to regenerate. The project is generated without intermediate groups (`createIntermediateGroups: false`) so the output does not depend on the name of the checkout folder.

Every CI run leaves a `Tristan-dmg` artifact on the run page, so any build can be installed for testing without a release.

## Windows

The `windows` job of `.github/workflows/windows.yml` runs on `windows-latest` with Swift 6.4.2 (`compnerd/gha-setup-swift`, pinned by commit). Its first step checks `scripts/setup-ollama.ps1` without installing anything: the PowerShell parser finds no errors, and in both `pwsh` and Windows PowerShell 5.1, with no Ollama on `PATH`, `-StartOnly` says Ollama is not installed and exits 0, a full run exits 2 naming `winget install -e --id Ollama.Ollama`, and an unknown parameter or a bad model name fails with a clear message (`setup-ollama.sh --start-only` exits 2 without Ollama; the PowerShell script exits 0). With a do-nothing `ollama.cmd` and the Ollama mock answering on port 11434, a chat reply that is not JSON fails with exit 1 and a clear message. The step also checks `cmdkey /delete` on a made-up `com.tristan.app/...` credential. It then builds `TristanCore` and `tristan`. `swift test --filter` succeeds when the filter matches nothing, so the test steps go through `scripts/ci/check-test-count.ps1`: it keeps the exit code of the tests, adds up the XCTest summary lines of each test executable, prints the count and fails below 200 core or 100 CLI tests. Its self-test (`scripts/ci/check-test-count.tests.ps1`, run just before) feeds it made-up logs with zero tests, too few tests and no summary, and checks each is rejected. The job runs `swift test --filter TristanCoreTests` and `--filter TristanCLITests` through `scripts/ci/check-test-count.ps1`, then drives the built `tristan.exe`:

- against the fake `claude` and `copilot` CLIs in `scripts/ci/fakes` (no real account or secret; the `aws` and `az` fakes there are used by the test suites);
- against `scripts/ci/mock-ollama.ps1`, a stand-in for Ollama on `127.0.0.1` that streams a two-chunk answer. The exe is pointed at it only with `tristan config set ollama.host` and `ollama.model`, `tristan providers` must report Ollama ready, and `tristan run --provider ollama "hello"` must exit 0 with the mock's answer.

`scripts/package-windows.ps1 -Version <version>` then builds `tristan.exe` in release, stamps the version into `Sources/TristanCLICore/BuildVersion.swift` for the build (so `tristan --version` prints it; development builds print `0.0.0-dev`), ships next to it every DLL it needs that Windows does not have (found with `dumpbin /dependents`: the Swift runtime and Foundation DLLs, about 60 MB with ICU, and the Visual C++ runtime; a `-static-stdlib` link fails because the Swift 6.4.2 Windows SDK has no static `curl.lib`), and writes `dist/Tristan-<version>-windows-x64.zip` (`tristan.exe`, those DLLs, `LICENSE.txt`, `THIRD-PARTY-NOTICES.txt`, `README.txt`) and `dist/Tristan-<version>-windows-x64.zip.sha256`. `THIRD-PARTY-NOTICES.txt` is the committed `scripts/THIRD-PARTY-NOTICES.windows.txt`: the licences of the Swift runtime and Foundation, ICU 76, curl 8.9.1, zlib 1.3.1 and Brotli 1.2.0 (linked into `FoundationNetworking.dll`), Swift Crypto with BoringSSL and Swift Argument Parser, each copied verbatim with its source and version. Update it when the Swift toolchain or a package version changes; the packaging script refuses to build without it and CI checks the zip carries it. CI packages version `0.0.0-ci` and uploads both files as the `tristan-windows` artifact, then extracts the zip into an empty folder and runs `tristan --version` and `tristan providers` with only the Windows system folders on `PATH`, and checks the SHA-256. A last step packages with made-up tags (`v9.9.9-test`, `v1.2`, `v1.2.3_rc1` and `v1.2.3-` followed by the Kelvin sign U+212A, which must become `1.2.3--`) using the same lines the release uses to turn a tag into a version, checks each zip name, `tristan --version`, checksum and notices file, and checks that the packaging script refuses a version containing that non-ASCII letter.

### The Windows installer

`scripts/windows/tristan.iss` is an Inno Setup 6 script for `Tristan-<version>-windows-x64-setup.exe`. It installs per user by default, without administrator rights, into `%LocalAppData%\Programs\Tristan`; choosing all users in the wizard or passing `/ALLUSERS` installs into Program Files and asks for administrator rights. It needs 64-bit Windows 10 or later. It installs the staging folder that the zip is made from, so `tristan.exe`, its DLLs, `LICENSE.txt`, `README.txt` and `THIRD-PARTY-NOTICES.txt` are the same files as in the zip. The task "Add Tristan to my PATH" is checked by default. It appends the install folder to `Path` in `HKCU\Environment` (per user) or `HKLM\System\CurrentControlSet\Control\Session Manager\Environment` (all users), only if that folder is not already listed (case-insensitive, ignoring a trailing backslash). It keeps the value's registry type (`REG_EXPAND_SZ` stays `REG_EXPAND_SZ`) and leaves every other entry as it was. A running terminal does not see the change: open a new one. The uninstaller removes the program folder, its Add/Remove Programs entry and only that `Path` entry, and **keeps the user's data**: settings and history in `%APPDATA%\Tristan`, and secrets in Windows Credential Manager. In the wizard, its last message says so. To remove them too, follow "Uninstall" on the Windows page. Installing a newer version with the same fixed `AppId` upgrades in place (same folder, one uninstaller), and nothing needs a restart. Setup never starts `tristan.exe`.

Silent switches (standard Inno Setup):

```text
Tristan-<version>-windows-x64-setup.exe /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CURRENTUSER /TASKS="addtopath" /LOG="setup.log"
  /CURRENTUSER or /ALLUSERS   per user (default) or all users (needs administrator rights)
  /DIR="C:\Tools\Tristan"      install folder (default: the previous one, else %LocalAppData%\Programs\Tristan or Program Files\Tristan)
  /TASKS="addtopath"           add the folder to PATH; /TASKS="" leaves PATH alone
  /LOG="file"                  write a setup log
"%LocalAppData%\Programs\Tristan\unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART   # uninstall
```

`scripts/package-windows-installer.ps1 -Version <version> [-StageDir <folder>] [-OutDir dist]` builds it. It runs after `package-windows.ps1` with the same version, which leaves its staging folder `dist/Tristan-<version>-windows-x64` in place. It checks the version with the same allowlist, checks that the staging folder holds the same files as the zip (names and SHA-256), compiles with `ISCC.exe /DAppVersion=<version> /DStageDir=<folder> /O<OutDir>`, and writes `Tristan-<version>-windows-x64-setup.exe.sha256` in the same `shasum` format as the zip's. The compiler is pinned to **Inno Setup 6.7.3**. An `ISCC.exe` of exactly that version under Program Files is used as it is. Otherwise the script downloads `innosetup-6.7.3.exe` from the Inno Setup GitHub release (`jrsoftware/issrc`, tag `is-6_7_3`), refuses it unless its SHA-256 is the pinned value, installs it silently into a private temporary folder and prints the compiler version. Chocolatey was not used: its community feed adds a second source and rate limits, and the official file with a pinned hash is simpler to audit.

`scripts/ci/test-installer.ps1 -Installer <setup.exe> -Version <version> [-StageDir <folder>]` is the shared proof that `windows.yml` and `release.yml` both run. On the runner, an administrator, it records the HKCU and HKLM `Path` values and their types (it never prints them, only their type and length). It installs silently per user into a new temporary folder with the PATH task, then checks the files against the staging folder byte for byte, `tristan --version`, and that `Path` holds the folder exactly once and is otherwise unchanged, with its type kept. It runs the same installer again without `/DIR`, which must upgrade the same folder. It puts a `settings.json` in `%APPDATA%\Tristan`, or keeps the one already there, and uninstalls with `unins000.exe /VERYSILENT /SUPPRESSMSGBOXES`. The uninstaller re-launches itself from a temporary copy, so the script waits until the folder and the Add/Remove Programs entry are gone. It checks that `Path` equals the recorded value exactly, value and type, and that the settings file is still there. It then installs and uninstalls without the PATH task (`/TASKS=""`, `Path` untouched) and for all users (`/ALLUSERS`, HKLM `Path` gains the folder and gets it back exactly). Every check prints PASS or FAIL. A `finally` uninstalls anything left over and restores both `Path` values and the settings file. The `/LOG` files are uploaded as the `installer-logs` artifact when a step fails. In `windows.yml` this runs for `0.0.0-ci`, whose setup and `.sha256` join the `tristan-windows` artifact, and for the made-up tag `v1.2.3_rc1` through the same lines `release.yml` uses.

What this does not prove: the setup is **not code-signed**, so SmartScreen may warn about it. Only silent installs ran, on Windows Server 2025. Nobody has clicked through the wizard or seen the final uninstall message, and nothing has run on a Windows 10 or 11 desktop. The installer is published since v0.6.1 (the release workflow built it and ran the same installer test before publishing); v0.6.0 has only the zip.

In `release.yml` the `windows` job (read-only token) runs the same tests through the same count check and the packaging script with the version from the tag, extracts the zip and checks `tristan --version` and the SHA-256, builds and tests the installer with the two scripts above, and uploads the zip and the installer as an artifact. The Mac `release` job waits for it (`needs: [secret-scan, windows]`), downloads them and attaches the zip and the installer, each with its `.sha256`, in the same `gh release create` as the DMG. One release carries all of them, and a failed Windows build or installer test stops the release. Any `v*` tag works, as for the DMG: the leading `v` is dropped and every character other than a letter, digit, dot or dash becomes a dash (`v1.2.3` gives `1.2.3`, `v1.2` gives `1.2`, `v1.2.3_rc1` gives `1.2.3-rc1`, a bare `v` gives `0.0.0`). Only a version that still does not start with a letter or digit (for example the tag `v-1`) stops the Windows job, and with it the release. `release.yml` has run twice with the Windows job. First for `v0.6.0` (2026-11-07, [run 42409091093](https://github.com/mariotristan/jarvis-tristan/actions/runs/42409091093), from commit `6146693` on `main`), which published the DMG, the zip and both checksums. Then for `v0.6.1` (2026-11-07, [run 42425315224](https://github.com/mariotristan/jarvis-tristan/actions/runs/42425315224), from commit `38c90d4` on `main`), which built the installer, ran the same installer test as `windows.yml` (silent install, upgrade, uninstall, PATH, all users, user data kept) and published the DMG, the zip and the installer with a checksum each. The three v0.6.1 checksums were downloaded and verified on a Mac. Running the extracted `tristan.exe`, or the installer, on a pristine Windows 10 or 11 desktop is still unverified, as is the installer's wizard. The same lines also run in `windows.yml` on every push.

`main` is protected: changes land only by pull request, and the checks `build-and-test`, `ios`, `windows` and `gitleaks` are required.

### Which jobs run

Each job runs only when the files it builds changed. CI and Windows always start (a workflow skipped by a path filter would leave its required checks waiting forever); their first job, `changes-ci` or `changes-windows` (ubuntu, about 15 seconds), lists the files the change brings (`git diff HEAD^1 HEAD` of the pull request's merge commit, or of a push that added one commit) and runs `scripts/ci/changed-paths.sh`. Its rules are a table at the top of that script; in short:

| Changed | `build-and-test` | `ios` | `windows` |
|---------|:-:|:-:|:-:|
| `docs/`, top-level `*.md`, `.gitignore` | | | |
| `Sources/Tristan/` (not `Shared/`), `Tests/TristanTests/`, `scripts/*.sh` | yes | | |
| `Sources/Tristan/Shared/` | yes | yes | |
| `ios/` | | yes | |
| `Sources/TristanCLICore/`, `Sources/TristanCLI/`, `Tests/TristanCoreTests/`, `Tests/TristanCLITests/` | yes | | yes |
| `scripts/*.ps1`, `scripts/ci/`, `scripts/windows/`, the Windows notices, `LICENSE`, `windows.yml`, `release.yml` | | | yes |
| `ci.yml` | yes | yes | |
| `Sources/TristanCore/`, `Package.swift`, `Package.resolved`, `VERSION`, the classifier scripts, anything else | yes | yes | yes |

A job skipped this way shows as skipped and counts as passing. Docs-only changes run only the secret scan and the two classifier jobs; the three build jobs are skipped. It is fail safe: if the `changes-*` job fails, its self-test (`scripts/ci/test-changed-paths.sh`, run first) fails, the event is not a pull request or a single-commit push, or no files are found, every job runs. `gitleaks` always runs. `windows-spike` runs only when started by hand (Actions, Windows, Run workflow), and a newer push to a pull request cancels its older runs, never runs on `main`.

## Publishing a release

```bash
# 1. Make sure CI is green on main (main is protected: changes land by pull request, and build-and-test, ios, windows and gitleaks must all pass).
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
pwsh -File scripts\setup-ollama.ps1    # Windows: checks for Ollama (prints the winget command if missing), starts it, pulls a model, sets it for tristan
pwsh -File scripts\package-windows.ps1 -Version 1.2.3   # Windows: dist\Tristan-1.2.3-windows-x64.zip and its .sha256 (see "Windows" above)
pwsh -File scripts\package-windows-installer.ps1 -Version 1.2.3   # then dist\Tristan-1.2.3-windows-x64-setup.exe and its .sha256 (see "The Windows installer")
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
