# How we build this site (rules for people and coding agents)

The project site is the `docs/` folder, published by GitHub Pages at https://mariotristan.github.io/jarvis-tristan/. This guide is the one place that says how we write and change it. Every coding-tool file in the repository (`AGENTS.md`, `CLAUDE.md`, `GEMINI.md`, `.github/copilot-instructions.md`, `.cursor/rules/`, `.windsurfrules`, `.clinerules`, `CONVENTIONS.md`) points here. If a rule changes, change it here first.

T.R.I.S.T.A.N. is a just-for-fun family learning project. The site is for people who want to try it, so it stays friendly, plain and honest.

## 1. The rules that matter most

1. **Be honest about what was checked.** Say what ran, where, and what did not. Never write that something works on a platform, with a provider or on a device unless it was run there. When you are unsure, say "not checked". The status labels are in section 6.
2. **Keep the author's employer and clients out.** No public page, README line, commit message, issue, pull request or screenshot may name the author's employer, a client or an internal system. Check your diff for that before you push. The same goes for secrets, tokens, account names, machine names, hostnames and real credentials: never paste them, not even in a log excerpt.
3. **Never push to `main`.** Work on a branch, open a pull request, wait for the required checks, then squash-merge. Tags and releases are cut only when the owner asks.
4. **Tests and checks never start a real provider tool.** Do not launch a real `claude`, `copilot`, `aws`, `az` or `ollama` from a test or a check. A test once printed real credentials this way. Use the fake programs in `scripts/ci/fakes` by absolute path.
5. **Dates and numbers are real.** Use absolute dates (`8 November 2026`, never "yesterday"). Take counts, versions, test numbers and timestamps from the repository (`git log`, `git tag`, `VERSION`, the test run), not from memory, and update every place that repeats them.
6. **Accessible and mobile first.** Every page works with a keyboard, has real headings, text alternatives for images and no horizontal page scroll at phone width.

## 2. Where things live

| What | Where |
|------|-------|
| The pages | `docs/*.html` (plain HTML, one file per page) |
| Shared style and script | `docs/assets/site.css`, `docs/assets/site.js` |
| Images and icons | `docs/assets/`, screenshots in `docs/screenshots/` |
| Demo videos (tracked, MP4) | `docs/demo/` |
| Long notes that are not pages | `docs/*.md` (this guide, `ci-and-release.md`, `ollama.md`) |
| Design specs, plans and spike notes | `docs/superpowers/` |
| The README | `README.md` (short; detail lives on the site) |
| The backlog, sized | `docs/backlog.html`, from the open GitHub issues |

There is **no build step and no framework**. Do not add a site generator, a bundler, a package manager or a web font download. The pages are edited by hand and served as they are (`docs/.nojekyll` switches Jekyll off). External scripts and trackers are not allowed; nothing on the site phones home.

## 3. The page template

Copy the head, header, footer and script tag of a recent guide page (`docs/backlog.html` is a good model) and change only what is yours.

- `<title>`: `Name—T.R.I.S.T.A.N.` with one em dash and no spaces. The Open Graph title is the same. These are the only places a new page uses an em dash.
- `<meta name="description">`, `<link rel="canonical">`, the `og:` tags and the icons, all with the page's own URL.
- A skip link, the **Fork me on GitHub** ribbon, the brand link and the main menu (`<nav aria-label="Main">`) with `aria-current="page"` on the current page only.
- A title box: an `eyebrow` ("Guide · Name"), one `<h1>` and a `lead` sentence.
- `<main id="main" class="doc">` with sections made of `<section>` and `<div class="wrap">`. Alternate plain and `class="soft"` sections. Use `<h2>` for sections and `<h3>` below them, never skip a level.
- A pager at the end (`← Previous` and `Next →`) and the standard footer with the same links as the menu, then the legal line.
- Tables go inside `<div class="tablewrap">` with a `<caption>` and `scope` attributes. Status words use the `pill` classes, never colour alone.
- A new page is added to the **menu and the footer of every page**, to the cards on the home page, to the pager chain, and to `README.md` if it is a guide. `scripts/check-site.sh` checks that the menus agree.

## 4. Writing style

- Write the name as **T.R.I.S.T.A.N.** in prose. The terminal command is `tristan` in code font. Code, file names, commands and keys go in `<code>` and `<kbd>`.
- Short sentences, plain words, active voice. Explain a term the first time. A child who is reading with a parent should follow it, and so should an engineer in a hurry.
- No em dashes in new body text (a few older lines on the home page still have them; leave those alone unless you are editing the sentence), and no emoji as decoration. Use a comma, a colon or two sentences. Use a real apostrophe (’) in prose like the existing pages.
- Say what the reader can do next. Put the command in a code block and the result under it.
- Mark limits with `<p class="note">`. Say "plans, not promises" for the roadmap.
- Do not invent features, quotes, benchmarks or user feedback. Link the issue or the commit instead.
- Do not name a competitor's product in a way that implies an endorsement. The footer disclaimer stays.

## 5. Facts that are repeated, and where

When one of these changes, search the whole repository for the old value before you open the pull request.

| Fact | Appears in |
|------|------------|
| Version (`VERSION`) and the file names `Tristan-<version>…` | `docs/index.html` (download line, install steps), `docs/install.html`, `docs/windows.html`, `README.md` |
| Test counts | `README.md`, `docs/index.html`, `docs/windows.html` |
| Theme count (32) | `README.md` (two places), `docs/index.html`, `docs/themes.html` (one picture per theme) |
| Providers and what is verified | `docs/providers.html`, `docs/index.html`, `docs/windows.html` (the matrix), `README.md` (Known limitations) |
| Open issues and sizes | `docs/backlog.html` (rows, totals, area table) |
| Timeline | `docs/how-we-build.html`, and `docs/windows.html` for the Windows port |

After a release, a docs pull request updates every place that names the released files, and adds the release to the timeline.

## 6. Honest status labels

The Windows page uses four labels, strictly. Reuse them wherever you describe what is supported:

- **Verified in CI**: a test or check ran on a GitHub Actions runner and passed.
- **Checked by hand**: a person ran it once on a real machine. Say what machine, what version and exactly which commands. It is a smoke check, not a test suite.
- **Implemented, needs a live-account check**: the code exists and was exercised with fakes, but not against the real service or a person at a real console.
- **Not on this platform**: not built for it yet.

When you add a check by hand, also say what it did **not** cover (for example the installer, SmartScreen or a clean install). Record the date.

## 7. Images, video and sound

- Screenshots come from the app itself: `swift build` then `.build/debug/Tristan --snapshot docs/screenshots`. Do not edit them by hand, and do not show real paths, names or tokens in them.
- The theme pictures come from `.build/debug/Tristan --snapshot-themes docs/screenshots/themes`, one JPEG per theme (1000 pixels wide, about 130 KB). Run it again when a theme is added or its colours change, and update `docs/themes.html` and the README grid. It does not change your saved theme.
- Demo videos are made by `scripts/record-demo.sh` (and `record-demo.sh kids`). They overwrite the tracked MP4s in `docs/demo/`: when you only test the recorder, copy the originals aside and `git checkout docs/demo` afterwards. Quit the installed app first.
- The kids demo uses the scripted DEMO provider only and never a real model. Kids mode always asks before an action, and a demo must not bypass that.
- Demo mode never touches the real Keychain.
- Sound: choose a clean voice over a loud one. Measure the recorded audio (peak, samples at full scale, crackle score, timing) with `scripts/record-window.swift`, say that it was measured and not heard, and ask a person to listen before you call audio done. Never leave the voice at full volume. See `docs/audio-crackle.html`.
- Give every `<img>` an `alt` (empty only when decorative) and every `<video>` a poster and controls.

## 8. Timelines and numbers from git

Timeline entries come from the repository, not from memory:

```bash
git log --reverse --format='%h %ad %s' --date=format:'%d %b %H:%M'
git tag -l --format='%(refname:short) %(creatordate:iso8601)'
gh pr list --state merged --json number,title,mergedAt
```

- Give the time zone once at the top of the timeline (commit times are UTC−6).
- Release entries link to `https://github.com/mariotristan/jarvis-tristan/releases/tag/<tag>`. A version that was bumped but never tagged is said to be untagged.
- Each entry has a `<time datetime="…">` with the real date, and a short hash or a pull request number a reader can look up.
- New work goes at the bottom of the list (oldest first).

## 9. How a change reaches `main`

1. Branch from an up-to-date `main` (`git switch -c docs/what-you-change`).
2. Edit. Run `scripts/check-site.sh` and, if you touched the classifier, `bash scripts/ci/test-changed-paths.sh`.
3. Open a pull request. Describe what changed and what was not checked.
4. CI is path-aware: a docs-only pull request skips the build jobs and is ready in about a minute. The required checks are `build-and-test`, `ios`, `windows` and `gitleaks`; a skipped job counts as passing. A change to `scripts/` or the workflows runs the jobs it belongs to (rules at the top of `scripts/ci/changed-paths.sh`).
5. Squash-merge once the checks pass. No approval is needed, but do not merge your own pull request if someone asked to review it.
6. Releases: a tag `vX.Y.Z` on a `main` commit whose `VERSION` was bumped. Ask the owner first. See `docs/ci-and-release.md`.

Never force-push, never skip hooks or checks, and keep unrelated files (for example an untracked `Package.resolved`) out of the commit.

## 10. Building and testing the code

- Swift tests need Xcode: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`. On Windows: `swift test --filter TristanCoreTests` and `--filter TristanCLITests`.
- Source layout: `Sources/TristanCore` (the portable core), `Sources/Tristan` (the Mac app, with `Shared/` also compiled into the iOS app), `Sources/TristanCLI*` (the `tristan` command), `ios/` (the iPhone and iPad app), `scripts/` (packaging and CI helpers).
- After adding or removing a file under `Sources/TristanCore` or `Sources/Tristan/Shared`, regenerate the iOS project (`cd ios && xcodegen generate`) or CI fails.
- Public documentation of tests and CI lives in `README.md` and `docs/ci-and-release.md`.

## 11. A checklist before you open the pull request

- [ ] Every claim says what was actually run, where, and what was not checked.
- [ ] Dates are absolute; versions, counts and links match the repository.
- [ ] No employer, client, secret, account, host or machine name anywhere in the diff.
- [ ] Menus, footers, pagers and home-page cards agree (`scripts/check-site.sh` passes).
- [ ] Headings in order, alt text present, tables in `tablewrap`, nothing scrolls sideways at 360 px wide.
- [ ] No em dashes in new body text; the product name is T.R.I.S.T.A.N.
- [ ] The branch is not `main`, and the commit does not include unrelated files.
