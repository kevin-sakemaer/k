/// Checks the GitHub Actions workflows against the hardened CI rules (#6).
library;

export 'src/cli.dart' show runCli;
export 'src/lint.dart' show jobPermissionScopes, lintWorkflows;
