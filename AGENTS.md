# AGENTS.md — workflow

All agents share the `kevin-sakemaer` GitHub account: classic GitHub approval is impossible, so validation relies on labels checked in CI.

## Repository rules
- Everything on GitHub (issues, PRs, labels, comments, commit messages, docs, code comments) is in English.
- Dart code uses only `///` doc comments; `//`, `/* */`, `/** */` and `// ignore:` are forbidden.
- Public members are documented.
- `k.yaml` at the repository root is the single source of configuration; nothing is hard-coded.
- Every rule must live in a required CI check. Checks still to come, each tracked in its own issue and made required on `main` when done:
  - `///`-only comments: #9;
  - dependency publishers: #4;
  - `k.yaml` validation: #10.

## Workflow
1. **One issue = one branch = one PR.** Never push directly to `main`.
2. Open the PR referencing the issue (`Closes #N`).
3. Required checks on `main`: **`test`** and **`review-gate`**.
   - `test`: when `pubspec.yaml` exists, runs `dart pub get`, `dart format --set-exit-if-changed`, `dart analyze --fatal-infos` and `dart test`. It fails if there are no tests. Without `pubspec.yaml` it passes.
   - `review-gate`: fails without the `review:approved` label or when `review:changes-requested` is present.
4. **Reviewer verdict**: a comment on the PR **and** a label, `review:approved` or `review:changes-requested`. Before re-approving, the Reviewer removes `review:changes-requested`.
5. **Every push** to the PR automatically removes `review:approved`, and `review-gate` turns red on the new commit. Removing a label with the workflow token does not trigger a new run, so the check **stays red until the Reviewer adds `review:approved` again**.
   - On fork PRs the token is read-only: the label cannot be removed automatically and the job fails with a clear message; the Reviewer removes the label by hand.
6. **Auto-merge** (not active yet, see below): the dev runs `gh pr merge --auto --squash`. The PR merges by itself when the Reviewer adds `review:approved` and every required check is green.
7. **Nobody merges by hand.** The only exception is the bootstrap: the PRs for #1 and #2 are merged once by hand after the Reviewer's verdict.

## Current status (#2)
- Done: squash merge only, branches deleted after merge.
- Right after this PR is merged:
  - create the `main` ruleset (PR required, squash only, 0 approvals, resolved threads, strict required checks `test` and `review-gate`, no force-push, no deletion, no bypass);
  - enable `allow_auto_merge`.
- Until then, auto-merge is **not** available, and direct pushes to `main` are not blocked by GitHub.

## Dependencies
- **Direct** dependencies are allowed only if their verified publisher on pub.dev is `dart.dev`, `tools.dart.dev` or `labs.dart.dev`.
- Any exception must be approved through **Grok Bot**.
