/// Checks the publishers of the direct dependencies.
library;

import 'package:k_config/k_config.dart';
import 'package:k_publishers/src/dependencies.dart';
import 'package:k_publishers/src/pub_client.dart';

/// Returns one message per problem found in [dependencies].
///
/// A pub.dev dependency must be published by one of
/// [DependenciesConfig.allowedPublishers] unless [config] lists it in its
/// exceptions. SDK and path dependencies are skipped. Git and other hosts are
/// never allowed without an exception. An exception that is not needed is a
/// problem too, so that the list stays minimal.
Future<List<String>> checkPublishers(
  List<DirectDependency> dependencies,
  DependenciesConfig config,
  PublisherClient client,
) async {
  const String registry = DependenciesConfig.registryUrl;
  final problems = <String>[];
  final publishers = <String, Future<String?>>{};
  for (final dependency in dependencies) {
    final String name = dependency.name;
    final where = '${dependency.pubspec}: $name';
    final bool excepted = config.exceptions.containsKey(name);
    switch (dependency.source) {
      case DependencySource.sdk || DependencySource.path:
        if (excepted) {
          problems.add('$where: unneeded exception (not from $registry).');
        }
      case DependencySource.git || DependencySource.otherHost:
        if (!excepted) {
          problems.add('$where: not hosted on $registry.');
        }
      case DependencySource.pubDev:
        final String? publisher;
        try {
          publisher = await publishers.putIfAbsent(
            name,
            () => client.publisherOf(name),
          );
        } on PublisherLookupException catch (error) {
          problems.add('$where: ${error.message}');
          continue;
        }
        final bool allowed = DependenciesConfig.allowedPublishers.contains(
          publisher,
        );
        if (allowed && excepted) {
          problems.add('$where: unneeded exception (published by $publisher).');
        } else if (!allowed && !excepted) {
          problems.add(
            '$where: published by ${publisher ?? 'no verified publisher'}, '
            'expected one of '
            '${DependenciesConfig.allowedPublishers.join(', ')}.',
          );
        }
    }
  }
  return problems;
}
