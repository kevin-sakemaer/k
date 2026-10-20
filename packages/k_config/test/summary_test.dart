import 'package:k_config/k_config.dart';
import 'package:test/test.dart';

void main() {
  group('renderSummary', () {
    test('lists every override and exception with its reason', () {
      const config = KConfig(
        coverage: CoverageConfig(
          defaultThreshold: 100,
          toolVersion: '1.16.0',
          overrides: {
            'alpha': CoverageOverride(
              threshold: 95,
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
          include: ['**.dart'],
          exclude: [],
          exceptions: [
            CommentException(path: 'lib/legacy.dart', reason: 'Vendored.'),
          ],
        ),
        closeIssues: CloseIssuesConfig(lookbackHours: 72),
      );

      expect(renderSummary(config), r'''
## k.yaml

The configuration is valid.

### Coverage

Default line coverage threshold: 100%.

Coverage tool: package:coverage 1.16.0.

| Package | Threshold | Reason |
| --- | --- | --- |
| alpha | 95% | Pipes \| and new lines are escaped. |

### Dependencies

Allowed publishers: dart.dev, tools.dart.dev, labs.dart.dev.

| Package | Reason | Approved by |
| --- | --- | --- |
| third_party | Needed. | Kevin. |

### Comments

| File | Reason |
| --- | --- |
| lib/legacy.dart | Vendored. |

### Closing issues

Look-back window of the close-issues sweep: 72 hours.

''');
    });

    test('says when nothing is overridden', () {
      const config = KConfig(
        coverage: CoverageConfig(
          defaultThreshold: 100,
          overrides: {},
          toolVersion: '1.16.0',
        ),
        dependencies: DependenciesConfig(exceptions: {}),
        comments: CommentsConfig(
          include: ['**.dart'],
          exclude: [],
          exceptions: [],
        ),
        closeIssues: CloseIssuesConfig(lookbackHours: 1),
      );

      final String summary = renderSummary(config);

      expect(summary, contains('No coverage overrides.\n'));
      expect(summary, contains('No dependency exceptions.\n'));
      expect(summary, contains('No comment exceptions.\n'));
      expect(summary, isNot(contains('|')));
    });
  });
}
