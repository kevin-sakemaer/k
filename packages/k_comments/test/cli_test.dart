import 'dart:io';

import 'package:k_comments/k_comments.dart';
import 'package:test/test.dart';

/// A valid `k.yaml` whose comment settings are given by [comments].
String kYaml(String comments) =>
    'coverage: {default: 100, tool_version: 1.16.0, overrides: {}}\n'
    'dependencies: {exceptions: {}}\n'
    'comments: $comments\n';

void main() {
  late Directory root;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    root = Directory.systemTemp.createTempSync('k_comments_cli_');
    File('${root.path}/pubspec.yaml')
        .writeAsStringSync('name: root\nworkspace: []\n');
    File('${root.path}/k.yaml').writeAsStringSync(
      kYaml('{include: ["**.dart"], exclude: ["gen/**"], exceptions: []}'),
    );
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() => root.deleteSync(recursive: true));

  int run(List<String> arguments) => runCli(arguments, out, err);

  test('exits 0 when only /// comments are present', () {
    File('${root.path}/a.dart').writeAsStringSync('/// a\nvoid a() {}\n');
    expect(run(<String>[root.path]), 0);
    expect(out.toString(), contains('No forbidden comments found.'));
  });

  test('uses the globs of k.yaml and lists violations', () {
    File('${root.path}/a.dart').writeAsStringSync('void a() {}\n// x\n');
    File('${root.path}/gen/b.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('/* y */\n');
    expect(run(<String>[root.path]), 1);
    expect(out.toString(), contains('a.dart:2:1: line comment'));
    expect(out.toString(), isNot(contains('gen/b.dart')));
    expect(out.toString(), contains('1 forbidden comment(s) found.'));
  });

  test('exits 1 on a file that is not valid UTF-8', () {
    File('${root.path}/a.dart').writeAsBytesSync(<int>[0xc3, 0x28]);
    expect(run(<String>[root.path]), 1);
    expect(out.toString(), contains('a.dart:1:1: cannot read file as UTF-8'));
  });

  test('applies the comment exceptions of k.yaml', () {
    File('${root.path}/a.dart').writeAsStringSync('// kept\n');
    File('${root.path}/k.yaml').writeAsStringSync(
      kYaml(
        '{include: ["**.dart"], exclude: [], '
        'exceptions: [{path: a.dart, reason: "Vendored."}]}',
      ),
    );
    expect(run(<String>[root.path]), 0);
  });

  test('exits 1 when k.yaml is invalid', () {
    File('${root.path}/k.yaml')
        .writeAsStringSync(kYaml('{include: [], exclude: [], exceptions: []}'));
    expect(run(<String>[root.path]), 1);
    expect(err.toString(), contains('comments.include'));
    expect(err.toString(), contains('k.yaml is invalid: 1 error(s).'));
  });

  test('defaults to the current directory', () {
    final Directory previous = Directory.current;
    addTearDown(() => Directory.current = previous);
    Directory.current = root;
    File('${root.path}/a.dart').writeAsStringSync('/* x */\n');
    expect(run(<String>[]), 1);
  });

  test('exits 64 when the root directory does not exist', () {
    expect(run(<String>['${root.path}/missing']), 64);
    expect(err.toString(), contains('Root directory not found'));
  });

  test('exits 64 on an extra positional argument', () {
    expect(run(<String>[root.path, 'x']), 64);
    expect(err.toString(), contains('Usage: k_comments [repository-root]'));
  });

  test('exits 64 on an option', () {
    expect(run(<String>['--root', root.path]), 64);
  });
}
