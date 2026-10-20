import 'dart:io';

import 'package:k_publishers/k_publishers.dart';
import 'package:test/test.dart';

/// Tests run against a local loopback server: no network is used.
void main() {
  late HttpServer server;
  late PubDevClient client;
  final requested = <String>[];

  setUp(() async {
    requested.clear();
    server = (await HttpServer.bind(InternetAddress.loopbackIPv4, 0))
      ..listen((request) async {
        requested.add(request.uri.path);
        final String name = request.uri.pathSegments[2];
        final HttpResponse response = request.response;
        switch (name) {
          case 'missing':
            response.statusCode = HttpStatus.notFound;
          case 'broken':
            response.statusCode = HttpStatus.internalServerError;
          case 'garbage':
            response.write('not json');
          case 'odd':
            response.write('[1]');
          case 'orphan':
            response.write('{"publisherId":null}');
          default:
            response.write('{"publisherId":"dart.dev"}');
        }
        await response.close();
      });
    client = PubDevClient(
      HttpClient(),
      baseUri: Uri.http('127.0.0.1:${server.port}'),
      timeout: const Duration(seconds: 30),
    );
  });

  tearDown(() async {
    client.close();
    await server.close(force: true);
  });

  test('reads the publisher id', () async {
    expect(await client.publisherOf('yaml'), 'dart.dev');
    expect(requested, ['/api/packages/yaml/publisher']);
  });

  test('returns null without publisher', () async {
    expect(await client.publisherOf('orphan'), isNull);
  });

  for (final (name, message) in [
    ('missing', 'missing: not found on https://pub.dev.'),
    ('broken', 'answered HTTP 500.'),
    ('garbage', 'answered invalid JSON.'),
    ('odd', 'answered an unexpected document.'),
  ]) {
    test('fails on $name', () {
      expect(
        client.publisherOf(name),
        throwsA(
          isA<PublisherLookupException>()
              .having((e) => e.message, 'message', contains(message))
              .having((e) => '$e', 'toString', startsWith('PublisherLookup')),
        ),
      );
    });
  }

  test('fails when the server is unreachable', () async {
    final int port = server.port;
    await server.close(force: true);
    final offline = PubDevClient(
      HttpClient(),
      baseUri: Uri.http('127.0.0.1:$port'),
      timeout: const Duration(seconds: 30),
    );
    addTearDown(offline.close);
    await expectLater(
      offline.publisherOf('yaml'),
      throwsA(
        isA<PublisherLookupException>().having(
          (e) => e.message,
          'message',
          contains('request to'),
        ),
      ),
    );
  });

  test('fails closed when the server never answers', () async {
    final ServerSocket silent = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final sockets = <Socket>[];
    silent.listen(sockets.add);
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await silent.close();
    });
    final slow = PubDevClient(
      HttpClient(),
      baseUri: Uri.http('127.0.0.1:${silent.port}'),
      timeout: const Duration(milliseconds: 200),
    );
    addTearDown(slow.close);
    await expectLater(
      slow.publisherOf('yaml'),
      throwsA(
        isA<PublisherLookupException>().having(
          (e) => e.message,
          'message',
          contains('timed out after 0:00:00.200000'),
        ),
      ),
    );
  });

  test('defaults to pub.dev', () {
    PubDevClient(HttpClient(), timeout: const Duration(seconds: 1)).close();
  });
}
