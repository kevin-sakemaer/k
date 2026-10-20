import 'package:yaml/yaml.dart';

/// Permission scopes that a job may grant, from the GitHub Actions workflow
/// syntax (`jobs.<job_id>.permissions`).
const Set<String> jobPermissionScopes = {
  'actions',
  'attestations',
  'checks',
  'contents',
  'deployments',
  'discussions',
  'id-token',
  'issues',
  'models',
  'packages',
  'pages',
  'pull-requests',
  'repository-projects',
  'security-events',
  'statuses',
};

/// Access levels that a job permission scope may have.
const Set<String> _accessLevels = {'read', 'write', 'none'};

/// A full commit SHA.
final RegExp _sha = RegExp(r'^[0-9a-f]{40}$');

/// A Docker image digest.
final RegExp _digest = RegExp(r'@sha256:[0-9a-f]{64}$');

/// A version comment after a pinned reference, such as `# v1.2.3`.
final RegExp _versionComment = RegExp(r'#\s*v\d');

/// Returns every hardened CI rule broken by the workflow [source], each
/// message prefixed with [path].
///
/// The rules:
/// - the file is valid YAML without duplicated keys;
/// - the top level sets exactly `permissions: {}`;
/// - `jobs` is a non-empty mapping of jobs;
/// - every job that runs steps sets a positive integer `timeout-minutes`
///   (a job that calls a reusable workflow cannot set one);
/// - job `permissions`, when set, is a mapping of known scopes to `read`,
///   `write` or `none`, never a shorthand such as `write-all` or `read-all`;
/// - every `uses:` of a job or a step is a local action (`./...`), a Docker
///   image pinned by digest (`docker://...@sha256:<64 hex>`), or
///   `owner/repo[/path]@<40 hex>` followed on its line by a `# v...` comment.
List<String> lintWorkflow(String source, String path) {
  final errors = <String>[];
  void report(String message) => errors.add('$path: $message');
  final YamlNode document;
  try {
    document = loadYamlNode(source, sourceUrl: Uri.file(path));
  } on YamlException catch (exception) {
    return ['$path: invalid YAML: ${exception.message}'];
  }
  if (document is! YamlMap) {
    return ['$path: a workflow must be a mapping.'];
  }
  final Object? permissions = document['permissions'];
  if (permissions is! Map || permissions.isNotEmpty) {
    report("top-level permissions must be exactly 'permissions: {}'.");
  }
  final YamlNode? jobs = document.nodes['jobs'];
  if (jobs is! YamlMap || jobs.isEmpty) {
    report('jobs must be a non-empty mapping.');
    return errors;
  }
  for (final MapEntry(:key, :value) in jobs.nodes.entries) {
    final job = '${(key as YamlNode).value}';
    if (value is! YamlMap) {
      report("job '$job' must be a mapping.");
      continue;
    }
    _lintJob(value, source, (message) => report("job '$job': $message"));
  }
  return errors;
}

void _lintJob(YamlMap job, String source, void Function(String) report) {
  final YamlNode? uses = job.nodes['uses'];
  if (uses != null) {
    _lintUses(uses, source, report);
  } else {
    final Object? timeout = job['timeout-minutes'];
    if (timeout is! int || timeout <= 0) {
      report('timeout-minutes must be a positive integer.');
    }
  }
  if (job.containsKey('permissions')) {
    _lintPermissions(job['permissions'], report);
  }
  final YamlNode? steps = job.nodes['steps'];
  if (steps is YamlList) {
    for (final YamlNode step in steps.nodes) {
      if (step is YamlMap) {
        if (step.nodes['uses'] case final YamlNode stepUses?) {
          _lintUses(stepUses, source, report);
        }
      }
    }
  }
}

void _lintPermissions(Object? permissions, void Function(String) report) {
  if (permissions is! Map) {
    report(
      'permissions must be a mapping of explicit scopes, '
      'not "$permissions".',
    );
    return;
  }
  for (final MapEntry(:key, :value) in permissions.entries) {
    if (!jobPermissionScopes.contains(key)) {
      report('unknown permission scope "$key".');
    } else if (!_accessLevels.contains(value)) {
      report('permission "$key" must be read, write or none, not "$value".');
    }
  }
}

void _lintUses(YamlNode node, String source, void Function(String) report) {
  final Object? value = node.value;
  if (value is! String) {
    report('uses must be a string.');
    return;
  }
  if (value.startsWith('./')) {
    return;
  }
  if (value.startsWith('docker://')) {
    if (!_digest.hasMatch(value)) {
      report('"$value" must be pinned by an image digest (@sha256:...).');
    }
    return;
  }
  final int at = value.lastIndexOf('@');
  if (at < 0 || !_sha.hasMatch(value.substring(at + 1))) {
    report('"$value" must be pinned by a full 40-character commit SHA.');
    return;
  }
  final int end = node.span.end.offset;
  final int lineEnd = source.indexOf('\n', end);
  final String rest = source.substring(
    end,
    lineEnd < 0 ? source.length : lineEnd,
  );
  if (!_versionComment.hasMatch(rest)) {
    report('"$value" must be followed by its version in a comment (# vX.Y.Z).');
  }
}
