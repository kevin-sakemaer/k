import 'package:k_config/k_config.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

/// Parses [source] against the default test workspace.
KConfigResult parse(String source) =>
    parseKConfig(source, Workspace.load(createRepository()));

/// Returns the errors of [source], which must be invalid.
List<String> errorsOf(String source) => switch (parse(source)) {
  KConfigInvalid(:final List<String> errors) => errors,
  KConfigValid() => fail('Expected an invalid configuration.'),
};

/// Returns [validConfig] with [from] replaced by [to].
String edit(String from, String to) {
  if (!validConfig.contains(from)) {
    throw ArgumentError.value(from, 'from', 'not found in validConfig');
  }
  return validConfig.replaceFirst(from, to);
}

/// Returns [text]: wraps one expected error split over several lines.
String message(String text) => text;

void main() {
  group('parseKConfig', () {
    test('returns typed values for a valid configuration', () {
      final KConfig config = switch (parse(validConfig)) {
        KConfigValid(:final KConfig config) => config,
        KConfigInvalid(:final List<String> errors) => fail('$errors'),
      };

      expect(config.coverage.defaultThreshold, 100);
      expect(config.coverage.thresholdFor('alpha'), 95);
      expect(config.coverage.thresholdFor('beta'), 100);
      expect(
        config.coverage.overrides['alpha']?.reason,
        'Generated bindings cannot be exercised.',
      );
      expect(DependenciesConfig.allowedPublishers, [
        'dart.dev',
        'tools.dart.dev',
        'labs.dart.dev',
      ]);
      expect(
        config.dependencies.exceptions['third_party']?.reason,
        'Needed for the generated bindings.',
      );
      expect(
        config.dependencies.exceptions['third_party']?.approvedBy,
        startsWith('Kevin'),
      );
      expect(config.comments.exceptions.single.path, endsWith('legacy.dart'));
      expect(config.comments.exceptions.single.reason, isNotEmpty);
    });

    test('accepts empty overrides and exceptions', () {
      const source = '''
coverage: {default: 100, overrides: {}}
dependencies: {exceptions: {}}
comments: {exceptions: []}
''';

      expect(parse(source), isA<KConfigValid>());
    });

    test('accepts a decimal threshold', () {
      expect(parse(edit('default: 100', 'default: 99.5')), isA<KConfigValid>());
    });

    final failures = <String, (String, List<String>)>{
      'invalid YAML': ('coverage: [unclosed', ['k.yaml: invalid YAML:']),
      'a duplicated section': (
        '$validConfig\ncomments:\n  exceptions: []\n',
        ['k.yaml: invalid YAML:'],
      ),
      'a document that is not a mapping': (
        '- coverage',
        ['k.yaml: (root): must be a mapping.'],
      ),
      'a non string key': (
        '${validConfig}42: true\n',
        ['k.yaml: (root): key "42" must be a string.'],
      ),
      'an unknown section': (
        '${validConfig}format: {}\n',
        [
          message(
            'k.yaml: format: unknown key. Allowed keys: '
            'comments, coverage, dependencies.',
          ),
        ],
      ),
      'a missing section': (
        validConfig.substring(0, validConfig.indexOf('comments:')),
        ['k.yaml: comments: missing required key.'],
      ),
      'an unknown nested key': (
        edit('  default: 100', '  default: 100\n  branches: 90'),
        [
          message(
            'k.yaml: coverage.branches: unknown key. Allowed keys: '
            'default, overrides.',
          ),
        ],
      ),
      'an unknown key in an override': (
        edit('      threshold: 95', '      threshold: 95\n      lines: 1'),
        [
          message(
            'k.yaml: coverage.overrides.alpha.lines: unknown key. '
            'Allowed keys: reason, threshold.',
          ),
        ],
      ),
      'a section that is not a mapping': (
        edit('comments:\n  exceptions:', 'comments: []\nunused:'),
        [
          'k.yaml: comments: must be a mapping.',
          message(
            'k.yaml: unused: unknown key. Allowed keys: '
            'comments, coverage, dependencies.',
          ),
        ],
      ),
      'a missing overrides key': (
        'coverage: {default: 100}\n'
            'dependencies: {exceptions: {}}\n'
            'comments: {exceptions: []}\n',
        ['k.yaml: coverage.overrides: missing required key.'],
      ),
      'a threshold of the wrong type': (
        edit('default: 100', 'default: "100"'),
        ['k.yaml: coverage.default: must be a number between 0 and 100.'],
      ),
      'a threshold above 100': (
        edit('threshold: 95', 'threshold: 101'),
        [
          message(
            'k.yaml: coverage.overrides.alpha.threshold: '
            'must be between 0 and 100, found 101.',
          ),
        ],
      ),
      'a negative threshold': (
        edit('default: 100', 'default: -1'),
        ['k.yaml: coverage.default: must be between 0 and 100, found -1.'],
      ),
      'a NaN threshold': (
        edit('default: 100', 'default: .nan'),
        ['k.yaml: coverage.default: must be between 0 and 100, found NaN.'],
      ),
      'an override for an unknown package': (
        edit('    alpha:\n      threshold', '    gamma:\n      threshold'),
        [
          message(
            'k.yaml: coverage.overrides.gamma: unknown package. '
            'Workspace packages: alpha, beta.',
          ),
        ],
      ),
      'an override without reason': (
        edit('      reason: "Generated bindings cannot be exercised."\n', ''),
        ['k.yaml: coverage.overrides.alpha.reason: missing required key.'],
      ),
      'an override with an empty reason': (
        edit('"Generated bindings cannot be exercised."', '"  "'),
        [
          message(
            'k.yaml: coverage.overrides.alpha.reason: must be a non-empty '
            'string that explains the exception.',
          ),
        ],
      ),
      'overrides that are not a mapping': (
        edit('  overrides:\n    alpha:', '  overrides: []\n  unused:'),
        [
          'k.yaml: coverage.overrides: must be a mapping.',
          message(
            'k.yaml: coverage.unused: unknown key. Allowed keys: '
            'default, overrides.',
          ),
        ],
      ),
      'an override that is not a mapping': (
        edit(
          message(
            '    alpha:\n      threshold: 95\n'
            '      reason: "Generated bindings cannot be exercised."',
          ),
          '    alpha: 95',
        ),
        ['k.yaml: coverage.overrides.alpha: must be a mapping.'],
      ),
      'an allowed_publishers key': (
        edit(
          'dependencies:\n',
          'dependencies:\n  allowed_publishers: [dart.dev, pub.dev]\n',
        ),
        [
          message(
            'k.yaml: dependencies.allowed_publishers: unknown key. '
            'Allowed keys: exceptions.',
          ),
        ],
      ),
      'an override equal to the default': (
        edit('threshold: 95', 'threshold: 100'),
        [
          message(
            'k.yaml: coverage.overrides.alpha.threshold: '
            'must be lower than coverage.default (100), found 100.',
          ),
        ],
      ),
      'an override above the default': (
        edit('default: 100', 'default: 90'),
        [
          message(
            'k.yaml: coverage.overrides.alpha.threshold: '
            'must be lower than coverage.default (90), found 95.',
          ),
        ],
      ),
      'a dependency exception without approver': (
        edit('      approved_by: "Kevin, 2026-10-20, via Grok Bot."\n', ''),
        [
          message(
            'k.yaml: dependencies.exceptions.third_party.approved_by: '
            'missing required key.',
          ),
        ],
      ),
      'a dependency exception with a blank approver': (
        edit('"Kevin, 2026-10-20, via Grok Bot."', '" "'),
        [
          message(
            'k.yaml: dependencies.exceptions.third_party.approved_by: '
            'must be a non-empty string that names the approver.',
          ),
        ],
      ),
      'an exception for a package that is not a direct dependency': (
        edit('    third_party:', '    left_pad:'),
        [
          message(
            'k.yaml: dependencies.exceptions.left_pad: '
            'not a direct dependency of any workspace package.',
          ),
        ],
      ),
      'a dependency exception without reason': (
        edit(
          message(
            '    third_party:\n'
            '      reason: "Needed for the generated bindings."\n'
            '      approved_by: "Kevin, 2026-10-20, via Grok Bot."',
          ),
          '    third_party: {approved_by: Kevin}',
        ),
        [
          message(
            'k.yaml: dependencies.exceptions.third_party.reason: '
            'missing required key.',
          ),
        ],
      ),
      'a dependency exception that is not a mapping': (
        edit(
          message(
            '    third_party:\n'
            '      reason: "Needed for the generated bindings."\n'
            '      approved_by: "Kevin, 2026-10-20, via Grok Bot."',
          ),
          '    third_party: approved',
        ),
        ['k.yaml: dependencies.exceptions.third_party: must be a mapping.'],
      ),
      'dependency exceptions that are not a mapping': (
        'coverage: {default: 100, overrides: {}}\n'
            'dependencies: {exceptions: []}\n'
            'comments: {exceptions: []}\n',
        ['k.yaml: dependencies.exceptions: must be a mapping.'],
      ),
      'a dependencies section that is not a mapping': (
        'coverage: {default: 100, overrides: {}}\n'
            'dependencies: []\n'
            'comments: {exceptions: []}\n',
        ['k.yaml: dependencies: must be a mapping.'],
      ),
      'a coverage section that is not a mapping': (
        'coverage: 100\n'
            'dependencies: {exceptions: {}}\n'
            'comments: {exceptions: []}\n',
        ['k.yaml: coverage: must be a mapping.'],
      ),
      'comment exceptions that are not a list': (
        edit(
          message(
            '    - path: packages/alpha/lib/legacy.dart\n'
            '      reason: "Vendored file kept verbatim."',
          ),
          '    path: packages/alpha/lib/legacy.dart',
        ),
        ['k.yaml: comments.exceptions: must be a list.'],
      ),
      'a comment exception for a missing file': (
        edit('lib/legacy.dart', 'lib/missing.dart'),
        [
          message(
            'k.yaml: comments.exceptions[0].path: '
            'file "packages/alpha/lib/missing.dart" not found.',
          ),
        ],
      ),
      'a comment exception with an absolute path': (
        edit('path: packages/alpha', 'path: /packages/alpha'),
        [
          message(
            'k.yaml: comments.exceptions[0].path: '
            'must be relative to the repository root, without "..".',
          ),
        ],
      ),
      'a comment exception that leaves the repository': (
        edit('path: packages/alpha', 'path: ../packages/alpha'),
        [
          message(
            'k.yaml: comments.exceptions[0].path: '
            'must be relative to the repository root, without "..".',
          ),
        ],
      ),
      'a comment exception with an empty path': (
        edit('path: packages/alpha/lib/legacy.dart', 'path: ""'),
        ['k.yaml: comments.exceptions[0].path: must be a non-empty string.'],
      ),
      'a comment exception without reason': (
        edit('      reason: "Vendored file kept verbatim."\n', ''),
        ['k.yaml: comments.exceptions[0].reason: missing required key.'],
      ),
      'a comment exception that is not a mapping': (
        edit(
          message(
            '    - path: packages/alpha/lib/legacy.dart\n'
            '      reason: "Vendored file kept verbatim."',
          ),
          '    - packages/alpha/lib/legacy.dart',
        ),
        ['k.yaml: comments.exceptions[0]: must be a mapping.'],
      ),
      'a duplicated comment exception': (
        '$validConfig'
            '    - path: packages/alpha/lib/legacy.dart\n'
            '      reason: "Again."\n',
        [
          message(
            'k.yaml: comments.exceptions[1]: '
            'duplicated path "packages/alpha/lib/legacy.dart".',
          ),
        ],
      ),
    };
    for (final MapEntry(key: description, value: (source, expected))
        in failures.entries) {
      test('fails on $description', () {
        final List<String> errors = errorsOf(source);

        expect(errors, unorderedMatches(expected.map(startsWith)));
      });
    }

    test('reports every error at once', () {
      final String source = edit('default: 100', 'default: 200')
          .replaceFirst('    alpha:', '    gamma:')
          .replaceFirst('    third_party:', '    left_pad:');

      expect(errorsOf(source), hasLength(3));
    });

    test('rejects an unknown package even with a valid override', () {
      final String source = edit('    alpha:', '    gamma:');

      expect(
        errorsOf(source).single,
        contains('coverage.overrides.gamma: unknown package.'),
      );
    });
  });
}
