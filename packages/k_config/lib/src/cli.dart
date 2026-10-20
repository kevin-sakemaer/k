/// Command line validation of `k.yaml`.
library;

import 'dart:io';

import 'loader.dart';
import 'summary.dart';

/// Validates `k.yaml` and returns the process exit code.
///
/// The repository root is the only optional entry of [arguments] and
/// defaults to the current directory. On success, the summary is written to
/// [out] and appended to the file named by the `GITHUB_STEP_SUMMARY` entry
/// of [environment], when set. On failure, every error is written to [err].
int runCli(
  List<String> arguments, {
  required StringSink out,
  required StringSink err,
  Map<String, String> environment = const {},
}) {
  if (arguments.length > 1) {
    err.writeln('Usage: k_config [repository-root]');
    return 64;
  }
  final root = Directory(arguments.isEmpty ? '.' : arguments.single);
  try {
    final summary = renderSummary(loadKConfig(root));
    out.write(summary);
    final summaryPath = environment['GITHUB_STEP_SUMMARY'];
    if (summaryPath != null && summaryPath.isNotEmpty) {
      File(summaryPath).writeAsStringSync(summary, mode: FileMode.append);
    }
    return 0;
  } on KConfigException catch (exception) {
    exception.errors.forEach(err.writeln);
    err.writeln('k.yaml is invalid: ${exception.errors.length} error(s).');
    return 1;
  }
}
