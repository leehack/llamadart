@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/src/core/models/chat/chat_message.dart';
import 'package:llamadart/src/core/models/chat/chat_role.dart';
import 'package:llamadart/src/core/models/chat/content_part.dart';
import 'package:llamadart/src/core/template/chat_template_engine.dart';
import 'package:llamadart/src/core/template/template_caps.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final Map<String, dynamic> _fixture =
    jsonDecode(
          File(
            'test/fixtures/template_message_json_upstream.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

List<LlamaChatMessage> _conversation(String name) {
  final spec = (_fixture['conversations'] as Map<String, dynamic>)[name];
  return <LlamaChatMessage>[
    for (final message in (spec as List).cast<Map<String, dynamic>>())
      LlamaChatMessage.withContent(
        role: LlamaChatRole.values.byName(message['role'] as String),
        content: <LlamaContentPart>[
          if (message['thinking'] != null)
            LlamaThinkingContent(message['thinking'] as String),
          if (message['text'] != null)
            LlamaTextContent(message['text'] as String),
          for (final call
              in (message['calls'] as List? ?? const <Object>[])
                  .cast<Map<String, dynamic>>())
            LlamaToolCallContent(
              id: call['id'] as String,
              name: call['name'] as String,
              arguments:
                  jsonDecode(call['raw'] as String) as Map<String, dynamic>,
              rawJson: call['raw'] as String,
            ),
          for (final result
              in (message['results'] as List? ?? const <Object>[])
                  .cast<Map<String, dynamic>>())
            LlamaToolResultContent(
              id: result['id'] as String,
              name: result['name'] as String,
              result: result['result'],
            ),
        ],
      ),
  ];
}

/// Masks the date that gpt-oss and Solar Open templates print with
/// `strftime_now`, which reads the wall clock.
String _withoutDate(Object? prompt) => (prompt as String).replaceAllMapped(
  RegExp(r'(Current date: |The current date is )\d{4}-\d{2}-\d{2}'),
  (match) => '${match[1]}<date>',
);

void main() {
  final cases = (_fixture['cases'] as List).cast<Map<String, dynamic>>();

  for (final entry in cases) {
    final template = entry['template'] as String;
    final conversation = entry['conversation'] as String;

    test('#${entry['issue']} ${p.basename(template)} renders $conversation '
        'as llama-server does', () {
      final source = File(template).readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        sha256.convert(utf8.encode(source)).toString(),
        entry['template_sha256'],
      );

      final result = ChatTemplateEngine.render(
        templateSource: source,
        messages: _conversation(conversation),
        metadata: const <String, String>{
          'tokenizer.ggml.bos_token': '',
          'tokenizer.ggml.eos_token': '</s>',
        },
      );

      expect(_withoutDate(result.prompt), _withoutDate(entry['prompt']));
    });
  }

  test('detects supports_object_arguments as llama-server reports it', () {
    final detected = <String, bool>{};
    final reported = <String, bool>{};
    for (final entry in cases) {
      final template = entry['template'] as String;
      detected[template] = TemplateCaps.detect(
        File(template).readAsStringSync(),
      ).supportsObjectArguments;
      reported[template] = entry['supports_object_arguments'] as bool;
    }

    expect(reported.values, containsAll(<bool>[true, false]));
    expect(detected, reported);
  });
}
