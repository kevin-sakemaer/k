import 'dart:io';

import 'package:k_config/k_config.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  group('loadKConfig', () {
    test('returns the validated configuration', () {
      final KConfig config = loadKConfig(createRepository());

      expect(config.coverage.thresholdFor('alpha'), 95);
    });

    test('fails when k.yaml is missing', () {
      final Directory root = createRepository();
      File('${root.path}/k.yaml').deleteSync();

      expect(
        () => loadKConfig(root),
        throwsA(
          isA<KConfigException>().having(
            (exception) => exception.errors.single,
            'error',
            'k.yaml: file not found in ${root.path}.',
          ),
        ),
      );
    });

    test('fails when the workspace cannot be read', () {
      final Directory root = createRepository(
        files: {'pubspec.yaml': 'name: r\n'},
      );

      expect(
        () => loadKConfig(root),
        throwsA(
          isA<KConfigException>().having(
            (exception) => exception.errors.single,
            'error',
            'pubspec.yaml: "workspace" must be a list of package paths.',
          ),
        ),
      );
    });

    test('fails with every validation error', () {
      final Directory root = createRepository(
        files: {'k.yaml': validConfig.replaceFirst('100', '"high"')},
      );

      expect(
        () => loadKConfig(root),
        throwsA(
          isA<KConfigException>().having(
            (exception) => exception.toString(),
            'toString',
            'KConfigException:\n'
                'k.yaml: coverage.default: must be an integer from 0 to 100, '
                'found "high".',
          ),
        ),
      );
    });
  });
}
