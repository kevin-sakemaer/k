import 'dart:io';

import 'package:k_comments/k_comments.dart';

/// Checks that Dart files only contain `///` comments.
void main(List<String> arguments) {
  exitCode = runCli(arguments, stdout, stderr);
}
