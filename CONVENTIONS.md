# Conventions (Aider and other tools that load a conventions file)

The rules for this repository are in [`AGENTS.md`](AGENTS.md), and the full rules for the website are in [`docs/site-guide.md`](docs/site-guide.md). Read both before you edit.

The short version:

- Say what was actually run and what was not. Use absolute dates and real numbers from the repository.
- Keep the author's employer, clients, secrets, account names and machine names out of everything public.
- Work on a branch and open a pull request. Never push to `main`. No tags or releases unless the owner asks.
- Never start a real `claude`, `copilot`, `aws`, `az` or `ollama` in a test.
- The site is plain static HTML in `docs/`: no framework, no external scripts, accessible, works at phone width, an em dash only in the title and none in new body text.
- Run `bash scripts/check-site.sh` before you open the pull request.
