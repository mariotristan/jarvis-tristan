# T.R.I.S.T.A.N.

A native macOS harness for AI coding agents, wrapped in an Iron Man style heads-up display.

You give Tristan a task ("add login to the API"). It works inside a project folder on your Mac, the way Claude Code does. You watch it think, write code and run commands through a glowing HUD, a notch overlay and a lot of animation. Before it edits files or runs commands, it asks you first.

[![CI](https://github.com/mariotristan/jarvis-tristan/actions/workflows/ci.yml/badge.svg)](https://github.com/mariotristan/jarvis-tristan/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Swift](https://img.shields.io/badge/Swift-5.9+-F05138?logo=swift&logoColor=white)
![SwiftUI](https://img.shields.io/badge/SwiftUI-native-0A84FF?logo=swift&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude_Code-supported-D97757?logo=anthropic&logoColor=white)
![AWS Bedrock](https://img.shields.io/badge/AWS_Bedrock-supported-FF9900?logo=amazonwebservices&logoColor=white)
![Azure OpenAI](https://img.shields.io/badge/Azure_OpenAI-supported-0078D4?logo=microsoftazure&logoColor=white)
![GitHub Copilot](https://img.shields.io/badge/GitHub_Copilot-supported-6e40c9?logo=githubcopilot&logoColor=white)

**T.R.I.S.T.A.N.** = **T**actical **R**easoning **I**nterface for **S**upervising **T**asks, **A**gents and **N**etworks.

> **Status: early experiment.** All four providers are built (Claude Code, Copilot, Bedrock, Azure OpenAI) plus a demo provider, together with the HUD, notch overlay, approvals, history, notifications and voice. 45 automated tests pass, but **only Claude Code has been run against the real service end to end**. Bedrock, Azure OpenAI, Copilot, the wake word and notifications are covered by tests with fakes and still need a live run. See [known limitations](#known-limitations) for exactly what is and is not verified.

## Screenshots

Rendered from the real views with sample data (`Tristan --snapshot docs/screenshots`).

**The HUD while a mission runs.** Mission log on the left, code stream on the right, arc reactor on top.

![HUD while working](docs/screenshots/hud-working.png)

**Ask-first approval.** The reactor and borders turn amber until you approve or deny.

![HUD approval prompt](docs/screenshots/hud-approval.png)

**Configuration.** Choose how much supervision a run gets.

![Configuration panel](docs/screenshots/hud-settings.png)

**Mission history.** Past missions with one-click re-run.

![Mission history](docs/screenshots/hud-history.png)

**The notch overlay**, expanded. It opens by itself when approval is needed, so you can answer without switching windows.

![Notch overlay](docs/screenshots/notch-approval.png)

## Why

Agent CLIs are powerful but plain. Tristan is a nicer front door for them: one Mac-native app that can sit around the camera notch, summon with a shortcut, and show you what an agent is doing instead of scrolling terminal text. It is also meant to be fun.

## Features

- **Full HUD window** with three areas:
  - **Mission log** on the left, a timestamped list of steps.
  - **Code stream** on the right, showing code as the agent writes it.
  - **Arc reactor** at the top, which spins and pulses faster while the agent works and turns amber, green or red for waiting, done or failed.
  - Animated grid and scanline backdrop.
- **Notch overlay.** A black pill around the camera notch with a mini reactor and a status dot. Hover to expand it. It also opens by itself when approval is needed and for a few seconds when a mission ends. On Macs without a notch it becomes a floating pill at the top centre of the screen.
- **Ask-first approvals.** Every action Claude Code wants permission for shows up as an approve or deny prompt, in the HUD or in the notch.
- **Always allow.** The approval prompt has an `ALWAYS ALLOW` button that remembers a narrow rule so you are not asked again (see [how approvals work](#how-approvals-work)). Rules are saved between launches and listed in the configuration panel, where you can remove them one by one or clear them all.
- **Approval modes** (gear button, saved between launches):
  - `ASK`: Tristan asks before each action. This is the default.
  - `AUTO`: routine actions run without asking and risky ones are blocked or still ask (Claude: its own safety classifier; Bedrock and Azure: in-folder writes and plain commands; Copilot: a short allow-list).
  - `YOLO`: all permission checks are skipped. Needs an explicit confirmation to turn on and shows a red badge.
- **Movie-style sound and voice.** Synthesised sci-fi sounds (power-up, approval ping, mission complete, failure) and short spoken lines in a British voice: "On it, sir.", "Authorization required.", "Mission complete." Both can be switched off in Configuration. Run `Tristan --sound-demo` to hear every cue.
- **Voice (push-to-talk).** Hold `⌥ ⇧ Space` and speak, release to send, or click the mic button. The transcript appears live in the input field and the notch. For tasks started by voice, Tristan reads the result aloud.
- **Wake word (optional, off by default).** Say "Hey Tristan, …" and stop talking; Tristan sends the command after a short silence. It uses on-device speech recognition only, so audio never leaves your Mac, and it pauses while a mission runs.
- **Mission history.** Every finished, failed or aborted mission is saved (task, provider, mode, a short summary and the folder, never code or file contents) and can be re-run in one click. The file is private to you (`0600`) in Application Support.
- **Mac notifications** when approval is needed or a mission ends while Tristan is in the background. Clicking one brings the HUD forward.
- **Global shortcut.** `⌥ Space` shows or hides the HUD from any app, and `Esc` hides it. Pick another combination in Configuration if it clashes with another app.
- **Remembered settings.** Provider, approval mode, default folder, shortcut, sound and voice settings and provider details survive restarts. Secrets live in the Keychain.
- **Menu bar item** next to the clock to open Tristan or quit.
- **Provider switcher** along the bottom of the HUD.
- **Folder picker** to choose the project folder the agent works in.

## Providers

| Provider | Status | How it works |
|----------|--------|--------------|
| `DEMO` | Working | Scripted run with a fake approval, for trying the HUD without spending tokens. |
| `CLAUDE` | Working | Runs `claude -p <task> --output-format stream-json --verbose` in the chosen folder and turns the JSON events into log lines and code. In `ASK` mode, permission prompts are routed back to you (see [how approvals work](#how-approvals-work)). |
| `BEDROCK` | Built, needs live validation | Tristan's own agent loop on Bedrock's Converse API (see [Bedrock](#aws-bedrock)). Covered by tests with a scripted model; not yet run against real AWS. |
| `COPILOT` | Built, needs live validation | Drives the GitHub Copilot CLI headlessly. Approval modes map onto the CLI's tool permissions (see [GitHub Copilot](#github-copilot)). |
| `AZURE` | Built, needs live validation | Tristan's own agent loop on an Azure OpenAI deployment, streaming tokens (see [Azure OpenAI](#azure-openai)). |

Claude Code runs its own agent loop, so Tristan only has to drive it and display the output. Bedrock, Azure OpenAI and Copilot's models are models, not agents, so Tristan runs its own small agent loop for them (built for Bedrock, reusable for the rest).

### Azure OpenAI

Point Tristan at an Azure OpenAI **deployment** in Configuration: endpoint (for example `https://my-resource.openai.azure.com`), deployment name and API version (default `2024-10-21`). The deployment's model must support tool calling (the GPT-4 and GPT-5 families do).

- **Credentials:** paste an API key and it is stored in the **macOS Keychain**. With no key, Tristan uses your Azure CLI login (`az login`) and an Entra ID token, so no secret is stored at all.
- **Key safety:** the key is only ever sent to an `https` endpoint on an Azure host (`openai.azure.com`, `cognitiveservices.azure.com`, `services.ai.azure.com`, and the US and China sovereign-cloud equivalents). A typo such as `http://…` or a look-alike host is refused before anything is sent.
- **Streaming:** text arrives token by token. Rate limits (429) and transient server errors are retried up to twice, honouring `Retry-After`.
- **Tools and approvals:** identical to Bedrock, since both use the same agent loop (see below).
- **Errors:** wrong credentials, a missing deployment, rate limits and content-filter blocks produce readable messages in the mission log.

### GitHub Copilot

The `COPILOT` provider drives the [GitHub Copilot CLI](https://github.com/github/copilot-cli) (`npm install -g @github/copilot`, then run `copilot` once to sign in) with `copilot -p`. Optionally set a model in Configuration.

**Important limitation.** In headless mode the Copilot CLI cannot ask before each action. It only understands `--allow-tool`, `--deny-tool` and `--allow-all-tools`, with denials always winning. Tristan maps the approval modes onto that:

| Mode | What Tristan does |
|------|-------------------|
| `ASK` | One approval up front ("Copilot cannot ask per action, allow it in this folder?"), then all tools are allowed **except** a deny list: `rm`, `sudo`, `dd`, `chmod`, `chown`, `mv`, `kill`, `curl`, `wget`, `ssh`, `scp`, `git push`, `git reset` and similar. |
| `AUTO` | Only file writes and a short list of routine commands (`git status/diff/log/add/commit`, `ls`, `cat`, `grep`, `swift build/test`, `npm test/run`, …) are allowed. Anything else is refused by the CLI. The deny list still applies. |
| `YOLO` | `--allow-all-tools`, no deny list. |

So per-action approval and `ALWAYS ALLOW` are **not available for Copilot**; that is a limit of the CLI, not a choice. Output is streamed as plain text because the CLI has no structured output mode yet.

### AWS Bedrock

The `BEDROCK` provider calls `aws bedrock-runtime converse` through the **AWS CLI**, so your credentials, SSO and profiles work exactly as in your terminal. Set the model id, region and optional profile in Configuration (the gear button).

- **Tools the model gets:** `read_file`, `list_dir`, `write_file`, `run_command`. File access is confined to the working folder (symlinks resolved, including for files that do not exist yet).
- **Approvals:** reads and listings never ask. `ASK` mode asks before every write and command. `AUTO` skips the prompt for file writes inside the folder and for plain commands, but still asks for chained, redirected or risky ones. `YOLO` never asks. `ALWAYS ALLOW` works the same as for Claude Code.
- **Model:** it must support tool use (Anthropic Claude models do). The default id is a guess, `us.anthropic.claude-sonnet-4-20250514-v1:0`. List what your account can use with `aws bedrock list-inference-profiles`.
- **Errors:** expired credentials, missing model access and a wrong model id produce a readable message in the mission log.
- **Streaming:** the AWS CLI is not streaming, so text appears once per model turn rather than token by token. True streaming needs SigV4 request signing and AWS's binary event-stream format (or the AWS SDK as a dependency), which I could not validate without live credentials, so it is not built yet.

`run_command` is not sandboxed beyond the working folder as its starting directory: a command can do anything your shell can. The approval prompt is the safety net, so be careful with `YOLO`.

## Requirements

- macOS 14 or later (developed on macOS 26).
- Xcode installed. The command line tools alone are not enough because SwiftUI's macros need the full toolchain. `scripts/bundle.sh` picks up `/Applications/Xcode.app` automatically even if `xcode-select` points elsewhere.
- For the `CLAUDE` provider: the [Claude Code CLI](https://docs.claude.com/en/docs/claude-code) installed and logged in. Tristan looks for `claude` on `PATH`, plus `/opt/homebrew/bin` and `/usr/local/bin`.

## Build and run

```bash
git clone https://github.com/mariotristan/jarvis-tristan.git
cd jarvis-tristan
scripts/bundle.sh      # builds a release binary and wraps it into Tristan.app
open Tristan.app
```

For a quick debug build without the app bundle:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Tristan has no Dock icon. Look for the notch overlay, the menu bar icon, or press `⌥ Space`.

## Using it

1. Pick a provider along the bottom. Start with `DEMO` to see everything move.
2. Click the folder button to choose the project folder.
3. Type a task and press Return or click **EXECUTE**.
4. Approve or deny when asked, in the HUD or from the notch.
5. Watch the mission log and code stream. Click **ABORT** to stop a run.

| Key | Action |
|-----|--------|
| `⌥ Space` | Show or hide the HUD from anywhere |
| `Esc` | Hide the HUD |
| `Return` | Execute the task |
| Hold `⌥ ⇧ Space` | Push-to-talk, release to send |

## How it works

```
Sources/Tristan/
├── main.swift         App entry point (accessory app, no Dock icon)
├── AppDelegate.swift  HUD window, menu bar item, global hotkey, notch setup
├── Session.swift      Observable state: phase, log, code, pending approval, provider
├── Providers.swift    AgentProvider protocol, approval modes, Demo and Claude Code providers, stream parser
├── PermissionBridge.swift  Unix-socket server in the app plus the MCP stdio shim Claude Code calls
├── AgentLoop.swift    The shared agent loop and provider-neutral transcript types
├── BedrockProvider.swift   Bedrock backend and the AWS CLI client
├── AzureProvider.swift     Azure OpenAI backend, streaming HTTP client, SSE assembler, config validation
├── CopilotProvider.swift   Copilot CLI driver and its permission mapping
├── Keychain.swift     Keychain storage for provider credentials
├── History.swift      Mission history records and their private JSON store
├── Notifier.swift     Mac notifications
├── WakeWord.swift     "Hey Tristan" matcher, silence-timing state machine and on-device listener
├── SettingsView.swift Configuration and history overlays
├── AgentTools.swift   Sandboxed file and shell tools, safe-path resolution, tool policy per mode
├── Audio.swift        Synthesised sound effects and spoken lines
├── Voice.swift        Push-to-talk speech recognition
├── Snapshot.swift     Renders the README screenshots from the real views
├── HUDView.swift      The main HUD, command bar and approval overlay
├── Notch.swift        Notch geometry, overlay panel and its expand/collapse logic
├── Theme.swift        Colours, glow panel, arc reactor, animated backdrop
└── HotKey.swift       Global hotkey through Carbon (no accessibility permission needed)
Tests/TristanTests/    45 tests: agent loop per provider, sandbox, rules, SSE, Copilot flags, wake word, history, audio
.github/workflows/     CI: build, test and bundle on macOS
```

A provider turns a task into a stream of events:

```swift
protocol AgentProvider: Sendable {
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent>
}

enum AgentEvent { case status(String), log(String), code(String), done(String), failed(String) }
```

`Session` consumes that stream and publishes state. The HUD and the notch both render from the same `Session`, so they always agree. A provider asks for permission by calling `approve(...)`, which suspends until you tap Approve or Deny.

### How approvals work

In `ASK` mode Tristan starts Claude Code with `--permission-mode manual` and `--permission-prompt-tool mcp__tristan__approve`, plus an MCP config that points at **its own binary** run as `Tristan --mcp-permission <socket>`. When Claude Code needs permission for a tool call:

1. It calls the `approve` tool on that tiny MCP stdio shim.
2. The shim forwards the request over a private Unix socket (a temp folder with `0700` permissions) to the running app.
3. The app shows the action in the HUD or notch and waits for you.
4. Your answer goes back as `{"behavior":"allow"}` or `{"behavior":"deny"}`.

**Always allow rules are deliberately narrow.** Tristan only offers `ALWAYS ALLOW` where generalising is reasonably safe:

| Action | Rule it remembers |
|--------|-------------------|
| `Edit`, `Write`, `MultiEdit`, `NotebookEdit` | That tool, for files **inside the working folder** only |
| `Bash` | The program name only (for example `npm` or `touch`) |

It is **not** offered for shell commands that chain or redirect (`;`, `&&`, `|`, `>`, `<`, backticks, `$(…)`), for risky programs (`rm`, `sudo`, `dd`, `chmod`, `mv`, `curl`, `sh`, `ssh` and similar), or for any other tool. Those always ask. Note that allowing a program like `npm` lets it run any arguments you did not see, so treat it as trust in that program.

Your existing Claude Code allow rules still apply, so actions you already allowed in your own settings are not asked about again. `AUTO` and `YOLO` skip the bridge and pass `--permission-mode auto` or `bypassPermissions` instead.

### Running the tests

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The Bedrock agent loop is tested end to end with a scripted fake model: approvals in every mode, denied actions reaching the model, sandbox and symlink escapes, the turn limit and error handling.

### Testing without the UI

```bash
# Drives a real Session without any window. The last argument answers approvals (allow, deny, always)
# or picks a mode (auto, yolo)
.build/debug/Tristan --headless /path/to/folder "Use Bash to run: echo hi > out.txt" deny
```

### Adding a provider

1. Create a type conforming to `AgentProvider` in `Providers.swift` (or its own file).
2. Emit `AgentEvent`s as work happens. Call `approve(...)` before anything with side effects.
3. Add a case to `ProviderKind` and return your provider from `makeProvider()`.

## Known limitations

**What has actually been verified live:** the Claude Code provider (all modes, including per-action approvals), the HUD and the packaged app launching. **Everything below is built and tested with fakes but not yet run against the real thing:**

- **Bedrock** has not run against live AWS (the AWS session was expired when it was built). The request format was checked against the AWS CLI's own skeleton.
- **Azure OpenAI** has not run against a real deployment. The streaming parser and wire format are tested with synthetic data in the OpenAI format.
- **Copilot** was not launched with real permissions during development. The command-line flags follow the CLI's own help text, and process handling is tested with a stand-in command. Its output format is unstructured, so the HUD shows it as plain text.
- **Wake word, push-to-talk, sound and notifications** build, launch and have unit tests for the logic (matching, timing, synthesis, gating), but have not been heard or seen working by me. Voice needs microphone and speech permission; the wake word needs a language with on-device recognition.
- **`YOLO` is exactly as risky as it sounds.** Do not use it in a folder you cannot afford to lose.
- **Actions you already allowed in your own Claude Code settings are not asked about again** in `ASK` mode.
- **Copilot cannot be approved per action** (see [GitHub Copilot](#github-copilot)).
- **Bedrock responses are not streamed** (see [AWS Bedrock](#aws-bedrock)).
- The notch overlay has only been tested on a notched MacBook, and the visuals have not had a design pass on other displays.
- Sound and voice quality depend on the voices installed on your Mac (a British English voice is preferred).

## Roadmap

Done:

- [x] Per-action approvals for Claude Code, approval modes (ask, auto, yolo) and "always allow"
- [x] Claude Code, Bedrock, Azure OpenAI and Copilot providers
- [x] Shared agent loop with sandboxed file and shell tools for the model-only providers
- [x] Push-to-talk voice, spoken results, sound effects and voice feedback
- [x] Optional on-device "Hey Tristan" wake word
- [x] Mac notifications, mission history with re-run
- [x] Settings: shortcut, default folder, Keychain credentials, remembered choices
- [x] Streaming for Azure OpenAI
- [x] Automated tests (45) and CI workflow

Next:

- [ ] Live validation of Bedrock, Azure OpenAI, Copilot, wake word and notifications (needs real credentials and a human in front of the Mac)
- [ ] Bedrock streaming (SigV4 signing plus event-stream parsing, or the AWS SDK)
- [ ] Per-action approvals for Copilot, if the CLI gains a permission prompt hook
- [ ] A shortcut recorder instead of presets
- [ ] Search and filters in mission history

## Regenerating the screenshots

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
.build/debug/Tristan --snapshot docs/screenshots
```

## Security notes

Tristan runs agents that can change files and run commands on your machine. Review what you approve.

- Secrets (the Azure OpenAI key) are stored in the macOS Keychain, never in the repository or in preferences. Entra ID and AWS logins are borrowed from the Azure CLI and AWS CLI and are never stored by Tristan. Because the app is only ad-hoc signed, macOS may ask for Keychain access again after you rebuild it.
- Mission history stores task text and short summaries, so treat it as private; it is `0600` and can be cleared in the app.
- The wake word is off by default, runs on-device only, and the microphone is released while a mission runs.
- Claude Code actions are gated per action in `ASK` mode, but Copilot's headless mode cannot be (see above).

## License

[MIT](LICENSE) © 2026 Mario Tristan
