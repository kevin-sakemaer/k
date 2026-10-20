import 'package:k_config/k_config.dart';
import 'package:k_publishers/k_publishers.dart';
import 'package:test/test.dart';

import 'support.dart';

DirectDependency dep(String name, [DependencySource s = .pubDev]) =>
    DirectDependency(name, 'pubspec.yaml', s);

DependenciesConfig config([List<String> excepted = const []]) =>
    DependenciesConfig(
      exceptions: {
        for (final name in excepted)
          name: const DependencyException(reason: 'r', approvedBy: 'Kevin'),
      },
    );

void main() {
  const expected = 'expected one of dart.dev, tools.dart.dev, labs.dart.dev.';
  final client = FakeClient({
    'yaml': 'tools.dart.dev',
    'test': 'dart.dev',
    'lab': 'labs.dart.dev',
    'provider': 'dash-overflow.net',
    'orphan': null,
  });

  test(
    'accepts the allowed publishers and looks each package up once',
    () async {
      client.calls.clear();
      expect(
        await checkPublishers(
          [dep('yaml'), dep('test'), dep('lab'), dep('test')],
          config(),
          client,
        ),
        isEmpty,
      );
      expect(client.calls, ['yaml', 'test', 'lab']);
    },
  );

  test('rejects other, missing and unknown publishers', () async {
    expect(
      await checkPublishers(
        [dep('provider'), dep('orphan'), dep('nope')],
        config(),
        client,
      ),
      [
        'pubspec.yaml: provider: published by dash-overflow.net, $expected',
        'pubspec.yaml: orphan: published by no verified publisher, $expected',
        'pubspec.yaml: nope: nope: not found on pub.dev.',
      ],
    );
  });

  test('applies exceptions and reports unneeded ones', () async {
    expect(
      await checkPublishers(
        [
          dep('provider'),
          dep('remote', .git),
          dep('yaml'),
          dep('local', .path),
        ],
        config(['provider', 'remote', 'yaml', 'local']),
        client,
      ),
      [
        'pubspec.yaml: yaml: unneeded exception (published by tools.dart.dev).',
        'pubspec.yaml: local: unneeded exception (not from pub.dev).',
      ],
    );
  });

  test('skips sdk and path, rejects git and other hosts', () async {
    expect(
      await checkPublishers(
        [
          dep('flutter', .sdk),
          dep('local', .path),
          dep('remote', .git),
          dep('mine', .otherHost),
        ],
        config(),
        client,
      ),
      [
        'pubspec.yaml: remote: not hosted on pub.dev.',
        'pubspec.yaml: mine: not hosted on pub.dev.',
      ],
    );
  });
}
