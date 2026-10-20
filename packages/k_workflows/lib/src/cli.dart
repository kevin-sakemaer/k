import 'dart:io';

import 'package:k_config/k_config.dart';
import 'package:k_workflows/src/lint.dart';

const String _usage = 'Usage: k_workflows [repository-root]';

/// Lints every workflow of `.github/workflows` (the location fixed by GitHub)
/// under the repository root against the `workflows` section of `k.yaml`,
/// read through `package:k_config`, and returns the exit code.
///
/// The repository root is the only optional entry of [arguments] and
/// defaults to the current directory. Exit codes: 0 when every workflow
/// passes; 1 when a rule is broken, `k.yaml` is invalid or no workflow is
/// found; 64 on a usage error. Problems are written to [err], the summary to
/// [out].
int runCli(List<String> arguments, StringSink out, StringSink err) {
  if (arguments.length > 1 || arguments.any((a) => a.startsWith('-'))) {
    err.writeln(_usage);
    return 64;
  }
  final String root = arguments.isEmpty ? '.' : arguments.single;
  final KConfig config;
  try {
    config = loadKConfig(Directory(root));
  } on KConfigException catch (exception) {
    exception.errors.forEach(err.writeln);
    err.writeln('k.yaml is invalid: ${exception.errors.length} error(s).');
    return 1;
  }
  final directory = Directory('$root/.github/workflows');
  final List<File> files =
      (directory.existsSync()
              ? directory.listSync().whereType<File>()
              : const <File>[])
          .where((f) => f.path.endsWith('.yml') || f.path.endsWith('.yaml'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (files.isEmpty) {
    err.writeln('k_workflows: no workflow found in ${directory.path}.');
    return 1;
  }
  final List<String> errors = lintWorkflows({
    for (final file in files)
      file.path.substring(root.length + 1): file.readAsStringSync(),
  }, config.workflows);
  if (errors.isNotEmpty) {
    errors.forEach(err.writeln);
    err.writeln('k_workflows: ${errors.length} problem(s) found.');
    return 1;
  }
  out.writeln('k_workflows: ${files.length} workflow(s) pass.');
  return 0;
}
