import 'dart:io';

import 'package:k_publishers/k_publishers.dart';

/// Checks the pub.dev publisher of every direct dependency.
Future<void> main(List<String> arguments) async {
  PubDevClient? client;
  try {
    exitCode = await runCli(
      arguments,
      stdout,
      stderr,
      (timeout) => client = PubDevClient(HttpClient(), timeout: timeout),
    );
  } finally {
    client?.close();
  }
}
