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

  test('exits 1 on a file that is not valid UTF-8', () {
    File('${root.path}/a.dart').writeAsBytesSync(<int>[0xc3, 0x28]);
    expect(run(<String>['--root', root.path, '--include', '**.dart']), 1);
    expect(out.toString(), contains('a.dart:1:1: cannot read file as UTF-8'));
  });

  test('exits 64 when the root directory does not exist', () {
    expect(
      run(<String>['--root', '${root.path}/missing', '--include', '**.dart']),
      64,
    );
    expect(err.toString(), contains('Root directory not found'));
  });

  test('exits 64 on an extra positional argument', () {
    expect(run(<String>['--root', root.path, '--include', '**.dart', 'x']), 64);
    expect(err.toString(), contains('no extra arguments'));
  });

  test('exits 64 on usage errors', () {
    expect(run(<String>['--unknown']), 64);
    expect(run(<String>['--include', '**.dart']), 64);
    expect(run(<String>['--root', root.path]), 64);
  });
}
