import 'dart:io';

import 'package:k_config/k_config.dart';
import 'package:k_publishers/k_publishers.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('k_pub_deps_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('reads every source, skips workspace packages', () {
    writeWorkspace(
      root,
      rootDeps: 'dev_dependencies:\n  test: ^1.0.0\n',
      memberDeps:
          'dependencies:\n'
          '  root: {path: ../..}\n'
          '  flutter: {sdk: flutter}\n'
          '  local: {path: ../local}\n'
          '  remote: {git: https://example.com/r.git}\n'
          '  mine: {hosted: https://example.com, version: ^1.0.0}\n'
          '  map_host: {hosted: {url: https://pub.dev/}, version: ^1.0.0}\n'
          '  short_host: {hosted: https://pub.dartlang.org}\n'
          '  plain: {version: ^1.0.0}\n',
    );
    final List<DirectDependency> deps = readDirectDependencies(root);
    expect(
      {for (final d in deps) d.name: (d.pubspec, d.source)},
      {
        'test': ('pubspec.yaml', DependencySource.pubDev),
        'flutter': ('packages/a/pubspec.yaml', DependencySource.sdk),
        'local': ('packages/a/pubspec.yaml', DependencySource.path),
        'remote': ('packages/a/pubspec.yaml', DependencySource.git),
        'mine': ('packages/a/pubspec.yaml', DependencySource.otherHost),
        'map_host': ('packages/a/pubspec.yaml', DependencySource.pubDev),
        'short_host': ('packages/a/pubspec.yaml', DependencySource.pubDev),
        'plain': ('packages/a/pubspec.yaml', DependencySource.pubDev),
      },
    );
  });

  test('reads dependency_overrides of the root and of members', () {
    writeWorkspace(
      root,
      rootDeps:
          'dependency_overrides:\n'
          '  a: {path: packages/a}\n'
          '  yaml: ^3.1.0\n',
      memberDeps:
          'dependency_overrides:\n'
          '  remote: {git: https://example.com/r.git}\n'
          '  local: {path: ../local}\n',
    );
    expect(
      [
        for (final d in readDirectDependencies(root))
          (d.name, d.pubspec, d.source, d.isOverride),
      ],
      [
        ('yaml', 'pubspec.yaml', DependencySource.pubDev, true),
        ('remote', 'packages/a/pubspec.yaml', DependencySource.git, true),
        ('local', 'packages/a/pubspec.yaml', DependencySource.path, true),
      ],
    );
  });

  test('throws on a broken workspace', () {
    File('${root.path}/pubspec.yaml').writeAsStringSync('name: root\n');
    expect(
      () => readDirectDependencies(root),
      throwsA(isA<WorkspaceException>()),
    );
  });
}
