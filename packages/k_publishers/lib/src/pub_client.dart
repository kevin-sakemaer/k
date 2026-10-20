/// Looks up the verified publisher of a package on pub.dev.
library;

import 'dart:convert';
import 'dart:io';

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
  /// [PublisherClient] that queries the pub.dev publisher API.
  ///
  /// [baseUri] defaults to `https://pub.dev`; tests point it to a local
  /// server.
  new(this._http, {Uri? baseUri}) : _base = baseUri ?? Uri.https('pub.dev');

  final HttpClient _http;
  final Uri _base;

  @override
  Future<String?> publisherOf(String package) async {
    final Uri uri = _base.replace(
      pathSegments: ['api', 'packages', package, 'publisher'],
    );
    final String body;
    final int status;
    try {
      final HttpClientRequest request = await _http.getUrl(uri);
      final HttpClientResponse response = await request.close();
      status = response.statusCode;
      body = await response.transform(utf8.decoder).join();
    } on IOException catch (error) {
      throw PublisherLookupException(
        '$package: request to $uri failed: $error',
      );
    }
    if (status == HttpStatus.notFound) {
      throw PublisherLookupException('$package: not found on pub.dev.');
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

  /// Closes the underlying HTTP client.
  void close() => _http.close();
}
