@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dinja/dinja.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_bundle_template.dart';
import 'package:test/test.dart';

const _llmMetadata = 5;
const _tokenizer = 6;

/// A bundle template that reads content as a string, as bundles built for
/// LiteRT-LM runtimes before v0.18 do.
const _stringContentTemplate =
    '{%- for message in messages -%}\n'
    '<|im_start|>\n'
    '{{ message.content }}<|im_end|>\n'
    '{% endfor -%}';

Uint8List _protoField(int field, List<int> value) =>
    Uint8List.fromList([(field << 3) | 2, ..._varint(value.length), ...value]);

List<int> _varint(int value) {
  final bytes = <int>[];
  var rest = value;
  while (rest >= 0x80) {
    bytes.add((rest & 0x7f) | 0x80);
    rest >>= 7;
  }
  return bytes..add(rest);
}

/// The `LlmMetadata` protobuf of a bundle whose template is [template].
Uint8List _metadata(String? template) => Uint8List.fromList([
  // start_token, a nested message, then max_num_tokens, a varint.
  ..._protoField(1, [0x0a, 0x01, 0x41]),
  0x28, 0x80, 0x20,
  if (template != null) ..._protoField(7, utf8.encode(template)),
]);

/// A `.litertlm` file with [sections] laid out after a FlatBuffers header.
Uint8List _bundle(List<({int type, Uint8List data})> sections) {
  const headerStart = 32;
  // Root offset, root vtable and table, section-metadata vtable and table,
  // then the vector of section objects.
  final objectsStart = 44 + 4 * sections.length;
  final headerEnd = headerStart + objectsStart + 36 * sections.length;
  var dataOffset = headerEnd + 16;

  final header = ByteData(headerEnd - headerStart);
  header.setUint32(0, 12, Endian.little);
  header.setUint16(4, 8, Endian.little);
  header.setUint16(6, 12, Endian.little);
  header.setUint16(10, 8, Endian.little);
  header.setInt32(12, 8, Endian.little);
  header.setUint32(20, 12, Endian.little);
  header.setUint16(24, 6, Endian.little);
  header.setUint16(26, 8, Endian.little);
  header.setUint16(28, 4, Endian.little);
  header.setInt32(32, 8, Endian.little);
  header.setUint32(36, 4, Endian.little);
  header.setUint32(40, sections.length, Endian.little);

  final body = BytesBuilder();
  for (var i = 0; i < sections.length; i++) {
    final vtable = objectsStart + 36 * i;
    final table = vtable + 12;
    final slot = 44 + 4 * i;
    header.setUint32(slot, table - slot, Endian.little);
    header.setUint16(vtable, 12, Endian.little);
    header.setUint16(vtable + 2, 24, Endian.little);
    header.setUint16(vtable + 6, 8, Endian.little);
    header.setUint16(vtable + 8, 16, Endian.little);
    header.setUint16(vtable + 10, 4, Endian.little);
    header.setInt32(table, 12, Endian.little);
    header.setUint8(table + 4, sections[i].type);
    header.setUint64(table + 8, dataOffset, Endian.little);
    dataOffset += sections[i].data.length;
    header.setUint64(table + 16, dataOffset, Endian.little);
    body.add(sections[i].data);
  }

  final prefix = ByteData(headerStart);
  prefix.buffer.asUint8List().setAll(0, ascii.encode('LITERTLM'));
  prefix.setUint32(8, 1, Endian.little);
  prefix.setUint32(12, 7, Endian.little);
  prefix.setUint64(24, headerEnd, Endian.little);
  return Uint8List.fromList([
    ...prefix.buffer.asUint8List(),
    ...header.buffer.asUint8List(),
    ...List<int>.filled(16, 0),
    ...body.takeBytes(),
  ]);
}

String _render(String template, Object? content) => Template(template).render({
  'messages': [
    {'role': 'user', 'content': content},
  ],
});

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp(
      'llamadart_litert_bundle_template_test_',
    );
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  String write(List<int> bytes) {
    final file = File('${tempDir.path}/model.litertlm')
      ..writeAsBytesSync(bytes);
    return file.path;
  }

  group('readLiteRtLmBundleChatTemplate', () {
    test('reads the template of the LlmMetadata section', () {
      const template = '{{ messages[0].content }} 안녕';
      final path = write(
        _bundle([
          (type: _tokenizer, data: Uint8List.fromList([1, 2, 3])),
          (type: _llmMetadata, data: _metadata(template)),
        ]),
      );

      expect(readLiteRtLmBundleChatTemplate(path), template);
    });

    test('is null for a bundle that declares no template', () {
      expect(
        readLiteRtLmBundleChatTemplate(
          write(_bundle([(type: _llmMetadata, data: _metadata(null))])),
        ),
        isNull,
      );
      expect(
        readLiteRtLmBundleChatTemplate(
          write(
            _bundle([
              (type: _tokenizer, data: Uint8List.fromList([1, 2, 3])),
            ]),
          ),
        ),
        isNull,
      );
    });

    test('is null for a file it cannot read as a bundle', () {
      final bundle = _bundle([
        (type: _llmMetadata, data: _metadata('{{ messages }}')),
      ]);
      final truncatedMetadata = bundle.sublist(0, bundle.length - 4);
      final truncatedHeader = bundle.sublist(0, 48);
      final brokenTable = Uint8List.fromList(bundle)
        ..buffer.asByteData().setInt32(32 + 12, 1 << 20, Endian.little);
      final brokenMetadata = _bundle([
        (type: _llmMetadata, data: Uint8List.fromList([0x3a, 0x7f, 0x41])),
      ]);

      expect(readLiteRtLmBundleChatTemplate(write(truncatedMetadata)), isNull);
      expect(readLiteRtLmBundleChatTemplate(write(truncatedHeader)), isNull);
      expect(readLiteRtLmBundleChatTemplate(write(brokenTable)), isNull);
      expect(readLiteRtLmBundleChatTemplate(write(brokenMetadata)), isNull);
      expect(
        readLiteRtLmBundleChatTemplate(write(utf8.encode('fake model'))),
        isNull,
      );
      expect(
        readLiteRtLmBundleChatTemplate('${tempDir.path}/missing.litertlm'),
        isNull,
      );
    });
  });

  group('liteRtLmRendersTextPartsAsList', () {
    const text = liteRtLmContentShapeProbeText;

    test('recognizes a serialized text part in either key order', () {
      for (final rendered in [
        '<|im_start|>user\n[{"text": "$text", "type": "text"}]<|im_end|>',
        '<|im_start|>user\n[{"type": "text", "text": "$text"}]<|im_end|>',
        "[{'type': 'text', 'text': '$text'}]",
      ]) {
        expect(liteRtLmRendersTextPartsAsList(rendered), isTrue);
      }
    });

    test('accepts the text itself', () {
      expect(
        liteRtLmRendersTextPartsAsList(
          '<|im_start|>user\n$text<|im_end|>\n<|im_start|>assistant\n',
        ),
        isFalse,
      );
      expect(liteRtLmRendersTextPartsAsList(''), isFalse);
    });
  });

  group('liteRtLmTextContentAdapter', () {
    final adapted = liteRtLmTextContentAdapter(_stringContentTemplate);
    const parts = [
      {'type': 'text', 'text': 'Hello "there"'},
    ];

    test('gives a string template the text of a single text part', () {
      expect(
        liteRtLmRendersTextPartsAsList(
          _render(
            _stringContentTemplate,
            liteRtLmContentShapeProbeMessage['content'],
          ),
        ),
        isTrue,
      );
      expect(
        _render(adapted, parts),
        '<|im_start|>\nHello "there"<|im_end|>\n',
      );
      expect(
        _render(adapted, 'Hello "there"'),
        _render(_stringContentTemplate, 'Hello "there"'),
      );
    });

    test('leaves other content as the runtime passed it', () {
      for (final content in <Object?>[
        [
          {'type': 'text', 'text': 'one'},
          {'type': 'text', 'text': 'two'},
        ],
        [
          {'type': 'tool_response', 'name': 'weather', 'response': 'sunny'},
        ],
        [
          {'type': 'image'},
        ],
        const <Object?>[],
      ]) {
        expect(
          _render(adapted, content),
          _render(_stringContentTemplate, content),
        );
      }
      expect(
        Template(adapted).render({
          'messages': [
            {'role': 'assistant'},
          ],
        }),
        Template(_stringContentTemplate).render({
          'messages': [
            {'role': 'assistant'},
          ],
        }),
      );
    });

    test('keeps the text a template starts with', () {
      expect(
        Template(
          liteRtLmTextContentAdapter('\n  start'),
        ).render({'messages': const <Object?>[]}),
        '\n  start',
      );
    });
  });
}
