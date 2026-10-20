import 'package:k_config/k_config.dart';
import 'package:k_workflows/k_workflows.dart';
import 'package:test/test.dart';

const String sha = '0123456789abcdef0123456789abcdef01234567';

/// A hardened workflow whose single step is [step].
String workflow({
  String step = '- uses: actions/checkout@$sha # v7.0.1',
  String root = 'permissions: {}',
  String job = '    timeout-minutes: 5\n    permissions:\n      contents: read',
}) =>
    'name: w\n'
    'on: pull_request\n'
    '$root\n'
    'jobs:\n'
    '  a:\n'
    '    runs-on: ubuntu-latest\n'
    '$job\n'
    '    steps:\n'
    '      $step\n';

/// Workflow settings without write scopes and with a 10 minute limit.
const WorkflowsConfig noWrites = WorkflowsConfig(
  maxTimeoutMinutes: 10,
  writeScopes: [],
);

/// Settings that declare the `write` of [scope] for job `a` of `w.yml`.
WorkflowsConfig declaring(String scope, {String workflow = 'w.yml'}) =>
    WorkflowsConfig(
      maxTimeoutMinutes: 10,
      writeScopes: [
        WriteScopeException(
          workflow: workflow,
          job: 'a',
          scope: scope,
          reason: 'Needed by the test.',
        ),
      ],
    );

List<String> lint(String source, {WorkflowsConfig config = noWrites}) =>
    lintWorkflows({'w.yml': source}, config);

/// Returns [text]: wraps one expected error split over several lines.
String message(String text) => text;

void main() {
  test('a hardened workflow passes', () {
    expect(lint(workflow()), isEmpty);
  });

  group('uses', () {
    test('a tag, a branch or a short SHA fails', () {
      for (final ref in <String>['v7', 'main', '0123456']) {
        expect(lint(workflow(step: '- uses: actions/checkout@$ref # v7')), [
          contains('must be owner/repo[/path]@<full 40-character commit SHA>'),
        ]);
      }
    });

    test('a reference with several @ or a bad owner/repo fails', () {
      for (final ref in <String>[
        'a/b@main@$sha',
        'a/b@$sha@$sha',
        'checkout@$sha',
        '/b@$sha',
        'a/b/@$sha',
      ]) {
        expect(lint(workflow(step: '- uses: $ref # v1')), [
          contains('with exactly one @'),
        ], reason: ref);
      }
    });

    test('a reference without @ fails', () {
      expect(lint(workflow(step: '- uses: actions/checkout')), [
        contains('must be owner/repo[/path]@<full 40-character commit SHA>'),
      ]);
    });

    test('flow and quoted keys are parsed', () {
      expect(lint(workflow(step: '- {uses: actions/checkout@main}')), [
        contains('"actions/checkout@main" must be owner/repo'),
      ]);
      expect(lint(workflow(step: '- "uses": actions/checkout@main')), [
        contains('"actions/checkout@main" must be owner/repo'),
      ]);
    });

    test('a SHA inside a comment does not count', () {
      expect(
        lint(
          workflow(step: '- uses: actions/checkout@main # uses: x@$sha # v1'),
        ),
        [contains('"actions/checkout@main" must be owner/repo')],
      );
    });

    test('a quoted SHA with a version comment passes', () {
      expect(
        lint(workflow(step: "- uses: 'actions/checkout@$sha' # v7")),
        isEmpty,
      );
      expect(lint(workflow(step: '- {uses: "a/b/c@$sha"} # v1.0.0')), isEmpty);
    });

    test('a pinned SHA without a version comment fails', () {
      expect(lint(workflow(step: '- uses: actions/checkout@$sha')), [
        contains('must be followed by its version in a comment'),
      ]);
      expect(lint(workflow(step: '- uses: a/b@$sha').trimRight()), [
        contains('must be followed by its version in a comment'),
      ]);
    });

    test('local actions pass', () {
      expect(lint(workflow(step: '- uses: ./.github/actions/setup')), isEmpty);
    });

    test('docker images must be pinned by digest', () {
      final digest = 'sha256:${'a' * 64}';
      expect(lint(workflow(step: '- uses: docker://alpine@$digest')), isEmpty);
      expect(lint(workflow(step: '- uses: docker://alpine:3.20')), [
        contains('must be pinned by an image digest'),
      ]);
    });

    test('a non-string uses fails', () {
      expect(lint(workflow(step: '- uses: [a]')), [
        contains('uses must be a string'),
      ]);
    });

    test('steps without uses and non-mapping steps are ignored', () {
      expect(lint(workflow(step: '- run: true')), isEmpty);
      expect(lint(workflow(step: '- just a string')), isEmpty);
    });

    test('reusable workflow jobs are checked and need no timeout', () {
      const source =
          'permissions: {}\n'
          'jobs:\n'
          '  call:\n'
          '    uses: org/repo/.github/workflows/w.yml@main\n'
          '  ok:\n'
          '    uses: org/repo/.github/workflows/w.yml@$sha # v1\n';
      const expected =
          "w.yml: job 'call': reusable workflow "
          '"org/repo/.github/workflows/w.yml@main" must be '
          'owner/repo/.github/workflows/<file>.yml (or .yaml) pinned as '
          '@<full 40-character commit SHA>.';
      expect(lint(source), [expected]);
    });
  });

  group('uses path segments', () {
    test('empty, ".", ".." or trailing-slash segments fail', () {
      for (final ref in <String>[
        'a/b/x/@$sha',
        'a/b/../c@$sha',
        'a/b/./c@$sha',
        'a//c@$sha',
        'a/@$sha',
        '/b@$sha',
        '../b@$sha',
        'a/b c@$sha',
      ]) {
        expect(lint(workflow(step: '- uses: "$ref" # v1')), [
          contains('must be owner/repo[/path]@<full 40-character commit SHA>'),
        ], reason: ref);
      }
    });

    test('a valid nested path passes', () {
      expect(lint(workflow(step: '- uses: a/b/c/d@$sha # v1')), isEmpty);
    });

    test('a local action with an empty, "." or ".." segment fails', () {
      for (final ref in <String>['./../x', './a/./b', './a//b', './a/']) {
        expect(lint(workflow(step: '- uses: $ref')), [
          contains('has an empty, "." or ".." path segment'),
        ], reason: ref);
      }
    });
  });

  group('reusable workflow calls', () {
    const called =
        'permissions: {}\n'
        'jobs:\n'
        '  a:\n'
        '    runs-on: ubuntu-latest\n'
        '    timeout-minutes: 5\n'
        '    steps:\n'
        '      - run: "true"\n';

    String caller(String uses) =>
        'permissions: {}\n'
        'jobs:\n'
        '  call:\n'
        '    uses: $uses\n';

    test('a linted local workflow passes and is itself linted', () {
      final Map<String, String> sources = {
        '.github/workflows/caller.yml': caller(
          './.github/workflows/called.yml',
        ),
        '.github/workflows/called.yml': called,
      };
      expect(lintWorkflows(sources, noWrites), isEmpty);
      sources['.github/workflows/called.yml'] = called.replaceFirst(
        '    timeout-minutes: 5\n',
        '',
      );
      expect(lintWorkflows(sources, noWrites), [
        contains("called.yml: job 'a': timeout-minutes"),
      ]);
    });

    test('a local path that is not a linted workflow fails', () {
      for (final uses in <String>[
        './.github/workflows/missing.yml',
        './.github/actions/x',
        './.github/workflows/../workflows/called.yml',
        './.github/workflows/called.json',
        './.github/workflows//called.yml',
        './.github/workflows/called.yml/',
      ]) {
        expect(
          lintWorkflows({
            '.github/workflows/caller.yml': caller(uses),
            '.github/workflows/called.yml': called,
            '.github/workflows/called.json': called,
          }, noWrites),
          [contains('must be ./.github/workflows/<file>.yml')],
          reason: uses,
        );
      }
    });

    test('a pinned remote .yml or .yaml workflow passes', () {
      for (final file in <String>['w.yml', 'w.yaml']) {
        expect(
          lint(caller('o/r/.github/workflows/$file@$sha # v1')),
          isEmpty,
          reason: file,
        );
      }
    });

    test('a pinned remote workflow without a version comment fails', () {
      expect(lint(caller('o/r/.github/workflows/w.yml@$sha')), [
        contains('must be followed by its version in a comment'),
      ]);
    });

    test('every other remote form fails (#45)', () {
      for (final uses in <String>[
        'o/r@$sha',
        'o/r/w.yml@$sha',
        'o/r/.github/actions/w.yml@$sha',
        'o/r/.github/workflows/w.json@$sha',
        'o/r/.github/workflows/sub/w.yml@$sha',
        'o/r/.github/workflows/@$sha',
        'o/r/.github/workflows/w.yml/@$sha',
        'o/r/.github//workflows/w.yml@$sha',
        'o/r/.github/workflows/../w.yml@$sha',
        'o/../.github/workflows/w.yml@$sha',
        '../r/.github/workflows/w.yml@$sha',
        'o/r/.github/workflows/w.yml@main',
        'o/r/.github/workflows/w.yml@$sha@$sha',
        '/r/.github/workflows/w.yml@$sha',
        'o/r/.github/workflows/w.yml@${sha.toUpperCase()}',
        'o/r/.github/workflows/w.yml@${sha.substring(1)}',
        'o/r/.github/workflows/w.yml@${sha}0',
        'o/r/.github/workflows/w.YML@$sha',
      ]) {
        expect(lint(caller('"$uses" # v1')), [
          contains('must be owner/repo/.github/workflows/'),
        ], reason: uses);
      }
    });

    test('a non-string job-level uses fails', () {
      expect(lint(caller('[a]')), [contains('uses must be a string.')]);
    });

    test('a docker reference cannot be called as a workflow', () {
      expect(lint(caller('docker://alpine@sha256:${'a' * 64}')), [
        contains('must be owner/repo/.github/workflows/'),
      ]);
    });
  });

  group('container and services images', () {
    final digest = 'sha256:${'0' * 64}';

    String withJob(String extra) =>
        workflow(job: '    timeout-minutes: 5\n$extra'.trimRight());

    test('images pinned by digest pass', () {
      expect(lint(withJob('    container: node@$digest\n')), isEmpty);
      expect(
        lint(withJob('    container:\n      image: node@$digest\n')),
        isEmpty,
      );
      expect(
        lint(
          withJob(
            '    services:\n      db:\n        image: postgres@$digest\n',
          ),
        ),
        isEmpty,
      );
    });

    test('unpinned or missing images fail', () {
      expect(lint(withJob('    container: node:20\n')), [
        contains('container image "node:20" must be pinned by digest'),
      ]);
      expect(lint(withJob('    container:\n      options: --cpus 1\n')), [
        contains('container image "null" must be pinned by digest'),
      ]);
      expect(
        lint(withJob('    services:\n      db:\n        image: postgres\n')),
        [contains("service 'db' image \"postgres\" must be pinned")],
      );
      expect(lint(withJob('    services:\n      db: redis:7\n')), [
        contains("service 'db' image \"redis:7\" must be pinned"),
      ]);
    });
  });

  group('merge keys', () {
    test('a merge key in a step fails', () {
      final String source = workflow(step: '- <<: *st').replaceFirst(
        'jobs:\n',
        'x: &st {uses: actions/checkout@main}\njobs:\n',
      );
      expect(lint(source), [contains('YAML merge keys (<<) are not allowed')]);
    });

    test('a merge key anywhere fails', () {
      final String source = workflow(
        job: '    timeout-minutes: 5\n    <<: {permissions: write-all}',
      );
      expect(lint(source), [contains('YAML merge keys (<<) are not allowed')]);
    });
  });

  group('permissions', () {
    test('top-level permissions must be exactly {}', () {
      for (final root in <String>[
        '',
        'permissions: write-all',
        'permissions: {contents: read}',
      ]) {
        expect(lint(workflow(root: root)), [
          contains("top-level permissions must be exactly 'permissions: {}'"),
        ]);
      }
    });

    test('duplicated top-level permissions fail as invalid YAML', () {
      expect(lint(workflow(root: 'permissions: {}\npermissions: write-all')), [
        contains('invalid YAML: Duplicate mapping key'),
      ]);
    });

    test('job permissions must be a mapping of explicit scopes', () {
      for (final grant in <String>['write-all', 'read-all']) {
        expect(
          lint(
            workflow(job: '    timeout-minutes: 5\n    permissions: $grant'),
          ),
          [contains('permissions must be a mapping of explicit scopes')],
        );
      }
      expect(
        lint(
          workflow(
            job:
                '    timeout-minutes: 5\n    permissions:\n'
                '      everything: write\n      contents: all',
          ),
        ),
        [
          contains('unknown permission scope "everything"'),
          contains('permission "contents" must be read, write or none'),
        ],
      );
    });

    test('a job without permissions passes', () {
      expect(lint(workflow(job: '    timeout-minutes: 5')), isEmpty);
    });

    test('every scope accepts read and none, and a declared write', () {
      for (final String scope in jobPermissionScopes) {
        for (final level in <String>['read', 'write', 'none']) {
          expect(
            lint(
              workflow(
                job:
                    '    timeout-minutes: 5\n    permissions:\n'
                    '      $scope: $level',
              ),
              config: level == 'write' ? declaring(scope) : noWrites,
            ),
            isEmpty,
            reason: '$scope: $level',
          );
        }
      }
    });
  });

  group('write scopes', () {
    String writing(String scope) => workflow(
      job: '    timeout-minutes: 5\n    permissions:\n      $scope: write',
    );

    test('an undeclared job-level write fails', () {
      expect(lint(writing('contents')), [
        message(
          "w.yml: job 'a': \"contents: write\" is not declared in "
          'workflows.write_scopes of k.yaml; declare it with a reason or '
          'grant read.',
        ),
      ]);
    });

    test('a write declared for another scope, job or workflow fails', () {
      expect(lint(writing('contents'), config: declaring('pull-requests')), [
        contains('"contents: write" is not declared'),
        contains("stale entry: job 'a' of w.yml"),
      ]);
      expect(
        lint(
          writing('contents').replaceFirst('  a:', '  b:'),
          config: declaring('contents'),
        ),
        [
          contains("job 'b': \"contents: write\" is not declared"),
          contains("stale entry: job 'a' of w.yml"),
        ],
      );
      expect(
        lint(
          writing('contents'),
          config: declaring('contents', workflow: 'x.yml'),
        ),
        [
          contains('"contents: write" is not declared'),
          contains("stale entry: job 'a' of x.yml"),
        ],
      );
    });

    test('a declared entry that the job no longer grants is stale', () {
      expect(lint(workflow(), config: declaring('contents')), [
        message(
          'k.yaml: workflows.write_scopes: stale entry: job '
          "'a' of w.yml does not grant \"contents: write\"; "
          'remove the entry.',
        ),
      ]);
      expect(lint(workflow(), config: declaring('statuses')), [
        contains('does not grant "statuses: write"'),
      ]);
    });

    test('workflows are matched by file name', () {
      expect(
        lintWorkflows({
          '.github/workflows/w.yml': writing('contents'),
        }, declaring('contents')),
        isEmpty,
      );
    });
  });

  group('structure', () {
    test('a job without a positive timeout fails', () {
      for (final job in <String>[
        '    permissions: {}',
        '    timeout-minutes: 0',
        '    timeout-minutes: "5"',
      ]) {
        expect(lint(workflow(job: job)), [
          contains('timeout-minutes must be a positive integer'),
        ]);
      }
    });

    test('a timeout above workflows.max_timeout_minutes fails', () {
      expect(lint(workflow(job: '    timeout-minutes: 10')), isEmpty);
      expect(lint(workflow(job: '    timeout-minutes: 11')), [
        message(
          "w.yml: job 'a': timeout-minutes is 11, above "
          'workflows.max_timeout_minutes of k.yaml (10).',
        ),
      ]);
    });

    test('invalid YAML, a non-mapping workflow or job, and no jobs fail', () {
      expect(lint('a: [unclosed'), [contains('w.yml: invalid YAML:')]);
      expect(lint('- a'), ['w.yml: a workflow must be a mapping.']);
      expect(lint('permissions: {}\njobs: {}\n'), [
        'w.yml: jobs must be a non-empty mapping.',
      ]);
      expect(lint('permissions: {}\njobs:\n  a: x\n'), [
        "w.yml: job 'a' must be a mapping.",
      ]);
    });
  });
}
