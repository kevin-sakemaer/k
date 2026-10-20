import 'dart:io';

import 'package:k_workflows/k_workflows.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    root = Directory.systemTemp.createTempSync('k_workflows_');
    Directory('${root.path}/.github/workflows').createSync(recursive: true);
    out = StringBuffer();
    err = StringBuffer();
  });

  tearDown(() => root.deleteSync(recursive: true));

  int run(List<String> arguments) => runCli(arguments, out, err);

  void write(String name, String content) =>
      File('${root.path}/.github/workflows/$name').writeAsStringSync(content);

  const good =
      'permissions: {}\njobs:\n  a:\n    timeout-minutes: 5\n'
      '    steps:\n      - run: true\n';

  test('exits 0 when every workflow passes', () {
    write('a.yml', good);
    write('b.yaml', good);
    write('notes.txt', 'not a workflow');
    expect(run(<String>[root.path]), 0);
    expect(out.toString(), contains('2 workflow(s) pass.'));
  });

  test('exits 1 and lists problems with relative paths', () {
    write(
      'a.yml',
      good.replaceFirst('permissions: {}', 'permissions: write-all'),
    );
    expect(run(<String>[root.path]), 1);
    expect(err.toString(), contains('.github/workflows/a.yml: top-level'));
    expect(err.toString(), contains('1 problem(s) found.'));
  });

  test('exits 1 when no workflow is found', () {
    expect(run(<String>[root.path]), 1);
    Directory('${root.path}/.github').deleteSync(recursive: true);
    expect(run(<String>[root.path]), 1);
    expect(err.toString(), contains('no workflow found'));
  });

  test('defaults to the current directory', () {
    final Directory previous = Directory.current;
    addTearDown(() => Directory.current = previous);
    Directory.current = root;
    write('a.yml', good);
    expect(run(<String>[]), 0);
  });

  test('exits 64 on usage errors', () {
    expect(run(<String>['--help']), 64);
    expect(run(<String>['a', 'b']), 64);
    expect(err.toString(), contains('Usage: k_workflows [repository-root]'));
  });

  test('the repository workflows pass', () {
    expect(run(<String>['../..']), 0, reason: err.toString());
  });
}
