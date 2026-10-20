<!-- One issue = one branch = one PR. Fill in every section; everything must be in English. -->

## Linked issue

Closes #

## Summary

<!-- What does this PR change, and why? -->

## Changes

-

## Checklist

- [ ] Everything (title, description, commits, code comments, docs) is in English
- [ ] Only `///` doc comments in Dart code (no `//`, `/* */`, `/** */`, no `// ignore:`)
- [ ] Formatting passes: `dart format --set-exit-if-changed .`
- [ ] Analysis passes: `dart analyze --fatal-infos`
- [ ] Tests added/updated
- [ ] Tests pass: `dart test`
- [ ] format/analyze/test pass locally
- [ ] Coverage meets the threshold configured in `k.yaml`
- [ ] No direct dependency outside dart.dev/tools.dart.dev/labs.dart.dev (exceptions listed in `k.yaml` with a reason, approved via Grok Bot)
- [ ] Settings live in `k.yaml`, nothing hard-coded
- [ ] All acceptance criteria of the linked issue are met
- [ ] `AGENTS.md` updated if the workflow or rules changed

## Acceptance criteria

<!-- Copy the acceptance criteria from the linked issue and tick each one. -->

- [ ]

## Notes for the Reviewer

<!-- Anything the Reviewer should know: trade-offs, follow-ups, how to test. -->
