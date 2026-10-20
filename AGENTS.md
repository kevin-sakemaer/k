# AGENTS.md — workflow

All agents share the `kevin-sakemaer` GitHub account: classic GitHub approval is impossible, so validation relies on labels checked in CI.

## Repository rules
- Everything on GitHub (issues, PRs, labels, comments, commit messages, docs, code comments) is in English.
- Dart code uses only `///` doc comments; `//`, `/* */`, `/** */` and `// ignore:` are forbidden. This rule applies to Dart only: `#` comments in shell and YAML are allowed.
- Public members are documented.
- `k.yaml` at the repository root is the single source of configuration; nothing is hard-coded.
- Every rule must live in a required CI check. Checks still to come, each tracked in its own issue and made required on `main` when done:
  - `///`-only comments: #9;
  - dependency publishers: #4;
  - `k.yaml` validation: #10.

## Pre-commit checklist
Mandatory before every commit and push (#16). The Reviewer may reject without detailed review any PR failing one of these points.

1. Branch rebased on up-to-date `origin/main`, containing no commits from other PRs.
2. `dart format --set-exit-if-changed .`
3. `dart analyze --fatal-infos` with zero diagnostics, including against the strictest analysis_options (#14).
4. `dart test` with 100% coverage (or the k.yaml override).
5. Same scripts as CI run locally (k_config, publishers check, comments check).
6. Self-review of `git diff origin/main` against the issue acceptance criteria and Reviewer rules: English only, `///` comments only, no hard-coded values outside k.yaml.

Points 2 to 5 live in a single script, `tool/check.sh`, which the `test` CI job also runs; `tool/check_test.sh` tests it. Install the hooks once per clone:

```bash
tool/install_hooks.sh
```

- The install script refuses to replace an existing `core.hooksPath` or local `.git/hooks` scripts unless `--force` is given.
- `pre-commit` runs `tool/check.sh --fast` (points 2, 3 and 5; tests and coverage are left to `pre-push`).
- `pre-push` fetches `origin/main`, then for each pushed commit checks that it contains `origin/main` (point 1) and runs the full `tool/check.sh` in a clean temporary worktree of that commit (points 2 to 5).
- Packages come from `dart pub workspace list --json`. Every package must have `test/**/*_test.dart`; the workspace root is skipped only when it has no `lib/`.
- Coverage threshold: `coverage.default` in `k.yaml`, a YAML integer from 0 to 100. If `k.yaml` or `coverage.default` is missing, the threshold defaults to **100%** and the check still fails (`k.yaml with coverage.default is required; defaulting to 100%`). Coverage is never disabled.
- Coverage counts every `lib/**/*.dart` file: a file that no test loads counts as 0%.
- Checks whose script is not on `main` yet (k_config #13, publishers #4, comments #9) are skipped with a `SKIP:` message and a CI warning while their issue is open; once the issue is closed, the missing script fails the check.
- Point 6 stays manual.

## Workflow
1. **One issue = one branch = one PR.** Never push directly to `main`.
2. Open the PR referencing the issue (`Closes #N`).
3. Required checks on `main`: **`test`** and **`review-gate`**.
   - `test`: runs `tool/check.sh` (see Pre-commit checklist). It always runs the review-gate script tests; when `pubspec.yaml` exists it also runs format, analyze, the repository scripts, tests and coverage, and fails if there are no tests.
   - `review-gate`: fails without the `review:approved` label or when `review:changes-requested` is present.
4. **Reviewer verdict**: a comment on the PR **and** a label, `review:approved` or `review:changes-requested`. Before re-approving, the Reviewer removes `review:changes-requested`.
5. **Every push** to the PR automatically removes `review:approved`, and `review-gate` turns red on the new commit. Removing a label with the workflow token does not trigger a new run, so the check **stays red until the Reviewer adds `review:approved` again**.
   - Every `review-gate` run also checks freshness: the latest `labeled review:approved` event in the PR timeline must be newer than the push that brought the current head SHA. The push time comes from the server-side repository activity API; if it is unavailable, from the fallback below. Commit dates are never used. A stale approval is removed and the job fails.
   - The check fails closed: if the GitHub API is slow to record the push, or fails, the check stays red. Adding the label again (`review:approved`) or re-running the job unblocks it.
   - The logic lives in `.github/scripts/review_gate.sh`, tested by `.github/scripts/review_gate_test.sh` (plain bash, fake `gh`) in the `test` job.
   - Reopening the PR is treated like a push: `review:approved` is removed and the check fails, because pushes made while a PR is closed leave no trace in its timeline.
   - The fallback push time is the latest of the `head_ref_force_pushed`, `reopened` and `head_ref_restored` events and the first workflow run for the head SHA. It is used only when the activity API answers an access 403 or 404. A rate-limit 403 fails the job; re-run it later.
   - `synchronize` and `reopened` runs each get their own concurrency group, so a label event can never cancel them.
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
