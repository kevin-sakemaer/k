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
  unreadable('cannot read file as UTF-8'),

  /// A symbolic link whose target is missing or outside the scan root.
  linkOutsideRoot('symbolic link target is missing or outside the scan root'),

  /// A `.dart` symbolic link that points to a directory.
  linkToDirectory('symbolic link points to a directory, not a Dart file'),

  /// A file listed in the comment exceptions that has no forbidden comment,
  /// or that is not checked at all.
  unusedException(
    'comment exception is not needed: the file is not checked or only has '
    '/// comments; remove it from k.yaml',
  );

  new(this.message);

  /// Message used in reports.
  final String message;

  /// Whether this kind is a forbidden comment, the only kind that a comment
  /// exception suppresses. File problems (unreadable files and bad symbolic
  /// links) are always reported.
  bool get isComment => switch (this) {
    line || ignore || block || docBlock || unterminatedBlock => true,
    unreadable ||
    linkOutsideRoot ||
    linkToDirectory ||
    unusedException => false,
  };
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
  /// Creates a configuration from glob patterns relative to the scan root,
  /// and the relative paths of the files allowed to keep forbidden comments.
  new({
    required List<String> include,
    required List<String> exclude,
    required Iterable<String> exceptions,
  }) : _include = include.map(Glob.new).toList(),
       _exclude = exclude.map(Glob.new).toList(),
       exceptions = Set.unmodifiable(exceptions);

  final List<Glob> _include;
  final List<Glob> _exclude;

  /// Relative paths, with `/` separators, of the excepted files.
  final Set<String> exceptions;

  /// Whether the file at [relativePath] (with `/` separators) is checked.
  bool matches(String relativePath) =>
      _include.any((glob) => glob.matches(relativePath)) &&
      !_exclude.any((glob) => glob.matches(relativePath));
}

/// Diagnostic name of the analyzer scanner for a `/*` that is never closed.
///
/// The analyzer only exposes this code under `src/`, so its name is compared.
/// `pubspec.lock` pins the analyzer version, and a dedicated test fails if
/// the name changes.
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

  var lastEnd = 0;
  Token? token = result.unit.beginToken;
  while (token != null) {
    Token? comment = token.precedingComments;
    while (comment != null) {
      final CommentKind? kind = _kindOf(comment.lexeme);
      if (kind != null) {
        violations.add(at(comment.offset, kind));
      }
      lastEnd = comment.end;
      comment = comment.next;
    }
    if (token.isEof) {
      break;
    }
    lastEnd = token.end;
    token = token.next;
  }
  for (final Diagnostic diagnostic in result.errors) {
    if (diagnostic.diagnosticCode.lowerCaseName == _unterminatedComment) {
      final int start = source.indexOf('/*', lastEnd);
      violations.add(
        at(
          start < 0 ? diagnostic.offset : start,
          CommentKind.unterminatedBlock,
        ),
      );
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
/// is reported as [CommentKind.unreadable].
///
/// A symbolic link to a `.dart` file is followed: its target is scanned and
/// reported under the link path when it is inside [root]. A link whose target
/// is missing or outside [root] is reported as [CommentKind.linkOutsideRoot].
/// A `.dart` link to a directory is reported as [CommentKind.linkToDirectory].
/// Other directory links are not followed.
///
/// The forbidden comments of a file listed in [CommentScanConfig.exceptions]
/// are not reported; its file problems still are. An exception whose file is
/// not checked or has no forbidden comment is reported as
/// [CommentKind.unusedException], so the list stays minimal.
///
/// Reported paths are relative to [root] and use `/` separators.
List<CommentViolation> scanFiles(Directory root, CommentScanConfig config) {
  final String canonicalRoot = root.resolveSymbolicLinksSync();
  final List<FileSystemEntity> entities =
      root
          .listSync(recursive: true, followLinks: false)
          .where((entity) => entity is File || entity is Link)
          .where((entity) => p.extension(entity.path) == '.dart')
          .where((entity) => config.matches(_relative(entity.path, root.path)))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  final violations = <CommentViolation>[];
  final usedExceptions = <String>{};
  for (final entity in entities) {
    final String path = _relative(entity.path, root.path);
    final List<CommentViolation> found = _scanEntity(
      entity,
      path,
      canonicalRoot,
    );
    if (config.exceptions.contains(path)) {
      final Iterable<CommentViolation> comments = found.where(
        (violation) => violation.kind.isComment,
      );
      if (comments.isNotEmpty) {
        usedExceptions.add(path);
      }
      violations.addAll(found.where((violation) => !violation.kind.isComment));
    } else {
      violations.addAll(found);
    }
  }
  final List<String> unused =
      config.exceptions.difference(usedExceptions).toList()..sort();
  return violations
    ..addAll(unused.map((path) => _atStart(path, CommentKind.unusedException)));
}

List<CommentViolation> _scanEntity(
  FileSystemEntity entity,
  String path,
  String canonicalRoot,
) {
  if (entity is File) {
    return _scanFile(entity, path);
  }
  final String target;
  try {
    target = entity.resolveSymbolicLinksSync();
  } on FileSystemException {
    return <CommentViolation>[_atStart(path, CommentKind.linkOutsideRoot)];
  }
  if (!p.isWithin(canonicalRoot, target)) {
    return <CommentViolation>[_atStart(path, CommentKind.linkOutsideRoot)];
  }
  if (FileSystemEntity.isDirectorySync(target)) {
    return <CommentViolation>[_atStart(path, CommentKind.linkToDirectory)];
  }
  return _scanFile(File(target), path);
}

CommentViolation _atStart(String path, CommentKind kind) =>
    CommentViolation(path: path, line: 1, column: 1, kind: kind);

List<CommentViolation> _scanFile(File file, String path) {
  final String source;
  try {
    source = file.readAsStringSync();
  } on FileSystemException {
    return <CommentViolation>[_atStart(path, CommentKind.unreadable)];
  }
  return findViolations(source, path);
}

String _relative(String path, String root) =>
    p.posix.joinAll(p.split(p.relative(path, from: root)));
