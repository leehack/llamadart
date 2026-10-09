@TestOn('vm')
@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 15))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/src/backends/litert_lm/litert_lm_bundle_template.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_cache.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_service.dart';
import 'package:llamadart/src/core/llama_logger.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

const _generationPrompt =
    "{%- if add_generation_prompt -%}{{ '<|im_start|>assistant\\n' }}"
    '{%- endif -%}';

/// ChatML templates that read message content as a string, keyed by how.
const _stringContentTemplates = {
  'interpolating':
      "{%- for message in messages -%}{{ '<|im_start|>' }}{{ message.role }}"
      "{{ '\\n' }}{{ message.content }}{{ '<|im_end|>\\n' }}{%- endfor -%}"
      '$_generationPrompt',
  'concatenating':
      "{%- for message in messages -%}{{ '<|im_start|>' + message.role + '\\n'"
      " + message.content + '<|im_end|>\\n' }}{%- endfor -%}"
      '$_generationPrompt',
  'string-only':
      '{%- for message in messages -%}'
      '{%- if message.content is string -%}{%- set text = message.content -%}'
      "{%- else -%}{%- set text = '' -%}{%- endif -%}"
      "{{ '<|im_start|>' + message.role + '\\n' + text + '<|im_end|>\\n' }}"
      '{%- endfor -%}'
      '$_generationPrompt',
};

/// A ChatML template that reads content parts and strings.
const _partsContentTemplate =
    "{%- for message in messages -%}{{ '<|im_start|>' + message.role + '\\n' }}"
    '{%- if message.content is string -%}{{ message.content }}{%- else -%}'
    "{%- for part in message.content -%}{%- if part.type == 'text' -%}"
    '{{ part.text }}{%- endif -%}{%- endfor -%}{%- endif -%}'
    "{{ '<|im_end|>\\n' }}{%- endfor -%}"
    '$_generationPrompt';

/// Writes every key the service or a caller can put on a message.
const _messageKeysTemplate =
    '{%- for message in messages -%}<{{ message.role }}'
    '|name={{ message.name }}|id={{ message.tool_call_id }}'
    '|reasoning={{ message.reasoning_content }}'
    '|custom={%- if message.custom -%}{{ message.custom.a }}{%- endif -%}'
    '|calls={%- for call in message.tool_calls or [] -%}'
    '{{ call.function.name }}({{ call.function.arguments.city }})'
    '{%- endfor -%}'
    '|content={%- if message.content is string -%}{{ message.content }}'
    '{%- else -%}{%- for part in message.content -%}{{ part.text }}'
    '{%- endfor -%}{%- endif -%}>\n'
    '{% endfor -%}';

const _userTurn = '<|im_start|>user\n';
const _assistantTurn = '<|im_end|>\n<|im_start|>assistant\n';

/// Records what the service asks of the real runtime.
class _RecordingClient extends LiteRtLmRuntimeClient {
  final List<String?> promptTemplates = <String?>[];
  final List<String> sentPrompts = <String>[];

  @override
  void createConversation({
    String? systemMessage,
    String? promptTemplate,
    List<Map<String, dynamic>>? messages,
    List<Map<String, dynamic>>? tools,
    Map<String, dynamic>? extraContext,
    double temperature = 0.8,
    int topK = 40,
    double topP = 0.95,
    int seed = 1,
    bool npuBackend = false,
    String? loraPath,
  }) {
    promptTemplates.add(promptTemplate);
    super.createConversation(
      systemMessage: systemMessage,
      promptTemplate: promptTemplate,
      messages: messages,
      tools: tools,
      extraContext: extraContext,
      temperature: temperature,
      topK: topK,
      topP: topP,
      seed: seed,
      npuBackend: npuBackend,
      loraPath: loraPath,
    );
  }

  @override
  Stream<String> generateMessageJson(
    String messageJson, {
    Map<String, dynamic>? extraContext,
    int? visualTokenBudget,
    int? maxOutputTokens,
  }) {
    try {
      sentPrompts.add(
        renderMessageToString(jsonDecode(messageJson) as Map<String, dynamic>),
      );
    } on StateError catch (error) {
      sentPrompts.add('render failed: ${error.message}');
    }
    return super.generateMessageJson(
      messageJson,
      extraContext: extraContext,
      visualTokenBudget: visualTokenBudget,
      maxOutputTokens: maxOutputTokens,
    );
  }
}

/// Copies the bundle at [model] to [directory] with [template], which the
/// bundle embeds, replaced by [replacement] padded to the same length.
String _bundleWithTemplate(
  String model,
  String template,
  String replacement,
  Directory directory,
) {
  final original = utf8.encode(template);
  final padding = original.length - utf8.encode(replacement).length;
  if (padding < 0) {
    fail('The bundle template is shorter than the replacement.');
  }
  // Spaces inside the first tag do not change what the template renders.
  final padded = replacement.replaceFirst('{%-', '{%-${' ' * padding}');

  final source = File(model).openSync();
  final Uint8List head;
  try {
    head = source.readSync(8 * 1024 * 1024);
  } finally {
    source.closeSync();
  }
  var offset = -1;
  for (var i = 0; i + original.length <= head.length && offset < 0; i++) {
    var matches = true;
    for (var j = 0; j < original.length && matches; j++) {
      matches = head[i + j] == original[j];
    }
    if (matches) offset = i;
  }
  expect(offset, isNonNegative, reason: 'template bytes in the bundle');

  final path = '${directory.path}/${File(model).uri.pathSegments.last}';
  // An APFS clone avoids a second copy of the weights.
  if (!Platform.isMacOS ||
      Process.runSync('cp', ['-c', model, path]).exitCode != 0) {
    File(model).copySync(path);
  }
  final copy = File(path).openSync(mode: FileMode.append);
  try {
    copy.setPositionSync(offset);
    copy.writeFromSync(utf8.encode(padded));
  } finally {
    copy.closeSync();
  }
  expect(readLiteRtLmBundleChatTemplate(path), padded);
  return path;
}

void main() {
  final model = Platform.environment['LITERT_LM_MODEL'];

  setUpAll(() {
    if (model == null || !File(model).existsSync()) {
      fail('Set LITERT_LM_MODEL to an existing .litertlm model.');
    }
  });

  group('the runtime', () {
    late LiteRtLmRuntimeClient client;

    setUpAll(() async {
      client = LiteRtLmRuntimeClient();
      await client.initialize(
        modelPath: model!,
        backend: 'cpu',
        maxTokens: 1024,
        cacheDir: liteRtLmNoCacheDirectory,
        speculativeDecoding: false,
      );
    });

    tearDownAll(() => client.dispose());

    String render(
      String? template, {
      String? systemMessage,
      List<Map<String, dynamic>>? messages,
      Map<String, dynamic> message = liteRtLmContentShapeProbeMessage,
    }) {
      client.createConversation(
        promptTemplate: template,
        systemMessage: systemMessage,
        messages: messages,
      );
      return client.renderMessageToString(message);
    }

    test('renders the bundle template through the adapter', () {
      final bundleTemplate = readLiteRtLmBundleChatTemplate(model!);
      final rendered = render(null);
      if (bundleTemplate == null) {
        // The runtime builds the template of a bundle that embeds none.
        expect(liteRtLmRendersProbeText(rendered), isTrue);
        return;
      }
      const history = [
        {'role': 'user', 'content': 'The code is cedar17.'},
        {'role': 'assistant', 'content': 'Understood.'},
      ];
      final seeded = render(
        null,
        systemMessage: 'Remember the code.',
        messages: history,
      );
      final adapted = render(
        liteRtLmTextContentAdapter(bundleTemplate),
        systemMessage: 'Remember the code.',
        messages: history,
      );

      // A template that reads content parts renders the same prompt either
      // way; one that interpolates a string differs only in each serialized
      // part list.
      expect(liteRtLmRendersProbeText(adapted), isTrue);
      expect(
        adapted,
        seeded.replaceAllMapped(
          RegExp(r'''\[\{(?:"type": "text", )?"text": "([^"]*)"[^\]]*\}\]'''),
          (match) => match[1]!,
        ),
      );
    });

    for (final MapEntry(key: shape, value: template)
        in _stringContentTemplates.entries) {
      test('renders text for a template $shape content only through the '
          'adapter', () {
        bool rendersText() {
          try {
            return liteRtLmRendersProbeText(render(template));
          } on StateError {
            return false;
          }
        }

        expect(rendersText(), isFalse);
        expect(
          render(liteRtLmTextContentAdapter(template)),
          '$_userTurn$liteRtLmContentShapeProbeText$_assistantTurn',
        );
      });
    }

    test('renders a template that reads content parts the same through the '
        'adapter', () {
      final rendered = render(_partsContentTemplate);

      expect(
        rendered,
        '$_userTurn$liteRtLmContentShapeProbeText$_assistantTurn',
      );
      expect(
        render(liteRtLmTextContentAdapter(_partsContentTemplate)),
        rendered,
      );
    });

    test('does not reach a template in the single-turn form', () {
      // The runtime gives such a template the message of a turn as `message`,
      // which the adapter does not rebind.
      const template =
          "{#- is_appending_to_prefill -#}{{ '<|im_start|>' }}"
          "{{ message.role }}{{ '\\n' }}{{ message.content }}";

      expect(
        render(template),
        allOf(
          startsWith('<|im_start|>user\n['),
          contains(liteRtLmContentShapeProbeText),
        ),
      );
      expect(
        liteRtLmRendersProbeText(render(liteRtLmTextContentAdapter(template))),
        isFalse,
      );
    });

    test('keeps every other message key through the adapter', () {
      const messages = [
        {'role': 'user', 'content': 'Weather?', 'name': 'bob'},
        {
          'role': 'assistant',
          'content': 'Checking.',
          'reasoning_content': 'needs a tool',
          'tool_calls': [
            {
              'type': 'function',
              'function': {
                'name': 'get_weather',
                'arguments': {'city': 'Paris'},
              },
            },
          ],
        },
        {
          'role': 'tool',
          'content': 'sunny',
          'name': 'get_weather',
          'tool_call_id': 'call_1',
        },
      ];
      const message = {
        'role': 'user',
        'content': 'Thanks',
        'custom': {'a': 'kept'},
      };
      final rendered = render(
        _messageKeysTemplate,
        messages: messages,
        message: message,
      );

      for (final value in [
        '<user|name=bob|',
        '|reasoning=needs a tool|',
        '|calls=get_weather(Paris)|content=Checking.>',
        '<tool|name=get_weather|id=call_1|',
        '|content=sunny>',
        '|custom=kept|calls=|content=Thanks>',
      ]) {
        expect(rendered, contains(value));
      }
      expect(
        render(
          liteRtLmTextContentAdapter(_messageKeysTemplate),
          messages: messages,
          message: message,
        ),
        rendered,
      );
    });

    test('keeps how a template handles the whitespace it starts with', () {
      for (final template in [
        '\n  start',
        '  start',
        '  {% if true %}X{% endif %}',
        '  {%- if true %}X{% endif %}',
        "  {{ 'X' }}",
        '\n{% if true %}\nX{% endif %}',
      ]) {
        expect(
          render(liteRtLmTextContentAdapter(template)),
          render(template),
          reason: template,
        );
      }
    });
  });

  group('the service', () {
    late Directory directory;
    final records = <LlamaLogRecord>[];

    setUp(() {
      directory = Directory.systemTemp.createTempSync('litert_bundle_e2e_');
      records.clear();
      LlamaLogger.instance.setLevel(LlamaLogLevel.warn);
      LlamaLogger.instance.setHandler(records.add);
    });

    tearDown(() {
      LlamaLogger.instance.setLevel(LlamaLogLevel.none);
      LlamaLogger.instance.setHandler(null);
      directory.deleteSync(recursive: true);
    });

    for (final MapEntry(key: shape, value: template)
        in _stringContentTemplates.entries) {
      test('answers with a bundle whose template is $shape content', () async {
        final bundleTemplate = readLiteRtLmBundleChatTemplate(model!);
        if (bundleTemplate == null) {
          markTestSkipped('The bundle embeds no template to replace.');
          return;
        }
        final path = _bundleWithTemplate(
          model,
          bundleTemplate,
          template,
          directory,
        );
        final embedded = readLiteRtLmBundleChatTemplate(path)!;
        final cache = Directory('${directory.path}/cache')..createSync();
        final client = _RecordingClient();
        final service = LiteRtLmService(clientFactory: () => client);
        final params = ModelParams(
          contextSize: 1024,
          liteRtLmBackend: LiteRtLmBackendPreference.cpu,
          liteRtLmCacheDir: cache.path,
        );
        try {
          final handle = await service.loadModel(path, params);
          final context = service.createContext(handle, params);
          for (var request = 0; request < 2; request++) {
            await service
                .generateChat(
                  context,
                  const [
                    LlamaChatMessage.fromText(
                      role: LlamaChatRole.user,
                      text: 'Hello',
                    ),
                  ],
                  const GenerationParams(maxTokens: 8, temp: 0, seed: 1),
                  enableThinking: false,
                )
                .drain<void>();
          }

          final adapter = liteRtLmTextContentAdapter(embedded);
          expect(client.promptTemplates, [null, adapter, adapter, adapter]);
          expect(client.sentPrompts, [
            '${_userTurn}Hello$_assistantTurn',
            '${_userTurn}Hello$_assistantTurn',
          ]);
          expect(
            records.where((record) => record.message.contains('adapt')),
            isEmpty,
          );
        } finally {
          service.dispose();
        }
      });
    }
  });
}
