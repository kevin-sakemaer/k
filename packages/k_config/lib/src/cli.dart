/// Command line validation of `k.yaml`.
library;

import 'dart:io';

import 'package:k_config/src/loader.dart';
import 'package:k_config/src/model.dart';
import 'package:k_config/src/summary.dart';

/// Validated values that `--get` can print, keyed by dotted path.
final Map<String, String Function(KConfig config)> _getters = {
  'coverage.default': (config) => '${config.coverage.defaultThreshold}',
  'coverage.tool_version': (config) => config.coverage.toolVersion,
};

const String _usage = 'Usage: k_config [--get <key>] [repository-root]';

/// Validates `k.yaml` and returns the process exit code.
///
/// The repository root is the last optional entry of [arguments] and
/// defaults to the current directory. With `--get <key>`, only the validated
/// value of `<key>` is written to [out], on one line, so that scripts never
/// parse `k.yaml` themselves. Otherwise the summary is written to [out] and
/// appended to the file named by the `GITHUB_STEP_SUMMARY` entry of
/// [environment], when set. An invalid `k.yaml` returns 1 and writes every
/// error to [err]; a usage error, such as an unsupported key, returns 64.
int runCli(
  List<String> arguments, {
  required StringSink out,
  required StringSink err,
  Map<String, String> environment = const {},
}) {
  var rest = arguments;
  String? key;
  if (rest.isNotEmpty && rest.first == '--get') {
    if (rest.length < 2) {
      err.writeln(_usage);
      return 64;
    }
    key = rest[1];
    rest = rest.sublist(2);
    if (!_getters.containsKey(key)) {
      err.writeln(
        'k_config: unsupported key "$key" for --get. Supported keys: '
        '${(_getters.keys.toList()..sort()).join(', ')}.',
      );
      return 64;
    }
  }
  if (rest.length > 1 || rest.any((argument) => argument.startsWith('-'))) {
    err.writeln(_usage);
    return 64;
  }
  final Directory root = repositoryRoot(rest);
  final KConfig config;
  try {
    config = loadKConfig(root);
  } on KConfigException catch (exception) {
    exception.errors.forEach(err.writeln);
    err.writeln('k.yaml is invalid: ${exception.errors.length} error(s).');
    return 1;
  }
  if (key != null) {
    out.writeln(_getters[key]!(config));
    return 0;
  }
  final String summary = renderSummary(config);
  out.write(summary);
  final String? summaryPath = environment['GITHUB_STEP_SUMMARY'];
  if (summaryPath != null && summaryPath.isNotEmpty) {
    File(summaryPath).writeAsStringSync(summary, mode: FileMode.append);
  }
  return 0;
}

/// Returns the repository root named by the only entry of [arguments], or
/// the current directory when [arguments] is empty.
Directory repositoryRoot(List<String> arguments) =>
    Directory(arguments.isEmpty ? '.' : arguments.single);
