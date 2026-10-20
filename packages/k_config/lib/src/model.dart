/// Typed values of a validated `k.yaml` file.
library;

/// The validated content of the global `k.yaml` configuration file.
final class KConfig {
  /// Creates a configuration from its validated sections.
  const new({
    required this.coverage,
    required this.dependencies,
    required this.comments,
  });

  /// Settings of the coverage check.
  final CoverageConfig coverage;

  /// Settings of the direct dependency publisher check.
  final DependenciesConfig dependencies;

  /// Settings of the Dart comment check.
  final CommentsConfig comments;
}

/// Settings of the coverage check.
final class CoverageConfig {
  /// Creates coverage settings.
  const new({
    required this.defaultThreshold,
    required this.overrides,
    required this.toolVersion,
  });

  /// Exact version of `package:coverage` (publisher tools.dart.dev) used to
  /// build the coverage report, in `MAJOR.MINOR.PATCH` form.
  final String toolVersion;

  /// Line coverage threshold, in percent, of every package without override.
  final int defaultThreshold;

  /// Justified thresholds, keyed by workspace package name.
  final Map<String, CoverageOverride> overrides;

  /// Returns the line coverage threshold, in percent, that applies to
  /// [package].
  int thresholdFor(String package) =>
      overrides[package]?.threshold ?? defaultThreshold;
}

/// A justified coverage threshold for one workspace package.
final class CoverageOverride {
  /// Creates an override with its [threshold] and [reason].
  const new({required this.threshold, required this.reason});

  /// Line coverage threshold, in percent.
  final int threshold;

  /// Why the package cannot reach the default threshold.
  final String reason;
}

/// Settings of the direct dependency publisher check.
final class DependenciesConfig {
  /// Creates dependency settings.
  const new({required this.exceptions});

  /// Verified pub.dev publishers whose packages may be direct dependencies.
  ///
  /// The list is fixed and cannot be changed from `k.yaml`: any other
  /// dependency needs an entry in [exceptions].
  static const List<String> allowedPublishers = [
    'dart.dev',
    'tools.dart.dev',
    'labs.dart.dev',
  ];

  /// Base URL of the registry whose publisher API the check queries, as
  /// `<registryUrl>/api/packages/<name>/publisher`.
  ///
  /// The registry is a fixed policy and cannot be changed from `k.yaml`: a
  /// configurable registry would bypass [allowedPublishers].
  static const String registryUrl = 'https://pub.dev';

  /// `hosted` URLs, without a trailing slash, that name the registry at
  /// [registryUrl]. A dependency hosted anywhere else needs an entry in
  /// [exceptions].
  ///
  /// The list is fixed and cannot be changed from `k.yaml`.
  static const List<String> hostedAliases = [
    'https://pub.dev',
    'https://pub.dartlang.org',
  ];

  /// Approved direct dependencies from other publishers, keyed by package
  /// name.
  final Map<String, DependencyException> exceptions;
}

/// An approved direct dependency from a publisher that is not allowed.
final class DependencyException {
  /// Creates an exception with its [reason] and [approvedBy].
  const new({required this.reason, required this.approvedBy});

  /// Why the dependency is needed.
  final String reason;

  /// Who approved the dependency, and when.
  final String approvedBy;
}

/// Settings of the Dart comment check.
final class CommentsConfig {
  /// Creates comment settings.
  const new({
    required this.include,
    required this.exclude,
    required this.exceptions,
  });

  /// Glob patterns, relative to the repository root, of the files to check.
  /// Only `.dart` files are ever read.
  final List<String> include;

  /// Glob patterns, relative to the repository root, of the files to skip.
  final List<String> exclude;

  /// Files that may contain non-documentation comments.
  final List<CommentException> exceptions;
}

/// A file that may contain non-documentation comments.
final class CommentException {
  /// Creates an exception for [path] with its [reason].
  const new({required this.path, required this.reason});

  /// Path of the file, relative to the repository root.
  final String path;

  /// Why the file needs non-documentation comments.
  final String reason;
}
