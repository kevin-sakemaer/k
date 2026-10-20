/// Checks that every direct dependency is published on pub.dev by an
/// allowed verified publisher.
library;

export 'src/check.dart' show checkPublishers;
export 'src/cli.dart' show PublisherClientFactory, runCli;
export 'src/dependencies.dart'
    show DependencySource, DirectDependency, readDirectDependencies;
export 'src/pub_client.dart'
    show PubDevClient, PublisherClient, PublisherLookupException;
