/// Entry point used by the other quality checks to read `k.yaml`.
library;

import 'dart:io';

import 'model.dart';
import 'parser.dart';
import 'workspace.dart';

/// Thrown by [loadKConfig] when `k.yaml` or the workspace is invalid.
final class KConfigException implements Exception {
  /// Creates an exception with one message per broken rule.
  const KConfigException(this.errors);

  /// One human readable message per broken rule.
  final List<String> errors;

  @override
  String toString() => 'KConfigException:\n${errors.join('\n')}';
}

/// Reads and validates `k.yaml` in the repository [root].
///
/// Throws a [KConfigException] when the file is missing, when the workspace
/// cannot be read, or when the file breaks a validation rule.
KConfig loadKConfig(Directory root) {
  final file = File('${root.path}/k.yaml');
  if (!file.existsSync()) {
    throw KConfigException(['k.yaml: file not found in ${root.path}.']);
  }
  final Workspace workspace;
  try {
    workspace = Workspace.load(root);
  } on WorkspaceException catch (error) {
    throw KConfigException([error.message]);
  }
  return switch (parseKConfig(file.readAsStringSync(), workspace)) {
    KConfigValid(:final config) => config,
    KConfigInvalid(:final errors) => throw KConfigException(errors),
  };
}
