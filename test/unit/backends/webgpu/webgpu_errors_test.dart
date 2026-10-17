@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/webgpu/webgpu_errors.dart';
import 'package:test/test.dart';

void main() {
  test('preserves typed unsupported errors', () {
    final error = LlamaUnsupportedException('unsupported model');
    expect(webGpuBridgeRequestError(error), same(error));
  });

  test('leaves unknown codes, names and non-JS errors to the operation', () {
    for (final error in <Object>[
      StateError('invalid argument'),
      'TypeError: invalid argument',
      JSObject()..setProperty('code'.toJS, 'INVALID_EMBEDDING_INPUT'.toJS),
      JSObject()..setProperty('name'.toJS, 42.toJS),
    ]) {
      expect(webGpuBridgeRequestError(error), isNull);
    }
  });

  test('redacts argument diagnostics', () {
    final error = JSObject()
      ..setProperty('name'.toJS, 'RangeError'.toJS)
      ..setProperty(
        'message'.toJS,
        'Rejected https://example.com/model?token=secret'.toJS,
      );
    expect(webGpuBridgeRequestError(error)!.message, isNot(contains('secret')));
  });

  test('worker fallback recognizes pinned validators only', () {
    for (final message in <String>[
      'CompletionOptions.minP must be a finite number from 0 to 1; got 2.',
      'CompletionOptions.presencePenalty must be a finite number; got NaN.',
      'CompletionOptions.speculativeDecoding.ngramSizeN must be an integer from 1 to 65535; got 99999.',
      'LoRA adapter scale must be a finite number, got NaN.',
      'LoRA adapter scale 1e40 is outside the 32-bit float range.',
    ]) {
      final error = JSObject()
        ..setProperty('name'.toJS, 'Error'.toJS)
        ..setProperty('message'.toJS, message.toJS);
      expect(
        webGpuBridgeRequestError(error),
        isA<LlamaArgumentException>(),
        reason: message,
      );
      error.setProperty('message'.toJS, 'GPU dispatch failed: $message'.toJS);
      expect(webGpuBridgeRequestError(error), isNull);
      error.setProperty('message'.toJS, message.toJS);
      error.setProperty('name'.toJS, 'RuntimeError'.toJS);
      expect(webGpuBridgeRequestError(error), isNull);
    }
  });
}
