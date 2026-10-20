import 'dart:io';

import 'package:args/args.dart';

import 'package:k_comments/src/scanner.dart';

/// Runs the command line tool and returns its exit code.
///
/// Exit codes: 0 when no forbidden comment is found, 1 when at least one is
/// found, 64 on a usage error. Violations are written to [out], usage errors
/// to [err].
int runCli(List<String> arguments, StringSink out, StringSink err) {
  final parser = ArgParser()
    ..addOption('root', help: 'Directory to scan.')
    ..addMultiOption(
      'include',
      help: 'Glob of files to check, relative to root.',
    )
    ..addMultiOption(
      'exclude',
      help: 'Glob of files to skip, relative to root.',
    );
  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on ArgParserException catch (error) {
    err
      ..writeln(error.message)
      ..writeln(parser.usage);
    return 64;
  }
  final List<String> include = results.multiOption('include');
  final String? rootPath = results.option('root');
  if (rootPath == null || include.isEmpty || results.rest.isNotEmpty) {
    err
      ..writeln(
        '--root and at least one --include are required, '
        'and no extra arguments.',
      )
      ..writeln(parser.usage);
    return 64;
  }
  final root = Directory(rootPath);
  if (!root.existsSync()) {
    err.writeln('Root directory not found: ${root.path}');
    return 64;
  }
  final List<CommentViolation> violations = scanFiles(
    root,
    CommentScanConfig(
      include: include,
      exclude: results.multiOption('exclude'),
    ),
  );
  if (violations.isEmpty) {
    out.writeln('No forbidden comments found.');
    return 0;
  }
  violations.forEach(out.writeln);
  out.writeln('${violations.length} forbidden comment(s) found.');
  return 1;
}
