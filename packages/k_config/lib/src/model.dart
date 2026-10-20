/// Typed values of a validated `k.yaml` file.
library;

/// The validated content of the global `k.yaml` configuration file.
final class KConfig {
  /// Creates a configuration from its validated sections.
  const KConfig({
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
  const CoverageConfig({
    required this.defaultThreshold,
    required this.overrides,
  });

  /// Line coverage threshold, in percent, of every package without override.
  final num defaultThreshold;

  /// Justified thresholds, keyed by workspace package name.
  final Map<String, CoverageOverride> overrides;

  /// Returns the line coverage threshold, in percent, that applies to
  /// [package].
  num thresholdFor(String package) =>
      overrides[package]?.threshold ?? defaultThreshold;
}

/// A justified coverage threshold for one workspace package.
final class CoverageOverride {
  /// Creates an override with its [threshold] and [reason].
  const CoverageOverride({required this.threshold, required this.reason});

  /// Line coverage threshold, in percent.
  final num threshold;

  /// Why the package cannot reach the default threshold.
  final String reason;
}

/// Settings of the direct dependency publisher check.
final class DependenciesConfig {
  /// Creates dependency settings.
  const DependenciesConfig({
    required this.allowedPublishers,
    required this.exceptions,
  });

  /// Verified pub.dev publishers whose packages may be direct dependencies.
  final List<String> allowedPublishers;

  /// Approved direct dependencies from other publishers, keyed by package
  /// name.
  final Map<String, DependencyException> exceptions;
}

/// An approved direct dependency from a publisher that is not allowed.
final class DependencyException {
  /// Creates an exception with its [reason].
  const DependencyException({required this.reason});

  /// Why, and by whom, the dependency was approved.
  final String reason;
}

/// Settings of the Dart comment check.
final class CommentsConfig {
  /// Creates comment settings.
  const CommentsConfig({required this.exceptions});

  /// Files that may contain non-documentation comments.
  final List<CommentException> exceptions;
}

/// A file that may contain non-documentation comments.
final class CommentException {
  /// Creates an exception for [path] with its [reason].
  const CommentException({required this.path, required this.reason});

  /// Path of the file, relative to the repository root.
  final String path;

  /// Why the file needs non-documentation comments.
  final String reason;
}
