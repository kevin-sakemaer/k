/// Reads the direct dependencies of the workspace pubspecs.
library;

import 'dart:io';

import 'package:k_config/k_config.dart';
import 'package:yaml/yaml.dart';

/// Where a direct dependency comes from.
enum DependencySource {
  /// A package hosted on pub.dev.
  pubDev,

  /// A package from the SDK (`sdk: flutter`, ...).
  sdk,

  /// A local package (`path: ...`).
  path,

  /// A package from a Git repository.
  git,

  /// A package hosted on another server than pub.dev.
  otherHost,
}

/// A direct dependency, regular or dev, or a dependency override of a
/// workspace pubspec.
final class DirectDependency {
  /// Creates a dependency named [name] declared in [pubspec].
  ///
  /// [isOverride] is true for an entry of `dependency_overrides`.
  const new(this.name, this.pubspec, this.source, {this.isOverride = false});

  /// Name of the package.
  final String name;

  /// Pubspec that declares it, relative to the repository root.
  final String pubspec;

  /// Where the package comes from.
  final DependencySource source;

  /// Whether the entry comes from `dependency_overrides`.
  final bool isOverride;
}

/// Reads the direct dependencies and the `dependency_overrides` of the root
/// pubspec and of every workspace member under [root], skipping the
/// workspace packages themselves.
///
/// Throws a [WorkspaceException] when a pubspec is missing or malformed.
List<DirectDependency> readDirectDependencies(Directory root) {
  final workspace = Workspace.load(root);
  final YamlMap rootPubspec = _read(root, 'pubspec.yaml');
  final pubspecs = <String, YamlMap>{'pubspec.yaml': rootPubspec};
  for (final Object? member in rootPubspec['workspace'] as YamlList) {
    final path = '$member/pubspec.yaml';
    pubspecs[path] = _read(root, path);
  }
  return [
    for (final MapEntry(key: String path, value: YamlMap pubspec)
        in pubspecs.entries)
      for (final section in const [
        'dependencies',
        'dev_dependencies',
        'dependency_overrides',
      ])
        if (_section(pubspec, section) case final deps?)
          for (final MapEntry(:Object? key, :Object? value) in deps.entries)
            if (!workspace.packages.contains('$key'))
              DirectDependency(
                '$key',
                path,
                _source(value),
                isOverride: section == 'dependency_overrides',
              ),
  ];
}

YamlMap _read(Directory root, String path) =>
    loadYaml(File('${root.path}/$path').readAsStringSync()) as YamlMap;

DependencySource _source(Object? value) {
  if (value is! YamlMap) {
    return DependencySource.pubDev;
  }
  if (value.containsKey('sdk')) {
    return DependencySource.sdk;
  }
  if (value.containsKey('path')) {
    return DependencySource.path;
  }
  if (value.containsKey('git')) {
    return DependencySource.git;
  }
  final Object? hosted = value['hosted'];
  final Object? url = hosted is YamlMap ? hosted['url'] : hosted;
  if (url == null ||
      DependenciesConfig.hostedAliases.contains(
        '$url'.replaceAll(RegExp(r'/+$'), ''),
      )) {
    return DependencySource.pubDev;
  }
  return DependencySource.otherHost;
}

YamlMap? _section(YamlMap pubspec, String section) {
  final Object? value = pubspec[section];
  return value is YamlMap ? value : null;
}
