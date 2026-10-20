import 'dart:io';

import 'package:k_comments/k_comments.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    root = Directory.systemTemp.createTempSync('k_comments_cli_');
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() => root.deleteSync(recursive: true));

  int run(List<String> arguments) => runCli(arguments, out, err);

  test('exits 0 when only /// comments are present', () {
    File('${root.path}/a.dart').writeAsStringSync('/// a\nvoid a() {}\n');
    expect(run(<String>['--root', root.path, '--include', '**.dart']), 0);
    expect(out.toString(), contains('No forbidden comments found.'));
  });

  test('exits 1 and lists violations', () {
    File('${root.path}/a.dart').writeAsStringSync('void a() {}\n// x\n');
    File('${root.path}/b.dart').writeAsStringSync('/* y */\n');
    expect(
      run(<String>[
        '--root',
        root.path,
        '--include',
        '**.dart',
        '--exclude',
        'b.dart',
      ]),
      1,
    );
    expect(out.toString(), contains('a.dart:2:1: line comment'));
    expect(out.toString(), isNot(contains('b.dart')));
    expect(out.toString(), contains('1 forbidden comment(s) found.'));
  });

  test('exits 64 on usage errors', () {
    expect(run(<String>['--unknown']), 64);
    expect(run(<String>['--include', '**.dart']), 64);
    expect(run(<String>['--root', root.path]), 64);
    expect(run(<String>['--root', root.path, '--include', '**.dart', 'x']), 64);
    expect(
      run(<String>['--root', '${root.path}/missing', '--include', '**.dart']),
      64,
    );
    expect(err.toString(), contains('Root directory not found'));
  });
}
