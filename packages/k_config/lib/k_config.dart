/// Loads and strictly validates the global `k.yaml` configuration file.
///
/// Every quality check of the repository reads its settings through this
/// library, so that `k.yaml` stays the single source of truth.
library;

export 'src/cli.dart' show runCli;
export 'src/loader.dart' show KConfigException, loadKConfig;
export 'src/model.dart';
export 'src/parser.dart'
    show KConfigInvalid, KConfigResult, KConfigValid, parseKConfig;
export 'src/summary.dart' show renderSummary;
export 'src/workspace.dart' show Workspace, WorkspaceException;
