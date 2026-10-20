/// Strict validation of the `k.yaml` source.
library;

import 'package:k_config/src/model.dart';
import 'package:k_config/src/workspace.dart';
import 'package:yaml/yaml.dart';

/// Outcome of [parseKConfig].
sealed class KConfigResult {
  const new();
}

/// A `k.yaml` source that passed every validation rule.
final class KConfigValid extends KConfigResult {
  /// Wraps the validated [config].
  const new(this.config);

  /// The typed configuration.
  final KConfig config;
}

/// A `k.yaml` source that broke at least one validation rule.
final class KConfigInvalid extends KConfigResult {
  /// Wraps the non-empty list of [errors].
  const new(this.errors);

  /// One human readable message per broken rule.
  final List<String> errors;
}

/// Parses and strictly validates the [source] of `k.yaml` against
/// [workspace].
///
/// Validation fails on an unknown or missing key at any level, a wrong type,
/// a threshold outside 0 to 100, an empty or missing `reason`, a duplicated
/// key, a coverage override for a package missing from the workspace, a
/// dependency exception for a package that is not a direct dependency, and
/// a comment exception for a missing or duplicated file.
KConfigResult parseKConfig(String source, Workspace workspace) {
  final Object? document;
  try {
    document = loadYaml(source);
  } on YamlException catch (error) {
    return KConfigInvalid(['k.yaml: invalid YAML: $error']);
  }
  final validator = _Validator(workspace);
  final KConfig? config = validator.config(document);
  if (config == null || validator.errors.isNotEmpty) {
    return KConfigInvalid(List.unmodifiable(validator.errors));
  }
  return KConfigValid(config);
}

/// Parses one value found at a dotted path, or returns `null` after
/// recording errors.
typedef _Parse<T> = T? Function(Object? value, String path);

/// Parses one entry of a mapping keyed by name.
typedef _ParseEntry<T> = T? Function(String name, Object? value, String path);

final class _Validator {
  new(this.workspace);

  final Workspace workspace;

  /// Every error found so far; the source is valid only if it stays empty.
  final List<String> errors = [];

  void error(String path, String message) =>
      errors.add('k.yaml: ${path.isEmpty ? '(root)' : path}: $message');

  KConfig? config(Object? document) {
    const path = '';
    final Map<String, Object?>? map = strictMap(document, path, const {
      'coverage',
      'dependencies',
      'comments',
    });
    if (map == null) {
      return null;
    }
    final CoverageConfig? coverageConfig = field(
      map,
      path,
      'coverage',
      coverage,
    );
    final DependenciesConfig? dependenciesConfig = field(
      map,
      path,
      'dependencies',
      dependencies,
    );
    final CommentsConfig? commentsConfig = field(
      map,
      path,
      'comments',
      comments,
    );
    if (coverageConfig == null ||
        dependenciesConfig == null ||
        commentsConfig == null) {
      return null;
    }
    return KConfig(
      coverage: coverageConfig,
      dependencies: dependenciesConfig,
      comments: commentsConfig,
    );
  }

  CoverageConfig? coverage(Object? value, String path) {
    final Map<String, Object?>? map = strictMap(value, path, const {
      'default',
      'overrides',
    });
    if (map == null) {
      return null;
    }
    final num? defaultThreshold = field(map, path, 'default', threshold);
    final Map<String, CoverageOverride>? overrides = field(
      map,
      path,
      'overrides',
      (value, path) => entries(value, path, coverageOverride),
    );
    if (defaultThreshold == null || overrides == null) {
      return null;
    }
    for (final MapEntry(:key, :value) in overrides.entries) {
      if (value.threshold >= defaultThreshold) {
        error(
          '$path.overrides.$key.threshold',
          'must be lower than coverage.default ($defaultThreshold), '
              'found ${value.threshold}.',
        );
      }
    }
    return CoverageConfig(
      defaultThreshold: defaultThreshold,
      overrides: overrides,
    );
  }

  CoverageOverride? coverageOverride(String name, Object? value, String path) {
    if (!workspace.packages.contains(name)) {
      error(
        path,
        'unknown package. Workspace packages: '
        '${_list(workspace.packages)}.',
      );
    }
    final Map<String, Object?>? map = strictMap(value, path, const {
      'threshold',
      'reason',
    });
    if (map == null) {
      return null;
    }
    final num? packageThreshold = field(map, path, 'threshold', threshold);
    final String? packageReason = field(map, path, 'reason', reason);
    if (packageThreshold == null || packageReason == null) {
      return null;
    }
    return CoverageOverride(threshold: packageThreshold, reason: packageReason);
  }

  DependenciesConfig? dependencies(Object? value, String path) {
    final Map<String, Object?>? map = strictMap(value, path, const {
      'exceptions',
    });
    if (map == null) {
      return null;
    }
    final Map<String, DependencyException>? exceptions = field(
      map,
      path,
      'exceptions',
      (value, path) => entries(value, path, dependencyException),
    );
    if (exceptions == null) {
      return null;
    }
    return DependenciesConfig(exceptions: exceptions);
  }

  DependencyException? dependencyException(
    String name,
    Object? value,
    String path,
  ) {
    if (!workspace.directDependencies.contains(name)) {
      error(path, 'not a direct dependency of any workspace package.');
    }
    final Map<String, Object?>? map = strictMap(value, path, const {
      'reason',
      'approved_by',
    });
    if (map == null) {
      return null;
    }
    final String? dependencyReason = field(map, path, 'reason', reason);
    final String? approver = field(map, path, 'approved_by', approvedBy);
    if (dependencyReason == null || approver == null) {
      return null;
    }
    return DependencyException(reason: dependencyReason, approvedBy: approver);
  }

  CommentsConfig? comments(Object? value, String path) {
    final Map<String, Object?>? map = strictMap(value, path, const {
      'exceptions',
    });
    if (map == null) {
      return null;
    }
    final List<CommentException>? exceptions = field(
      map,
      path,
      'exceptions',
      commentExceptions,
    );
    if (exceptions == null) {
      return null;
    }
    return CommentsConfig(exceptions: exceptions);
  }

  List<CommentException>? commentExceptions(Object? value, String path) {
    if (value is! List) {
      error(path, 'must be a list.');
      return null;
    }
    final exceptions = <CommentException>[];
    var valid = true;
    for (final (index, item) in value.indexed) {
      final itemPath = '$path[$index]';
      final CommentException? exception = commentException(item, itemPath);
      if (exception == null) {
        valid = false;
      } else if (exceptions.any((known) => known.path == exception.path)) {
        valid = false;
        error(itemPath, 'duplicated path "${exception.path}".');
      } else {
        exceptions.add(exception);
      }
    }
    return valid ? List.unmodifiable(exceptions) : null;
  }

  CommentException? commentException(Object? value, String path) {
    final Map<String, Object?>? map = strictMap(value, path, const {
      'path',
      'reason',
    });
    if (map == null) {
      return null;
    }
    final String? filePath = field(map, path, 'path', repositoryFile);
    final String? fileReason = field(map, path, 'reason', reason);
    if (filePath == null || fileReason == null) {
      return null;
    }
    return CommentException(path: filePath, reason: fileReason);
  }

  String? repositoryFile(Object? value, String path) {
    if (value is! String || value.trim().isEmpty) {
      error(path, 'must be a non-empty string.');
      return null;
    }
    if (value.startsWith('/') || value.split('/').contains('..')) {
      error(path, 'must be relative to the repository root, without "..".');
      return null;
    }
    if (!workspace.containsFile(value)) {
      error(path, 'file "$value" not found.');
      return null;
    }
    return value;
  }

  num? threshold(Object? value, String path) {
    if (value is! num) {
      error(path, 'must be a number between 0 and 100.');
      return null;
    }
    if (!(value >= 0 && value <= 100)) {
      error(path, 'must be between 0 and 100, found $value.');
      return null;
    }
    return value;
  }

  String? reason(Object? value, String path) {
    if (value is! String || value.trim().isEmpty) {
      error(path, 'must be a non-empty string that explains the exception.');
      return null;
    }
    return value;
  }

  String? approvedBy(Object? value, String path) {
    if (value is! String || value.trim().isEmpty) {
      error(path, 'must be a non-empty string that names the approver.');
      return null;
    }
    return value;
  }

  Map<String, T>? entries<T>(Object? value, String path, _ParseEntry<T> parse) {
    final Map<String, Object?>? map = stringMap(value, path);
    if (map == null) {
      return null;
    }
    final result = <String, T>{};
    var valid = true;
    for (final MapEntry(:key, :value) in map.entries) {
      final T? entry = parse(key, value, _join(path, key));
      if (entry == null) {
        valid = false;
      } else {
        result[key] = entry;
      }
    }
    return valid ? Map.unmodifiable(result) : null;
  }

  Map<String, Object?>? strictMap(
    Object? value,
    String path,
    Set<String> keys,
  ) {
    final Map<String, Object?>? map = stringMap(value, path);
    if (map == null) {
      return null;
    }
    for (final String key in map.keys) {
      if (!keys.contains(key)) {
        error(_join(path, key), 'unknown key. Allowed keys: ${_list(keys)}.');
      }
    }
    for (final key in keys) {
      if (!map.containsKey(key)) {
        error(_join(path, key), 'missing required key.');
      }
    }
    return map;
  }

  Map<String, Object?>? stringMap(Object? value, String path) {
    if (value is! Map) {
      error(path, 'must be a mapping.');
      return null;
    }
    final map = <String, Object?>{};
    var valid = true;
    for (final MapEntry(:key, :value) in value.entries) {
      if (key is! String) {
        valid = false;
        error(path, 'key "$key" must be a string.');
      } else {
        map[key] = value;
      }
    }
    return valid ? map : null;
  }

  T? field<T>(
    Map<String, Object?> map,
    String path,
    String key,
    _Parse<T> parse,
  ) => map.containsKey(key) ? parse(map[key], _join(path, key)) : null;
}

String _join(String path, String key) => path.isEmpty ? key : '$path.$key';

String _list(Iterable<String> values) {
  final List<String> sorted = values.toList()..sort();
  return sorted.isEmpty ? '(none)' : sorted.join(', ');
}
