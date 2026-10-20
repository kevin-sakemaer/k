import 'dart:io';

import 'package:k_config/k_config.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

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
          contains('k.yaml: coverage.default: must be between 0 and 100'),
          contains('k.yaml: coverage.overrides.gamma: unknown package.'),
          endsWith('k.yaml is invalid: 2 error(s).\n'),
        ),
      );
    });

    test('rejects extra arguments', () {
      expect(runCli(const ['a', 'b'], out: out, err: err), 64);
      expect(err.toString(), 'Usage: k_config [repository-root]\n');
    });
  });
}
