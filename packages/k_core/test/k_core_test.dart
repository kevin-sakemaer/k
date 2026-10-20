import 'package:k_core/k_core.dart';
import 'package:test/test.dart';

void main() {
  test('greet addresses the given name', () {
    expect(greet('k'), 'Hello, k!');
  });
}
