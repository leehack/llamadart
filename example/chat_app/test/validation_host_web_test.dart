@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/validation/host.dart';
import 'package:llamadart_validation/llamadart_validation.dart';

void main() {
  test('the Web host rejects decision profiles off WebGPU before any '
      'download', () async {
    for (final backend in ['cpu', 'metal']) {
      final id = 'decision-gguf-$backend';
      final profile = ValidationProfile.fromJson(<String, dynamic>{
        'schema_version': 1,
        'id': id,
        'runtime': 'gguf',
        'backend': backend,
        'model': {
          'id': 'laya-q8_0',
          'kind': 'decision',
          'filename': 'laya-Q8_0.gguf',
          'revision': 'ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c',
          'url':
              'https://huggingface.co/fr0stbit3/laya-gguf/resolve/ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c/laya-Q8_0.gguf',
          'sha256':
              '76a5787a9c853d04db4ff214ae31fe2bd51aa15c8bef2fc886a3493f3c136dae',
          'bytes': 421407968,
          'quantization': 'Q8_0',
        },
        'decision': {
          'head': {
            'filename': 'laya-head.safetensors',
            'revision': 'ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c',
            'url':
                'https://huggingface.co/fr0stbit3/laya-gguf/resolve/ce2afdc0a8766af56a29a22dcf4a781e1f5c7d3c/laya-head.safetensors',
            'sha256':
                'c1ec428e034614c9373ebcf3fdc255d8eafcc04be9b2f0c2ffeef92bb1361b83',
            'bytes': 106052840,
          },
        },
        'selection': 'quick',
        'context_size': 512,
        'threads': 4,
      });
      await expectLater(
        createValidationHost().prepare(profile),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('decision-gguf-webgpu'),
          ),
        ),
        reason: id,
      );
    }
  });
}
