@TestOn('vm')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/exit_teardown_api.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:test/test.dart';

import '../../../support/fake_mtmd.dart';
import '../../../support/synthetic_embedding_gguf.dart';

const _params = ModelParams(gpuLayers: 0, contextSize: 64);

final Map<String, dynamic> _fixture =
    jsonDecode(
          File(
            'test/fixtures/media_marker_render_upstream.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

// Runs the real llama.cpp runtime on the CPU with a fake projector and reads
// the prompt the service hands to mtmd_tokenize.
void main() {
  late Directory dir;
  late LlamaCppService service;
  late FakeMtmd fake;
  late int context;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('llamadart_media_prompt_');
    addTearDown(() => dir.deleteSync(recursive: true));
    service = LlamaCppService(objectCalls: LlamaCppObjectCalls.upstream)
      ..initializeBackend();
    final model = service.loadModel(
      writeSyntheticLlamaGguf('${dir.path}/model.gguf').path,
      _params,
    );
    fake = FakeMtmd.install(
      service,
      tokens: service.tokenize(model, 'ab', true),
    );
    addTearDown(fake.dispose);
    addTearDown(service.dispose);
    context = service.createContext(model, _params);
    final projectorPath = '${dir.path}/mmproj.gguf';
    File(projectorPath).writeAsStringSync('GGUF');
    service.createMultimodalContext(model, projectorPath);
  });

  Future<String> promptAtMtmd(
    String prompt,
    List<LlamaContentPart> parts,
  ) async {
    final cancel = calloc<Int8>();
    try {
      await service
          .generate(
            context,
            prompt,
            const GenerationParams(maxTokens: 1, temp: 0, topK: 1, seed: 1),
            cancel.address,
            parts: parts,
          )
          .drain<void>();
    } finally {
      calloc.free(cancel);
    }
    return fake.prompts.single;
  }

  for (final conversation in ['image_then_text', 'two_images_then_text']) {
    test('hands mtmd the Qwen3.5 $conversation prompt llama-server '
        'renders', () async {
      final upstream = (_fixture['cases'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (entry) =>
                entry['conversation'] == conversation &&
                (entry['template'] as String).endsWith('Qwen3_5-0_8B.jinja'),
          );
      final image = LlamaImageContent(
        bytes: base64Decode(_fixture['image_png_base64'] as String),
      );
      final parts = <LlamaContentPart>[
        for (final part
            in ((_fixture['conversations']
                            as Map<String, dynamic>)[conversation]
                        as List)
                    .single['parts']
                as List)
          part['image'] == true
              ? image
              : LlamaTextContent(part['text'] as String),
      ];
      final rendered = ChatTemplateEngine.render(
        templateSource: File(upstream['template'] as String).readAsStringSync(),
        messages: [
          LlamaChatMessage.withContent(
            role: LlamaChatRole.user,
            content: parts,
          ),
        ],
        metadata: {
          'tokenizer.ggml.bos_token': '',
          'tokenizer.ggml.eos_token': upstream['eos_token'] as String,
        },
      );

      expect(
        await promptAtMtmd(
          rendered.prompt,
          parts.whereType<LlamaImageContent>().toList(),
        ),
        upstream['prompt'],
      );
    });
  }
}
