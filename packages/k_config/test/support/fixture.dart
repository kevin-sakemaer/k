/// Temporary repositories used by the tests.
library;

import 'dart:io';

import 'package:test/test.dart';

/// A strict, valid `k.yaml` for the repository created by [createRepository].
const validConfig = '''
coverage:
  default: 100
  overrides:
    alpha:
      threshold: 95
      reason: "Generated bindings cannot be exercised."
dependencies:
  allowed_publishers: [dart.dev, tools.dart.dev, labs.dart.dev]
  exceptions:
    third_party:
      reason: "Approved by Kevin on 2026-10-20 via Grok Bot."
comments:
  exceptions:
    - path: packages/alpha/lib/legacy.dart
      reason: "Vendored file kept verbatim."
''';

/// Creates a temporary repository with a two package workspace and returns
/// its root.
///
/// The member `alpha` depends on `yaml` and `third_party` and has `test` as
/// a dev dependency. The member `beta` depends on `alpha`. Entries of [files]
/// are written last, keyed by relative path, and replace the default files.
/// The directory is deleted when the current test ends.
Directory createRepository({Map<String, String> files = const {}}) {
  final root = Directory.systemTemp.createTempSync('k_config_test_');
  addTearDown(() => root.deleteSync(recursive: true));
  final defaults = {
    'pubspec.yaml': '''
name: workspace_root
publish_to: none
workspace:
  - packages/alpha
  - packages/beta
''',
    'packages/alpha/pubspec.yaml': '''
name: alpha
dependencies:
  yaml: ^3.1.3
  third_party: ^1.0.0
dev_dependencies:
  test: ^1.26.0
''',
    'packages/alpha/lib/legacy.dart': 'void legacy() {}\n',
    'packages/beta/pubspec.yaml': '''
name: beta
dependencies:
  alpha: any
''',
    'k.yaml': validConfig,
  };
  for (final MapEntry(:key, :value) in {...defaults, ...files}.entries) {
    File('${root.path}/$key')
      ..createSync(recursive: true)
      ..writeAsStringSync(value);
  }
  return root;
}
