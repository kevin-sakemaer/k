import 'dart:io';

import 'package:k_config/k_config.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

/// Usage line printed on a usage error.
const usage = 'Usage: k_config [--get <key>] [repository-root]';

void main() {
  group('runCli', () {
    late StringBuffer out;
    late StringBuffer err;

    setUp(() {
      out = StringBuffer();
      err = StringBuffer();
    });

    test('prints the summary and appends it to the job summary', () {
      final Directory root = createRepository();
      final jobSummary = File('${root.path}/summary.md')
        ..writeAsStringSync('previous\n');

      final int code = runCli(
        [root.path],
        out: out,
        err: err,
        environment: {'GITHUB_STEP_SUMMARY': jobSummary.path},
      );

      expect(code, 0);
      expect(err.toString(), isEmpty);
      expect(out.toString(), contains('| alpha | 95% |'));
      expect(jobSummary.readAsStringSync(), 'previous\n$out');
    });

    test('ignores an empty job summary path', () {
      final int code = runCli(
        [createRepository().path],
        out: out,
        err: err,
        environment: {'GITHUB_STEP_SUMMARY': ''},
      );

      expect(code, 0);
      expect(out.toString(), startsWith('## k.yaml'));
    });

    test('defaults to the current directory', () {
      final Directory previous = Directory.current;
      addTearDown(() => Directory.current = previous);
      Directory.current = createRepository();

      expect(runCli(const [], out: out, err: err), 0);
    });

    test('prints every error and fails on an invalid configuration', () {
      final Directory root = createRepository(
        files: {
          'k.yaml': validConfig
              .replaceFirst('default: 100', 'default: 101')
              .replaceFirst('    alpha:', '    gamma:'),
        },
      );

      final int code = runCli([root.path], out: out, err: err);

      expect(code, 1);
      expect(out.toString(), isEmpty);
      expect(
        err.toString(),
        allOf(
          contains(
            'k.yaml: coverage.default: must be an integer from 0 to 100',
          ),
          contains('k.yaml: coverage.overrides.gamma: unknown package.'),
          endsWith('k.yaml is invalid: 2 error(s).\n'),
        ),
      );
    });

    test('rejects extra arguments', () {
      expect(runCli(const ['a', 'b'], out: out, err: err), 64);
      expect(err.toString(), '$usage\n');
    });

    test('rejects an unknown option', () {
      expect(runCli(const ['--set'], out: out, err: err), 64);
      expect(err.toString(), '$usage\n');
    });

    group('--get', () {
      test('prints only the validated value', () {
        final String root = createRepository().path;

        expect(
          runCli(['--get', 'coverage.default', root], out: out, err: err),
          0,
        );
        expect(
          runCli(['--get', 'coverage.tool_version', root], out: out, err: err),
          0,
        );
        expect(out.toString(), '100\n1.16.0\n');
        expect(err.toString(), isEmpty);
      });

      test('prints the override or the default of every package', () {
        final String root = createRepository().path;

        expect(
          runCli(['--get', 'coverage.thresholds', root], out: out, err: err),
          0,
        );
        expect(out.toString(), 'alpha\t95\nbeta\t100\nworkspace_root\t100\n');
      });

      test('applies an override to the workspace root', () {
        final String root = createRepository(
          files: {
            'k.yaml': validConfig.replaceFirst(
              '    alpha:',
              '    workspace_root:',
            ),
          },
        ).path;

        expect(
          runCli(['--get', 'coverage.thresholds', root], out: out, err: err),
          0,
        );
        expect(out.toString(), 'alpha\t100\nbeta\t100\nworkspace_root\t95\n');
      });

      test('fails on an override without reason', () {
        final String root = createRepository(
          files: {
            'k.yaml': validConfig.replaceFirst(
              '      reason: "Generated bindings cannot be exercised."\n',
              '',
            ),
          },
        ).path;

        expect(
          runCli(['--get', 'coverage.thresholds', root], out: out, err: err),
          1,
        );
        expect(out.toString(), isEmpty);
        expect(
          err.toString(),
          contains('coverage.overrides.alpha.reason: missing required key.'),
        );
      });

      test('reads a flow style coverage section', () {
        const source =
            'coverage: {default: 100, tool_version: 1.16.0, overrides: {}}\n'
            'dependencies: {exceptions: {}}\n'
            'comments: {include: ["**.dart"], exclude: [], exceptions: []}\n';
        final String root = createRepository(files: {'k.yaml': source}).path;

        expect(
          runCli(['--get', 'coverage.tool_version', root], out: out, err: err),
          0,
        );
        expect(out.toString(), '1.16.0\n');
      });

      test('fails on an unbalanced quote', () {
        final String root = createRepository(
          files: {
            'k.yaml': validConfig.replaceFirst(
              'tool_version: 1.16.0',
              'tool_version: "1.16.0',
            ),
          },
        ).path;

        final int code = runCli(
          ['--get', 'coverage.tool_version', root],
          out: out,
          err: err,
        );

        expect(code, 1);
        expect(out.toString(), isEmpty);
        expect(err.toString(), contains('invalid YAML'));
      });

      test('fails on an unsupported key', () {
        expect(runCli(const ['--get', 'coverage'], out: out, err: err), 64);
        expect(
          err.toString(),
          'k_config: unsupported key "coverage" for --get. Supported keys: '
          'coverage.default, coverage.thresholds, coverage.tool_version.\n',
        );
      });

      test('fails without a key', () {
        expect(runCli(const ['--get'], out: out, err: err), 64);
        expect(err.toString(), '$usage\n');
      });
    });
  });
}
