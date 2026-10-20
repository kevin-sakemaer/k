/// Finds comments other than `///` documentation comments in Dart code.
library;

export 'src/cli.dart' show runCli;
export 'src/scanner.dart'
    show
        CommentKind,
        CommentScanConfig,
        CommentViolation,
        findViolations,
        scanFiles;
