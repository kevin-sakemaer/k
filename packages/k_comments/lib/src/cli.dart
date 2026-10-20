import 'dart:io';

import 'package:k_comments/src/scanner.dart';
import 'package:k_config/k_config.dart';

const String _usage = 'Usage: k_comments [repository-root]';

/// Runs the command line tool and returns its exit code.
///
/// The repository root is the only optional entry of [arguments] and
/// defaults to the current directory. The files to check and the comment
/// exceptions come from the `comments` section of `k.yaml`, read and
/// validated by `package:k_config`.
///
/// Exit codes: 0 when no violation is found; 1 when at least one is found
/// (a forbidden or unterminated comment, an unreadable file, a bad symbolic
/// link or an unneeded exception) or when `k.yaml` is invalid; 64 on a usage
/// error. Violations are written to [out], other errors to [err].
int runCli(List<String> arguments, StringSink out, StringSink err) {
  if (arguments.length > 1 || arguments.any((a) => a.startsWith('-'))) {
    err.writeln(_usage);
    return 64;
  }
  final root = Directory(arguments.isEmpty ? '.' : arguments.single);
  if (!root.existsSync()) {
    err
      ..writeln('Root directory not found: ${root.path}')
      ..writeln(_usage);
    return 64;
  }
  final KConfig config;
  try {
    config = loadKConfig(root);
  } on KConfigException catch (exception) {
    exception.errors.forEach(err.writeln);
    err.writeln('k.yaml is invalid: ${exception.errors.length} error(s).');
    return 1;
  }
  final CommentsConfig comments = config.comments;
  final List<CommentViolation> violations = scanFiles(
    root,
    CommentScanConfig(
      include: comments.include,
      exclude: comments.exclude,
      exceptions: comments.exceptions.map((exception) => exception.path),
    ),
  );
  if (violations.isEmpty) {
    out.writeln('No forbidden comments found.');
    return 0;
  }
  violations.forEach(out.writeln);
  out.writeln('${violations.length} forbidden comment(s) found.');
  return 1;
}
