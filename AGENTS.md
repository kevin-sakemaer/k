# AGENTS.md — workflow

All agents share the `kevin-sakemaer` GitHub account: classic GitHub approval is impossible, so validation relies on labels checked in CI.

## Workflow
1. **One issue = one branch = one PR.** Never push directly to `main`.
2. Open the PR referencing the issue (`Closes #N`).
3. Required checks on `main`: **`test`** and **`review-gate`**.
   - `test`: `dart format --set-exit-if-changed`, `dart analyze --fatal-infos`, `dart test` (when `pubspec.yaml` and tests exist).
   - `review-gate`: fails without the `review:approved` label or when `review:changes-requested` is present.
4. **Reviewer verdict**: a comment on the PR **and** a label, `review:approved` or `review:changes-requested`.
5. **Every push** to the PR automatically removes `review:approved`: a new review is required.
6. **Auto-merge**: once the required checks are in place (ruleset from #2 active), the dev runs `gh pr merge --auto --squash`. The PR merges by itself when the Reviewer adds `review:approved` and everything is green.
7. **Nobody merges by hand** (only exception: the bootstrap of #1 and #2, merged once after the Reviewer's verdict).

## Dependencies
- **Direct** dependencies are allowed only if their verified publisher on pub.dev is `dart.dev`, `tools.dart.dev` or `labs.dart.dev`.
- Any exception must be approved through **Grok Bot**.
