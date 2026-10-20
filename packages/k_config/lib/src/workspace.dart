/// Reads the pub workspace that `k.yaml` describes.
library;

import 'dart:io';

import 'package:yaml/yaml.dart';

/// Thrown when the workspace pubspecs are missing or malformed.
final class WorkspaceException implements Exception {
  /// Creates an exception with a human readable [message].
  const WorkspaceException(this.message);

  /// Human readable description of the problem.
  final String message;

  @override
  String toString() => 'WorkspaceException: $message';
}

/// Packages and direct dependencies of a pub workspace.
final class Workspace {
  /// Creates a workspace description.
  const Workspace({
    required this.root,
    required this.packages,
    required this.directDependencies,
  });

  /// Reads the workspace whose root `pubspec.yaml` is in [root].
  ///
  /// Throws a [WorkspaceException] when a pubspec is missing or malformed.
  factory Workspace.load(Directory root) {
    final rootPubspec = _readPubspec(root, 'pubspec.yaml');
    final members = rootPubspec['workspace'];
    if (members is! YamlList) {
      throw const WorkspaceException(
        'pubspec.yaml: "workspace" must be a list of package paths.',
      );
    }
    final packages = <String>{};
    final dependencies = <String>{..._dependencyNames(rootPubspec, '')};
    for (final member in members) {
      if (member is! String) {
        throw WorkspaceException(
          'pubspec.yaml: workspace entry "$member" must be a path.',
        );
      }
      final pubspecPath = '$member/pubspec.yaml';
      final pubspec = _readPubspec(root, pubspecPath);
      final name = pubspec['name'];
      if (name is! String) {
        throw WorkspaceException('$pubspecPath: "name" must be a string.');
      }
      packages.add(name);
      dependencies.addAll(_dependencyNames(pubspec, pubspecPath));
    }
    dependencies.removeAll(packages);
    return Workspace(
      root: root,
      packages: Set.unmodifiable(packages),
      directDependencies: Set.unmodifiable(dependencies),
    );
  }

  /// Directory that contains the root `pubspec.yaml` and `k.yaml`.
  final Directory root;

  /// Names of the workspace member packages.
  final Set<String> packages;

  /// Names of the direct dependencies, regular or dev, of the root and of the
  /// members, excluding the members themselves.
  final Set<String> directDependencies;

  /// Whether [relativePath] names an existing file under [root].
  bool containsFile(String relativePath) =>
      File('${root.path}/$relativePath').existsSync();
}

YamlMap _readPubspec(Directory root, String relativePath) {
  final file = File('${root.path}/$relativePath');
  if (!file.existsSync()) {
    throw WorkspaceException('$relativePath: file not found.');
  }
  final Object? document;
  try {
    document = loadYaml(file.readAsStringSync());
  } on YamlException catch (error) {
    throw WorkspaceException('$relativePath: invalid YAML: ${error.message}.');
  }
  if (document is! YamlMap) {
    throw WorkspaceException('$relativePath: must be a mapping.');
  }
  return document;
}

Iterable<String> _dependencyNames(YamlMap pubspec, String location) sync* {
  final label = location.isEmpty ? 'pubspec.yaml' : location;
  for (final section in const ['dependencies', 'dev_dependencies']) {
    final value = pubspec[section];
    if (value == null) {
      continue;
    }
    if (value is! YamlMap) {
      throw WorkspaceException('$label: "$section" must be a mapping.');
    }
    yield* value.keys.map((key) => '$key');
  }
}
