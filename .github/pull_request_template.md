<!-- One issue = one branch = one PR. Fill in every section; everything must be in English. -->
<!-- Draft-first (#27): open with `gh pr create --draft`, run `gh pr ready` only once every CI check is green, and `gh pr ready --undo` if CI turns red after review. -->

## Linked issue

<!-- Use `Closes #N` only if this PR fully delivers the issue. Otherwise use `Part of #N` or `Refs #N` and no closing keyword anywhere. -->

Closes #

## Summary

<!-- What does this PR change, and why? -->

## Changes

-

## Checklist

<!-- Apply the "Pre-commit checklist" of AGENTS.md before every commit and push. Install the hooks once per clone with `tool/install_hooks.sh`; they run `tool/check.sh`, the same script as the `test` CI job. -->

- [ ] The [Pre-commit checklist](https://github.com/kevin-sakemaer/k/blob/main/AGENTS.md#pre-commit-checklist) of `AGENTS.md` is applied: branch contains up-to-date `origin/main`, `tool/check.sh` passes (hooks installed with `tool/install_hooks.sh`), and `git diff origin/main` was self-reviewed

- [ ] Opened as a draft and marked ready only once every CI check is green (back to draft with `gh pr ready --undo` if CI turns red)
- [ ] Everything (title, description, commits, code comments, docs) is in English
- [ ] Only `///` doc comments in Dart code (no `//`, `/* */`, `/** */`, no `// ignore:`)
- [ ] Tests added/updated
- [ ] Coverage meets the threshold configured in `k.yaml`
- [ ] No direct dependency outside dart.dev/tools.dart.dev/labs.dart.dev. An exception needs both an entry in `k.yaml` with an explicit reason **and** approval via Grok Bot, linked in this PR
- [ ] Settings live in `k.yaml`, nothing hard-coded
- [ ] All acceptance criteria of the linked issue are met
- [ ] `Closes #N` only if this PR fully delivers the issue; a partial PR (`Part of #N` / `Refs #N`) has no closing keyword (close/fix/resolve and their forms followed by `#N`) in its title, description or commits
- [ ] `AGENTS.md` updated if the workflow or rules changed

## Acceptance criteria

<!-- Copy the acceptance criteria from the linked issue and tick each one. -->

- [ ]

## Notes for the Reviewer

<!-- Anything the Reviewer should know: trade-offs, follow-ups, how to test. -->
