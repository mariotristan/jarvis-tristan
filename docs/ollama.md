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
pwsh -File scripts\setup-ollama.ps1 -StartOnly      # only start an installed Ollama; without Ollama it says so and exits 0 (setup-ollama.sh --start-only exits 2)
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
| `llama3.1` (default) | Handles tool calls well in the round one benchmark below, but it ran a command for a plain question we asked, so expect it to reach for tools when you only wanted an answer. |
| `qwen2.5-coder` | Writes good code, but in the round one benchmark below it wrote its tool calls as plain text, so it could not do the file and command tasks. |
| Any other | Try it. A model without tool support gets a clear message in the log; it still answers plain questions. |

Small models are more likely to fumble tool calls than a cloud model, so expect simple edits to work better than long multi-step tasks.

## Which model? Round one, 8 November 2026

Issue [#86](https://github.com/mariotristan/jarvis-tristan/issues/86) asked which local models come closest to a cloud agent. This is a small first round: five models on one Mac. It did **not** compare any model with a cloud provider, the seven tasks are short and easy, and every pass or fail is a rule in the script, not a person's judgement.

Machine: Apple M4 Pro, 48 GB, Ollama 0.40.14. Each model got each task 3 times (`temperature` 0, fixed seed) through `/api/chat` with tools. The runs are close to identical repeats, so 3/3 means steady, not three independent samples. Tasks: three tool calls (read a file, start a small edit, run a listing command; the script only checks the call and never runs it), a plain question that must not call a tool, a spoken status line (at most 25 words, no Markdown), a small coding task (run in a throwaway Python process, `re` is the only import allowed) and finding one codeword in about 8,000 to 10,500 tokens.

| Model | Read, edit, run | Plain question | Spoken line | Code | Long context | Speed | Loaded size |
|-------|-----------------|----------------|-------------|------|--------------|-------|-------------|
| `qwen3:8b` | 3/3, 3/3, 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 36 tokens/s | 9.5 GB |
| `qwen3:14b` | 3/3, 3/3, 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 24 tokens/s | 13.9 GB |
| `gemma4:12b-it-q4_K_M` | 3/3, 3/3, 3/3 | 3/3 | 3/3 | 3/3 | 3/3 | 42 tokens/s | not measured |
| `llama3.1` (8B, the default) | 3/3, 3/3, 3/3 | **0/3** | 3/3 | 3/3 | 3/3 | 40 tokens/s | 9.2 GB |
| `qwen2.5-coder` (7B) | **0/3, 0/3, 0/3** | 3/3 | 3/3 | 3/3 | 3/3 | 43 tokens/s | 6.6 GB |

- Speed is the median generated tokens per second over all tasks (the Qwen3 models think first and those tokens count). Loaded size is what Ollama reported after the long-context task, so it includes working memory for about 10,000 tokens. The `gemma4` figure looked wrong (about 1 GB) and is left out.
- Time to first token is **not** published: the runs reused Ollama's prompt cache, so the times were near zero.
- `llama3.1` asked to run `git help branch` instead of answering "In one sentence, what is a git branch?" in all three runs (one question, so how often it happens is not known). `qwen2.5-coder` replied with `{"name": "read_file", ...}` as text; we did not check whether the app copes with that.
- A first version of the script marked the Qwen3 and Gemma 4 models down for the wrong reasons. Those two checks were fixed and the cells that had failed or could have been affected were re-run (edit: `gemma4`, `llama3.1`, `qwen2.5-coder`; code: both Qwen3 models, `llama3.1`, `qwen2.5-coder`). Cells that had already passed were kept, because the fixed checks accept everything the first ones did; the other cells come from the first full run, with unchanged checks. The code check was made stricter afterwards and not re-run, so a fresh run may differ slightly.

Candidates by Mac memory (Ollama library **download** sizes for the default 4-bit builds and their listed tool support, checked 8 November 2026; only the models in the table were run). A model used about 1.5 to 1.8 times its download while running in our test (`qwen3:14b`: 9.3 GB became 13.9 GB), so a download size does not prove a fit:

| Mac memory | Models to try | Status |
|------------|------------------------|--------|
| 8 GB | `qwen3:4b` (2.5 GB), `gemma4:e4b-it-q4_K_M` (6.6 GB, tight) | Not measured |
| 16 GB | `qwen3:8b` (5.2 GB), `gemma4:12b-it-q4_K_M` (8.0 GB), `qwen3:14b` (9.3 GB, 13.9 GB loaded, probably too big) | Measured on a 48 GB Mac, headroom on 16 GB not checked |
| 32 GB | `qwen3-coder:30b` (19 GB), `qwen3.8:27b` (18 GB), `qwen3.6:27b` (17 GB), `gemma4:26b-a4b-it-q4_K_M` (18 GB), `gpt-oss:20b` (14 GB), `devstral` (14 GB) | Not measured, planned in [#90](https://github.com/mariotristan/jarvis-tristan/issues/90) |
| 48 GB | the 32 GB list plus `gemma4:31b-it-q4_K_M` (20 GB) and `qwen3.6:35b-a3b` (23 GB) | Not measured, planned in #90 |

For now: `qwen3:8b` is a good all-round pick on 16 GB or more (all seven tasks, 36 tokens/s, 9.5 GB loaded), `qwen3:14b` is the best quality measured (same score, slower), and `gemma4:12b-it-q4_K_M` is the fastest that passed everything. These are suggestions from five models and a short test. The setup script still pulls `llama3.1`; to use another model run `scripts/setup-ollama.sh qwen3:8b` and pick it in Configuration. When no local model is good enough, stay on a cloud provider: the offline fallback still asks before every action, and a rule that refuses risky actions on a weak model is not built.

To run it yourself (manual, never part of the tests, needs Python 3 and a running Ollama; it does not set `num_ctx`, so the long-context task needs an Ollama default of at least about 11,000 tokens): `python3 scripts/bench-ollama.py qwen3:8b llama3.1 --runs 3 --json results.json`. Pass `--only tool_edit,code` to run some tasks. Round two is in #90.

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
