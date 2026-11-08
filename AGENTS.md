# Instructions for coding agents

T.R.I.S.T.A.N. is a native macOS HUD for AI coding agents, with an iPhone and iPad remote and a Windows terminal command (`tristan`). It is a just-for-fun family project. This file is read by Codex, Cursor, GitHub Copilot's coding agent, Jules, Amp, Aider, Factory and other tools that follow the `AGENTS.md` convention. `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`, `.cursor/rules/`, `.windsurfrules`, `.clinerules` and `CONVENTIONS.md` point here.

**Before you change the website (`docs/`), the README or the issues, read [`docs/site-guide.md`](docs/site-guide.md).** It has the page template, the writing style, the status labels, the checklists and the pull request flow. The rules below are the short version.

## Rules that always apply

1. **Honesty first.** Say what was run, where, and what was not checked. Never claim a platform, provider or device works unless it was run there. Use absolute dates, and take versions, counts and timestamps from the repository.
2. **No employer, client or personal data in anything public** (pages, README, commits, issues, pull requests, screenshots). No secrets, tokens, account names, host names or machine names either.
3. **Never push to `main`.** Branch, open a pull request, wait for the required checks (`build-and-test`, `ios`, `windows`, `gitleaks`), squash-merge. Never force-push. Do not create tags or releases unless the owner asks.
4. **Never run a real `claude`, `copilot`, `aws`, `az` or `ollama` from a test or a check.** Use the fakes in `scripts/ci/fakes` by absolute path.
5. **The site is hand-written static HTML in `docs/`.** No framework, no build step, no external scripts. Keep pages accessible and usable at phone width. An em dash only in the `<title>` and `og:title`; none in new body text. Write the name as T.R.I.S.T.A.N. in prose and `tristan` for the command.
6. **Keep repeated facts in sync** (version, file names, test counts, theme count, backlog rows, timeline). Search the repository for the old value before you open the pull request.
7. **Audio:** quality over loudness. Measure recordings, say they were measured and not heard, and never leave the voice at full volume.

## Build and test

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test    # Mac: all targets (Xcode is required)
swift test --filter TristanCoreTests                                    # Windows or Linux: the portable core
swift test --filter TristanCLITests                                     # the tristan command
bash scripts/ci/test-changed-paths.sh                                   # the CI path classifier
bash scripts/check-site.sh                                              # the site checks (menus, links, dashes)
```

## Layout

- `Sources/TristanCore`: the portable core (agent loop, tools, providers, memory, history, approval policy).
- `Sources/Tristan`: the Mac app (`Shared/` is also compiled into the iOS app).
- `Sources/TristanCLICore`, `Sources/TristanCLI`: the `tristan` command.
- `ios/`: the iPhone and iPad app. After adding or removing a file in `Sources/TristanCore` or `Sources/Tristan/Shared`, run `cd ios && xcodegen generate`.
- `docs/`: the website (GitHub Pages), notes, design specs and plans. `scripts/`: packaging and CI helpers. `.github/workflows/`: CI and releases (see `docs/ci-and-release.md`).

## Working with issues and pull requests

- Open issues are the backlog, sized in `docs/backlog.html`. When you add or close an issue, update that page (rows, totals, area table).
- A pull request that touches only `docs/` and top-level Markdown skips the build jobs. Anything under `Sources/`, `Tests/`, `ios/`, `scripts/` or the workflows runs the jobs it belongs to.
- Commit messages are short and say why. Keep unrelated files out of the commit.
