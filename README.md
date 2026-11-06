# T.R.I.S.T.A.N.

A native macOS harness for AI coding agents, wrapped in an Iron Man style heads-up display.

You give Tristan a task ("add login to the API"). It works inside a project folder on your Mac, the way Claude Code does. You watch it think, write code and run commands through a glowing HUD, a notch overlay and a lot of animation. Before it edits files or runs commands, it asks you first.

> **Status: early experiment.** The first slice works end to end with a scripted demo provider and the Claude Code CLI. Copilot, Bedrock, Azure OpenAI and voice are planned, not built. See the [roadmap](#roadmap) and [known limitations](#known-limitations).

## Screenshots

Rendered from the real views with sample data (`Tristan --snapshot docs/screenshots`).

**The HUD while a mission runs.** Mission log on the left, code stream on the right, arc reactor on top.

![HUD while working](docs/screenshots/hud-working.png)

**Ask-first approval.** The reactor and borders turn amber until you approve or deny.

![HUD approval prompt](docs/screenshots/hud-approval.png)

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
- **Ask-first approvals.** Approve or deny from the HUD or straight from the notch.
- **Global shortcut.** `⌥ Space` shows or hides the HUD from any app. `Esc` hides it.
- **Menu bar item** next to the clock to open Tristan or quit.
- **Provider switcher** along the bottom of the HUD.
- **Folder picker** to choose the project folder the agent works in.

## Providers

| Provider | Status | How it works |
|----------|--------|--------------|
| `DEMO` | Working | Scripted run with a fake approval, for trying the HUD without spending tokens. |
| `CLAUDE` | Working (basic) | Runs `claude -p <task> --output-format stream-json --verbose` in the chosen folder and turns the JSON events into log lines and code. |
| `COPILOT` | Planned | Not wired up yet. |
| `BEDROCK` | Planned | Not wired up yet. |
| `AZURE` | Planned | Not wired up yet. |

Claude Code runs its own agent loop, so Tristan only has to drive it and display the output. Copilot, Bedrock and Azure OpenAI are models, not agents. For those, Tristan will need its own small agent loop with tools to read files, write files and run commands, still gated by approvals.

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

## How it works

```
Sources/Tristan/
├── main.swift         App entry point (accessory app, no Dock icon)
├── AppDelegate.swift  HUD window, menu bar item, global hotkey, notch setup
├── Session.swift      Observable state: phase, log, code, pending approval, provider
├── Providers.swift    AgentProvider protocol, Demo and Claude Code providers, stream parser
├── HUDView.swift      The main HUD, command bar and approval overlay
├── Notch.swift        Notch geometry, overlay panel and its expand/collapse logic
├── Theme.swift        Colours, glow panel, arc reactor, animated backdrop
└── HotKey.swift       Global hotkey through Carbon (no accessibility permission needed)
```

A provider turns a task into a stream of events:

```swift
protocol AgentProvider: Sendable {
    func run(task: String, workingDirectory: URL, approve: @escaping Approver) -> AsyncStream<AgentEvent>
}

enum AgentEvent { case status(String), log(String), code(String), done(String), failed(String) }
```

`Session` consumes that stream and publishes state. The HUD and the notch both render from the same `Session`, so they always agree. A provider asks for permission by calling `approve(...)`, which suspends until you tap Approve or Deny.

### Adding a provider

1. Create a type conforming to `AgentProvider` in `Providers.swift` (or its own file).
2. Emit `AgentEvent`s as work happens. Call `approve(...)` before anything with side effects.
3. Add a case to `ProviderKind` and return your provider from `makeProvider()`.

## Known limitations

- **Approvals are coarse for Claude Code.** Tristan asks once before the run, then starts Claude Code with `--permission-mode acceptEdits`, so it can edit files in the chosen folder without asking again. Per-action approval needs Claude Code's permission prompt tool and is on the roadmap. Do not point it at a folder you are not comfortable with an agent editing.
- Only `DEMO` and `CLAUDE` exist. The other providers show an "offline" state.
- No voice yet.
- The notch overlay has only been tested on a notched MacBook, and the visuals have not had a design pass on other displays.
- No automated tests yet.

## Roadmap

- [ ] Per-action approvals for Claude Code through its permission prompt tool
- [ ] Voice input, push-to-talk first, wake word later
- [ ] Spoken responses
- [ ] Own agent loop with file and shell tools for the model-only providers
- [ ] GitHub Copilot provider
- [ ] AWS Bedrock provider
- [ ] Azure OpenAI provider
- [ ] Mac notifications for approvals and finished missions
- [ ] Settings window (shortcut, default folder, credentials in the Keychain)
- [ ] Task history
- [ ] Tests

## Regenerating the screenshots

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
.build/debug/Tristan --snapshot docs/screenshots
```

## Security notes

Tristan runs agents that can change files and run commands on your machine. Credentials for future providers will be stored in the macOS Keychain, never in the repository. Review what you approve.

## License

[MIT](LICENSE) © 2026 Mario Tristan
