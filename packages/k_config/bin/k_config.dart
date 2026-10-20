/// Validates the `k.yaml` of a repository and prints its summary.
library;

import 'dart:io';

import 'package:k_config/k_config.dart';

/// Validates `k.yaml` in the directory given as the only argument, or in the
/// current directory.
void main(List<String> arguments) {
  exitCode = runCli(
    arguments,
    out: stdout,
    err: stderr,
    environment: Platform.environment,
  );
}
