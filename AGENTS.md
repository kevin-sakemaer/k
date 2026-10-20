# AGENTS.md — workflow

All agents share the `kevin-sakemaer` GitHub account: classic GitHub approval is impossible, so validation relies on labels checked in CI.

## Repository rules
- Everything on GitHub (issues, PRs, labels, comments, commit messages, docs, code comments) is in English.
- Dart code uses only `///` doc comments; `//`, `/* */`, `/** */` and `// ignore:` are forbidden. This rule applies to Dart only: `#` comments in shell and YAML are allowed.
- Public members are documented.
- `k.yaml` at the repository root is the single source of configuration; nothing is hard-coded.
- Every rule must live in a required CI check. Checks still to come, each tracked in its own issue and made required on `main` when done:
  - `///`-only comments: #9 (runs in the `test` check, settings in the `comments` section of k.yaml);
  - dependency publishers: #4 (runs in the `test` check, exceptions in the `dependencies` section of k.yaml);
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
8. No stacked PRs (#33): the PR targets `main` (`gh pr create --base main`), never another PR's branch.
9. Draft-first (#27): the PR was opened with `gh pr create --draft` and is marked ready (`gh pr ready`) only once every CI check is green; if a push turns CI red, convert it back with `gh pr ready --undo`.

Points 2 to 5 live in a single script, `tool/check.sh`, which the `test` CI job also runs; `tool/check_test.sh` tests it. Install the hooks once per clone:

```bash
tool/install_hooks.sh
```

- The install script refuses to replace an existing `core.hooksPath` or local `.git/hooks` scripts unless `--force` is given.
- `pre-commit` runs `tool/check.sh --fast` (points 2, 3 and 5; tests and coverage are left to `pre-push`).
- `pre-push` fetches `origin/main`, then for each pushed commit checks that it contains `origin/main` (point 1) and runs the full `tool/check.sh` in a clean temporary worktree of that commit (points 2 to 5).
- Packages come from `dart pub workspace list --json`. Every package must have `test/**/*_test.dart`; the workspace root is skipped only when it has no `lib/`.
- `k.yaml` is mandatory: without it, `tool/check.sh` fails first with `k.yaml is required`. There is no default value outside `k.yaml`.
- `tool/check.sh` never parses `k.yaml`: it validates it with `k_config` (required: a missing `packages/k_config/bin/k_config.dart` fails the job), then reads each value through `dart run k_config --get <key>` (`coverage.thresholds`, `coverage.tool_version`). An invalid `k.yaml` fails the check. Coverage is never disabled.
- Coverage counts every `lib/**/*.dart` file: a file that no test loads counts as 0%.
- The comments check (#9) runs `dart run k_comments` (package `packages/k_comments`, #20). It reads `comments.include`, `comments.exclude` and `comments.exceptions` from k.yaml through `k_config`, and only `.dart` files are ever read. It fails on any `//` (including `////`, `// ignore:` and `// ignore_for_file:`), `/* */` or `/** */` comment, on an unterminated `/*`, on a file that is not valid UTF-8, on a `.dart` symbolic link that is broken, points outside the repository or points to a directory, and on a comment exception that is not needed. Each violation is reported as `path:line:column`, with the column counted in Unicode code points. Text inside string literals is never treated as a comment. `packages/k_comments/bin/k_comments.dart` is on `main`, so a missing checker always fails the job. A workspace package executable `packages/<name>/bin/<name>.dart` is run by package name, any other script by path.
- The publishers check (#4) runs `dart run k_publishers` (package `packages/k_publishers`). `packages/k_publishers/bin/k_publishers.dart` is on `main`, so a missing checker always fails the job. It reads the direct `dependencies` and `dev_dependencies` and the `dependency_overrides` of the root pubspec and of every workspace member, skips workspace packages and `sdk` and `path` dependencies, fails on any `path`, `git` or non-registry hosted override (an exception does not help; overrides of workspace packages are allowed), sends pub.dev overrides through the publisher check, and asks `https://pub.dev/api/packages/<name>/publisher` for each pub.dev package. It fails on a publisher outside `DependenciesConfig.allowedPublishers` (fixed in `k_config`), on a package without a verified publisher or unknown to pub.dev, on a `git` or non-pub.dev hosted dependency, on a lookup error or a lookup slower than `DependenciesConfig.registryTimeout` (fail-closed), and on an exception from `dependencies.exceptions` that is not needed. Its tests never use the network: they inject a fake client or a loopback server.
- Every repository script run by `tool/check.sh` is required: a missing script fails the check. There is no skip while an issue is open.
- Points 6 to 9 stay manual (`review-gate` also enforces point 8).

## Workflow
1. **One issue = one branch = one PR.** Never push directly to `main`.
   **No stacked PRs** (#33): every PR targets `main`. Dependent work waits for the parent PR to merge, then branches from the updated `origin/main`. The `main` ruleset protects only `main`, so a PR on any other base would merge with no checks: `review-gate` fails any PR whose base is not `main`, and the `auto-merge` workflow enables auto-merge only on PRs targeting `main` and disables it when a PR is retargeted to any other base (`edited` event).
   - Known limit: `pull_request_target` runs the workflow from the PR's *new* base. A PR retargeted to a branch that does not contain this `auto-merge` workflow (an old branch cut before #35) keeps auto-merge armed. The Lead decided not to extend the ruleset to all branches (required checks would block pushes on feature branches, and `review-gate` fails on drafts). Mitigation: delete every branch whose PR is merged or closed (never a branch with an open PR) and keep active branches rebased on `main`, so every possible base contains this workflow.
2. **Draft-first** (#27): open the PR as a draft (`gh pr create --draft`) and mark it ready (`gh pr ready`) only once every CI check is green. The Reviewer reviews only non-draft PRs with fully green CI and skips draft, red or pending PRs. If a push after review turns CI red, the author converts the PR back to draft (`gh pr ready --undo`) until CI is green again. `review-gate` fails on a draft PR, even with `review:approved`, so a draft PR never merges, even with auto-merge enabled.
   Reference the issue in the PR: `Closes #N` only if the PR fully delivers the issue; otherwise `Part of #N` or `Refs #N`, with no closing keyword (`close`, `closes`, `closed`, `fix`, `fixes`, `fixed`, `resolve`, `resolves`, `resolved` followed by `#N`) anywhere in the title, description or commit messages (see Pre-commit checklist point 7).
3. Required checks on `main`: **`test`**, **`review-gate`** and **`github-guard`**.
   - `test`: runs `tool/check.sh` (see Pre-commit checklist). It always runs the review-gate script tests; it fails if `pubspec.yaml` is missing, then runs format, analyze, the repository scripts, tests and coverage, and fails if any workspace package has no tests or no member package is tested.
   - `review-gate`: fails on a PR whose base is not `main`, on a draft PR, without the `review:approved` label, or when `review:changes-requested` is present. It also runs on `ready_for_review` and `converted_to_draft`; on a draft PR it keeps `review:approved` (marking the PR ready re-runs the gate), but a push still removes it.
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
   - `github-guard` (workflow `.github/workflows/github-guard.yml`, job `github-guard`, also on `pull_request_target`, base-branch code only) fails when the PR changes, adds, deletes or renames a protected path: anything under `.github/`, `tool/check.sh`, `tool/*_test.sh`, `tool/hooks/`, and `analysis_options.yaml`, `k.yaml` or `dart_test.yaml` at any depth (the gate itself; the analyzer uses the nearest `analysis_options.yaml`; `dart_test.yaml` tags, skips, presets and platforms can silently exclude tests, so any change to it needs the label (#22), and the test-runner flags such as `--exclude-tags` live in `tool/check.sh` and `.github/`, already protected; no `dart_test.yaml` setting is pre-allowed, so k.yaml declares none; the `test` check runs head code, so these files could otherwise weaken the check of the PR that edits them). It passes only with the label `ci:github-change-approved`, and only if that label is fresh: its latest `labeled` event must be newer than the push of the current head, with the same rule and fallback as `review-gate` (shared helper `.github/scripts/freshness.sh`). A stale label is removed. Every push (and reopen) also removes it. The job fails closed when the listed files do not match the PR's `changed_files` count. The logic lives in `.github/scripts/github_guard.sh`, tested by `.github/scripts/github_guard_test.sh`. The protected paths and the label are hard-coded in the script on purpose, not in k.yaml.
   - Everyone shares one GitHub account, so anyone can add `ci:github-change-approved`: it is meaningful only as an explicit, fresh second acknowledgment. Only the Lead adds it, after the Reviewer's `review:approved` and the Lead's own review of the diff. That is why the freshness rule is essential.
   - Rollout (#15): `github-guard` is a required check on `main` since #19 merged; it must stay required now that auto-merge is enabled on every PR, otherwise a protected change would merge as soon as `review:approved` is set.
6. **Auto-merge**: enabled automatically by the `auto-merge` workflow (`.github/workflows/auto-merge.yml`, logic in `.github/scripts/auto_merge.sh`, tested by `.github/scripts/auto_merge_test.sh`), only for PRs whose base is `main` (on any other base, including after a retarget, it disables auto-merge), when a PR is opened, reopened, marked ready for review, or labelled `review:approved` (re-running it is harmless, so PRs opened before the workflow or with auto-merge disabled still get it). If that workflow fails, the dev must enable it by hand with `gh pr merge --auto --squash`. Enabling auto-merge only queues the merge: the ruleset still requires `test`, `review-gate`, `github-guard` and resolved threads, with no bypass actors. Because the merge is done by `GITHUB_TOKEN`, the `push: main` workflows do not run after it.
   - **Closing issues after merge** (#40): merges done by auto-merge with `GITHUB_TOKEN` neither apply closing keywords nor start workflows (`pull_request_target` `closed` included), so the `close-issues` workflow (`.github/workflows/close-issues.yml`, logic in `.github/scripts/close_issues.sh`, tested by `.github/scripts/close_issues_test.sh`) is a sweep: every 15 minutes (`schedule`) and on demand (`workflow_dispatch`, optionally for one merged PR number), it lists the PRs merged into `main` within `close_issues.lookback_hours` (k.yaml) and closes the open issues of this repository in their GraphQL `closingIssuesReferences` (the linked issues of the PR sidebar). It runs only code from `main`. Issues of other repositories and issues that are not open are skipped; the sweep closes an issue first, then posts one comment linking the PR and merge commit, with a hidden marker. A human reopen wins: an open issue that already carries a marker posted by `github-actions[bot]` (author login and `Bot` type checked, all comment pages read; a marker from any other author is ignored, since anyone can comment) was reopened after the sweep closed it, so it is never closed again. A failed close leaves no marker and is retried by the next run; a comment that fails after the close fails the job, and the next run skips the now closed issue (it then has no comment). The window is read with `k_config` in a step without `GH_TOKEN`. API or GraphQL errors, truncated results and a missing or unmerged PR fail the job. A failed or missed run is caught up by the next one while the PR is inside the window. Permissions: `contents: read`, `issues: write`, `pull-requests: read`.
   - Residual risk: the closing set is read after the merge, so a PR description edited after `review:approved` (an edit is not a push and does not remove the label) changes which issues get closed. Reviewers re-check the linked issues in the sidebar before the merge.
7. **Resolve every review thread.** The ruleset requires all review threads to be resolved: the author resolves each of their threads (after fixing or answering it), otherwise an approved PR with green checks does not merge.
8. **Nobody merges by hand.** The only exception is the bootstrap: the PRs for #1 and #2 are merged once by hand after the Reviewer's verdict.

## Hardened CI (#6)
- Every `uses:` of a job or a step has one of three forms:
  - `owner/repo[/path]@<40-character commit SHA>` with exactly one `@`, followed on its line by the version in a comment (`# vX.Y.Z`); quoting the value is fine;
  - a local action (`./...`);
  - a Docker image pinned by digest (`docker://image@sha256:<64 hex>`).
- Path segments are never empty, `.` or `..` (no `a/b/x/@sha`, `a/b/../c@sha`, `./a//b`). A job-level `uses:` (reusable workflow call) is either `./.github/workflows/<file>`, one of the linted workflows, or a SHA-pinned remote workflow; never a Docker image.
- Every job `container` image (string or `image:` key) and every `services.<id>.image` is pinned by digest (`image@sha256:<64 hex>`).
- Every workflow sets exactly `permissions: {}` at the top level.
- Job `permissions`, when set, is a mapping of explicit GitHub scopes (`contents`, `pull-requests`, ...) to `read`, `write` or `none`. A shorthand such as `write-all` or `read-all` and an unknown scope are rejected. Each job grants only the scopes it uses.
- Every job-level `write` is an explicit exception declared in `workflows.write_scopes` of `k.yaml`, with its workflow file name, job, scope and reason (#39). An undeclared `write` fails, and so does a declared entry that no longer matches a job granting that `write` (stale exception). The `k-config` job summary lists every declared write scope.
- A new write scope must be justified in the PR that adds it, by one line in this file naming the workflow, job, scope and why `read` is not enough.
- Every job that runs steps sets a positive integer `timeout-minutes`, at most `workflows.max_timeout_minutes` of `k.yaml` (#39). A job that calls a reusable workflow cannot set one, so the called workflow must be linted itself (local) or pinned by SHA.
- `packages/k_workflows` reads the `workflows` section of `k.yaml` through `loadKConfig` and enforces these rules on `.github/workflows/*.yml|yaml` with a real YAML parse (`package:yaml`), so flow mappings, quoted keys and comments cannot hide a reference, a duplicated key is invalid YAML, and YAML merge keys (`<<`) are rejected anywhere. `tool/check.sh` runs it in the required `test` check.
- `concurrency` uses `cancel-in-progress: true` for `test` and `k-config`. The gates (`review-gate`, `github-guard`) and `auto-merge` keep `cancel-in-progress: false` on purpose: a newer event must never cancel a run that removes a stale approval label.
- `pubspec.lock` is committed, and every `dart pub get` in CI runs with `--enforce-lockfile`, so an out-of-sync lockfile fails the job.
- The pub cache (`~/.pub-cache`) is cached with `actions/cache`, keyed on the hash of every `pubspec.lock`.
- Each job installs the Dart SDK once, with `dart-lang/setup-dart`. The SDK version is pinned in the workflows, because it is needed before Dart (and therefore `k_config`) can run.

## Current status (#2)
- Done: squash merge only, branches deleted after merge, auto-merge enabled.
- The `main` ruleset is active: PR required, squash only, 0 approvals, resolved threads, strict required checks `test`, `review-gate` and `github-guard`, no force-push, no deletion, no bypass. Direct pushes to `main` are rejected.

## Dependencies
- **Direct** dependencies are allowed only if their verified publisher on pub.dev is `dart.dev`, `tools.dart.dev` or `labs.dart.dev`.
- Any exception must be approved through **Grok Bot**.
- The registry is a fixed policy in `k_config`, like the publishers: `DependenciesConfig.registryUrl` (`https://pub.dev`) and `DependenciesConfig.hostedAliases` (`https://pub.dev`, `https://pub.dartlang.org`), and `DependenciesConfig.registryTimeout` (30 seconds, for the connection and the whole response). `k.yaml` has no key for them, because a configurable registry would bypass the publisher rule; `k_publishers` hard-codes no URL.

## k.yaml
`k.yaml` at the repository root holds every quality setting. It is validated by `packages/k_config` (`dart run packages/k_config/bin/k_config.dart`) by `tool/check.sh`, so it runs in the required `test` check. The separate `k-config` workflow runs the same validation and writes the job summary; it is not a required check. On success the job summary lists every active override and exception with its reason.

```yaml
coverage:
  default: 100              # Integer from 0 to 100, line coverage in percent.
  tool_version: 1.16.0      # Exact package:coverage version, MAJOR.MINOR.PATCH.
  overrides:                # Required, may be {}.
    some_package:           # A workspace package, or the root package.
      threshold: 95         # Integer from 0 to 100, lower than coverage.default.
      reason: "Why this package cannot reach the default."
dependencies:
  exceptions:               # Required, may be {}.
    some_pkg:               # Must be a direct dependency of the workspace.
      reason: "Why this dependency is needed."
      approved_by: "Kevin, YYYY-MM-DD, via Grok Bot."
close_issues:
  lookback_hours: 72        # Integer from 1 to 720: window of the close-issues sweep.
comments:
  include:                  # Required, at least one glob, relative to the root.
    - "**.dart"
  exclude:                  # Required, may be [].
    - ".dart_tool/**"
  exceptions:               # Required, may be [].
    - path: packages/foo/lib/vendored.dart   # Existing file, relative path.
      reason: "Why this file needs non-documentation comments."
workflows:
  max_timeout_minutes: 20   # Integer greater than 0, largest job timeout-minutes.
  write_scopes:             # Required, may be [].
    - workflow: test.yml    # File name in .github/workflows.
      job: test             # Job identifier in that workflow.
      scope: contents       # Scope that the job grants with write.
      reason: "Why the job needs to write with this scope."
```

- `coverage`: `default` applies to every package; an override lowers it for one package and must be strictly lower than `default`. `tool/check.sh` (#5) enforces, per package, the line coverage of `lib/` against its override or `coverage.default`, read through `k_config --get coverage.thresholds`; below the threshold the required `test` check fails. Every measured package gets a threshold, including the workspace root when it has a `lib/`; the root `pubspec.yaml` must therefore have a `name`, or `k_config` fails. The coverage of each package is added to the job summary, even when the package fails, next to the k.yaml summary that lists every active override with its reason. The lcov report of each package is uploaded as the `lcov-<PR>-<sha>` artifact of the `test` job, even when the job fails; a successful run without any report fails. `tool_version` is the exact version of `package:coverage` (tools.dart.dev) that `tool/check.sh` activates to build the lcov report.
- `dependencies`: the publishers `dart.dev`, `tools.dart.dev` and `labs.dart.dev` are fixed in `k_config` and cannot be changed from `k.yaml` (an `allowed_publishers` key fails as an unknown key). Any other direct dependency needs an entry in `exceptions`.
- `comments`: `include` and `exclude` are the globs of the files checked by the comments check (only `.dart` files are read). `exceptions` lists the files allowed to contain non-documentation comments, each with a reason. An exception that is not needed fails the check.
- `close_issues`: `lookback_hours` is how far back, in hours, the `close-issues` sweep (#40) looks for PRs merged into `main`. It must cover the longest expected gap between two successful runs (72 hours by default, at most 720).
- `workflows`: `max_timeout_minutes` bounds the `timeout-minutes` of every job, and `write_scopes` lists every job-level `write` permission allowed in `.github/workflows`, each with a reason. `k_workflows` fails on an undeclared `write` and on a stale entry.
- `k_config` is the only reader of `k.yaml`: shell scripts read scalars with `k_config --get <key>`, and Dart code reads lists through the `loadKConfig` library function.

Validation fails on an unknown or missing key at any level, a duplicated key, a wrong type, a threshold that is not a plain decimal integer from 0 to 100 (no decimal, exponent, hexadecimal, octal, sign, separator, leading zero, string or boolean), a `tool_version` that is not an exact `MAJOR.MINOR.PATCH` string, a coverage override not strictly lower than `coverage.default` or for a package outside the workspace, a missing or blank `reason` (or `approved_by`), a dependency exception for a package that is not a direct dependency, a comment exception for a missing or duplicated file, a comment `include` list that is empty, or an `include` or `exclude` entry that is blank, not a string or duplicated, a `workflows.max_timeout_minutes` that is not a plain decimal integer greater than 0, and a `workflows.write_scopes` entry whose `workflow` is not a `.yml` or `.yaml` file name without directory, whose `job` or `scope` is blank or padded, or that duplicates another entry.

### Adding an exception
1. Get Kevin's approval first: **every exception requires Kevin's agreement** (through Grok Bot).
2. Add the entry under the right section with a non-blank `reason`; dependency exceptions also need `approved_by` naming Kevin and the date.
3. Open a PR; the `test` check must be green and the `k-config` job summary shows the new exception.
