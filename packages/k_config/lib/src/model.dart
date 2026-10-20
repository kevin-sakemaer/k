/// Typed values of a validated `k.yaml` file.
library;

/// The validated content of the global `k.yaml` configuration file.
final class KConfig {
  /// Creates a configuration from its validated sections.
  const new({
    required this.coverage,
    required this.dependencies,
    required this.comments,
    required this.closeIssues,
    required this.workflows,
  });

  /// Settings of the coverage check.
  final CoverageConfig coverage;

  /// Settings of the direct dependency publisher check.
  final DependenciesConfig dependencies;

  /// Settings of the Dart comment check.
  final CommentsConfig comments;

  /// Settings of the scheduled `close-issues` sweep.
  final CloseIssuesConfig closeIssues;

  /// Settings of the GitHub Actions workflow lint.
  final WorkflowsConfig workflows;
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
  const new({required this.registryTimeoutSeconds, required this.exceptions});

  /// Largest accepted value of [registryTimeoutSeconds]: five minutes.
  static const int maxRegistryTimeoutSeconds = 300;

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

  /// Longest time, in seconds, allowed to connect to [registryUrl] and to
  /// receive a whole publisher response, from
  /// `dependencies.registry_timeout_seconds`. A lookup that takes longer fails
  /// the check.
  final int registryTimeoutSeconds;

  /// [registryTimeoutSeconds] as a [Duration].
  Duration get registryTimeout => Duration(seconds: registryTimeoutSeconds);

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

/// Settings of the scheduled `close-issues` sweep (#40).
final class CloseIssuesConfig {
  /// Creates sweep settings.
  const new({required this.lookbackHours});

  /// Largest accepted value of [lookbackHours]: 30 days.
  static const int maxLookbackHours = 720;

  /// How far back, in hours, the sweep looks for PRs merged into `main`.
  final int lookbackHours;
}

/// Settings of the GitHub Actions workflow lint.
final class WorkflowsConfig {
  /// Creates workflow settings.
  const new({required this.maxTimeoutMinutes, required this.writeScopes});

  /// Largest `timeout-minutes` that a job may set.
  final int maxTimeoutMinutes;

  /// Job-level `write` permissions that are allowed, each with its reason.
  ///
  /// Any other job-level `write` permission fails the workflow lint.
  final List<WriteScopeException> writeScopes;
}

/// A justified job-level `write` permission of a workflow.
final class WriteScopeException {
  /// Creates an exception for the [scope] of [job] in [workflow].
  const new({
    required this.workflow,
    required this.job,
    required this.scope,
    required this.reason,
  });

  /// File name of the workflow in `.github/workflows`, such as `test.yml`.
  final String workflow;

  /// Identifier of the job in the `jobs` mapping of [workflow].
  final String job;

  /// Permission scope that [job] grants with `write`, such as `contents`.
  final String scope;

  /// Why the job needs to write with [scope].
  final String reason;
}
