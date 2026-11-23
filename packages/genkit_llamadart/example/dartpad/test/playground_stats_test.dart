import 'package:flutter_test/flutter_test.dart';
import 'package:genkit_llamadart_dartpad_example/playground_controller.dart';

void main() {
  test('reported output tokens over 2000 ms are 10.0 tokens per second', () {
    expect(formatStats(20, 2000), '20 tok · 10.0 tok/s');
  });

  test('unreported output tokens produce neither a count nor a rate', () {
    expect(formatStats(null, 2000), isEmpty);
  });

  test('missing or zero latency preserves the count without a rate', () {
    expect(formatStats(20, null), '20 tok');
    expect(formatStats(20, 0), '20 tok');
  });
}
