@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/core/llama_logger.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/chat_template_result.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/tools/tool_definition.dart';
import 'package:llamadart/src/core/models/tools/tool_param.dart';
import 'package:llamadart/src/core/template/chat_format.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/template_caps_cache.dart';
import 'package:test/test.dart';

const List<LlamaChatMessage> _conversation = <LlamaChatMessage>[
  LlamaChatMessage.fromText(
    role: LlamaChatRole.user,
    text: 'Weather in Paris?',
  ),
  LlamaChatMessage.withContent(
    role: LlamaChatRole.assistant,
    content: <LlamaContentPart>[
      LlamaToolCallContent(
        id: 'call00001',
        name: 'get_weather',
        arguments: <String, dynamic>{'city': 'Paris'},
        rawJson: '{"city":"Paris"}',
      ),
    ],
  ),
  LlamaChatMessage.withContent(
    role: LlamaChatRole.tool,
    content: <LlamaContentPart>[
      LlamaToolResultContent(
        id: 'call00001',
        name: 'get_weather',
        result: 'sunny',
      ),
    ],
  ),
  LlamaChatMessage.fromText(
    role: LlamaChatRole.assistant,
    text: 'It is sunny.',
  ),
  LlamaChatMessage.fromText(role: LlamaChatRole.user, text: 'And Rome?'),
];

LlamaChatTemplateResult _render(String fixture, {required bool parallel}) {
  return ChatTemplateEngine.render(
    templateSource: File('test/fixtures/templates/$fixture').readAsStringSync(),
    messages: _conversation,
    metadata: const <String, String>{},
    tools: <ToolDefinition>[
      ToolDefinition(
        name: 'get_weather',
        description: 'Get weather',
        parameters: <ToolParam>[ToolParam.string('city')],
        handler: _noopHandler,
      ),
    ],
    parallelToolCalls: parallel,
    now: DateTime(2026, 1, 2, 12),
  );
}

void main() {
  late List<String> messages;

  setUp(() {
    TemplateCapsCache.shared.clear();
    messages = <String>[];
    LlamaLogger.instance.setLevel(LlamaLogLevel.debug);
    LlamaLogger.instance.setHandler((record) => messages.add(record.message));
  });

  tearDown(() {
    TemplateCapsCache.shared.clear();
    LlamaLogger.instance.setHandler(null);
    LlamaLogger.instance.setLevel(LlamaLogLevel.none);
  });

  test('Llama 3.2 renders a tool-call conversation', () {
    final result = _render('Llama-3_2-3B-Instruct.jinja', parallel: true);

    expect(result.format, ChatFormat.llama3.index);
    expect(result.prompt, contains('"name": "get_weather"'));
    expect(
      result.prompt,
      contains(
        'Weather in Paris?<|eot_id|>'
        '<|start_header_id|>assistant<|end_header_id|>\n\n'
        '{"name": "get_weather", "parameters": {"city":"Paris"}}<|eot_id|>'
        '<|start_header_id|>ipython<|end_header_id|>\n\n'
        '"sunny"<|eot_id|>'
        '<|start_header_id|>assistant<|end_header_id|>\n\n'
        'It is sunny.<|eot_id|>'
        '<|start_header_id|>user<|end_header_id|>\n\n'
        'And Rome?<|eot_id|>'
        '<|start_header_id|>assistant<|end_header_id|>\n\n',
      ),
    );
    expect(result.grammar, isNotNull);
    expect(
      messages,
      contains(contains('ChatTemplateEngine: Disabling parallelToolCalls')),
    );
    expect(
      messages,
      isNot(contains(contains('does not advertise tool definitions'))),
    );
  });

  test('Ministral 3 renders a tool-call conversation', () {
    final result = _render('Ministral-3-3B-Reasoning.jinja', parallel: true);

    expect(result.format, ChatFormat.ministral.index);
    expect(
      result.prompt,
      contains(
        '[AVAILABLE_TOOLS][{"type":"function","function":'
        '{"name":"get_weather","description":"Get weather","parameters":'
        '{"type":"object","properties":{"city":{"type":"string"}}}}}]'
        '[/AVAILABLE_TOOLS]'
        '[INST]Weather in Paris?[/INST]'
        '[TOOL_CALLS]get_weather[ARGS]{"city":"Paris"}</s>'
        '[TOOL_RESULTS]sunny[/TOOL_RESULTS]'
        'It is sunny.</s>'
        '[INST]And Rome?[/INST]',
      ),
    );
    expect(result.grammar, isNotNull);
    expect(
      messages,
      isNot(
        contains(contains('ChatTemplateEngine: Disabling parallelToolCalls')),
      ),
    );
    expect(
      messages,
      isNot(contains(contains('does not advertise tool definitions'))),
    );
  });

  test('Ministral 3 allows one tool call unless parallel calls are on', () {
    final single = _render('Ministral-3-3B-Reasoning.jinja', parallel: false);
    final parallel = _render('Ministral-3-3B-Reasoning.jinja', parallel: true);

    expect(single.prompt, parallel.prompt);
    expect(single.parser, isNot(parallel.parser));
  });
}

Future<Object?> _noopHandler(_) async {
  return 'ok';
}
