/// Strict validation of the `k.yaml` source.
library;

import 'package:glob/glob.dart';
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
/// dependency exception for a package that is not a direct dependency, a
/// comment exception for a missing or duplicated file, a
/// `workflows.max_timeout_minutes` that is not an integer greater than 0,
/// and a duplicated or malformed `workflows.write_scopes` entry.
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

  /// Source text of every scalar value read so far, keyed by dotted path, so
  /// that a value can be checked as written and not only as parsed.
  final Map<String, String> sourceText = {};

  void error(String path, String message) =>
      errors.add('k.yaml: ${path.isEmpty ? '(root)' : path}: $message');

  KConfig? config(Object? document) {
    const path = '';
    final Map<String, Object?>? map = strictMap(document, path, const {
      'coverage',
      'dependencies',
      'comments',
      'close_issues',
      'workflows',
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
    final CloseIssuesConfig? closeIssuesConfig = field(
      map,
      path,
      'close_issues',
      closeIssues,
    );
    final WorkflowsConfig? workflowsConfig = field(
      map,
      path,
      'workflows',
      workflows,
    );
    if (coverageConfig == null ||
        dependenciesConfig == null ||
        commentsConfig == null ||
        closeIssuesConfig == null ||
        workflowsConfig == null) {
      return null;
    }
    return KConfig(
      coverage: coverageConfig,
      dependencies: dependenciesConfig,
      comments: commentsConfig,
      closeIssues: closeIssuesConfig,
      workflows: workflowsConfig,
    );
  }

  CloseIssuesConfig? closeIssues(Object? value, String path) {
    final Map<String, Object?>? map = strictMap(value, path, const {
      'lookback_hours',
    });
    if (map == null) {
      return null;
    }
    final int? hours = field(map, path, 'lookback_hours', lookbackHours);
    return hours == null ? null : CloseIssuesConfig(lookbackHours: hours);
  }

  int? lookbackHours(Object? value, String path) {
    final String? source = sourceText[path];
    final String text = source == null || source.isEmpty ? '$value' : source;
    if (value is! int ||
        !_decimalInteger.hasMatch(text) ||
        value < 1 ||
        value > CloseIssuesConfig.maxLookbackHours) {
      error(
        path,
        'must be an integer from 1 to '
        '${CloseIssuesConfig.maxLookbackHours}, found $text.',
      );
      return null;
    }
    return value;
  }

  CoverageConfig? coverage(Object? value, String path) {
    final Map<String, Object?>? map = strictMap(value, path, const {
      'default',
      'overrides',
      'tool_version',
    });
    if (map == null) {
      return null;
    }
    final int? defaultThreshold = field(map, path, 'default', threshold);
    final Map<String, CoverageOverride>? overrides = field(
      map,
      path,
      'overrides',
      (value, path) => entries(value, path, coverageOverride),
    );
    final String? toolVersion = field(map, path, 'tool_version', semver);
    if (defaultThreshold == null || overrides == null || toolVersion == null) {
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
      toolVersion: toolVersion,
    );
  }

  /// Exact version without range, prerelease or build suffix.
  static final RegExp _semver = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  );

  String? semver(Object? value, String path) {
    if (value is! String || !_semver.hasMatch(value)) {
      error(
        path,
        'must be an exact version MAJOR.MINOR.PATCH as a string, '
        'found ${value is String ? '"$value"' : value}.',
      );
      return null;
    }
    return value;
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
    final int? packageThreshold = field(map, path, 'threshold', threshold);
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
      'include',
      'exclude',
      'exceptions',
    });
    if (map == null) {
      return null;
    }
    final List<String>? include = field(map, path, 'include', nonEmptyGlobs);
    final List<String>? exclude = field(map, path, 'exclude', globs);
    final List<CommentException>? exceptions = field(
      map,
      path,
      'exceptions',
      commentExceptions,
    );
    if (include == null || exclude == null || exceptions == null) {
      return null;
    }
    return CommentsConfig(
      include: include,
      exclude: exclude,
      exceptions: exceptions,
    );
  }

  List<String>? nonEmptyGlobs(Object? value, String path) {
    final List<String>? patterns = globs(value, path);
    if (patterns != null && patterns.isEmpty) {
      error(path, 'must list at least one glob pattern.');
      return null;
    }
    return patterns;
  }

  List<String>? globs(Object? value, String path) {
    if (value is! List) {
      error(path, 'must be a list.');
      return null;
    }
    final patterns = <String>[];
    var valid = true;
    for (final (index, item) in value.indexed) {
      if (item is! String || item.trim().isEmpty) {
        valid = false;
        error('$path[$index]', 'must be a non-empty glob pattern string.');
      } else if (_globError(item) case final String message?) {
        valid = false;
        error('$path[$index]', 'invalid glob pattern "$item": $message.');
      } else if (patterns.contains(item)) {
        valid = false;
        error('$path[$index]', 'duplicated pattern "$item".');
      } else {
        patterns.add(item);
      }
    }
    return valid ? List.unmodifiable(patterns) : null;
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

  WorkflowsConfig? workflows(Object? value, String path) {
    final Map<String, Object?>? map = strictMap(value, path, const {
      'max_timeout_minutes',
      'write_scopes',
    });
    if (map == null) {
      return null;
    }
    final int? maxTimeout = field(
      map,
      path,
      'max_timeout_minutes',
      positiveInteger,
    );
    final List<WriteScopeException>? scopes = field(
      map,
      path,
      'write_scopes',
      writeScopes,
    );
    if (maxTimeout == null || scopes == null) {
      return null;
    }
    return WorkflowsConfig(maxTimeoutMinutes: maxTimeout, writeScopes: scopes);
  }

  List<WriteScopeException>? writeScopes(Object? value, String path) {
    if (value is! List) {
      error(path, 'must be a list.');
      return null;
    }
    final scopes = <WriteScopeException>[];
    var valid = true;
    for (final (index, item) in value.indexed) {
      final itemPath = '$path[$index]';
      final WriteScopeException? scope = writeScope(item, itemPath);
      if (scope == null) {
        valid = false;
      } else if (scopes.any(
        (known) =>
            known.workflow == scope.workflow &&
            known.job == scope.job &&
            known.scope == scope.scope,
      )) {
        valid = false;
        error(
          itemPath,
          'duplicated write scope "${scope.scope}" of job "${scope.job}" in '
          '"${scope.workflow}".',
        );
      } else {
        scopes.add(scope);
      }
    }
    return valid ? List.unmodifiable(scopes) : null;
  }

  WriteScopeException? writeScope(Object? value, String path) {
    final Map<String, Object?>? map = strictMap(value, path, const {
      'workflow',
      'job',
      'scope',
      'reason',
    });
    if (map == null) {
      return null;
    }
    final String? workflow = field(map, path, 'workflow', workflowFile);
    final String? job = field(map, path, 'job', name);
    final String? scope = field(map, path, 'scope', name);
    final String? scopeReason = field(map, path, 'reason', reason);
    if (workflow == null ||
        job == null ||
        scope == null ||
        scopeReason == null) {
      return null;
    }
    return WriteScopeException(
      workflow: workflow,
      job: job,
      scope: scope,
      reason: scopeReason,
    );
  }

  /// A file name with a `.yml` or `.yaml` extension and no directory.
  static final RegExp _workflowFile = RegExp(r'^[A-Za-z0-9_.-]+\.ya?ml$');

  String? workflowFile(Object? value, String path) {
    if (value is! String || !_workflowFile.hasMatch(value)) {
      error(
        path,
        'must be the file name of a workflow in .github/workflows, such as '
        '"test.yml", found ${value is String ? '"$value"' : value}.',
      );
      return null;
    }
    return value;
  }

  String? name(Object? value, String path) {
    if (value is! String || value.trim().isEmpty || value.trim() != value) {
      error(path, 'must be a non-empty string without surrounding spaces.');
      return null;
    }
    return value;
  }

  int? positiveInteger(Object? value, String path) {
    final String? source = sourceText[path];
    final String text = source == null || source.isEmpty ? '$value' : source;
    if (value is! int || !_decimalInteger.hasMatch(text) || value <= 0) {
      error(path, 'must be an integer greater than 0, found $text.');
      return null;
    }
    return value;
  }

  /// The parse error of the glob [pattern], or `null` when it is valid.
  static String? _globError(String pattern) {
    try {
      Glob(pattern);
      return null;
    } on FormatException catch (exception) {
      return exception.message;
    }
  }

  /// A plain decimal integer, without sign, leading zero, separator, base
  /// prefix, exponent or fraction.
  static final RegExp _decimalInteger = RegExp(r'^(0|[1-9][0-9]*)$');

  int? threshold(Object? value, String path) {
    final String? source = sourceText[path];
    final String text = source == null || source.isEmpty ? '$value' : source;
    if (value is! int || !_decimalInteger.hasMatch(text) || value > 100) {
      error(path, 'must be an integer from 0 to 100, found $text.');
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
    for (final MapEntry(:key, value: entry) in value.entries) {
      if (key is! String) {
        valid = false;
        error(path, 'key "$key" must be a string.');
      } else {
        map[key] = entry;
        final Object? node = value is YamlMap ? value.nodes[key] : null;
        if (node is YamlScalar) {
          sourceText[_join(path, key)] = node.span.text;
        }
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
