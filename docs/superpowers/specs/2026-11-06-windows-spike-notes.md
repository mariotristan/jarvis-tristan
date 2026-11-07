# Windows spike notes (plan Task 0)

These checks ran on GitHub Actions `windows-latest` (image `win25-vs2026` 20261103.298.1, x64), not on a person's PC. The job is `windows-spike` in `.github/workflows/windows.yml`. Its tools and fixtures are in `scripts/ci/spike/`.

Runs:
- First run: https://github.com/mariotristan/jarvis-tristan/actions/runs/42346619772 (spike job 128325650428).
- Confirmed in the first all-green run: https://github.com/mariotristan/jarvis-tristan/actions/runs/42348730665 (spike job 128332076709).

## (a) Toolchain
```
Swift version 6.4.2 (swift-6.4.2-RELEASE)
Target: x86_64-unknown-windows-msvc
```
- Installed with `compnerd/gha-setup-swift` v0.5.1 (`swift-6.4.2-release` / `6.4.2-RELEASE`), the latest stable 6.x release.
- Builds print one harmless warning from the toolchain's own WinSDK module: `reference to type 'wchar_t' broken by a context change`.
- Packages resolved to the same versions as on the Mac: swift-argument-parser 1.8.2, swift-crypto 3.15.1, swift-asn1 1.7.4.

## (b) Does URLSession stream?
Apple's `URLSession.bytes(for:)` **does not exist** in the open-source Foundation that Windows uses. swift-corelibs-foundation offers only `data(for:)` and `data(from:)` as async calls. It also lacks `FileHandle.bytes` and `AsyncSequence.lines`, so the core did not compile on Windows as written.

A `URLSession` data delegate **does** deliver chunks as they arrive. The test server was a PowerShell `HttpListener` that sends chunked line 1, waits 1 s, then sends line 2. The client printed:
```
   19.1 ms  head: status 200
   19.1 ms  line: {"line":1}
 1022.2 ms  line: {"line":2}
PASS: line 1 at 19 ms, line 2 at 1022 ms (URLSession delegate streams incrementally)
```
The project's own acceptance test agrees. `HTTPStreamingTests.testStreamsLinesIncrementally` serves two lines 0.8 s apart from the project's loopback socket, and `testReportsStatusAndErrorBody` checks that a 401 returns its JSON body. Both pass on Windows through the compatibility layer (1.0 s and 0.2 s).

**Task 5 decision: no third-party HTTP client.** `Sources/TristanCore/AsyncBytesCompat.swift` is compiled only where Darwin is unavailable. It supplies:
- `URLSession.bytes(for:)`, built on a data delegate with a private session that uses the caller's configuration;
- `FileHandle.bytes`, which reads on a background thread;
- `.lines`, which splits on LF, CR LF or CR and skips empty lines, as Apple's version does.

Call sites in Ollama, Azure, Bedrock, Copilot and Claude Code are unchanged, and Mac and iOS compile none of this code. AsyncHTTPClient and a WinHTTP wrapper were not needed: the chunk-timing check passed with URLSession.

## (c) Foundation.Process and awkward arguments
The arguments passed were: `two words`, `quote"inside`, `a&b`, `100%`, `%PATH%`, `trail\`, `trail space\ `, `café 日本`, `^caret`, `pipe|x`, `(paren)`, `!bang!`, and an empty string.

| What was started | What the child received |
|---|---|
| A real `.exe` (argdump) | All arguments exactly, including non-ASCII, **except the empty string, which is dropped**. Foundation writes it as nothing on the command line (raw line ends `!bang! `). |
| `hello.cmd` (cmd.exe in between) | **`%PATH%` is expanded** into the whole PATH, which split into about 80 arguments. Everything else came through. This is why `CmdShimGuard` and shim parsing exist. |
| An npm-style shim (`shim.cmd` → node) | The same `%PATH%` expansion as `hello.cmd`. |
| node started directly on the shim's script | All arguments exactly (the empty string dropped). This is the path `ProcessLauncher` takes for npm shims. `WindowsPlatformTests.testNpmShimArgumentsReachNodeUnchanged` confirms it through `ProcessLauncher.plan` with `back\\"slash` added. |
| `pwsh -File` and `powershell.exe -File` | All arguments exactly (the empty string dropped). |
| run_command style: `pwsh`/`powershell.exe -NoLogo -NoProfile -NonInteractive -Command "Write-Output 'a & b' '100%' 'café 日本'; exit 3"` | Output `a & b`, `100%`, `café 日本`, and exit status 3 for both shells. |
| A bare name (`az`, `aws`) | `could not start … Code=260 "The file doesn’t exist."`. Foundation.Process never searches PATH, so `ProcessLauncher` must resolve names (it does). |
| Resolved full paths (`…\CLI2\wbin\az.cmd`, `…\AWSCLIV2\aws.exe`) | Both run `--version` and exit 0. |

Also seen:
- **Non-ASCII output from run_command** comes back as correct UTF-8: `"café 日本\r\n\n[exit status 0]"` (`WindowsPlatformTests.testRunCommandNonASCIIOutput`). The OEM code-page concern from the Task 7 ruling did not appear on the runner with pwsh 7. A console with a non-UTF-8 code page on a real PC is still unproven.
- **Empty arguments are dropped.** This comes from Foundation's quoting on Windows; a run with an empty prompt (`-p ""`) would shift the argument list. **Since fix round 1, `ProcessLauncher` refuses any empty argument on Windows** with `EmptyArgument` ("refusing to start <tool> with an empty argument…"). No caller passes `""` on purpose; an empty task, command or region now fails with that message instead of shifting the arguments.

## (d) Tools on PATH (`where.exe`)
| Tool | Result |
|---|---|
| pwsh | `C:\Program Files\PowerShell\7\pwsh.exe` |
| powershell | `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe` |
| node | `C:\Program Files\nodejs\node.exe` |
| git | `C:\Program Files\Git\bin\git.exe` (also `…\Git\cmd\git.exe` and `…\Git\ucrt64\bin\git.exe`) |
| npm | `C:\Program Files\nodejs\npm` and `npm.cmd` |
| aws | `C:\Program Files\Amazon\AWSCLIV2\aws.exe` |
| az | `C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az` and `az.cmd` (az is a .cmd; it is not a node shim) |
| claude, copilot | not installed |

`PATHEXT` is `.COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC;.CPL`.

## (e) Sockets, ACLs, tree kill, process liveness
- **icacls with `%USERDOMAIN%\%USERNAME%` fails on the runner.** The step's environment has `USERNAME=SYSTEM`, while `whoami /user` shows `runnervmm7ud1\runneradmin` (SID `S-1-5-21-…-500`). icacls answered `runnervmm7ud1\SYSTEM: No mapping between account names and security IDs was done.` with exit code 1332. This was a real bug: the approval folder could never be restricted, so Claude Code approvals would always have failed.
  - **First fix:** name the user by the SID of the process token (`OpenProcessToken` → `GetTokenInformation(TokenUser)`) and grant `*S-1-5-…:(OI)(CI)F` with icacls.
  - **Fix round 1:** a check of the result showed that `icacls /inheritance:r /grant:r` still left explicit `NT AUTHORITY\SYSTEM:(OI)(CI)(F)` and `BUILTIN\Administrators:(OI)(CI)(F)` entries next to the user's. `PermissionServer` now sets a protected DACL with exactly one entry (FILE_ALL_ACCESS, inherited by sub-folders and files, for the token SID) through `SetEntriesInAclW` and `SetNamedSecurityInfoW`. No icacls process runs any more.
  - `WindowsPlatformTests.testApprovalFolderGrantsOnlyTheCurrentUser` checks the result with icacls: no `(I)` entries, exactly one entry ending `:(OI)(CI)(F)`, and `/findsid *<token SID>` finds it.
  - The PermissionServer and provider approval-flow tests pass on Windows.
- **SO_EXCLUSIVEADDRUSE** holds for the exact address: a second socket with SO_REUSEADDR cannot bind `127.0.0.1:<held port>`.
  - Windows **does** allow another socket to bind `0.0.0.0:<held port>` (`wildcard bind on the held port: allowed`). Connections to `127.0.0.1` still reach the host's more specific binding, and the full token handshake succeeds (`WindowsPlatformTests.testLoopbackPortCannotBeTakenWhileHeld`).
  - A rogue listener after the host has died is handled by the server token (Task 9). The mutual tokens protect the channel, not the port.
- **Shutting a socket down does not reliably wake a blocked `recv` on Windows.** Handshake reads therefore wait in 200 ms slices (`WSAPoll`, or `poll` on POSIX) and stop once evicted. At the 32-thread cap, the accept loop evicts the oldest unfinished handshake and waits for a thread instead of dropping the new client. With 40 silent clients connected first, the real shim still completes its handshake in about 0.2 s on Windows (`ApprovalTransportTests.testFortySilentClientsStillLetTheRealShimThrough`).
- **Cancellation:** off Apple platforms a cancelled consumer of `bytes(for:)` gets `CancellationError` (`HTTPStreamingTests.testCancellingTheConsumerThrows`). On the Mac, Apple's `AsyncBytes` was seen to ignore the cancel and deliver the rest of the body.
- **Credential Manager** stores a 2,560-byte secret and refuses 2,561 bytes, keeping the old value (`KeychainTests.testCredentialManagerSizeLimit`).
- **`taskkill /T /F`** stopped a `cmd` → `ping` tree: the root and both children were gone. `ProcessTreeWindowsTests.testCancelTerminatesProcessTreeOnWindows` passes.
- **OpenProcess / STILL_ACTIVE** liveness works: `SessionRegistryTests.testProcessIsAlive` passes on Windows (this process is alive, `Int32.max` is not).
- **Junctions and symlinks:** `SafePath.real` (Foundation's `resolvingSymlinksInPath`) follows `mklink /J` junctions and `mklink /D` directory symlinks on Windows. A junction from the working folder to a sibling resolves to the sibling, and `ToolSandbox` and `ApprovalRule` treat it as outside. A root given by its 8.3 short name still contains paths given by their long names. **No `GetFinalPathNameByHandleW` change was needed.**
