import 'dart:io';

import 'package:k_workflows/k_workflows.dart';

/// Lints the GitHub Actions workflows of the repository.
void main(List<String> arguments) {
  exitCode = runCli(arguments, stdout, stderr);
}
