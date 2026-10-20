/// Looks up the verified publisher of a package on pub.dev.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:k_config/k_config.dart';

/// Thrown when the publisher of a package cannot be read.
final class PublisherLookupException implements Exception {
  /// Creates an exception with a human readable [message].
  const new(this.message);

  /// Human readable description of the problem.
  final String message;

  @override
  String toString() => 'PublisherLookupException: $message';
}

/// Finds the verified publisher of a package.
abstract interface class PublisherClient {
  /// The publisher id of [package], or `null` when it has none.
  ///
  /// Throws a [PublisherLookupException] when the package is unknown or the
  /// lookup fails.
  Future<String?> publisherOf(String package);
}

/// [PublisherClient] that queries `<baseUri>/api/packages/<name>/publisher`.
final class PubDevClient implements PublisherClient {
  /// [PublisherClient] that queries the publisher API of the registry.
  ///
  /// [baseUri] defaults to [DependenciesConfig.registryUrl]; tests point it
  /// to a local server. `timeout` bounds the connection and the whole
  /// request; the command line tool passes
  /// [DependenciesConfig.registryTimeout], read from `k.yaml`.
  new(this._http, {required this._timeout, Uri? baseUri})
    : _base = baseUri ?? Uri.parse(DependenciesConfig.registryUrl) {
    _http.connectionTimeout = _timeout;
  }

  final HttpClient _http;
  final Uri _base;
  final Duration _timeout;

  @override
  Future<String?> publisherOf(String package) async {
    final Uri uri = _base.replace(
      pathSegments: ['api', 'packages', package, 'publisher'],
    );
    final String body;
    final int status;
    try {
      (status, body) = await _get(uri).timeout(_timeout);
    } on TimeoutException {
      throw PublisherLookupException(
        '$package: request to $uri timed out after $_timeout.',
      );
    } on IOException catch (error) {
      throw PublisherLookupException(
        '$package: request to $uri failed: $error',
      );
    }
    if (status == HttpStatus.notFound) {
      throw PublisherLookupException(
        '$package: not found on ${DependenciesConfig.registryUrl}.',
      );
    }
    if (status != HttpStatus.ok) {
      throw PublisherLookupException('$package: $uri answered HTTP $status.');
    }
    final Object? json;
    try {
      json = jsonDecode(body);
    } on FormatException {
      throw PublisherLookupException('$package: $uri answered invalid JSON.');
    }
    return switch (json) {
      {'publisherId': final String id} => id,
      {'publisherId': null} => null,
      _ => throw PublisherLookupException(
        '$package: $uri answered an unexpected document.',
      ),
    };
  }

  Future<(int, String)> _get(Uri uri) async {
    final HttpClientRequest request = await _http.getUrl(uri);
    final HttpClientResponse response = await request.close();
    return (response.statusCode, await response.transform(utf8.decoder).join());
  }

  /// Closes the underlying HTTP client.
  ///
  /// Pending requests are aborted, so that a timed out request does not keep
  /// the process alive.
  void close() => _http.close(force: true);
}
