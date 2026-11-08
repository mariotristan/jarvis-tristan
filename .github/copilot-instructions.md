# Instructions for GitHub Copilot

Follow [`AGENTS.md`](../AGENTS.md) and, for anything under `docs/`, the README or issues, [`docs/site-guide.md`](../docs/site-guide.md).

Always:

- Say what was run and what was not checked; use absolute dates and real numbers from the repository.
- Keep the author's employer, clients, secrets, account names and machine names out of everything public.
- Work on a branch and open a pull request. Never push to `main`; no tags or releases unless the owner asks.
- Never start a real `claude`, `copilot`, `aws`, `az` or `ollama` from a test or a check.
- The website is hand-written static HTML in `docs/`: no framework, no external scripts, accessible, usable at phone width, an em dash only in the title and none in new body text, the name written T.R.I.S.T.A.N.
- Run `bash scripts/check-site.sh` and `bash scripts/ci/test-changed-paths.sh` (when you touch CI paths) before you open the pull request.
