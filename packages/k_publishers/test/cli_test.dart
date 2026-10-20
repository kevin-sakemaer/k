import 'dart:io';

import 'package:k_publishers/k_publishers.dart';
import 'package:test/test.dart';

import 'support.dart';

void main() {
  late Directory root;
  late StringBuffer out;
  late StringBuffer err;
  final client = FakeClient({'test': 'dart.dev', 'provider': 'other.dev'});

  setUp(() {
    root = Directory.systemTemp.createTempSync('k_pub_cli_');
    out = StringBuffer();
    err = StringBuffer();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<int> run(List<String> arguments) =>
      runCli(arguments, out, err, client);

  test('exits 0 when every dependency is allowed', () async {
    writeWorkspace(root, rootDeps: 'dev_dependencies:\n  test: ^1.0.0\n');
    expect(await run([root.path]), 0);
    expect(out.toString(), contains('Every direct dependency'));
  });

  test('exits 1 on a disallowed publisher', () async {
    writeWorkspace(root, memberDeps: 'dependencies:\n  provider: ^6.0.0\n');
    expect(await run([root.path]), 1);
    expect(out.toString(), contains('packages/a/pubspec.yaml: provider:'));
    expect(out.toString(), contains('1 dependency problem(s) found.'));
  });

  test('accepts an exception from k.yaml', () async {
    writeWorkspace(
      root,
      memberDeps: 'dependencies:\n  provider: ^6.0.0\n',
      exceptions: '{provider: {reason: r, approved_by: Kevin}}',
    );
    expect(await run([root.path]), 0);
  });

  test('exits 1 on an invalid k.yaml', () async {
    writeWorkspace(root, exceptions: '{ghost: {reason: r, approved_by: K}}');
    expect(await run([root.path]), 1);
    expect(err.toString(), contains('k.yaml is invalid'));
  });

  test('exits 64 on usage errors', () async {
    expect(await run(['--x']), 64);
    expect(await run(['a', 'b']), 64);
    expect(await run(['${root.path}/none']), 64);
    expect(err.toString(), contains('Root directory not found'));
  });

  test('defaults to the current directory', () async {
    writeWorkspace(root);
    final Directory previous = Directory.current;
    Directory.current = root;
    addTearDown(() => Directory.current = previous);
    expect(await run([]), 0);
  });
}
