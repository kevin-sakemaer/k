# k_config

Loads and strictly validates `k.yaml`, the global quality configuration at
the repository root. Every quality check reads its settings through this
package, so `k.yaml` is the single source of truth: no threshold or list may
be hard-coded in a workflow or a script.

## Usage

```sh
dart run packages/k_config/bin/k_config.dart [repository-root]
```

The command exits with code 1 and prints one line per error when `k.yaml` is
invalid. When it is valid, it prints a Markdown summary of every active
override and exception, and appends it to `$GITHUB_STEP_SUMMARY` when that
variable is set. `tool/check.sh` runs it in the required `test` check on every pull
request; the `k-config` workflow (not required) also runs it and writes the
job summary.

`dart run packages/k_config/bin/k_config.dart --get <key> [repository-root]`
prints only the validated value of `<key>`: `coverage.default`,
`coverage.tool_version`, or `coverage.thresholds` (one `<package>\t<threshold>`
line per workspace package, its override or `coverage.default`) and exits with code 1 when `k.yaml` is invalid, or 64
for an unsupported key. Scripts use it instead of parsing `k.yaml`.

Other checks read the typed values with `loadKConfig(Directory root)`.

## Schema

```yaml
coverage:
  default: 100              # Integer from 0 to 100, line coverage in percent.
  tool_version: 1.16.0      # Exact package:coverage version, MAJOR.MINOR.PATCH.
  overrides:                # Required, may be {}.
    some_package:           # Must be a workspace package.
      threshold: 95         # Integer from 0 to 100, lower than coverage.default.
      reason: "Why this package cannot reach the default."
dependencies:
  exceptions:               # Required, may be {}.
    some_pkg:               # Must be a direct dependency of the workspace.
      reason: "Why this dependency is needed."
      approved_by: "Kevin, YYYY-MM-DD, via Grok Bot."
comments:
  exceptions:               # Required, may be [].
    - path: packages/foo/lib/vendored.dart   # Existing file, relative path.
      reason: "Why this file needs non-documentation comments."
```

Direct dependencies published by `dart.dev`, `tools.dart.dev` or
`labs.dart.dev` are always allowed; this list is fixed in the code and an
`allowed_publishers` key fails as an unknown key.

Validation fails on:

- an unknown key, or a missing key, at any level;
- a duplicated key, including a duplicated section;
- a value of the wrong type;
- a threshold that is not a plain decimal integer from 0 to 100 (no decimal, exponent, hexadecimal, octal, sign, separator, leading zero, string or boolean);
- a `coverage.tool_version` that is not an exact `MAJOR.MINOR.PATCH` string;
- a missing or blank `reason`;
- a coverage override for a package that is not in the workspace, or whose
  threshold is not strictly lower than `coverage.default`;
- a missing or blank `approved_by` on a dependency exception;
- a dependency exception for a package that is not a direct dependency;
- a comment exception for a missing file, or a duplicated path.

## Adding a section

1. Add a typed class to `lib/src/model.dart` and a field to `KConfig`.
2. Add the key to the root keys in `lib/src/parser.dart` and write its
   parser with the strict helpers there.
3. Render it in `lib/src/summary.dart`, add it to `k.yaml`, and cover every
   invalid case in the tests.
