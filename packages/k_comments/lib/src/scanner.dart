import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/source/line_info.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;

/// The kind of a forbidden comment.
enum CommentKind {
  /// A `//` line comment, including `////` and longer runs of slashes.
  line('line comment is not allowed, use /// only'),

  /// A `// ignore:` or `// ignore_for_file:` suppression comment.
  ignore('ignore comment is not allowed, use /// only'),

  /// A `/* */` block comment.
  block('block comment is not allowed, use /// only'),

  /// A `/** */` documentation block comment.
  docBlock('documentation block comment is not allowed, use /// only'),

  /// A `/*` that is never closed before the end of the file.
  unterminatedBlock('unterminated block comment'),

  /// A file that cannot be read as UTF-8 text.
  unreadable('cannot read file as UTF-8');

  new(this.message);

  /// Message used in reports.
  final String message;
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

  /// 1-based column of the start of the comment, counted in Unicode code
  /// points (runes), not UTF-16 code units.
  final int column;

  /// Kind of the comment.
  final CommentKind kind;

  @override
  String toString() => '$path:$line:$column: ${kind.message}';
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

/// Diagnostic name of the analyzer scanner for a `/*` that is never closed.
const String _unterminatedComment = 'unterminated_multi_line_comment';

/// Returns every forbidden comment in [source], reported against [path].
///
/// Only `///` comments are allowed. A `/*` that is never closed is reported
/// as [CommentKind.unterminatedBlock]. Text inside string literals is never a
/// comment, because the source is tokenized by `package:analyzer`.
List<CommentViolation> findViolations(String source, String path) {
  final ParseStringResult result = parseString(
    content: source,
    path: path,
    throwIfDiagnostics: false,
  );
  final LineInfo lineInfo = result.lineInfo;
  final violations = <CommentViolation>[];
  CommentViolation at(int offset, CommentKind kind) {
    final CharacterLocation location = lineInfo.getLocation(offset);
    final int lineStart = lineInfo.getOffsetOfLine(location.lineNumber - 1);
    return CommentViolation(
      path: path,
      line: location.lineNumber,
      column: source.substring(lineStart, offset).runes.length + 1,
      kind: kind,
    );
  }

  Token? token = result.unit.beginToken;
  while (token != null) {
    Token? comment = token.precedingComments;
    while (comment != null) {
      final CommentKind? kind = _kindOf(comment.lexeme);
      if (kind != null) {
        violations.add(at(comment.offset, kind));
      }
      comment = comment.next;
    }
    if (token.isEof) {
      break;
    }
    token = token.next;
  }
  for (final Diagnostic diagnostic in result.errors) {
    if (diagnostic.diagnosticCode.lowerCaseName == _unterminatedComment) {
      violations.add(at(diagnostic.offset, CommentKind.unterminatedBlock));
    }
  }
  return violations;
}

CommentKind? _kindOf(String lexeme) {
  if (lexeme.startsWith('///') && !lexeme.startsWith('////')) {
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
/// Only files with the `.dart` extension are read, whatever the globs match,
/// so YAML and other files are never scanned. A file that is not valid UTF-8
/// is reported as [CommentKind.unreadable]. Reported paths are relative to [root] and use `/` separators.
List<CommentViolation> scanFiles(Directory root, CommentScanConfig config) {
  final List<File> files =
      root
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where((file) => p.extension(file.path) == '.dart')
          .where((file) => config.matches(_relative(file.path, root.path)))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return <CommentViolation>[
    for (final file in files)
      ..._scanFile(file, _relative(file.path, root.path)),
  ];
}

List<CommentViolation> _scanFile(File file, String path) {
  final String source;
  try {
    source = file.readAsStringSync();
  } on FileSystemException {
    return <CommentViolation>[
      CommentViolation(
        path: path,
        line: 1,
        column: 1,
        kind: CommentKind.unreadable,
      ),
    ];
  }
  return findViolations(source, path);
}

String _relative(String path, String root) =>
    p.posix.joinAll(p.split(p.relative(path, from: root)));
