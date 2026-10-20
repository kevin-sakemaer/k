import 'dart:io';

import 'package:k_comments/k_comments.dart';
import 'package:test/test.dart';

List<CommentKind> kinds(String source) =>
    findViolations(source, 'a.dart').map((v) => v.kind).toList();

void main() {
  test('only comment kinds can be suppressed by an exception', () {
    expect(CommentKind.values.where((kind) => kind.isComment), <CommentKind>[
      CommentKind.line,
      CommentKind.ignore,
      CommentKind.block,
      CommentKind.docBlock,
      CommentKind.unterminatedBlock,
    ]);
  });

  group('findViolations', () {
    test('allows /// documentation comments', () {
      expect(kinds('/// Doc.\nvoid f() {}\n'), isEmpty);
      expect(kinds('void f() {\n  /// Inside.\n}\n'), isEmpty);
    });

    test('reports // line comments with line and column', () {
      final List<CommentViolation> found = findViolations(
        'void f() {\n  // note\n}\n',
        'lib/a.dart',
      );
      expect(found, hasLength(1));
      expect(found.single.line, 2);
      expect(found.single.column, 3);
      expect(found.single.kind, CommentKind.line);
      expect(
        found.single.toString(),
        'lib/a.dart:2:3: line comment is not allowed, use /// only',
      );
    });

    test('reports ignore and ignore_for_file comments', () {
      expect(kinds('// ignore: x\nvoid f() {}\n'), <CommentKind>[
        CommentKind.ignore,
      ]);
      expect(kinds('//ignore_for_file: x\nvoid f() {}\n'), <CommentKind>[
        CommentKind.ignore,
      ]);
    });

    test('reports block and documentation block comments', () {
      expect(kinds('/* a */ void f() {}\n'), <CommentKind>[CommentKind.block]);
      expect(kinds('/** a */ void f() {}\n'), <CommentKind>[
        CommentKind.docBlock,
      ]);
      expect(kinds('/* a /* nested */ b */ void f() {}\n'), <CommentKind>[
        CommentKind.block,
      ]);
    });

    test('reports comments before the end of file', () {
      expect(kinds('void f() {}\n// end'), <CommentKind>[CommentKind.line]);
      expect(kinds('void f() {}\n/* end */\n'), <CommentKind>[
        CommentKind.block,
      ]);
      expect(kinds('// only a comment\n'), <CommentKind>[CommentKind.line]);
    });

    test('reports every comment of a group in order', () {
      expect(kinds('// a\n/* b */\n/// c\nvoid f() {}\n'), <CommentKind>[
        CommentKind.line,
        CommentKind.block,
      ]);
    });

    test('ignores comment markers inside string literals', () {
      expect(kinds("const a = 'http://x // y /* z */';\n"), isEmpty);
      expect(kinds('const a = r"// raw /* x */";\n'), isEmpty);
      expect(kinds("const a = '''\n// multi\n/* line */\n''';\n"), isEmpty);
      expect(kinds('const a = r"""\n// raw multi\n""";\n'), isEmpty);
      expect(
        kinds(
          r"const b = 1; const a = 'x ${b} // y';"
          '\n',
        ),
        isEmpty,
      );
    });

    test('reports comments inside string interpolation code', () {
      expect(
        kinds("const b = 1;\nconst a = 'x \${b /* c */}';\n"),
        <CommentKind>[CommentKind.block],
      );
    });

    test('reports //// as a line comment', () {
      expect(kinds('//// four\nvoid f() {}\n'), <CommentKind>[
        CommentKind.line,
      ]);
      expect(kinds('/////\nvoid f() {}\n'), <CommentKind>[CommentKind.line]);
    });

    test('reports an unterminated block comment at its opening', () {
      expect(
        findViolations(
          'void f() {}\n/* never closed\n',
          'a.dart',
        ).map((v) => v.toString()),
        <String>['a.dart:2:1: unterminated block comment'],
      );
    });

    test('locates an unterminated block comment followed by lines', () {
      expect(
        findViolations(
          'void f() {}\n/// ok\nvoid g() {} /* open\nline\n// x\nend\n',
          'a.dart',
        ).map((v) => v.toString()),
        <String>['a.dart:3:13: unterminated block comment'],
      );
    });

    test('locates an unterminated block comment after a closed one', () {
      expect(
        findViolations(
          '/* a */\n  /* b /* c */\nx\n',
          'a.dart',
        ).map((v) => v.toString()),
        <String>[
          'a.dart:1:1: block comment is not allowed, use /// only',
          'a.dart:2:3: unterminated block comment',
        ],
      );
    });

    test('counts columns in Unicode code points', () {
      final List<CommentViolation> found = findViolations(
        "var s = '\u{1F600}'; // x\n",
        'a.dart',
      );
      expect(found.single.column, 14);
    });

    test('does not fail on invalid code', () {
      expect(kinds('void f( {\n// x\n'), <CommentKind>[CommentKind.line]);
    });
  });

  group('scanFiles', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('k_comments_');
      File('${root.path}/lib/a.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('// a\n');
      File('${root.path}/lib/b.dart').writeAsStringSync('/// b\nvoid b() {}\n');
      File('${root.path}/gen/c.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync('// generated\n');
      File('${root.path}/notes.txt').writeAsStringSync('// not dart\n');
    });

    tearDown(() => root.deleteSync(recursive: true));

    test('checks included files and skips excluded ones', () {
      final List<CommentViolation> found = scanFiles(
        root,
        CommentScanConfig(
          include: <String>['**.dart'],
          exclude: <String>['gen/**'],
          exceptions: <String>[],
        ),
      );
      expect(found.map((v) => v.toString()), <String>[
        'lib/a.dart:1:1: line comment is not allowed, use /// only',
      ]);
    });

    test('never scans non-Dart files, even with a broad glob', () {
      File('${root.path}/a.yaml').writeAsStringSync('url: https://pub.dev\n');
      final List<CommentViolation> found = scanFiles(
        root,
        CommentScanConfig(
          include: <String>['**'],
          exclude: <String>['gen/**'],
          exceptions: <String>[],
        ),
      );
      expect(found.map((v) => v.path), <String>['lib/a.dart']);
    });

    test('reports a file that is not valid UTF-8', () {
      File('${root.path}/lib/bad.dart')
          .writeAsBytesSync(<int>[0xff, 0xfe, 0x00]);
      final List<CommentViolation> found = scanFiles(
        root,
        CommentScanConfig(
          include: <String>['lib/**'],
          exclude: <String>[],
          exceptions: <String>[],
        ),
      );
      expect(found.map((v) => v.toString()), <String>[
        'lib/a.dart:1:1: line comment is not allowed, use /// only',
        'lib/bad.dart:1:1: cannot read file as UTF-8',
      ]);
    });

    test('scans the target of a symbolic link inside the root', () {
      Link('${root.path}/lib/link.dart').createSync('${root.path}/gen/c.dart');
      final List<CommentViolation> found = scanFiles(
        root,
        CommentScanConfig(
          include: <String>['lib/**'],
          exclude: <String>[],
          exceptions: <String>[],
        ),
      );
      expect(found.map((v) => v.toString()), <String>[
        'lib/a.dart:1:1: line comment is not allowed, use /// only',
        'lib/link.dart:1:1: line comment is not allowed, use /// only',
      ]);
    });

    test('reports symbolic links that are outside the root or broken', () {
      final Directory outside = Directory.systemTemp.createTempSync('k_out_');
      addTearDown(() => outside.deleteSync(recursive: true));
      File('${outside.path}/real.dart').writeAsStringSync('// real\n');
      Link('${root.path}/lib/out.dart').createSync('${outside.path}/real.dart');
      Link('${root.path}/lib/broken.dart').createSync('${root.path}/none.dart');
      final List<CommentViolation> found = scanFiles(
        root,
        CommentScanConfig(
          include: <String>['lib/**'],
          exclude: <String>[],
          exceptions: <String>[],
        ),
      );
      const message =
          'symbolic link target is missing or outside the scan root';
      expect(found.map((v) => v.toString()), <String>[
        'lib/a.dart:1:1: line comment is not allowed, use /// only',
        'lib/broken.dart:1:1: $message',
        'lib/out.dart:1:1: $message',
      ]);
    });

    test('reports a .dart symbolic link to a directory', () {
      Directory('${root.path}/dir').createSync();
      Link('${root.path}/lib/dir.dart').createSync('${root.path}/dir');
      final List<CommentViolation> found = scanFiles(
        root,
        CommentScanConfig(
          include: <String>['lib/**'],
          exclude: <String>[],
          exceptions: <String>['lib/a.dart'],
        ),
      );
      expect(found.map((v) => v.toString()), <String>[
        'lib/dir.dart:1:1: symbolic link points to a directory, not a Dart file',
      ]);
    });

    test('skips the violations of an excepted file', () {
      final List<CommentViolation> found = scanFiles(
        root,
        CommentScanConfig(
          include: <String>['**.dart'],
          exclude: <String>[],
          exceptions: <String>['gen/c.dart'],
        ),
      );
      expect(found.map((v) => v.path), <String>['lib/a.dart']);
    });

    test('exceptions never hide file problems', () {
      File('${root.path}/lib/bad.dart').writeAsBytesSync(<int>[0xff, 0xfe]);
      Directory('${root.path}/dir').createSync();
      Link('${root.path}/lib/dir.dart').createSync('${root.path}/dir');
      final List<CommentViolation> found = scanFiles(
        root,
        CommentScanConfig(
          include: <String>['lib/**'],
          exclude: <String>[],
          exceptions: <String>['lib/a.dart', 'lib/bad.dart', 'lib/dir.dart'],
        ),
      );
      const unused =
          'comment exception is not needed: the file is not checked or only '
          'has /// comments; remove it from k.yaml';
      expect(found.map((v) => v.toString()), <String>[
        'lib/bad.dart:1:1: cannot read file as UTF-8',
        'lib/dir.dart:1:1: symbolic link points to a directory, not a Dart file',
        'lib/bad.dart:1:1: $unused',
        'lib/dir.dart:1:1: $unused',
      ]);
    });

    test('reports exceptions that are not needed', () {
      File('${root.path}/notes.dart').writeAsStringSync('/// ok\n');
      final List<CommentViolation> found = scanFiles(
        root,
        CommentScanConfig(
          include: <String>['lib/**'],
          exclude: <String>[],
          exceptions: <String>['lib/a.dart', 'lib/b.dart', 'gen/c.dart'],
        ),
      );
      const unused =
          'comment exception is not needed: the file is not checked or only '
          'has /// comments; remove it from k.yaml';
      expect(found.map((v) => v.toString()), <String>[
        'gen/c.dart:1:1: $unused',
        'lib/b.dart:1:1: $unused',
      ]);
    });

    test('reports files in path order', () {
      final List<CommentViolation> found = scanFiles(
        root,
        CommentScanConfig(
          include: <String>['**.dart'],
          exclude: <String>[],
          exceptions: <String>[],
        ),
      );
      expect(found.map((v) => v.path), <String>['gen/c.dart', 'lib/a.dart']);
    });
  });
}
