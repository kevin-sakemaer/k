# AGENTS.md — workflow

All agents share the `kevin-sakemaer` GitHub account: classic GitHub approval is impossible, so validation relies on labels checked in CI.

## Repository rules
- Everything on GitHub (issues, PRs, labels, comments, commit messages, docs, code comments) is in English.
- Dart code uses only `///` doc comments; `//`, `/* */`, `/** */` and `// ignore:` are forbidden. This rule applies to Dart only: `#` comments in shell and YAML are allowed.
- Public members are documented.
- `k.yaml` at the repository root is the single source of configuration; nothing is hard-coded.
- Every rule must live in a required CI check. Checks still to come, each tracked in its own issue and made required on `main` when done:
  - `///`-only comments: #9 (runs in the `test` check; its k.yaml settings come with #13);
  - dependency publishers: #4;
  - `k.yaml` validation: #10;
  - no closing keywords in partial PRs (Pre-commit checklist point 7): #26.

## Pre-commit checklist
Mandatory before every commit and push (#16). The Reviewer may reject without detailed review any PR failing one of these points.

1. Branch rebased on up-to-date `origin/main`, containing no commits from other PRs.
2. `dart format --set-exit-if-changed .`
3. `dart analyze --fatal-infos` with zero diagnostics, including against the strictest analysis_options (#14).
4. `dart test` with 100% coverage (or the k.yaml override).
5. Same scripts as CI run locally (k_config, publishers check, comments check).
6. Self-review of `git diff origin/main` against the issue acceptance criteria and Reviewer rules: English only, `///` comments only, no hard-coded values outside k.yaml.
7. Issue references: a partial PR (`Part of #N` or `Refs #N`) contains no closing keyword for that issue anywhere (title, description, commit messages): no `close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves` or `resolved` followed by `#N`. `Closes #N` is allowed only when the PR fully delivers issue #N.
8. Draft-first (#27): the PR was opened with `gh pr create --draft` and is marked ready (`gh pr ready`) only once every CI check is green; if a push turns CI red, convert it back with `gh pr ready --undo`.

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
- The comments check (#9) runs `dart run k_comments --root . --include '**.dart' --exclude '.dart_tool/**' --exclude '**/.dart_tool/**'` (package `packages/k_comments`, #20) and fails on any violation. `packages/k_comments/bin/k_comments.dart` is on `main`, so a missing checker always fails the job. Its globs and exceptions move to k.yaml with #13. A workspace package executable `packages/<name>/bin/<name>.dart` is run by package name, any other script by path.
- Checks whose script is not on `main` yet (k_config #13 at `packages/k_config/bin/k_config.dart`, publishers #4 at `packages/k_publishers/bin/k_publishers.dart`; #4 may change that location) are skipped with a `SKIP:` message and a CI warning while their issue is open; once the issue is closed, the missing script fails the check.
- Points 6 to 8 stay manual.

## Workflow
1. **One issue = one branch = one PR.** Never push directly to `main`.
2. **Draft-first** (#27): open the PR as a draft (`gh pr create --draft`) and mark it ready (`gh pr ready`) only once every CI check is green. The Reviewer reviews only non-draft PRs with fully green CI and skips draft, red or pending PRs. If a push after review turns CI red, the author converts the PR back to draft (`gh pr ready --undo`) until CI is green again. `review-gate` fails on a draft PR, even with `review:approved`, so a draft PR never merges, even with auto-merge enabled.
   Reference the issue in the PR: `Closes #N` only if the PR fully delivers the issue; otherwise `Part of #N` or `Refs #N`, with no closing keyword (`close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved` followed by `#N`) anywhere in the title, description or commit messages (see Pre-commit checklist point 7).
3. Required checks on `main`: **`test`**, **`review-gate`** and **`github-guard`**.
   - `test`: runs `tool/check.sh` (see Pre-commit checklist). It always runs the review-gate script tests; it fails if `pubspec.yaml` is missing, then runs format, analyze, the repository scripts, tests and coverage, and fails if any workspace package has no tests or no member package is tested.
   - `review-gate`: fails on a draft PR, without the `review:approved` label, or when `review:changes-requested` is present. It also runs on `ready_for_review` and `converted_to_draft`; on a draft PR it keeps `review:approved` (marking the PR ready re-runs the gate), but a push still removes it.
4. **Reviewer verdict**: a comment on the PR **and** a label, `review:approved` or `review:changes-requested`. Before re-approving, the Reviewer removes `review:changes-requested`.
5. **Every push** to the PR automatically removes `review:approved`, and `review-gate` turns red on the new commit. Removing a label with the workflow token does not trigger a new run, so the check **stays red until the Reviewer adds `review:approved` again**.
   - Every `review-gate` run also checks freshness: the latest `labeled review:approved` event in the PR timeline must be newer than the push that brought the current head SHA. The push time comes from the server-side repository activity API; if it is unavailable, from the fallback below. Commit dates are never used. A stale approval is removed and the job fails.
   - The check fails closed: if the GitHub API is slow to record the push, or fails, the check stays red. Adding the label again (`review:approved`) or re-running the job unblocks it.
   - The logic lives in `.github/scripts/review_gate.sh`, tested by `.github/scripts/review_gate_test.sh` (plain bash, fake `gh`) in the `test` job.
   - Reopening the PR is treated like a push: `review:approved` is removed and the check fails, because pushes made while a PR is closed leave no trace in its timeline.
   - The fallback push time is the latest of the `head_ref_force_pushed`, `reopened` and `head_ref_restored` events and the first workflow run for the head SHA. It is used only when the activity API answers an access 403 or 404. A rate-limit 403 fails the job; re-run it later.
   - `synchronize` and `reopened` runs each get their own concurrency group, so a label event can never cancel them.
   - Re-running an old `review-gate` run stays red: a re-run reuses its original event (and that event's labels), so it cannot see a label added later. To unblock a PR, add `review:approved` again; do not re-run the job.
   - Fork PRs: under `pull_request_target` the token has the permissions declared in the workflow, even on fork PRs, so both gates can remove their label automatically.
   - `review-gate` runs on `pull_request_target`: the workflow and `.github/scripts/review_gate.sh` always come from the base branch (`main`), never from the PR head, so a PR cannot change the gate that checks it (#15). A change to the gate only takes effect once merged.
   - `github-guard` (workflow `.github/workflows/github-guard.yml`, job `github-guard`, also on `pull_request_target`, base-branch code only) fails when the PR changes, adds, deletes or renames a protected path: anything under `.github/`, `tool/check.sh`, `tool/*_test.sh`, `tool/hooks/`, and `analysis_options.yaml` or `k.yaml` at any depth (the gate itself; the analyzer uses the nearest `analysis_options.yaml`; the `test` check runs head code, so these files could otherwise weaken the check of the PR that edits them). It passes only with the label `ci:github-change-approved`, and only if that label is fresh: its latest `labeled` event must be newer than the push of the current head, with the same rule and fallback as `review-gate` (shared helper `.github/scripts/freshness.sh`). A stale label is removed. Every push (and reopen) also removes it. The job fails closed when the listed files do not match the PR's `changed_files` count. The logic lives in `.github/scripts/github_guard.sh`, tested by `.github/scripts/github_guard_test.sh`. The protected paths and the label are hard-coded in the script on purpose, not in k.yaml.
   - Everyone shares one GitHub account, so anyone can add `ci:github-change-approved`: it is meaningful only as an explicit, fresh second acknowledgment. Only the Lead adds it, after the Reviewer's `review:approved` and the Lead's own review of the diff. That is why the freshness rule is essential.
   - Rollout (#15): `github-guard` is a required check on `main` since #19 merged; it must stay required now that auto-merge is enabled on every PR, otherwise a protected change would merge as soon as `review:approved` is set.
6. **Auto-merge**: enabled automatically by the `auto-merge` workflow (`.github/workflows/auto-merge.yml`) when a PR is opened, reopened, marked ready for review, or labelled `review:approved` (re-running it is harmless, so PRs opened before the workflow or with auto-merge disabled still get it). If that workflow fails, the dev must enable it by hand with `gh pr merge --auto --squash`. Enabling auto-merge only queues the merge: the ruleset still requires `test`, `review-gate`, `github-guard` and resolved threads, with no bypass actors. Because the merge is done by `GITHUB_TOKEN`, the `push: main` workflows do not run after it.
7. **Resolve every review thread.** The ruleset requires all review threads to be resolved: the author resolves each of their threads (after fixing or answering it), otherwise an approved PR with green checks does not merge.
8. **Nobody merges by hand.** The only exception is the bootstrap: the PRs for #1 and #2 are merged once by hand after the Reviewer's verdict.

## Current status (#2)
- Done: squash merge only, branches deleted after merge, auto-merge enabled.
- The `main` ruleset is active: PR required, squash only, 0 approvals, resolved threads, strict required checks `test`, `review-gate` and `github-guard`, no force-push, no deletion, no bypass. Direct pushes to `main` are rejected.

## Dependencies
- **Direct** dependencies are allowed only if their verified publisher on pub.dev is `dart.dev`, `tools.dart.dev` or `labs.dart.dev`.
- Any exception must be approved through **Grok Bot**.
