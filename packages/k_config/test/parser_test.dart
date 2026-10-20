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
      expect(config.coverage.toolVersion, '1.16.0');
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
      expect(config.comments.include, ['**.dart']);
      expect(config.comments.exclude, ['.dart_tool/**']);
      expect(config.comments.exceptions.single.path, endsWith('legacy.dart'));
      expect(config.comments.exceptions.single.reason, isNotEmpty);
    });

    test('accepts empty overrides and exceptions', () {
      const source = '''
coverage: {default: 100, overrides: {}, tool_version: 1.16.0}
dependencies: {exceptions: {}}
comments: {include: ["**.dart"], exclude: [], exceptions: []}
''';

      expect(parse(source), isA<KConfigValid>());
    });

    test('accepts the bounds 0 and 100', () {
      const empty =
          'dependencies: {exceptions: {}}\n'
          'comments: {include: ["**.dart"], exclude: [], exceptions: []}\n';
      for (final bound in [0, 100]) {
        final source =
            'coverage: {default: $bound, tool_version: 1.16.0, overrides: {}}\n'
            '$empty';
        final KConfig config = switch (parse(source)) {
          KConfigValid(:final KConfig config) => config,
          KConfigInvalid(:final List<String> errors) => fail('$bound: $errors'),
        };
        expect(config.coverage.defaultThreshold, bound);
        expect(config.coverage.thresholdFor('alpha'), bound);
      }
      final KConfig config = switch (parse(
        edit('threshold: 95', 'threshold: 0'),
      )) {
        KConfigValid(:final KConfig config) => config,
        KConfigInvalid(:final List<String> errors) => fail('$errors'),
      };
      expect(config.coverage.thresholdFor('alpha'), 0);
      expect(config.coverage.defaultThreshold, 100);
    });

    test('rejects an override of 0 when coverage.default is 0', () {
      final String source = edit(
        'default: 100',
        'default: 0',
      ).replaceFirst('threshold: 95', 'threshold: 0');
      expect(errorsOf(source), [
        message(
          'k.yaml: coverage.overrides.alpha.threshold: '
          'must be lower than coverage.default (0), found 0.',
        ),
      ]);
    });

    final failures = <String, (String, List<String>)>{
      'invalid YAML': ('coverage: [unclosed', ['k.yaml: invalid YAML:']),
      'a duplicated section': (
        '$validConfig\ncomments:\n'
            '  include: ["**.dart"]\n  exclude: []\n  exceptions: []\n',
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
            'default, overrides, tool_version.',
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
        '${validConfig.substring(0, validConfig.indexOf('comments:'))}'
            'comments: []\nunused: {}\n',
        [
          'k.yaml: comments: must be a mapping.',
          message(
            'k.yaml: unused: unknown key. Allowed keys: '
            'comments, coverage, dependencies.',
          ),
        ],
      ),
      'a missing tool version': (
        edit('  tool_version: 1.16.0\n', ''),
        ['k.yaml: coverage.tool_version: missing required key.'],
      ),
      'a tool version that is not a string': (
        edit('tool_version: 1.16.0', 'tool_version: 1.16'),
        [
          message(
            'k.yaml: coverage.tool_version: must be an exact version '
            'MAJOR.MINOR.PATCH as a string, found 1.16.',
          ),
        ],
      ),
      'a tool version range': (
        edit('tool_version: 1.16.0', 'tool_version: "^1.16.0"'),
        [
          message(
            'k.yaml: coverage.tool_version: must be an exact version '
            'MAJOR.MINOR.PATCH as a string, found "^1.16.0".',
          ),
        ],
      ),
      'a prerelease tool version': (
        edit('tool_version: 1.16.0', 'tool_version: 1.16.0-dev'),
        [
          message(
            'k.yaml: coverage.tool_version: must be an exact version '
            'MAJOR.MINOR.PATCH as a string, found "1.16.0-dev".',
          ),
        ],
      ),
      'a tool version with a leading zero': (
        edit('tool_version: 1.16.0', 'tool_version: "01.16.0"'),
        [
          message(
            'k.yaml: coverage.tool_version: must be an exact version '
            'MAJOR.MINOR.PATCH as a string, found "01.16.0".',
          ),
        ],
      ),
      'a missing overrides key': (
        'coverage: {default: 100, tool_version: 1.16.0}\n'
            'dependencies: {exceptions: {}}\n'
            'comments: {include: ["**.dart"], exclude: [], exceptions: []}\n',
        ['k.yaml: coverage.overrides: missing required key.'],
      ),
      'a quoted threshold': (
        edit('default: 100', 'default: "100"'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found "100".',
          ),
        ],
      ),
      'a threshold above 100': (
        edit('threshold: 95', 'threshold: 101'),
        [
          message(
            'k.yaml: coverage.overrides.alpha.threshold: '
            'must be an integer from 0 to 100, found 101.',
          ),
        ],
      ),
      'a negative threshold': (
        edit('default: 100', 'default: -1'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found -1.',
          ),
        ],
      ),
      'a NaN threshold': (
        edit('default: 100', 'default: .nan'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found .nan.',
          ),
        ],
      ),
      'a decimal threshold': (
        edit('default: 100', 'default: 100.0'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found 100.0.',
          ),
        ],
      ),
      'a fractional override threshold': (
        edit('threshold: 95', 'threshold: 99.5'),
        [
          message(
            'k.yaml: coverage.overrides.alpha.threshold: '
            'must be an integer from 0 to 100, found 99.5.',
          ),
        ],
      ),
      'a threshold in scientific notation': (
        edit('default: 100', 'default: 1e2'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found 1e2.',
          ),
        ],
      ),
      'a hexadecimal threshold': (
        edit('default: 100', 'default: 0x64'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found 0x64.',
          ),
        ],
      ),
      'an octal threshold': (
        edit('default: 100', 'default: 0o144'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found 0o144.',
          ),
        ],
      ),
      'a threshold with a plus sign': (
        edit('default: 100', 'default: +100'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found +100.',
          ),
        ],
      ),
      'a threshold with a separator': (
        edit('default: 100', 'default: 1_00'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found 1_00.',
          ),
        ],
      ),
      'a threshold with a leading zero': (
        edit('threshold: 95', 'threshold: 095'),
        [
          message(
            'k.yaml: coverage.overrides.alpha.threshold: '
            'must be an integer from 0 to 100, found 095.',
          ),
        ],
      ),
      'a boolean threshold': (
        edit('default: 100', 'default: true'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found true.',
          ),
        ],
      ),
      'an empty threshold': (
        edit('default: 100', 'default:'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found null.',
          ),
        ],
      ),
      'a null threshold': (
        edit('default: 100', 'default: null'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found null.',
          ),
        ],
      ),
      'an infinite threshold': (
        edit('default: 100', 'default: .inf'),
        [
          message(
            'k.yaml: coverage.default: '
            'must be an integer from 0 to 100, found .inf.',
          ),
        ],
      ),
      'an override for an unknown package': (
        edit('    alpha:\n      threshold', '    gamma:\n      threshold'),
        [
          message(
            'k.yaml: coverage.overrides.gamma: unknown package. '
            'Workspace packages: alpha, beta, workspace_root.',
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
            'default, overrides, tool_version.',
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
        'coverage: {default: 100, overrides: {}, tool_version: 1.16.0}\n'
            'dependencies: {exceptions: []}\n'
            'comments: {include: ["**.dart"], exclude: [], exceptions: []}\n',
        ['k.yaml: dependencies.exceptions: must be a mapping.'],
      ),
      'a dependencies section that is not a mapping': (
        'coverage: {default: 100, overrides: {}, tool_version: 1.16.0}\n'
            'dependencies: []\n'
            'comments: {include: ["**.dart"], exclude: [], exceptions: []}\n',
        ['k.yaml: dependencies: must be a mapping.'],
      ),
      'a coverage section that is not a mapping': (
        'coverage: 100\n'
            'dependencies: {exceptions: {}}\n'
            'comments: {include: ["**.dart"], exclude: [], exceptions: []}\n',
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
      'comment include globs that are not a list': (
        edit('  include:\n    - "**.dart"', '  include: "**.dart"'),
        ['k.yaml: comments.include: must be a list.'],
      ),
      'empty comment include globs': (
        edit('  include:\n    - "**.dart"', '  include: []'),
        ['k.yaml: comments.include: must list at least one glob pattern.'],
      ),
      'missing comment include globs': (
        edit('  include:\n    - "**.dart"\n', ''),
        ['k.yaml: comments.include: missing required key.'],
      ),
      'a blank comment exclude glob': (
        edit('    - ".dart_tool/**"', '    - " "'),
        [
          message(
            'k.yaml: comments.exclude[0]: '
            'must be a non-empty glob pattern string.',
          ),
        ],
      ),
      'a comment exclude glob that is not a string': (
        edit('    - ".dart_tool/**"', '    - 3'),
        [
          message(
            'k.yaml: comments.exclude[0]: '
            'must be a non-empty glob pattern string.',
          ),
        ],
      ),
      'an invalid comment include glob': (
        edit('    - "**.dart"', '    - "[unclosed"'),
        ['k.yaml: comments.include[0]: invalid glob pattern "[unclosed": '],
      ),
      'an invalid comment exclude glob': (
        edit('    - ".dart_tool/**"', '    - "{a,b"'),
        ['k.yaml: comments.exclude[0]: invalid glob pattern "{a,b": '],
      ),
      'a duplicated comment exclude glob': (
        edit(
          '    - ".dart_tool/**"',
          '    - ".dart_tool/**"\n    - ".dart_tool/**"',
        ),
        ['k.yaml: comments.exclude[1]: duplicated pattern ".dart_tool/**".'],
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
