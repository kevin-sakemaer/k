import 'dart:io';

import 'package:k_publishers/k_publishers.dart';

/// Checks the pub.dev publisher of every direct dependency.
Future<void> main(List<String> arguments) async {
  final client = PubDevClient(HttpClient());
  try {
    exitCode = await runCli(arguments, stdout, stderr, client);
  } finally {
    client.close();
  }
}
