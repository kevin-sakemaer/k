import 'dart:io';

import 'package:k_config/k_config.dart';
import 'package:test/test.dart';

import 'support/fixture.dart';

void main() {
  group('Workspace.load', () {
    test('reads member packages and their direct dependencies', () {
      final workspace = Workspace.load(createRepository());

      expect(workspace.packages, {'alpha', 'beta'});
      expect(workspace.directDependencies, {'yaml', 'third_party', 'test'});
      expect(workspace.containsFile('packages/alpha/lib/legacy.dart'), isTrue);
      expect(
        workspace.containsFile('packages/alpha/lib/missing.dart'),
        isFalse,
      );
    });

    test('includes the dependencies of the root pubspec', () {
      final root = createRepository(
        files: {
          'pubspec.yaml': '''
name: workspace_root
workspace: [packages/alpha]
dev_dependencies:
  lints: any
''',
        },
      );

      expect(Workspace.load(root).directDependencies, contains('lints'));
    });

    final failures = {
      'an empty root pubspec': (
        {'pubspec.yaml': ''},
        'pubspec.yaml: must be a mapping.',
      ),
      'invalid YAML': (
        {'pubspec.yaml': 'name: [unclosed'},
        'pubspec.yaml: invalid YAML:',
      ),
      'a missing workspace list': (
        {'pubspec.yaml': 'name: workspace_root\n'},
        'pubspec.yaml: "workspace" must be a list of package paths.',
      ),
      'a non string workspace entry': (
        {'pubspec.yaml': 'name: r\nworkspace: [42]\n'},
        'pubspec.yaml: workspace entry "42" must be a path.',
      ),
      'a missing member pubspec': (
        {'pubspec.yaml': 'name: r\nworkspace: [packages/gamma]\n'},
        'packages/gamma/pubspec.yaml: file not found.',
      ),
      'a member without name': (
        {'packages/beta/pubspec.yaml': 'version: 1.0.0\n'},
        'packages/beta/pubspec.yaml: "name" must be a string.',
      ),
      'a malformed dependency section': (
        {'packages/beta/pubspec.yaml': 'name: beta\ndependencies: [alpha]\n'},
        'packages/beta/pubspec.yaml: "dependencies" must be a mapping.',
      ),
      'a malformed root dependency section': (
        {'pubspec.yaml': 'name: r\nworkspace: []\ndev_dependencies: lints\n'},
        'pubspec.yaml: "dev_dependencies" must be a mapping.',
      ),
    };
    for (final MapEntry(key: description, value: (files, message))
        in failures.entries) {
      test('fails on $description', () {
        final root = createRepository(files: files);

        expect(
          () => Workspace.load(root),
          throwsA(
            isA<WorkspaceException>().having(
              (exception) => exception.message,
              'message',
              startsWith(message),
            ),
          ),
        );
      });
    }

    test('fails when the root pubspec does not exist', () {
      final root = createRepository();
      root.listSync().whereType<File>().forEach((file) => file.deleteSync());

      expect(
        () => Workspace.load(root),
        throwsA(
          isA<WorkspaceException>().having(
            (exception) => exception.toString(),
            'toString',
            'WorkspaceException: pubspec.yaml: file not found.',
          ),
        ),
      );
    });
  });
}
