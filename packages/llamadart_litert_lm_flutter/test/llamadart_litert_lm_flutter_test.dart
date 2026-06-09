import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_litert_lm_flutter/llamadart_litert_lm_flutter.dart';

void main() {
  test('declares LiteRT-LM runtime family', () {
    expect(llamadartLiteRtLmFlutterRuntime, 'litert_lm');
  });
}
