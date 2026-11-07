# Local models with Ollama

T.R.I.S.T.A.N. can run on a model that lives on your own Mac, through [Ollama](https://ollama.com). Nothing is sent over the internet: no account, no API key, no cloud. It is also what **kids safe mode** uses, so a child's questions stay on the Mac.

## Quick start

```sh
scripts/setup-ollama.sh                 # installs Ollama if needed and pulls llama3.1
scripts/setup-ollama.sh qwen2.5-coder   # or pull a different model by name
```

Then open T.R.I.S.T.A.N., pick `OLLAMA` along the bottom and give it a task. In **Configuration > OLLAMA** you can see the installed models, click one to choose it, and press **REFRESH** to rescan. Leave the model blank to use the first installed one.

## On Windows

`scripts/setup-ollama.ps1` does the same job for the `tristan` command (see [Windows](https://mariotristan.github.io/jarvis-tristan/windows.html)):

```powershell
pwsh -File scripts\setup-ollama.ps1                 # checks for Ollama, starts it, pulls llama3.1, sets it for tristan
pwsh -File scripts\setup-ollama.ps1 qwen2.5-coder   # another model
pwsh -File scripts\setup-ollama.ps1 -StartOnly      # only start an installed Ollama; without Ollama it says so and exits 0
pwsh -File scripts\setup-ollama.ps1 -NoPin          # do not run `tristan config set ollama.model`
```

It never installs Ollama by itself: when Ollama is missing it prints `winget install -e --id Ollama.Ollama` and exits 2. Windows CI checks that it parses, the `-StartOnly` and missing-Ollama paths, and its refusal of bad arguments; the start, pull and check steps have not yet run on a Windows machine with Ollama.

## What `scripts/setup-ollama.sh` does

The script is plain bash (`set -euo pipefail`), safe to run again, and prints each step. Read it before you run it: it is about 50 lines.

| Step | What happens | If it fails |
|------|--------------|-------------|
| 1. Find Ollama | Looks for `ollama` on `PATH`. If missing, runs `brew install ollama`. | Without Homebrew it stops and points you to <https://ollama.com/download>. |
| 2. Start the server | Asks `http://localhost:11434/api/tags`. If nothing answers, it starts `ollama serve` in the background (log: `/tmp/ollama-serve.log`) and waits up to 30 seconds. | Stops and names the log file. |
| 3. Pull the model | Runs `ollama pull <model>`. The default, `llama3.1`, is about 5 GB the first time; later runs finish at once. | Ollama's own error is shown (for example, an unknown model name). |
| 4. Check it answers | Sends one tiny chat request to `/v1/chat/completions` (the same endpoint T.R.I.S.T.A.N. uses) and prints the reply. | Stops and prints the error. |
| 5. Check tool support | Sends a request that offers a `list_dir` tool. If Ollama replies "does not support tools", it prints a warning. | Only a warning: such a model still works for questions (kids mode) but not for coding. |
| 6. Summary | Prints `ollama list` and, if the script started the server, how to stop it (`pkill -f 'ollama serve'`). | |

What it does **not** do: it never touches T.R.I.S.T.A.N.'s settings, never sends anything off the machine other than downloading the model from Ollama's registry, and never deletes models.

## Choosing a model

T.R.I.S.T.A.N. edits files and runs commands through **tool calls**, so a coding task needs a model that supports them.

| Model | Good for |
|-------|----------|
| `llama3.1` (default) | A solid all-rounder that handles tools. |
| `qwen2.5-coder` | Coding tasks. |
| Any other | Try it. A model without tool support gets a clear message in the log; it still answers plain questions. |

Small models are more likely to fumble tool calls than a cloud model, so expect simple edits to work better than long multi-step tasks.

## How it works inside T.R.I.S.T.A.N.

- `Sources/TristanCore/OllamaProvider.swift` talks to Ollama's OpenAI-compatible endpoint (`/v1/chat/completions`, streaming) and reuses the same agent loop as Azure OpenAI.
- Model discovery uses `GET /api/tags` with a 2-second timeout. A blank model means "the first one in Ollama's list", which is the one added or used most recently, so downloading another model can change which one is used. Pick a model in Configuration to pin it; that also decides the model for the offline fallback and kids mode. A short name such as `qwen` matches `qwen:7b`.
- **Local only.** The host must be `localhost`, `127.0.0.1` or `::1` over plain `http`. Anything else is refused before a prompt is sent. Change the host with the `ollama.host` setting if you use another port (`tristan config set ollama.host http://127.0.0.1:<port>` in the terminal version).
- Errors are readable: server not running, no model installed, model not found, model without tool support.

## Kids safe mode

While kids safe mode is on:

1. Every question goes to Ollama, whichever provider is selected.
2. If Ollama isn't running or has no model, **nothing is sent anywhere**. The child sees "Please ask a parent."
3. A parent is asked (PIN, or Touch ID / Mac password) whether this one question may go to the selected cloud provider (`CLAUDE` if Ollama itself was selected).
4. Approving does not unlock kids mode, and the next question is local again. Cancelling keeps the question off the cloud.
5. T.R.I.S.T.A.N. speaks in a brighter voice with friendlier lines. It uses the most child-like voice installed (macOS's "Junior" or "Kathy" if present, otherwise a friendly American voice) and does not imitate any TV character.

Not built yet: a child-safe system prompt and screening of the model's answers.

## Testing it

`swift test` covers the host check, model resolution, the provider on a scripted model, and the kids-mode routing, refusal and one-time parent approval (`Tests/TristanCoreTests/OllamaTests.swift` and, for kids mode in the app, `Tests/TristanTests/KidsLocalOnlyTests.swift`). Building needs the full Xcode toolchain (`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`). `llama3.1`'s streamed tool-call format was checked by hand against a real Ollama; a full mission in the HUD on a local model has not been recorded yet.

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| "Ollama is not running" | `ollama serve`, or open the Ollama app. |
| "no model installed" | `scripts/setup-ollama.sh` or `ollama pull llama3.1`. |
| "cannot use tools" | Choose a tool-capable model in Configuration. |
| Kids mode says "ask a parent" for every question | The local model isn't ready. Check `ollama list` and that the server is running. |
| First answer is slow | Ollama loads the model into memory on first use. |
