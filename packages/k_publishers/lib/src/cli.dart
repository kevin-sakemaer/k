import 'dart:io';

import 'package:k_config/k_config.dart';
import 'package:k_publishers/src/check.dart';
import 'package:k_publishers/src/dependencies.dart';
import 'package:k_publishers/src/pub_client.dart';

const String _usage = 'Usage: k_publishers [repository-root]';

/// Runs the command line tool with [client] and returns its exit code.
///
/// The repository root is the only optional entry of [arguments] and
/// defaults to the current directory. The exceptions come from the
/// `dependencies` section of `k.yaml`, read and validated by
/// `package:k_config`.
///
/// Exit codes: 0 when every direct dependency is allowed; 1 when a problem is
/// found or when `k.yaml` is invalid; 64 on a usage error. Problems are
/// written to [out], other errors to [err].
Future<int> runCli(
  List<String> arguments,
  StringSink out,
  StringSink err,
  PublisherClient client,
) async {
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
  final List<String> problems = await checkPublishers(
    readDirectDependencies(root),
    config.dependencies,
    client,
  );
  if (problems.isEmpty) {
    out.writeln('Every direct dependency has an allowed publisher.');
    return 0;
  }
  problems.forEach(out.writeln);
  out.writeln('${problems.length} dependency problem(s) found.');
  return 1;
}
