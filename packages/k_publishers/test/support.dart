import 'dart:io';

import 'package:k_publishers/k_publishers.dart';

/// [PublisherClient] that answers from [publishers] without any network.
///
/// A package missing from [publishers] fails like an unknown package.
final class FakeClient implements PublisherClient {
  /// Creates a client that knows the given [publishers].
  new(this.publishers);

  /// Publisher id of each known package.
  final Map<String, String?> publishers;

  /// Packages looked up, in order.
  final List<String> calls = [];

  @override
  Future<String?> publisherOf(String package) async {
    calls.add(package);
    if (!publishers.containsKey(package)) {
      throw PublisherLookupException('$package: not found on pub.dev.');
    }
    return publishers[package];
  }
}

/// Writes a workspace under [root]: the root pubspec with [rootDeps] and one
/// member `packages/a` with [memberDeps], plus `k.yaml` with [exceptions].
void writeWorkspace(
  Directory root, {
  String rootDeps = '',
  String memberDeps = '',
  String exceptions = '{}',
}) {
  Directory('${root.path}/packages/a').createSync(recursive: true);
  File('${root.path}/pubspec.yaml')
      .writeAsStringSync('name: root\nworkspace:\n  - packages/a\n$rootDeps');
  File('${root.path}/packages/a/pubspec.yaml')
      .writeAsStringSync('name: a\n$memberDeps');
  File('${root.path}/k.yaml').writeAsStringSync(
    'coverage: {default: 100, tool_version: 1.16.0, overrides: {}}\n'
    'dependencies: {exceptions: $exceptions}\n'
    'comments: {include: ["**.dart"], exclude: [], exceptions: []}\n',
  );
}
