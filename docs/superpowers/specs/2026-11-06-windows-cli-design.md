# Tristan on Windows: a terminal version first

Backlog: #23 (Windows support). Shares its core work with #24 (command-line version) and #22 (Linux).

## Intent
Tristan runs only on macOS. Windows developers already run Claude Code, Copilot, the AWS and Azure CLIs and Ollama, so they could use Tristan's approvals, sessions and kids-mode routing too. The smallest real proof is a **terminal version**: run a mission, watch the log and code stream, and approve or deny each action in Windows Terminal or PowerShell. It is the same executable as the command-line version in #24, so Windows is its first target and Linux gets it almost for free.

Decided by the user: terminal UI first; **all five providers** (Claude Code, Copilot, Bedrock, Azure OpenAI, Ollama) must work; a physical Windows machine is available for testing.

## Goals
- A `tristan` command that builds and runs on Windows 10/11 (x64) and runs a mission on every provider.
- Same approval modes (`ask`, `auto`, `yolo`) and the same narrow Always-allow rules, with approvals answered in the terminal.
- Windows CI that builds the core and runs its tests, so Windows stays working.
- The Mac app keeps working unchanged. Its tests stay green and its look and behaviour do not change.
- A guide for Windows users: install, set up each provider, run a mission.

## Non-goals (this milestone)
- A graphical window, the notch overlay or any Windows HUD.
- Voice (speaking, push-to-talk, wake word), Spotify, notifications, launch at login.
- Windows Hello for the kids-mode parent unlock. The PIN works as is.
- The iPhone remote link to a Windows host (the transport uses Apple's Network framework with TLS-PSK).
- An installer, MSIX or package-manager entry. A zip from CI is enough.
- ARM64 Windows.

## Anti-goals
- A Windows build that silently runs weaker safety than the Mac: `auto` mode must not approve a command the Mac would ask about because the risky-program list only knows Unix names.
- Forking the core. There must be one copy of the agent loop, providers and approval logic, used by the Mac app and the CLI.
- Secrets in plain text files or in the repository.

## Findings from the code (current state)
- One macOS-only executable target (`Package.swift`, `.macOS(.v14)`); no library target.
- `Sources/Tristan/Shared/` is meant to be portable but 7 of its 17 files import more than Foundation: SwiftUI (`Theme`, `Themes`, `Markdown`), Security (`Keychain`), Network (`RemoteClient`, `RemoteTransport`) and CryptoKit (`BedrockStreaming`, and the kids-mode PIN).
- Process launching assumes Unix: `/usr/bin/env <tool>`, `/bin/zsh`, `/bin/bash` and a Homebrew `PATH`. It is repeated in `Providers`, `CopilotProvider`, `BedrockProvider`, `Connectivity`, `Shared/AzureProvider`, `Shared/BedrockStreaming` and `Shared/AgentTools`.
- Agent loop tools: `run_command` is `#if os(macOS)` and uses `/bin/zsh`. The API providers (Azure, Bedrock, Ollama) need it, and a Windows runner does not exist.
- Approval bridge for Claude Code: `PermissionBridge` uses raw `AF_UNIX` sockets (`Darwin`, `sockaddr_un`, `strlcpy`). The provider re-launches its own binary (`Bundle.main.executablePath`) with `--mcp-permission <socket>` as an MCP server.
- Approval policy is Unix-shaped: `ApprovalRule` has a `neverGeneralise` list (`rm`, `sudo`, `curl`, `ssh`, ...), a shell-operator check, and `file.hasPrefix(root + "/")` for the folder check. `ToolPolicy` leans on the same notion of a "plain" command.
- Settings use `UserDefaults.standard` (Bedrock, Azure, Ollama config, `copilot.model`). Secrets use the Keychain through `KeychainStore`.
- iOS already forced some separation: Azure and Bedrock have key-based paths that need no CLI (`#if os(macOS)` guards the CLI paths).
- CI is macOS only (`.github/workflows/ci.yml`).

## Approach
1. **Split the core.** Create a library target (working name `TristanCore`) holding the agent loop, tools, providers, approval types and policy, conversation memory, history, themes data and the Markdown parser. The Mac app, the iOS project (which includes `Shared/` files directly today) and the CLI depend on it. SwiftUI-only parts (themes as `Color`, Markdown rendering) stay in the UI layer or are guarded.
2. **Platform seams** behind small protocols or `#if os(Windows)` where a protocol is overkill:
   - `SecretStore`: Keychain on Apple, Windows Credential Manager on Windows.
   - `SettingsStore`: `UserDefaults` on Apple; a JSON file under `%APPDATA%\Tristan` on Windows. The CLI reads the same keys.
   - `ProcessLauncher`: finds a tool on `PATH` (honouring `PATHEXT`, so `copilot.cmd` and `az.cmd` resolve), launches it, streams output, kills it on cancel. Replaces every `/usr/bin/env` and Homebrew `PATH` line.
   - `ShellRunner`: `/bin/zsh -c` on Mac, PowerShell (`pwsh` if present, else `powershell.exe`) on Windows.
   - `ApprovalChannel`: the transport between the Claude Code MCP shim and the host. Unix socket on Mac; on Windows a localhost TCP socket with a one-time random token (my call; named pipes are the alternative). The `Process` and `Bundle.main.executablePath` use becomes `CommandLine.arguments[0]` / the current executable path.
   - `Crypto`: swift-crypto where CryptoKit is used on Windows (SigV4 signing, PIN hashing).
3. **The `tristan` executable** (new target) with `run`, `providers`, `sessions`, `history` as in #24, plain streaming output first. Approvals prompt in the terminal per action with allow / deny / always-allow; `--yes-routine` for Auto; `YOLO` needs an explicit flag.
4. **Windows safety review** of the approval policy: Windows equivalents for the never-generalise list (`del`, `rd`, `rmdir`, `Remove-Item`, `Invoke-Expression`/`iex`, `Invoke-WebRequest`/`iwr`, `curl.exe`, `powershell`, `cmd`, `reg`, `format`, `taskkill` and similar), PowerShell operators in the "plain command" check (`;`, `&`, `|`, `>`, backtick, `$()`, `-EncodedCommand`), and folder containment with drive letters, `\` and `/`, case-insensitivity, UNC paths and junctions. Containment compares resolved paths, not string prefixes.
5. **CI**: a Windows job (`windows-latest`, Swift toolchain) that builds the core and the CLI and runs the core tests. Also publish the CLI as a zip artifact.
6. **Docs**: a Windows install and usage page on the site, README requirements, and `scripts/setup-ollama.ps1`.

## Providers: what each needs
| Provider | Needs on Windows | Effort |
|---|---|---|
| Ollama | Core split, settings store, `setup-ollama.ps1`. Already HTTP and local. | Low |
| Azure OpenAI | Credential Manager for the API key; `az account get-access-token` through the launcher (`az.cmd`); URLSession streaming for SSE. | Low to medium |
| Bedrock | swift-crypto for SigV4; `aws configure export-credentials` and `aws bedrock-runtime converse` through the launcher; a Windows-safe `file://` argument for the CLI fallback; messages say `winget`, not `brew`. | Medium |
| Copilot | Launcher resolving `copilot.cmd`; correct argument quoting; no POSIX permission bits on temp folders. Copilot's ask mode is one up-front approval and stays that way. | Medium |
| Claude Code | Launcher resolving `claude`; the new `ApprovalChannel`; the MCP shim running from the CLI binary. Claude Code itself may need Git for Windows installed. | High |

## Order of work (my suggestion)
1. Spike: confirm the Swift toolchain on the Windows machine builds the portable files, and that `URLSession` can stream (the `bytes`/SSE paths in Azure, Ollama, Bedrock work on Windows). Results decide whether a different HTTP client is needed.
2. Core split and the Mac app still green; Windows CI building the core.
3. Seams (secrets, settings, launcher, shell, crypto), then the CLI with Ollama.
4. Azure, then Bedrock, then Copilot.
5. Approval channel and Claude Code.
6. Windows safety review and tests for the policy, then docs.
Each step ships on its own and leaves the Mac app working.

## Validation
- Unit tests for the policy and path containment run on Windows CI, with Windows-style inputs.
- A manual pass on the Windows machine, one real mission per provider (needs an Ollama install, Azure OpenAI deployment or key, AWS profile with Bedrock access, a Copilot login and a Claude Code login). Track these as `validation` issues like #1 to #5.
- Kids-mode routing check: with kids mode on, the CLI answers only through Ollama and refuses cloud providers.

## Open questions and my calls
- Approval channel on Windows: localhost TCP with a random token (my call). Named pipes would avoid opening a port but are more work in Swift on Windows.
- Windows shell for `run_command`: PowerShell (my call), not `cmd.exe`, because the models and the policy are easier to reason about with one shell.
- Settings: a JSON file in `%APPDATA%\Tristan` (my call). Whether the CLI should share settings with the Mac app is moot until Windows has a GUI.
- x64 only (my call).
- Library name `TristanCore` and the executable name `tristan` (my call).
- Toolchain: the current stable Swift release on Windows, with `swift-crypto` and, if the spike shows `URLSession` cannot stream, AsyncHTTPClient or a small WinHTTP wrapper behind the existing HTTP seam (the builder picks the replacement; see the user's decision below).
- iOS: the iOS project keeps including `Sources/Tristan/Shared` by path (`ios/project.yml`), so the core split must leave those files compiling for iOS. Moving iOS onto the library is out of this milestone. CI's existing iOS job is the check (answered by the project).
- Policy parity: there is no policy test suite today (only `BedrockTests` touches `ApprovalRule`). Step 6 first writes Mac tests that pin the current behaviour of `ApprovalRule`, `ToolPolicy` and `SafePath`, then runs the same cases with Windows inputs. Windows keeps the Mac rule: a plain program name not on the never-generalise list can be generalised, and anything with an operator always asks (my call; "unknown commands always ask" is stricter than the Mac and is not adopted).
- No terminal attached (stdin not a TTY): `ask` mode denies every action that needs approval and exits non-zero. `--yes-routine` or `--yolo` must be explicit (my call).
- Shim token: passed to the Claude Code MCP shim through the `env` block of the generated MCP config, not the command line, and the config file is created in a per-run folder only the current user can read (my call).
- Credential Manager: a small system-library C interop target around `CredRead` and `CredWrite`; never shell out with a secret as an argument (my call).
- CI smoke test: the CLI runs one mission against a mocked Ollama endpoint on Windows CI (my call).
- Kids mode in the CLI: `tristan kids on|off|set-pin` writes the same settings keys and PIN hash the Mac app uses, so a Windows-only machine can enable it (my call).
- Decided by the user: all five providers are a hard requirement for this milestone. Claude Code is not deferred; if it proves hard, the builder finds a way (for example the named-pipe channel) rather than cutting scope.
- Decided by the user: if the spike shows `URLSession` cannot stream on Windows, the builder picks the replacement HTTP client without asking.

## Left to the builder
Package layout details, exact protocol shapes for the seams, the argument parser (`swift-argument-parser` is a reasonable default), the prompt UX wording, and the Windows CI toolchain setup.
