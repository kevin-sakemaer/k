import 'dart:io';

import 'package:k_workflows/k_workflows.dart';
import 'package:test/test.dart';

/// A valid `k.yaml` whose workflow settings are given by [workflows].
String kYaml(String workflows) =>
    'coverage: {default: 100, tool_version: 1.16.0, overrides: {}}\n'
    'dependencies: {exceptions: {}}\n'
    'comments: {include: ["**.dart"], exclude: [], exceptions: []}\n'
    'close_issues: {lookback_hours: 72}\n'
    'workflows: $workflows\n';

void main() {
  late Directory root;
  late StringBuffer out;
  late StringBuffer err;

  setUp(() {
    root = Directory.systemTemp.createTempSync('k_workflows_');
    Directory('${root.path}/.github/workflows').createSync(recursive: true);
    Directory('${root.path}/packages/a').createSync(recursive: true);
    File('${root.path}/pubspec.yaml')
        .writeAsStringSync('name: root\nworkspace:\n  - packages/a\n');
    File('${root.path}/packages/a/pubspec.yaml').writeAsStringSync('name: a\n');
    File(
      '${root.path}/k.yaml',
    ).writeAsStringSync(kYaml('{max_timeout_minutes: 10, write_scopes: []}'));
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

  test('checks write scopes and timeouts against k.yaml', () {
    write(
      'a.yml',
      good.replaceFirst(
        'timeout-minutes: 5',
        'timeout-minutes: 11\n    permissions: {contents: write}',
      ),
    );
    expect(run(<String>[root.path]), 1);
    expect(err.toString(), contains('timeout-minutes is 11'));
    expect(err.toString(), contains('"contents: write" is not declared'));
    File('${root.path}/k.yaml').writeAsStringSync(
      kYaml(
        '{max_timeout_minutes: 11, write_scopes: [{workflow: a.yml, job: a, '
        'scope: contents, reason: "Pushes."}]}',
      ),
    );
    out.clear();
    expect(run(<String>[root.path]), 0, reason: err.toString());
    expect(out.toString(), contains('1 workflow(s) pass.'));
  });

  test('exits 1 when k.yaml is invalid', () {
    write('a.yml', good);
    File('${root.path}/k.yaml')
        .writeAsStringSync(kYaml('{max_timeout_minutes: 0, write_scopes: []}'));
    expect(run(<String>[root.path]), 1);
    expect(err.toString(), contains('workflows.max_timeout_minutes'));
    expect(err.toString(), contains('k.yaml is invalid: 1 error(s).'));
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
