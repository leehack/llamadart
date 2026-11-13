@TestOn('vm')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

final Map<String, dynamic> _fixture =
    jsonDecode(
          File(
            'test/fixtures/bos_eos_prompt_tokens_upstream.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

void main() {
  final models = Platform.environment['LLAMADART_TEST_MODELS_DIR'];
  final scenarios = _fixture['scenarios'] as Map<String, dynamic>;

  for (final model
      in (_fixture['models'] as List).cast<Map<String, dynamic>>()) {
    test('${model['model']} prompts tokenize as llama-server does', () async {
      final file = File(
        path.join(models ?? 'models', model['model'] as String),
      );
      if (!file.existsSync()) {
        markTestSkipped('Requires local ${model['model']} weights');
        return;
      }
      expect(
        '${await sha256.bind(file.openRead()).first}',
        model['model_sha256'],
      );
      final engine = LlamaEngine(LlamaBackend());
      addTearDown(engine.dispose);
      await engine.loadModel(
        file.path,
        modelParams: const ModelParams(
          contextSize: 512,
          gpuLayers: 0,
          numberOfThreads: 2,
          numberOfThreadsBatch: 2,
        ),
      );

      final metadata = await engine.getMetadata();
      expect(metadata['tokenizer.ggml.bos_token'], model['bos_token']);
      expect(metadata['tokenizer.ggml.eos_token'], model['eos_token']);

      final cases = model['cases'] as Map<String, dynamic>;
      for (final MapEntry(key: name, value: upstream) in cases.entries) {
        final rendered = await engine.chatTemplate([
          for (final message
              in (scenarios[name] as List).cast<Map<String, dynamic>>())
            LlamaChatMessage.fromText(
              role: LlamaChatRole.values.byName(message['role'] as String),
              text: message['content'] as String,
            ),
        ]);
        expect(
          await engine.tokenize(rendered.prompt),
          (upstream as Map<String, dynamic>)['tokens'],
          reason: name,
        );
      }
    });
  }
}
