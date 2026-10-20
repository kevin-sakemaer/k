import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// The kind of a forbidden comment.
enum CommentKind {
  /// A `//` line comment.
  line('line comment'),

  /// A `// ignore:` or `// ignore_for_file:` suppression comment.
  ignore('ignore comment'),

  /// A `/* */` block comment.
  block('block comment'),

  /// A `/** */` documentation block comment.
  docBlock('documentation block comment');

  new(this.label);

  /// Human-readable name used in reports.
  final String label;
}

/// A forbidden comment found in a Dart file.
final class CommentViolation {
  /// Creates a violation at [line] and [column] (both 1-based) of [path].
  const new({
    required this.path,
    required this.line,
    required this.column,
    required this.kind,
  });

  /// Path of the file, as given to the scanner.
  final String path;

  /// 1-based line of the start of the comment.
  final int line;

  /// 1-based column of the start of the comment.
  final int column;

  /// Kind of the comment.
  final CommentKind kind;

  @override
  String toString() =>
      '$path:$line:$column: ${kind.label} is not allowed, use /// only';
}

/// Which files [scanFiles] checks.
///
/// Every value comes from the caller: the scanner has no built-in defaults.
final class CommentScanConfig {
  /// Creates a configuration from glob patterns relative to the scan root.
  new({required List<String> include, required List<String> exclude})
    : _include = include.map(Glob.new).toList(),
      _exclude = exclude.map(Glob.new).toList();

  final List<Glob> _include;
  final List<Glob> _exclude;

  /// Whether the file at [relativePath] (with `/` separators) is checked.
  bool matches(String relativePath) =>
      _include.any((glob) => glob.matches(relativePath)) &&
      !_exclude.any((glob) => glob.matches(relativePath));
}

/// Returns every forbidden comment in [source], reported against [path].
///
/// Only `///` comments are allowed. Text inside string literals is never a
/// comment, because the source is tokenized by `package:analyzer`.
List<CommentViolation> findViolations(String source, String path) {
  final ParseStringResult result = parseString(
    content: source,
    path: path,
    throwIfDiagnostics: false,
  );
  final LineInfo lineInfo = result.lineInfo;
  final violations = <CommentViolation>[];
  Token? token = result.unit.beginToken;
  while (token != null) {
    Token? comment = token.precedingComments;
    while (comment != null) {
      final CommentKind? kind = _kindOf(comment.lexeme);
      if (kind != null) {
        final CharacterLocation location = lineInfo.getLocation(comment.offset);
        violations.add(
          CommentViolation(
            path: path,
            line: location.lineNumber,
            column: location.columnNumber,
            kind: kind,
          ),
        );
      }
      comment = comment.next;
    }
    if (token.isEof) {
      break;
    }
    token = token.next;
  }
  return violations;
}

CommentKind? _kindOf(String lexeme) {
  if (lexeme.startsWith('///')) {
    return null;
  }
  if (lexeme.startsWith('/**')) {
    return CommentKind.docBlock;
  }
  if (lexeme.startsWith('/*')) {
    return CommentKind.block;
  }
  final String body = lexeme.substring(2).trimLeft();
  if (body.startsWith('ignore:') || body.startsWith('ignore_for_file:')) {
    return CommentKind.ignore;
  }
  return CommentKind.line;
}

/// Scans the Dart files under [root] selected by [config].
///
/// Reported paths are relative to [root] and use `/` separators.
List<CommentViolation> scanFiles(Directory root, CommentScanConfig config) {
  final List<File> files =
      root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => config.matches(_relative(file.path, root.path)))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return <CommentViolation>[
    for (final file in files)
      ...findViolations(
        file.readAsStringSync(),
        _relative(file.path, root.path),
      ),
  ];
}

String _relative(String path, String root) =>
    p.posix.joinAll(p.split(p.relative(path, from: root)));
