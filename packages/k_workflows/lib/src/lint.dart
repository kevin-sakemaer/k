import 'package:k_config/k_config.dart';
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

/// `owner/repo[/path]@<40 hex commit SHA>`, with exactly one `@`.
final RegExp _pinnedAction = RegExp(
  r'^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[^@\s]+)?@[0-9a-f]{40}$',
);

/// A Docker image digest.
final RegExp _digest = RegExp(r'@sha256:[0-9a-f]{64}$');

/// A version comment after a pinned reference, such as `# v1.2.3`.
final RegExp _versionComment = RegExp(r'#\s*v\d');

/// Returns every hardened CI rule broken by the workflows of [sources], and
/// every entry of [config] that no longer matches them.
///
/// [sources] maps the path of each workflow file, relative to the repository
/// root, to its content; messages are prefixed with that path. A workflow is
/// matched against `workflows.write_scopes` of `k.yaml` by its file name.
///
/// The rules:
/// - the file is valid YAML without duplicated keys;
/// - the top level sets exactly `permissions: {}`;
/// - `jobs` is a non-empty mapping of jobs;
/// - every job that runs steps sets a positive integer `timeout-minutes` no
///   larger than [WorkflowsConfig.maxTimeoutMinutes] (a job that calls a
///   reusable workflow cannot set one);
/// - job `permissions`, when set, is a mapping of known scopes to `read`,
///   `write` or `none`, never a shorthand such as `write-all` or `read-all`;
/// - every job-level `write` is declared in [WorkflowsConfig.writeScopes],
///   and every declared entry matches a job that grants that `write`;
/// - no mapping uses the YAML merge key `<<`;
/// - every `uses:` of a job or a step is a local action (`./...`), a Docker
///   image pinned by digest (`docker://...@sha256:<64 hex>`), or
///   `owner/repo[/path]@<40 hex>` (exactly one `@`) followed on its line by a `# v...` comment.
List<String> lintWorkflows(
  Map<String, String> sources,
  WorkflowsConfig config,
) {
  final errors = <String>[];
  final Set<(String, String, String)> granted = {};
  for (final MapEntry(key: path, value: source) in sources.entries) {
    final String workflow = path.split('/').last;
    errors.addAll(
      _lintWorkflow(
        source,
        path,
        config,
        (job, scope) => granted.add((workflow, job, scope)),
      ),
    );
  }
  for (final WriteScopeException declared in config.writeScopes) {
    if (!granted.contains((declared.workflow, declared.job, declared.scope))) {
      errors.add(
        'k.yaml: workflows.write_scopes: stale entry: job '
        "'${declared.job}' of ${declared.workflow} does not grant "
        '"${declared.scope}: write"; remove the entry.',
      );
    }
  }
  return errors;
}

List<String> _lintWorkflow(
  String source,
  String path,
  WorkflowsConfig config,
  void Function(String job, String scope) onWrite,
) {
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
  if (_hasMergeKey(document)) {
    const message =
        'YAML merge keys (<<) are not allowed: they can hide a uses: or a '
        'permissions value.';
    return ['$path: $message'];
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
  final String workflow = path.split('/').last;
  for (final MapEntry(:key, :value) in jobs.nodes.entries) {
    final job = '${(key as YamlNode).value}';
    if (value is! YamlMap) {
      report("job '$job' must be a mapping.");
      continue;
    }
    _lintJob(
      value,
      source,
      _JobContext(
        workflow: workflow,
        job: job,
        config: config,
        report: (message) => report("job '$job': $message"),
        onWrite: (scope) => onWrite(job, scope),
      ),
    );
  }
  return errors;
}

/// What [_lintJob] needs to know about the job it checks.
final class _JobContext {
  const new({
    required this.workflow,
    required this.job,
    required this.config,
    required this.report,
    required this.onWrite,
  });

  final String workflow;
  final String job;
  final WorkflowsConfig config;
  final void Function(String message) report;
  final void Function(String scope) onWrite;

  bool declares(String scope) => config.writeScopes.any(
    (entry) =>
        entry.workflow == workflow && entry.job == job && entry.scope == scope,
  );
}

bool _hasMergeKey(YamlNode node) => switch (node) {
  YamlMap(:final Map<dynamic, YamlNode> nodes) => nodes.entries.any(
    (entry) =>
        (entry.key as YamlNode).value == '<<' || _hasMergeKey(entry.value),
  ),
  YamlList(:final List<YamlNode> nodes) => nodes.any(_hasMergeKey),
  _ => false,
};

void _lintJob(YamlMap job, String source, _JobContext context) {
  final void Function(String) report = context.report;
  final YamlNode? uses = job.nodes['uses'];
  if (uses != null) {
    _lintUses(uses, source, report);
  } else {
    final Object? timeout = job['timeout-minutes'];
    final int max = context.config.maxTimeoutMinutes;
    if (timeout is! int || timeout <= 0) {
      report('timeout-minutes must be a positive integer.');
    } else if (timeout > max) {
      report(
        'timeout-minutes is $timeout, above '
        'workflows.max_timeout_minutes of k.yaml ($max).',
      );
    }
  }
  if (job.containsKey('permissions')) {
    _lintPermissions(job['permissions'], context);
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

void _lintPermissions(Object? permissions, _JobContext context) {
  final void Function(String) report = context.report;
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
    } else if (value == 'write') {
      context.onWrite('$key');
      if (!context.declares('$key')) {
        report(
          '"$key: write" is not declared in workflows.write_scopes of '
          'k.yaml; declare it with a reason or grant read.',
        );
      }
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
  if (!_pinnedAction.hasMatch(value)) {
    report(
      '"$value" must be owner/repo[/path]@<full 40-character commit SHA>, '
      'with exactly one @.',
    );
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
