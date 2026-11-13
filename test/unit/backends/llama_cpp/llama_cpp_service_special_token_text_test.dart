@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

import '../../../support/synthetic_embedding_gguf.dart';

const _params = ModelParams(
  numberOfThreads: 2,
  numberOfThreadsBatch: 2,
  gpuLayers: 0,
  contextSize: 64,
);

const _template = "{{ bos_token }}{{ messages[0]['content'] }}{{ eos_token }}";

// The synthetic vocabulary is `<unk>`, `<s>`, `</s>` and 256 byte tokens;
// llama.cpp defaults its BOS to 1 and its EOS to 2.
void main() {
  late Directory dir;
  late LlamaCppService service;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_special_token_');
    addTearDown(() => dir.deleteSync(recursive: true));
    service = LlamaCppService(objectCalls: LlamaCppObjectCalls.upstream)
      ..initializeBackend();
    addTearDown(service.dispose);
  });

  String prompt(int model) => service.applyChatTemplate(model, [
    {'role': 'user', 'content': 'hi'},
  ], customTemplate: _template);

  test('reports the vocabulary BOS and EOS text without GGUF id keys', () {
    final model = service.loadModel(
      writeSyntheticLlamaGguf('${dir.path}/model.gguf').path,
      _params,
    );

    final metadata = service.getMetadata(model);
    expect(metadata, isNot(contains('tokenizer.ggml.bos_token_id')));
    expect(metadata['tokenizer.ggml.bos_token'], '<s>');
    expect(metadata['tokenizer.ggml.eos_token'], '</s>');
  });

  test('renders a template with the BOS and EOS the GGUF selects', () {
    final model = service.loadModel(
      writeSyntheticLlamaGguf(
        '${dir.path}/model.gguf',
        eosTokenId: 1,
        uint32Metadata: const {'tokenizer.ggml.bos_token_id': 2},
      ).path,
      _params,
    );

    final metadata = service.getMetadata(model);
    expect(metadata['tokenizer.ggml.bos_token'], '</s>');
    expect(metadata['tokenizer.ggml.eos_token'], '<s>');

    final rendered = prompt(model);
    expect(rendered, '</s>hi<s>');
    final tokens = service.tokenize(model, rendered, true);
    expect(tokens.first, 2);
    expect(tokens.last, 1);
    expect(tokens.where((token) => token == 1 || token == 2), [
      2,
      1,
    ], reason: 'the rendered BOS is the only BOS');
  });

  test('reports the vocabulary text over a GGUF string under the same key', () {
    final model = service.loadModel(
      writeSyntheticLlamaGguf(
        '${dir.path}/model.gguf',
        stringMetadata: const {'tokenizer.ggml.bos_token': '<file-bos>'},
      ).path,
      _params,
    );

    expect(service.getMetadata(model)['tokenizer.ggml.bos_token'], '<s>');
    expect(prompt(model), '<s>hi</s>');
  });
}
