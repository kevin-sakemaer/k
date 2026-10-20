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

  test('throws on a broken workspace', () {
    File('${root.path}/pubspec.yaml').writeAsStringSync('name: root\n');
    expect(
      () => readDirectDependencies(root),
      throwsA(isA<WorkspaceException>()),
    );
  });
}
