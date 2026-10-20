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
          registryTimeoutSeconds: 30,
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
        workflows: WorkflowsConfig(
          maxTimeoutMinutes: 20,
          writeScopes: [
            WriteScopeException(
              workflow: 'auto-merge.yml',
              job: 'auto-merge',
              scope: 'contents',
              reason: 'Enables auto-merge.',
            ),
          ],
        ),
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

Registry timeout: 30 seconds.

| Package | Reason | Approved by |
| --- | --- | --- |
| third_party | Needed. | Kevin. |

### Comments

| File | Reason |
| --- | --- |
| lib/legacy.dart | Vendored. |

### Closing issues

Look-back window of the close-issues sweep: 72 hours.

### Workflows

Maximum job timeout: 20 minutes.

| Workflow | Job | Write scope | Reason |
| --- | --- | --- | --- |
| auto-merge.yml | auto-merge | contents | Enables auto-merge. |

''');
    });

    test('says when nothing is overridden', () {
      const config = KConfig(
        coverage: CoverageConfig(
          defaultThreshold: 100,
          overrides: {},
          toolVersion: '1.16.0',
        ),
        dependencies: DependenciesConfig(
          registryTimeoutSeconds: 1,
          exceptions: {},
        ),
        comments: CommentsConfig(
          include: ['**.dart'],
          exclude: [],
          exceptions: [],
        ),
        closeIssues: CloseIssuesConfig(lookbackHours: 1),
        workflows: WorkflowsConfig(maxTimeoutMinutes: 20, writeScopes: []),
      );

      final String summary = renderSummary(config);

      expect(summary, contains('No coverage overrides.\n'));
      expect(summary, contains('No dependency exceptions.\n'));
      expect(summary, contains('No comment exceptions.\n'));
      expect(summary, contains('No job-level write scopes.\n'));
      expect(summary, isNot(contains('|')));
    });
  });
}
