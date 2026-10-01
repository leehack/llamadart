@TestOn('vm')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

const String _modelPathEnv = 'LLAMADART_LLAMA_CPP_TEMPLATE_MODEL_PATH';
const String _defaultModelFileName = 'Qwen3.5-0.8B-Q4_K_M.gguf';

void main() {
  group('llama.cpp direct chat-template backend', () {
    late String modelPath;

    setUpAll(() {
      final resolved = _resolveModelPath();
      if (resolved == null) {
        markTestSkipped(
          'Set $_modelPathEnv or place $_defaultModelFileName in the default '
          'llamadart cache to run llama.cpp chat-template backend E2E.',
        );
      }
      modelPath = resolved ?? '';
    });

    test(
      'renders default, custom, and unsupported multimodal templates',
      () async {
        if (modelPath.isEmpty) {
          return;
        }

        final backend = LlamaBackend();
        int? modelHandle;
        try {
          await backend.setLogLevel(LlamaLogLevel.warn);
          modelHandle = await backend.modelLoad(
            modelPath,
            const ModelParams(
              contextSize: 512,
              preferredBackend: GpuBackend.cpu,
              gpuLayers: 0,
              numberOfThreads: 2,
              numberOfThreadsBatch: 2,
            ),
          );

          final rendered = await backend.applyChatTemplate(modelHandle, const [
            {'role': 'user', 'content': 'Say hello.'},
          ]);
          expect(rendered, contains('Say hello.'));
          expect(rendered, isNot(equals('Say hello.')));

          final custom = await backend.applyChatTemplate(modelHandle, const [
            {'role': 'user', 'content': 'Say hello.'},
          ], customTemplate: '{{ "CUSTOM:" ~ messages[0]["content"] }}');
          expect(custom, contains('CUSTOM:Say hello.'));

          await backend.modelFree(modelHandle);
          modelHandle = null;
          modelHandle = await backend.modelLoad(
            modelPath,
            const ModelParams(
              contextSize: 512,
              preferredBackend: GpuBackend.cpu,
              gpuLayers: 0,
              numberOfThreads: 2,
              numberOfThreadsBatch: 2,
              chatTemplate: '{{ "MODELPARAM:" ~ messages[0]["content"] }}',
            ),
          );

          final modelParamRendered = await backend.applyChatTemplate(
            modelHandle,
            const [
              {'role': 'user', 'content': 'Use the configured template.'},
            ],
          );
          expect(
            modelParamRendered,
            contains('MODELPARAM:Use the configured template.'),
          );

          final perCallCustom = await backend.applyChatTemplate(
            modelHandle,
            const [
              {'role': 'user', 'content': 'Use the per-call template.'},
            ],
            customTemplate: '{{ "PERCALL:" ~ messages[0]["content"] }}',
          );
          expect(perCallCustom, contains('PERCALL:Use the per-call template.'));
          expect(perCallCustom, isNot(contains('MODELPARAM:')));

          await backend.modelFree(modelHandle);
          modelHandle = null;
          modelHandle = await backend.modelLoad(
            modelPath,
            const ModelParams(
              contextSize: 512,
              preferredBackend: GpuBackend.cpu,
              gpuLayers: 0,
              numberOfThreads: 2,
              numberOfThreadsBatch: 2,
              chatTemplate: '',
            ),
          );

          final emptyTemplateRendered = await backend.applyChatTemplate(
            modelHandle,
            const [
              {'role': 'user', 'content': 'Say hello.'},
            ],
          );
          expect(emptyTemplateRendered, rendered);

          await expectLater(
            backend.applyChatTemplate(modelHandle, const [
              {
                'role': 'user',
                'content': [
                  {
                    'type': 'image_url',
                    'image_url': {'url': 'file:///tmp/image.png'},
                  },
                  {'type': 'text', 'text': 'Describe it.'},
                ],
              },
            ]),
            throwsA(
              isA<LlamaUnsupportedException>().having(
                (error) => error.message,
                'message',
                contains('multimodal chat-template content'),
              ),
            ),
          );
        } finally {
          if (modelHandle != null) {
            await backend.modelFree(modelHandle);
          }
          await backend.dispose();
        }
      },
    );

    test(
      'LlamaEngine renders, generates and parses with ModelParams.chatTemplate',
      () async {
        if (modelPath.isEmpty) {
          return;
        }

        final engine = LlamaEngine(LlamaBackend());
        final tools = [
          ToolDefinition(
            name: 'get_weather',
            description: 'Get the current weather for a city.',
            parameters: [ToolParam.string('city', required: true)],
            handler: (_) async => 'sunny',
          ),
        ];
        const messages = [
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: 'What is the weather in Seoul?',
          ),
        ];
        try {
          await engine.setNativeLogLevel(LlamaLogLevel.warn);
          await engine.loadModel(
            modelPath,
            modelParams: const ModelParams(
              contextSize: 1024,
              preferredBackend: GpuBackend.cpu,
              gpuLayers: 0,
              numberOfThreads: 2,
              numberOfThreadsBatch: 2,
              chatTemplate: _hermesOverrideTemplate,
            ),
          );

          final plain = await engine.chatTemplate(messages);
          expect(
            plain.prompt,
            '<|im_start|>user\nWhat is the weather in Seoul?<|im_end|>\n'
            '<|im_start|>assistant\n',
          );

          final withTools = await engine.chatTemplate(messages, tools: tools);
          expect(withTools.format, ChatFormat.hermes.index);
          expect(withTools.prompt, startsWith('<|im_start|>system\n# Tools'));

          final chunks = await engine
              .create(
                messages,
                params: const GenerationParams(maxTokens: 64, temp: 0, seed: 1),
                tools: tools,
                toolChoice: ToolChoice.required,
                enableThinking: false,
              )
              .toList();
          final toolCalls = chunks
              .expand((chunk) => chunk.choices.first.delta.toolCalls ?? [])
              .toList();
          expect(chunks.last.choices.first.finishReason, 'tool_calls');
          expect(toolCalls, hasLength(1));
          expect(toolCalls.single.function?.name, 'get_weather');
        } finally {
          await engine.dispose();
        }
      },
    );
  });
}

const String _hermesOverrideTemplate = '''
{%- if tools %}<|im_start|>system
# Tools

<tools>
{%- for tool in tools %}
{{ tool | tojson }}
{%- endfor %}
</tools>

For each function call, return a json object with function name and arguments within <tool_call></tool_call> XML tags:
<tool_call>
{"name": <function-name>, "arguments": <args-json-object>}
</tool_call><|im_end|>
{% endif %}
{%- for message in messages %}<|im_start|>{{ message.role }}
{{ message.content }}<|im_end|>
{% endfor %}
{%- if add_generation_prompt %}<|im_start|>assistant
{% endif %}''';

String? _resolveModelPath() {
  final explicit = Platform.environment[_modelPathEnv];
  if (explicit != null && explicit.isNotEmpty) {
    if (File(explicit).existsSync()) {
      return explicit;
    }
    throw StateError('$_modelPathEnv does not exist: $explicit');
  }

  final candidates = <String>[
    path.join(Directory.current.path, 'models', _defaultModelFileName),
    if (Platform.environment['HOME'] case final home?)
      path.join(
        home,
        'Library',
        'Caches',
        'llamadart',
        'models',
        _defaultModelFileName,
      ),
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) {
      return candidate;
    }
  }
  return null;
}
