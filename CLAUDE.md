# Claude Code

@AGENTS.md

Claude Code specifics:

- Read `docs/site-guide.md` before you edit anything under `docs/`, `README.md` or an issue. Its checklist (section 11) is the definition of done for site work.
- For a change that touches several pages or the menu, make a short plan first, then edit, then run `bash scripts/check-site.sh`.
- Use a separate subagent or `/code-review` for review, and give it the diff, not your conclusion.
- Do not run `gh release`, push tags, or merge your own pull request unless the owner asked in this session.
