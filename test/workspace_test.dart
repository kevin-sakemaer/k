import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('every workspace member resolves through the workspace', () async {
    final ProcessResult result = await Process.run(
      Platform.resolvedExecutable,
      <String>['pub', 'workspace', 'list', '--json'],
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final decoded = jsonDecode(result.stdout as String) as Map<String, Object?>;
    final List<String> packages = (decoded['packages']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map((package) => package['path']! as String)
        .toList();
    final String root = Directory.current.resolveSymbolicLinksSync();
    final List<String> members = packages
        .where((path) => Directory(path).resolveSymbolicLinksSync() != root)
        .toList();
    expect(members, isNotEmpty);
    for (final member in members) {
      final List<String> lines = File('$member/pubspec.yaml').readAsLinesSync();
      expect(
        lines,
        contains('resolution: workspace'),
        reason: '$member must declare resolution: workspace',
      );
      expect(
        lines,
        contains('publish_to: none'),
        reason: '$member must declare publish_to: none',
      );
    }
  });
}
