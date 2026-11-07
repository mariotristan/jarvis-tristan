# Windows Terminal Version Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `tristan` command that runs missions on Windows 10/11 with all five providers (Claude Code, Copilot, Bedrock, Azure OpenAI, Ollama), approving actions in the terminal, while the Mac and iOS apps keep working.

**Architecture:** Split the portable code into a `TristanCore` library target that builds on macOS, iOS (by path inclusion) and Windows. Platform differences sit behind small seams (settings, secrets, process launching, shell, crypto, approval transport) chosen at compile time. A new `TristanCLI` executable (`tristan`) sits on the core.

**Tech Stack:** Swift 5.9 tools (current stable Swift on Windows), SwiftPM, swift-crypto (Windows only), swift-argument-parser, `WinSDK` for Credential Manager and Winsock, GitHub Actions `windows-latest`.

**Spec:** `docs/superpowers/specs/2026-11-06-windows-cli-design.md`

## Global Constraints
- Targets Windows 10/11 x64. ARM64, a Windows GUI, voice, Spotify, notifications, launch at login, Windows Hello, the iPhone remote link to a Windows host, and an installer are out of scope.
- All five providers are required; none is deferred. If `URLSession` cannot stream on Windows, pick the replacement HTTP client yourself (Task 5).
- One copy of the agent loop, providers and approval logic, used by the Mac app and the CLI. No forked core.
- The Mac app's behaviour, look and tests stay unchanged; `swift test` and the iOS CI job stay green after every task.
- The iOS project keeps compiling `Sources/Tristan/Shared` and the portable part of `Sources/TristanCore` by path (`ios/project.yml`); moving iOS onto the library is out of scope.
- `auto` mode on Windows must never approve a command the Mac would ask about. Mac policy tests are written first and the same cases run with Windows inputs. Windows keeps the Mac rule: a plain program name not on the never-generalise list can be generalised; anything with an operator always asks.
- `run_command` runs PowerShell (`pwsh` if present, else `powershell.exe`) on Windows.
- Approval channel on Windows: localhost TCP with a one-time random token. The token reaches the Claude Code MCP shim through the `env` block of the generated MCP config, never the command line; the config lives in a per-run folder only the current user can read.
- Secrets: Windows Credential Manager through `WinSDK` calls (`CredReadW`, `CredWriteW`, `CredDeleteW`); never shell out with a secret as an argument; no secrets in plain files or the repo. (The spec said "C interop target"; `import WinSDK` meets its intent with less code.)
- Settings on Windows: JSON file `%APPDATA%\Tristan\settings.json`, same keys as the Mac's `UserDefaults`.
- `ask` mode with no terminal attached (stdin not a TTY) denies every action needing approval and the run exits non-zero. `--yes-routine` (Auto) and `--yolo` must be explicit flags.
- Kids mode in the CLI: `tristan kids on|off|set-pin` uses the same `kidsMode` key and PIN hash as the Mac app; with kids mode on, only Ollama answers and cloud providers are refused.
- Names: library `TristanCore`, executable `tristan`, CLI target `TristanCLI`.
- Mac builds and tests need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. Commit messages follow the repo style (`Area: summary`) and end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`.

## Review Focus
1. **Folder containment with Windows paths:** `c:\work\proj\a.txt` is inside `C:\Work\Proj`; `C:\Work\Proj-evil\a.txt`, `C:\Work\Proj\..\Other`, and a UNC `\\server\share\Proj` are not. (Task 8)
2. **`SafePath.real` must terminate and not return nil for a drive root** (`C:\`), where `deleteLastPathComponent` never reaches `"/"`. (Task 8)
3. **Command names with case, extension and PowerShell syntax:** `DEL.EXE x`, `Remove-Item x`, `iex`, `Get-Item $(x)`, a backtick, `{ }` blocks and `-EncodedCommand` must not generalise into an Always-allow rule or run unasked in Auto. (Task 8)
4. **Arguments with spaces, quotes, `%`, `^`, `&` and non-ASCII text passed to `.cmd` shims** (`copilot.cmd`, `az.cmd`): cmd.exe would interpret them. Resolve the shim to its real target or refuse unsafe arguments. (Task 6)
5. **Ctrl+C and cancel must stop the whole provider process tree**, not leave `node`/`claude` children running and holding the working folder. (Task 11)

---

### Task 0: Spike on the Windows machine
Throwaway work outside the repo; only the notes are kept.

**Files:**
- Create: `docs/superpowers/specs/2026-11-06-windows-spike-notes.md`

**Interfaces:**
- Produces: a written answer to four questions that later tasks read: (a) Swift version installed; (b) does the portable code (Task 2's file list) compile on Windows; (c) does `URLSession.shared.bytes(for:)` deliver chunks as they arrive from a streaming server (SSE, Ollama NDJSON) and is `FoundationNetworking` complete enough; (d) does `Foundation.Process` launch `copilot.cmd`, `az.cmd`, `claude` and `aws` found on `PATH`.

- [ ] **Step 1:** In a scratch SwiftPM package (scratchpad folder), copy `AgentLoop.swift`, `AgentTypes.swift`, `AgentTools.swift`, `OllamaProvider.swift`, `ConversationMemory.swift`, `Models.swift` and build with `swift build` on Windows; list every compile error by file.
- [ ] **Step 2:** Write a 30-line client that streams `http://localhost:11434/api/chat` and prints the arrival time of each chunk. Pass means the first chunk arrives well before the last (not all at the end).
- [ ] **Step 3:** Launch each of `copilot`, `az`, `claude`, `aws` with `--version` through `Process` using a bare name, then a resolved full path; record which forms work.
- [ ] **Step 4:** Write the notes. If (c) fails, name the replacement client: try AsyncHTTPClient first, then a thin WinHTTP wrapper; choose the first one whose chunk-timing test from Step 2 passes. Record the choice.
- [ ] **Step 5:** `git add docs/superpowers/specs/2026-11-06-windows-spike-notes.md && git commit -m "Docs: Windows spike notes (toolchain, streaming, process launching)"`

### Task 1: Pin today's policy behaviour with Mac tests
**Files:**
- Create: `Tests/TristanTests/PolicyTests.swift`

**Interfaces:**
- Consumes: `ApprovalRule.make(tool: String, input: [String: Any], workingDirectory: URL) -> ApprovalRule?`, `ToolPolicy(mode:).needsApproval(tool:rule:) -> Bool`, `SafePath.real(_ url: URL) -> String?`, `ToolSandbox(root:).resolve(_ path: String) -> URL?`
- Produces: the characterization suite later tasks must keep green (Task 8 extends it with Windows inputs).

- [ ] **Step 1:** Write tests that pass against the current code: `testBashPlainProgramGeneralises` (`ls -la` gives key `Bash:ls`), `testBashOperatorsNeverGeneralise` (one case each for `;`, `&`, `|`, `>`, `<`, backtick, `$(`, newline, backslash), `testNeverGeneraliseList` (every name in the list returns nil), `testEditInsideFolderGeneralises` and `testEditOutsideFolderDoesNot` (including `../x` and a sibling `Proj-evil`), `testAutoModeAsksForRiskyAndAllowsPlain` (`ToolPolicy(mode: .auto)` with `run_command`: nil rule asks, non-nil rule does not; `.ask` always asks; `.yolo` never asks), `testSandboxRejectsSymlinkEscape`.
- [ ] **Step 2:** Run `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PolicyTests`. Expected: all pass. A failure means the test misdescribes today's behaviour: fix the test, not the code.
- [ ] **Step 3:** `git add Tests/TristanTests/PolicyTests.swift && git commit -m "Tests: pin the approval policy and sandbox before the core split"`

### Task 2: Split out `TristanCore`
**Files:**
- Modify: `Package.swift`, `ios/project.yml`, `.github/workflows/ci.yml`
- Move (git mv) into `Sources/TristanCore/`: `Shared/{AgentTypes,Models,AgentLoop,AgentTools,OllamaProvider,AzureProvider,BedrockBackend,BedrockStreaming,ConversationMemory,HistoryStore,Keychain}.swift`; into `Sources/TristanCore/Processes/`: `ClaudeCodeProvider` (the struct and `ClaudeStream`, extracted from `Providers.swift`), `CopilotProvider.swift`, `BedrockProvider.swift`, `PermissionBridge.swift`, and `ParentPIN` (extracted from `KidsMode.swift` into `ParentPIN.swift`, directly in `Sources/TristanCore/`)
- Stay in `Sources/Tristan/Shared/` (Apple-only: SwiftUI or Network): `Theme`, `Themes`, `Markdown`, `RemoteClient`, `RemoteTransport`, `RemoteProtocol`. (Scoping call: the Markdown parser and theme data stay here this milestone because the plain-text CLI does not render them; split them when a TUI needs them.)
- Move tests that compile against core only into `Tests/TristanCoreTests/`: `AzureTests`, `BedrockTests`, `BedrockStreamingTests`, `CopilotTests`, `OllamaTests`, `PolicyTests`, and any other test file that needs neither AppKit, SwiftUI nor Network.

**Interfaces:**
- Produces: library target `TristanCore`; Swift `package` access on every core declaration the Mac target uses; the directory rule that `Sources/TristanCore/Processes/` holds everything built on `Process` or sockets (iOS excludes it).

- [ ] **Step 1:** `Package.swift`: add `.target(name: "TristanCore", path: "Sources/TristanCore")`; make `Tristan` depend on it (`Sources/Tristan/Shared` stays inside the `Tristan` target); add `.testTarget(name: "TristanCoreTests", dependencies: ["TristanCore"])`; the app tests keep `@testable import Tristan` and add `@testable import TristanCore`.
- [ ] **Step 2:** Do the moves above with `git mv`. Build; for each "cannot find X in scope" or "X is inaccessible" error in `Sources/Tristan`, add `package` to that declaration in the core (prefix top-level types, `package extension` for extensions, `package` on members and `init`s). Repeat until `swift build` passes.
- [ ] **Step 3:** `ios/project.yml`: keep `../Sources/Tristan/Shared`; add `../Sources/TristanCore` with `excludes: ["Processes/**"]`. Regenerate with `cd ios && xcodegen generate`. Wherever core files call `Process` or sockets outside `Processes/`, guard with `#if !os(iOS)` (they already use `#if os(macOS)`; leave those as they are for now).
- [ ] **Step 4:** Run `swift test` (all targets) and `scripts/bundle.sh`. Expected: tests pass, `Tristan.app` builds. Run the iOS CI steps locally if possible, else push the branch and read the `ios` job.
- [ ] **Step 5:** `git add -A && git commit -m "Core: split the portable code into a TristanCore library"`

### Task 3: Settings seam
**Files:**
- Create: `Sources/TristanCore/Settings.swift`, `Tests/TristanCoreTests/SettingsTests.swift`
- Modify: `OllamaProvider.swift`, `AzureProvider.swift`, `BedrockBackend.swift`, `CopilotProvider.swift` (every `UserDefaults.standard` read in the core)

**Interfaces:**
- Produces: `protocol SettingsBackend: AnyObject { func object(forKey: String) -> Any?; func set(_ value: Any?, forKey: String) }`; `final class UserDefaultsBackend: SettingsBackend`; `final class JSONFileBackend: SettingsBackend { init(url: URL) }` (writes atomically, creates the folder); `enum Settings { nonisolated(unsafe) static var backend: SettingsBackend; static func string(_ key: String) -> String?; static func bool(_ key: String) -> Bool; static func data(_ key: String) -> Data?; static func set(_ value: Any?, forKey: String) }`. Default backend: `UserDefaultsBackend` on Apple, `JSONFileBackend` at `%APPDATA%\Tristan\settings.json` on Windows.

- [ ] **Step 1:** Write `testJSONFileBackendRoundTrip` (set a string, a bool and a Data value; a new backend at the same URL reads them back), `testSettingsSurvivesMissingFile`, `testOllamaConfigReadsThroughSettings` (swap `Settings.backend` for an in-memory one holding `ollama.host`/`ollama.model` and check `OllamaConfig.load()`).
- [ ] **Step 2:** Run `swift test --filter SettingsTests`. Expected: FAIL (no `Settings`).
- [ ] **Step 3:** Implement the types above; replace `UserDefaults.standard` in the four core files with `Settings`. The Mac app keeps using `UserDefaults.standard` directly; both resolve to the same store on Apple.
- [ ] **Step 4:** `swift test`. Expected: all pass.
- [ ] **Step 5:** Commit: `Core: settings seam with a JSON file backend for Windows`

### Task 4: Crypto seam
**Files:**
- Modify: `Package.swift`, `Sources/TristanCore/BedrockStreaming.swift`, `Sources/TristanCore/ParentPIN.swift`
- Test: `Tests/TristanCoreTests/BedrockStreamingTests.swift`, `Tests/TristanCoreTests/ParentPINTests.swift`

**Interfaces:**
- Consumes: `ParentPIN.hash(_ pin: String) -> String`.
- Produces: `#if canImport(CryptoKit) import CryptoKit #else import Crypto #endif` in both files; `swift-crypto` as a dependency of `TristanCore` only on `.windows` and `.linux`.

- [ ] **Step 1:** Add `ParentPINTests.testHashIsStable`: `ParentPIN.hash("1234")` equals the value the current code produces (compute it once on the Mac and paste the hex into the test). Existing SigV4 tests are the oracle for signing.
- [ ] **Step 2:** `Package.swift`: `.package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")` and `.product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.windows, .linux]))`.
- [ ] **Step 3:** Swap the imports as above; `HMAC<SHA256>` and `SHA256` have the same API in both.
- [ ] **Step 4:** `swift test`. Expected: pass. Commit: `Core: swift-crypto where CryptoKit is missing`

### Task 5: HTTP streaming seam (only if Task 0 says `URLSession` cannot stream on Windows)
If the spike notes say streaming works, write "skipped: streaming works" in the spike notes, commit that line, and move on.

**Files:**
- Create: `Sources/TristanCore/HTTPStreaming.swift`, `Tests/TristanCoreTests/HTTPStreamingTests.swift`
- Modify: `OllamaProvider.swift`, `AzureProvider.swift`, `BedrockStreaming.swift`

**Interfaces:**
- Produces: `protocol HTTPStreamer: Sendable { func lines(for request: URLRequest) async throws -> (status: Int, lines: AsyncThrowingStream<String, Error>) }` with `URLSessionStreamer` (Apple) and the replacement chosen in Task 0 (Windows); `HTTPStreamers.default`.

- [ ] **Step 1:** Write `testStreamsLinesIncrementally` against a local test server that writes one line, waits 300 ms, writes another: the first line arrives before 250 ms; and `testReportsStatusAndErrorBody` (HTTP 401 with a JSON body).
- [ ] **Step 2:** Run it; expected FAIL. Implement both streamers; route the three providers' `session.bytes(for:)` calls through `HTTPStreamers.default`.
- [ ] **Step 3:** `swift test` (Mac) and run the new tests on Windows. Expected: pass. Commit: `Core: HTTP streaming seam for Windows`

### Task 6: Process launcher
**Files:**
- Create: `Sources/TristanCore/Processes/ProcessLauncher.swift`, `Tests/TristanCoreTests/ProcessLauncherTests.swift`
- Modify: every `/usr/bin/env` and Homebrew `PATH` site: `ClaudeCodeProvider`, `CopilotProvider`, `BedrockProvider`, `Connectivity.swift`, `AzureProvider` (`azureCLIToken`), `BedrockStreaming` (`AWSCLICredentials`), `AgentTools` (Task 7 finishes that one)

**Interfaces:**
- Produces: `struct ToolNotFound: Error { let name: String }`; `struct UnsafeArguments: Error { let tool: String }`; `enum ExecutableResolver { static func resolve(_ name: String, searchPath: [String], pathExt: [String], isFile: (String) -> Bool, windows: Bool) -> String? }` (a name containing a path separator is returned as is; on Windows try each `PATHEXT` suffix when the name has none); `enum CmdShimGuard { static func isSafe(_ arguments: [String]) -> Bool }` (false if any argument contains `%`, `^`, `&`, `|`, `<`, `>`, `"`, `\n` or `\r`); `enum ProcessLauncher { static func prepare(_ tool: String, _ arguments: [String], directory: URL?, extraEnvironment: [String: String]) throws -> Process }` — resolves the tool, adds the Homebrew paths to `PATH` on Mac only, and for a Windows `.cmd`/`.bat` target first tries to read the npm shim and run `node <script>` directly, else throws `UnsafeArguments` when `CmdShimGuard.isSafe` is false.

- [ ] **Step 1:** Write tests with Windows-style inputs that run on the Mac: `testResolvesCmdThroughPathExt` (`copilot` + `[".EXE", ".CMD"]` finds `C:\npm\copilot.cmd`), `testPathWithSeparatorIsNotSearched`, `testMacResolutionUnchanged` (`aws` found in `/opt/homebrew/bin`), `testCmdShimGuardRejectsMetacharacters` (each of the nine inputs above is unsafe; `"fix the login bug"` and non-ASCII text are safe), `testNotFoundThrowsToolNotFound`.
- [ ] **Step 2:** Run `swift test --filter ProcessLauncherTests`; expected FAIL.
- [ ] **Step 3:** Implement. Replace each site's `Process()` + `executableURL` + `PATH` lines with `ProcessLauncher.prepare`; map `ToolNotFound` to each provider's existing "not found / install it" message, with `winget` hints on Windows and `brew` on Mac (keep Mac wording unchanged). `CopilotProvider.launchOverride` stays for tests.
- [ ] **Step 4:** `swift test`; expected all pass (provider tests use overrides). Manually run one Mac mission with Ollama to confirm launching still works.
- [ ] **Step 5:** Commit: `Core: launch CLI tools through one launcher that understands PATHEXT and cmd shims`

### Task 7: Shell runner and `run_command` everywhere
**Files:**
- Create: `Sources/TristanCore/Processes/ShellRunner.swift`, `Tests/TristanCoreTests/ShellRunnerTests.swift`
- Modify: `Sources/TristanCore/AgentTools.swift` (the `#if os(macOS)` around `run` and `shellTools`)

**Interfaces:**
- Produces: `enum ShellFlavor { case posix, powershell; static var current: ShellFlavor; var ruleToolName: String }` (`"Bash"` / `"PowerShell"`); `enum ShellRunner { static func command(for text: String, flavor: ShellFlavor) -> (tool: String, arguments: [String]) }` — posix: `("/bin/zsh", ["-c", text])`; powershell: `("pwsh" or "powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", text])`; `AgentToolSpec.definitions` offers `run_command` on macOS and Windows with the shell named in its description ("zsh" / "PowerShell"); never on iOS.

- [ ] **Step 1:** Write `testPosixCommand`, `testPowerShellCommandArguments`, `testToolSpecNamesTheShell`, and `testRunCommandCapturesOutputAndExitStatus` (macOS only: `echo hi` returns text containing `hi` and `[exit status 0]`; a failing command has `isError`).
- [ ] **Step 2:** Run; expected FAIL. Implement; change the guards from `#if os(macOS)` to `#if !os(iOS)` and make `ToolSandbox.run` use `ShellRunner` + `ProcessLauncher.prepare`.
- [ ] **Step 3:** In `AgentLoop`, build run-command rules with `ShellFlavor.current.ruleToolName` (verify how the loop calls `ApprovalRule.make` today and keep Mac output identical).
- [ ] **Step 4:** `swift test`; commit: `Core: run_command through zsh or PowerShell`

### Task 8: Windows-aware policy and path containment
**Files:**
- Modify: `Sources/TristanCore/AgentTypes.swift` (`ApprovalRule`), `Sources/TristanCore/AgentTools.swift` (`SafePath`, `ToolSandbox.resolve`)
- Create: `Sources/TristanCore/PathContainment.swift`
- Test: `Tests/TristanCoreTests/PolicyTests.swift` (extend), `Tests/TristanCoreTests/PathContainmentTests.swift`

**Interfaces:**
- Consumes: `ShellFlavor` (Task 7).
- Produces: `enum PathFlavor { case posix, windows; static var current: PathFlavor }`; `enum PathContainment { static func contains(root: String, path: String, flavor: PathFlavor) -> Bool }` (windows: case-insensitive, `\` and `/` equal, drive letters, trailing separators ignored, UNC roots only contain the same share, never matches on string prefix alone); `ShellFlavor.neverGeneralise: Set<String>` (posix: today's list; powershell adds `del`, `erase`, `rd`, `rmdir`, `remove-item`, `ri`, `invoke-expression`, `iex`, `invoke-webrequest`, `iwr`, `invoke-restmethod`, `irm`, `curl`, `curl.exe`, `wget`, `powershell`, `pwsh`, `cmd`, `reg`, `format`, `taskkill`, `stop-process`, `start-process`, `set-executionpolicy`, `net`, `netsh`, `schtasks`, `sc`, `bitsadmin`, `certutil`, `mshta`, `wscript`, `cscript`, `rundll32`, `regsvr32`, `ssh`, `scp`, `sh`, `bash`, `env`, `xargs`); `ShellFlavor.operators: [String]` (powershell adds `$`, `{`, `}`, `@(`, `-encodedcommand` matched case-insensitively, `\r`). `ApprovalRule.make` picks the flavor from the tool name (`"Bash"` posix, `"PowerShell"` powershell) and compares program names lower-cased with `.exe`, `.cmd`, `.bat`, `.ps1` stripped for the PowerShell flavor.

- [ ] **Step 1:** Write tests (they run on the Mac with Windows strings): `testWindowsContainmentCaseAndSeparators` (`c:/work/proj/a.txt` inside `C:\Work\Proj`), `testWindowsSiblingPrefixIsOutside` (`C:\Work\Proj-evil\a.txt`), `testWindowsDotDotEscapes`, `testUNCOnlyMatchesSameShare`, `testPowerShellNeverGeneralise` (`DEL.EXE x`, `Remove-Item x`, `iex`, `Invoke-WebRequest u` all nil), `testPowerShellOperatorsNeverGeneralise` (`Get-Item $(x)`, backtick, `{ x }`, `x -EncodedCommand y`, `a; b`), `testPowerShellPlainProgramGeneralises` (`git status` gives key `PowerShell:git`), `testSafePathRealTerminatesAtDriveRoot` (feed `SafePath.real` a path whose ancestors never exist: it returns within one second and does not return nil for an existing root), and re-run all Task 1 tests unchanged.
- [ ] **Step 2:** Run; expected FAIL on the new tests.
- [ ] **Step 3:** Implement. `SafePath.real` stops when `deleteLastPathComponent` no longer changes the path (not only at `"/"`); `ToolSandbox.resolve` and `ApprovalRule.make` call `PathContainment.contains` instead of `hasPrefix(root + "/")`; accept `C:\...` as absolute in `resolve` when `PathFlavor.current == .windows`. Rule keys for Bash keep their current format so saved Mac rules still match.
- [ ] **Step 4:** `swift test`; expected all pass, including Task 1's suite.
- [ ] **Step 5:** Commit: `Core: Windows-aware approval policy and folder containment`

### Task 9: Approval transport (Unix socket or loopback TCP) and the MCP shim
**Files:**
- Create: `Sources/TristanCore/Processes/ApprovalTransport.swift`, `Tests/TristanCoreTests/ApprovalTransportTests.swift`
- Modify: `PermissionBridge.swift`, `ClaudeCodeProvider` (MCP config), CLI/app entry points that handle `--mcp-permission`

**Interfaces:**
- Produces: `protocol ApprovalConnection: AnyObject { func readLine() -> String?; func writeLine(_ text: String); func close() }`; `protocol ApprovalListener: AnyObject { var endpoint: String { get }; var token: String? { get }; func accept() -> ApprovalConnection?; func close() }`; `enum ApprovalTransport { static func listen(directory: URL) -> ApprovalListener?; static func connect(endpoint: String, token: String?) -> ApprovalConnection? }`. Endpoints are `unix:<path>` or `tcp:127.0.0.1:<port>`. Default on Windows is TCP; elsewhere Unix. `LoopbackListener` (POSIX sockets, Winsock under `#if os(Windows)`) binds `127.0.0.1` on an ephemeral port, generates a 256-bit random hex token, and `accept()` drops any connection whose first line is not the token. The shim reads `TRISTAN_APPROVAL_TOKEN` from its environment.

- [ ] **Step 1:** Write tests that use the TCP implementation directly (so they run on the Mac): `testLoopbackRoundTrip` (a client sends the token then a line; the server reads it and replies), `testWrongTokenIsDropped` (a client with a wrong token gets nothing and the next valid client is still accepted), `testListensOnLoopbackOnly` (bound address is `127.0.0.1`), `testUnixTransportStillRoundTrips`.
- [ ] **Step 2:** Run; expected FAIL.
- [ ] **Step 3:** Implement. Refactor `PermissionServer` and the MCP shim to use `ApprovalListener`/`ApprovalConnection` instead of `UnixSocket` file descriptors (keep `UnixSocket` as the Unix implementation). `ClaudeCodeProvider` writes the MCP config with `"args": ["--mcp-permission", listener.endpoint]` and, when a token exists, `"env": ["TRISTAN_APPROVAL_TOKEN": token]`; replace `Bundle.main.executablePath` with `CommandLine.arguments[0]` resolved to an absolute path. On Windows create the per-run folder and restrict it to the current user (inheritance removed, one allow ACE for the user).
- [ ] **Step 4:** `swift test`; also run one Mac mission with Claude Code in `ask` mode to confirm approvals still arrive. Commit: `Core: approval transport with a token-protected loopback option`

### Task 10: Build the core on Windows, Credential Manager, Windows CI
**Files:**
- Create: `Sources/TristanCore/Processes/WindowsCredentialStore.swift`, `.github/workflows/windows.yml`
- Modify: `Sources/TristanCore/Keychain.swift`; any core file that fails to compile on Windows
- Test: `Tests/TristanCoreTests/KeychainTests.swift`

**Interfaces:**
- Produces: `KeychainStore.get(_ account: String) -> String?` and `KeychainStore.set(_ value: String, account: String) -> Bool` keep their signatures; `#if canImport(Security)` uses the Keychain, `#elseif os(Windows)` uses `WindowsCredentialStore` (target names `com.tristan.app/<account>`; an empty value deletes); `NoKeychain` and the in-memory path stay.

- [ ] **Step 1:** Write `KeychainTests.testSetGetDeleteRoundTrip` (using `NoKeychain.enabled = false` on Windows only, `#if os(Windows)`; on the Mac the test uses the in-memory path) and `testEmptyValueDeletes`.
- [ ] **Step 2:** On the Windows machine run `swift build --target TristanCore`; fix each compile error. Typical causes: `import Darwin`, `Security`, `Network` outside `#if canImport`; `#if os(macOS)` guards that should be `#if !os(iOS)`; `posixPermissions` attributes (skip them on Windows); `lstat`-style APIs. Keep every change a small `#if`, never a copy of a file.
- [ ] **Step 3:** Implement `WindowsCredentialStore` with `CredReadW`, `CredWriteW` (type `CRED_TYPE_GENERIC`, persist `CRED_PERSIST_LOCAL_MACHINE`), `CredDeleteW` and `CredFree`.
- [ ] **Step 4:** `.github/workflows/windows.yml`: on push to `main` and pull requests, `windows-latest`, install Swift with `compnerd/gha-setup-swift` (read its README for current inputs and pin a released tag), run `swift build` and `swift test --filter TristanCoreTests`. Expected on Windows: core tests pass.
- [ ] **Step 5:** Run the Mac `swift test` and the iOS job; commit: `Core: build on Windows, Credential Manager secrets, Windows CI`

### Task 11: The `tristan` command: `providers` and `run`, with terminal approvals
**Files:**
- Modify: `Package.swift` (add `swift-argument-parser` from `1.3.0`, target `TristanCLI`, product `tristan`)
- Create: `Sources/TristanCLI/main.swift`, `Sources/TristanCLI/RunCommand.swift`, `Sources/TristanCLI/ProvidersCommand.swift`, `Sources/TristanCLI/TerminalApprover.swift`, `Sources/TristanCLI/ProviderFactory.swift`, `Tests/TristanCLITests/RunCommandTests.swift`, `Tests/TristanCLITests/TerminalApproverTests.swift`

**Interfaces:**
- Consumes: `AgentProvider.run(task:workingDirectory:approve:)`, `AgentEvent`, `ApprovalRequest`, `ApprovalMode`, `Settings`, `OllamaStatus.ready()`.
- Produces: `final class TerminalApprover: @unchecked Sendable { init(interactive: Bool, mode: ApprovalMode, input: @escaping () -> String?, output: @escaping (String) -> Void); func approve(_ request: ApprovalRequest) -> Bool; private(set) var denials: Int }` — prints the summary, detail and `[y]es / [n]o / [a]lways`; `a` stores `request.rule` in `Settings` key `allowRules` (same JSON as the Mac) when a rule exists; not interactive means deny and count it; `enum CLIProvider: String { case claude, copilot, bedrock, azure, ollama; func make(mode: ApprovalMode) -> AgentProvider }`; `enum ExitCode: Int32 { case ok = 0, failed = 1, usage = 2, denied = 3 }`; `func render(_ event: AgentEvent) -> String` (log lines as `> text`, code as is, status to stderr, done/failed final line). Flags: `--provider`, `--folder` (default current directory), `--yes-routine` (Auto), `--yolo`, mutually exclusive, default `ask`. `main` handles `--mcp-permission` before parsing (as `Sources/Tristan/main.swift` does) and calls `SetConsoleOutputCP(65001)` on Windows.

- [ ] **Step 1:** Write `testNonInteractiveAskDeniesAndCounts`, `testAlwaysStoresRule`, `testYesAnswers` (`y`, `Y`, `yes` allow; anything else denies), `testRunExitsDeniedWhenAnythingWasDenied` (a fake provider that requests one approval), `testRunExitsFailedOnFailedEvent`, `testYesRoutineAndYoloAreExclusive`, `testRenderSeparatesLogCodeAndStatus`.
- [ ] **Step 2:** Run `swift test --filter TristanCLITests`; expected FAIL.
- [ ] **Step 3:** Implement. `providers` prints each provider with `ready` / `not ready: <reason>` (Ollama via `OllamaStatus.ready()`, CLI tools via `ExecutableResolver`, Azure and Bedrock by key or CLI presence). Cancel: on SIGINT / Ctrl+C cancel the run task, terminate the provider process and, on Windows, run `taskkill /T /F /PID <pid>` for its tree; ensure `ProcessLauncher` exposes the `Process` so the provider's `onTermination` can do this.
- [ ] **Step 4:** Add `testCancelTerminatesProcessTree` (spawns a shell that starts a child that sleeps; after cancel neither is running; runs on the Mac with `/bin/sh` and on Windows with PowerShell). Run on both.
- [ ] **Step 5:** On Windows: `swift run tristan run --provider ollama "say hello"` against a running Ollama prints a streamed answer and exits 0. Commit: `CLI: tristan providers and run with terminal approvals`

### Task 12: Windows CI smoke test with a mocked Ollama, and the zip artifact
**Files:**
- Create: `scripts/ci/mock-ollama.ps1`
- Modify: `.github/workflows/windows.yml`

**Interfaces:**
- Produces: a PowerShell `HttpListener` mock on `http://localhost:11434` that serves the Ollama endpoints the core calls (`OllamaStatus.installedModels` and the chat endpoint used by `OllamaHTTPClient`; read those two paths in `OllamaProvider.swift`) and streams a fixed two-chunk answer with a delay between chunks.

- [ ] **Step 1:** Write the mock; test it locally in PowerShell with `Invoke-WebRequest` (the model list returns one model; the chat endpoint streams).
- [ ] **Step 2:** In the workflow, after tests: start the mock in the background, set `ollama.model` through `tristan` settings (or `%APPDATA%\Tristan\settings.json`), run `swift run tristan run --provider ollama "hello"`, assert exit 0 and that the output contains the mock's answer text.
- [ ] **Step 3:** Build `swift build -c release --product tristan`, zip `tristan.exe` and its runtime DLLs, upload as artifact `tristan-windows`.
- [ ] **Step 4:** Push and read the job. Expected: green, artifact present. Commit: `CI: Windows smoke test against a mocked Ollama and a zip artifact`

### Task 13: Azure OpenAI on Windows
**Files:**
- Modify: `Sources/TristanCore/AzureProvider.swift`
- Test: `Tests/TristanCoreTests/AzureTests.swift`

**Interfaces:**
- Consumes: `ProcessLauncher.prepare`, `KeychainStore`, `Settings`.

- [ ] **Step 1:** Add `testAzureCLITokenUsesLauncher` (inject a launcher that records `az account get-access-token ...` and returns `token\r\n`; the token is trimmed of `\r\n`) and `testMissingAzureMessageMentionsWinget` (Windows wording behind a `windows:` parameter so it runs on the Mac).
- [ ] **Step 2:** Run; expected FAIL. Make `azureCLIToken` available on every non-iOS platform (change its `#if os(macOS)`), trim `\r`, and use the launcher. 
- [ ] **Step 3:** `swift test`. On Windows run `tristan run --provider azure "say hello"` with an API key stored through `tristan` settings or Credential Manager, then with `az login` and no key. Both complete. Commit: `Azure: work on Windows (az.cmd, Credential Manager key)`

### Task 14: Bedrock on Windows
**Files:**
- Modify: `Sources/TristanCore/Processes/BedrockProvider.swift`, `Sources/TristanCore/BedrockStreaming.swift`
- Test: `Tests/TristanCoreTests/BedrockTests.swift`

- [ ] **Step 1:** Add `testCLIInputURLIsValidOnWindows` (a pure helper `AWSCLIConverseClient.inputArgument(for path: String, windows: Bool) -> String` returns `file://C:/Users/x/AppData/Local/Temp/tristan-bedrock-1/request.json` for `C:\Users\x\...` and `file:///tmp/...` on posix) and `testExplainMentionsWindowsInstallHint` (`aws` not found gives a `winget install Amazon.AWSCLI` hint when `windows: true`).
- [ ] **Step 2:** Run; expected FAIL. Implement; make `AWSCLICredentials` available on all non-iOS platforms and read `aws configure export-credentials` output with `\r\n` tolerated.
- [ ] **Step 3:** `swift test`. On Windows: run a mission with `AWS_PROFILE` set (streaming over HTTPS), then temporarily break the streaming path (block the endpoint) and confirm the CLI fallback answers. Commit: `Bedrock: work on Windows (streaming and the aws CLI fallback)`

### Task 15: Copilot on Windows
**Files:**
- Modify: `Sources/TristanCore/Processes/CopilotProvider.swift`
- Test: `Tests/TristanCoreTests/CopilotTests.swift`

- [ ] **Step 1:** Add `testStripANSIHandlesCRLF` (`"\u{1B}[32mok\u{1B}[0m\r\n"` gives `ok` with no stray `\r`), `testUnsafeTaskOnCmdShimIsRefusedWithMessage` (the provider yields `.failed` naming the problem when `ProcessLauncher` throws `UnsafeArguments`, rather than launching), and `testLogFolderCreationDoesNotNeedPosixPermissions` (the folder is created when attributes are skipped on Windows).
- [ ] **Step 2:** Run; expected FAIL. Implement: use `ProcessLauncher.prepare("copilot", ...)`, skip `posixPermissions` on Windows, trim `\r` from lines.
- [ ] **Step 3:** `swift test`. On Windows: `tristan run --provider copilot "list the files here"` in an ask-mode approval and in `--yes-routine`, with a prompt that includes spaces, quotes and an `&`. Expected: runs through the resolved Node entry point, or fails with the clear message. Commit: `Copilot: work on Windows (npm shim, CRLF, no POSIX modes)`

### Task 16: Claude Code on Windows
**Files:**
- Modify: `Sources/TristanCore/Processes/ClaudeCodeProvider.swift`, `Sources/TristanCLI/main.swift`
- Test: `Tests/TristanCoreTests/ClaudeProviderTests.swift`

- [ ] **Step 1:** Write `testMCPConfigUsesEnvForTheToken` (the generated `mcp.json` has `env.TRISTAN_APPROVAL_TOKEN` and no `args` entry contains the token), `testMCPConfigEndpointIsTCPWhenListenerIsLoopback`, `testStreamParserToleratesCRLFLines`, and `testClaudeNotFoundMessageMentionsGitForWindows` (Windows wording behind a parameter).
- [ ] **Step 2:** Run; expected FAIL. Implement using `ApprovalTransport` (Task 9) and `ProcessLauncher` (Task 6); `--permission-prompt-tool mcp__tristan__approve` and the other flags stay as they are.
- [ ] **Step 3:** On Windows: `tristan run --provider claude "create hello.txt with hi"` in `ask` mode. Expected: a terminal prompt appears for the write, `y` creates the file, `n` does not, and the process list shows no leftover `claude`, `node` or `tristan` after the run. Repeat with `--yes-routine`.
- [ ] **Step 4:** Commit: `Claude Code: work on Windows through the loopback approval channel`

### Task 17: Kids mode in the CLI
**Files:**
- Create: `Sources/TristanCore/KidsRouting.swift`, `Sources/TristanCLI/KidsCommand.swift`, `Tests/TristanCoreTests/KidsRoutingTests.swift`, `Tests/TristanCLITests/KidsCommandTests.swift`
- Modify: `Sources/Tristan/MissionSession.swift` (`route`, line ~54), `Sources/TristanCLI/RunCommand.swift`

**Interfaces:**
- Consumes: `ParentPIN.isSet`, `ParentPIN.matches(_:)`, `ParentPIN.set(_:)`, `Settings.bool("kidsMode")`.
- Produces: `enum KidsRouting { static func mustStayLocal(kidsMode: Bool, cloudOnce: Bool) -> Bool }`; CLI `kids on`, `kids off` (asks for the PIN when one is set), `kids set-pin` (asks for the existing PIN when set; minimum length `ParentPIN.minimumLength`; PIN read without echo); `run` in kids mode: default provider is `ollama`, a requested cloud provider exits `usage` with a message unless `--allow-cloud` is given and the PIN is entered, and approval mode is forced to `ask`.

- [ ] **Step 1:** Write `testMustStayLocal` (kids on and not once: true; kids off: false; kids on with `cloudOnce`: false), `testKidsRunRefusesCloudProvider` (exit `usage`, provider never started), `testKidsRunDefaultsToOllama`, `testKidsRunForcesAsk` (`--yolo` is rejected), `testKidsOffNeedsPIN`, `testSetPinRejectsShortPIN`.
- [ ] **Step 2:** Run; expected FAIL. Implement; change `MissionSession.route` to call `KidsRouting.mustStayLocal` (behaviour identical, including the DEMO exception).
- [ ] **Step 3:** `swift test` (Mac tests unchanged and green). On Windows: `tristan kids set-pin`, `tristan kids on`, then `tristan run --provider claude "hi"` is refused and `tristan run "hi"` answers through Ollama. Commit: `CLI: kids mode (local-only answers, PIN to leave it)`

### Task 18: `history` and `sessions`
**Files:**
- Create: `Sources/TristanCLI/HistoryCommand.swift`, `Sources/TristanCLI/SessionsCommand.swift`, `Sources/TristanCLI/SessionRegistry.swift`, `Tests/TristanCLITests/HistoryCommandTests.swift`, `Tests/TristanCLITests/SessionRegistryTests.swift`
- Modify: `RunCommand.swift` (record to history and the registry)

**Interfaces:**
- Consumes: `HistoryStore(url:limit:)`, `MissionRecord`, `[MissionRecord].filtered(query:status:)`, `HistoryFilter`.
- Produces: history file at `%APPDATA%\Tristan\history.json` on Windows (the Mac app's location on Mac); `tristan history [--query <text>] [--status all|done|failed] [--rerun <n>]`; `struct SessionRegistry { init(directory: URL, isAlive: (Int32) -> Bool); func register(pid: Int32, task: String, provider: String, folder: String); func unregister(pid: Int32); func active() -> [SessionInfo] }` writing `<directory>/<pid>.json` (stale entries whose process is gone are skipped and removed); `tristan sessions` lists active runs.

- [ ] **Step 1:** Write `testHistoryFilterByQueryAndStatus`, `testRunRecordsMission` (only task and short summary stored, never code), `testRegistryListsAliveAndDropsStale`, `testRegistryUnregisterOnExit`.
- [ ] **Step 2:** Run; expected FAIL. Implement; `run` registers before starting and unregisters on every exit path, including Ctrl+C.
- [ ] **Step 3:** `swift test`; on Windows start a long mission, run `tristan sessions` from a second terminal and see it listed. Commit: `CLI: history and sessions commands`

### Task 19: Docs, release artifact and validation issues
**Files:**
- Create: `docs/windows.html`, `scripts/setup-ollama.ps1`
- Modify: `README.md` (Requirements), `docs/index.html` and `docs/install.html` (link and a Windows section), `docs/ci-and-release.md` (Windows workflow and artifact), `.github/workflows/release.yml` (attach the Windows zip to the release)

- [ ] **Step 1:** Write `docs/windows.html` in the style of the other pages: install (download the zip, add to `PATH`), per-provider setup (Ollama, Azure key or `az login`, Bedrock profile, Copilot `npm install -g @github/copilot` and sign in, Claude Code with Git for Windows), running a mission, approvals and the non-terminal behaviour, kids mode, safety notes (PowerShell, what Auto allows), known limits (no window, voice or notch).
- [ ] **Step 2:** `scripts/setup-ollama.ps1` mirroring `scripts/setup-ollama.sh` (`--start-only` becomes `-StartOnly`); test on the Windows machine.
- [ ] **Step 3:** Update README, site pages and `docs/ci-and-release.md`; extend `release.yml` to build the Windows zip and attach it with its SHA-256.
- [ ] **Step 4:** Open one `validation` + `windows` issue per provider (Claude Code, Copilot, Bedrock, Azure OpenAI, Ollama) with the manual checklist from Tasks 13 to 16, link them from #23 and tick the matching boxes in #23 and #21.
- [ ] **Step 5:** Commit: `Docs: Windows terminal version`
