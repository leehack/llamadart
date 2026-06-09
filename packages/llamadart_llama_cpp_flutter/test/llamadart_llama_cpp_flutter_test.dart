import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_llama_cpp_flutter/llamadart_llama_cpp_flutter.dart';

void main() {
  test('declares llama.cpp runtime family', () {
    expect(llamadartLlamaCppFlutterRuntime, 'llama_cpp');
  });
}
