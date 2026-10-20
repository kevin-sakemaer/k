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

List<String> lint(String source) => lintWorkflow(source, 'w.yml');

void main() {
  test('a hardened workflow passes', () {
    expect(lint(workflow()), isEmpty);
  });

  group('uses', () {
    test('a tag, a branch or a short SHA fails', () {
      for (final ref in <String>['v7', 'main', '0123456']) {
        expect(lint(workflow(step: '- uses: actions/checkout@$ref # v7')), [
          contains('must be pinned by a full 40-character commit SHA'),
        ]);
      }
    });

    test('a reference without @ fails', () {
      expect(lint(workflow(step: '- uses: actions/checkout')), [
        contains('must be pinned by a full 40-character commit SHA'),
      ]);
    });

    test('flow and quoted keys are parsed', () {
      expect(lint(workflow(step: '- {uses: actions/checkout@main}')), [
        contains('"actions/checkout@main" must be pinned'),
      ]);
      expect(lint(workflow(step: '- "uses": actions/checkout@main')), [
        contains('"actions/checkout@main" must be pinned'),
      ]);
    });

    test('a SHA inside a comment does not count', () {
      expect(
        lint(
          workflow(step: '- uses: actions/checkout@main # uses: x@$sha # v1'),
        ),
        [contains('"actions/checkout@main" must be pinned')],
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
          "w.yml: job 'call': "
          '"org/repo/.github/workflows/w.yml@main" must be pinned by a full '
          '40-character commit SHA.';
      expect(lint(source), [expected]);
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

    test('every scope accepts read, write and none', () {
      for (final String scope in jobPermissionScopes) {
        for (final level in <String>['read', 'write', 'none']) {
          expect(
            lint(
              workflow(
                job:
                    '    timeout-minutes: 5\n    permissions:\n'
                    '      $scope: $level',
              ),
            ),
            isEmpty,
          );
        }
      }
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
