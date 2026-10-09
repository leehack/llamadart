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
            'test/fixtures/media_marker_render_upstream.json',
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
          for (final part
              in (message['parts'] as List).cast<Map<String, dynamic>>())
            if (part['image'] == true)
              LlamaImageContent(
                bytes: base64Decode(_fixture['image_png_base64'] as String),
              )
            else if (part['audio'] == true)
              LlamaAudioContent(
                bytes: base64Decode(_fixture['audio_wav_base64'] as String),
              )
            else
              LlamaTextContent(part['text'] as String),
        ],
      ),
  ];
}

void main() {
  final cases = (_fixture['cases'] as List).cast<Map<String, dynamic>>();

  for (final entry in cases) {
    final template = entry['template'] as String;
    final conversation = entry['conversation'] as String;

    test('${p.basename(template)} renders $conversation as llama-server '
        'does', () {
      final source = File(template).readAsStringSync().replaceAll('\r\n', '\n');
      expect(
        sha256.convert(utf8.encode(source)).toString(),
        entry['template_sha256'],
      );

      final result = ChatTemplateEngine.render(
        templateSource: source,
        messages: _conversation(conversation),
        metadata: <String, String>{
          'tokenizer.ggml.bos_token': '',
          'tokenizer.ggml.eos_token': entry['eos_token'] as String,
        },
        mediaMarker: entry['media_marker'] as String,
      );

      expect(result.prompt, entry['prompt']);
    });
  }

  test('covers templates that read part lists with and without string '
      'content, as llama-server reports them', () {
    final detected = <String, List<bool>>{};
    final reported = <String, List<bool>>{};
    for (final entry in cases) {
      final template = entry['template'] as String;
      final caps = TemplateCaps.detect(File(template).readAsStringSync());
      detected[template] = [
        caps.supportsStringContent,
        caps.supportsTypedContent,
      ];
      reported[template] = [
        entry['supports_string_content'] as bool,
        entry['supports_typed_content'] as bool,
      ];
    }

    expect(
      reported.values,
      containsAll(<List<bool>>[
        [true, true],
        [false, true],
      ]),
    );
    expect(detected, reported);
  });
}
