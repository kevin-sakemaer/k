import 'package:k_config/k_config.dart';
import 'package:test/test.dart';

void main() {
  group('renderSummary', () {
    test('lists every override and exception with its reason', () {
      const config = KConfig(
        coverage: CoverageConfig(
          defaultThreshold: 100,
          overrides: {
            'alpha': CoverageOverride(
              threshold: 95.5,
              reason: 'Pipes | and\n  new lines are escaped.',
            ),
          },
        ),
        dependencies: DependenciesConfig(
          exceptions: {
            'third_party': DependencyException(
              reason: 'Needed.',
              approvedBy: 'Kevin.',
            ),
          },
        ),
        comments: CommentsConfig(
          exceptions: [
            CommentException(path: 'lib/legacy.dart', reason: 'Vendored.'),
          ],
        ),
      );

      expect(renderSummary(config), r'''
## k.yaml

The configuration is valid.

### Coverage

Default line coverage threshold: 100%.

| Package | Threshold | Reason |
| --- | --- | --- |
| alpha | 95.5% | Pipes \| and new lines are escaped. |

### Dependencies

Allowed publishers: dart.dev, tools.dart.dev, labs.dart.dev.

| Package | Reason | Approved by |
| --- | --- | --- |
| third_party | Needed. | Kevin. |

### Comments

| File | Reason |
| --- | --- |
| lib/legacy.dart | Vendored. |

''');
    });

    test('says when nothing is overridden', () {
      const config = KConfig(
        coverage: CoverageConfig(defaultThreshold: 100, overrides: {}),
        dependencies: DependenciesConfig(exceptions: {}),
        comments: CommentsConfig(exceptions: []),
      );

      final String summary = renderSummary(config);

      expect(summary, contains('No coverage overrides.\n'));
      expect(summary, contains('No dependency exceptions.\n'));
      expect(summary, contains('No comment exceptions.\n'));
      expect(summary, isNot(contains('|')));
    });
  });
}
