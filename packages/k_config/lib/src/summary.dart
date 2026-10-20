/// Markdown summary of the active settings of `k.yaml`.
library;

import 'package:k_config/src/model.dart';

/// Renders [config] as a Markdown summary that lists every active override
/// and exception with its reason, for the CI job summary.
String renderSummary(KConfig config) {
  final buffer = StringBuffer()
    ..writeln('## k.yaml')
    ..writeln()
    ..writeln('The configuration is valid.')
    ..writeln()
    ..writeln('### Coverage')
    ..writeln()
    ..writeln(
      'Default line coverage threshold: '
      '${config.coverage.defaultThreshold}%.',
    )
    ..writeln()
    ..writeln('Coverage tool: package:coverage ${config.coverage.toolVersion}.')
    ..writeln();
  _table(
    buffer,
    empty: 'No coverage overrides.',
    header: ['Package', 'Threshold', 'Reason'],
    rows: [
      for (final MapEntry(:key, :value) in config.coverage.overrides.entries)
        [key, '${value.threshold}%', value.reason],
    ],
  );
  buffer
    ..writeln('### Dependencies')
    ..writeln()
    ..writeln(
      'Allowed publishers: '
      '${DependenciesConfig.allowedPublishers.join(', ')}.',
    )
    ..writeln();
  _table(
    buffer,
    empty: 'No dependency exceptions.',
    header: ['Package', 'Reason', 'Approved by'],
    rows: [
      for (final MapEntry(:key, :value)
          in config.dependencies.exceptions.entries)
        [key, value.reason, value.approvedBy],
    ],
  );
  buffer
    ..writeln('### Comments')
    ..writeln();
  _table(
    buffer,
    empty: 'No comment exceptions.',
    header: ['File', 'Reason'],
    rows: [
      for (final exception in config.comments.exceptions)
        [exception.path, exception.reason],
    ],
  );
  return buffer.toString();
}

void _table(
  StringBuffer buffer, {
  required String empty,
  required List<String> header,
  required List<List<String>> rows,
}) {
  if (rows.isEmpty) {
    buffer
      ..writeln(empty)
      ..writeln();
    return;
  }
  buffer
    ..writeln(_row(header))
    ..writeln(_row([for (final _ in header) '---']));
  for (final row in rows) {
    buffer.writeln(_row(row));
  }
  buffer.writeln();
}

String _row(List<String> cells) => '| ${cells.map(_escape).join(' | ')} |';

String _escape(String cell) =>
    cell.replaceAll('|', r'\|').replaceAll(RegExp(r'\s*\n\s*'), ' ').trim();
