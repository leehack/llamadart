import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int _maxHeaderBytes = 16 * 1024 * 1024;
const int _maxMetadataBytes = 16 * 1024 * 1024;

// `AnySectionDataType.LlmMetadataProto` in LiteRT-LM's
// `schema/core/litertlm_header_schema.fbs`.
const int _llmMetadataSectionType = 5;

// `LlmMetadata.jinja_prompt_template` in `runtime/proto/llm_metadata.proto`.
const int _jinjaPromptTemplateField = 7;

/// The text of [liteRtLmContentShapeProbeMessage].
const String liteRtLmContentShapeProbeText = 'llamadart-content-shape-probe';

final RegExp _probeTextAsListItem = RegExp(
  '["\']text["\']\\s*:\\s*["\']$liteRtLmContentShapeProbeText["\']',
);

/// The message whose rendering shows whether a native LiteRT-LM conversation
/// template reads the content the runtime gives it. See
/// [liteRtLmRendersProbeText].
const Map<String, dynamic> liteRtLmContentShapeProbeMessage = {
  'role': 'user',
  'content': [
    {'type': 'text', 'text': liteRtLmContentShapeProbeText},
  ],
};

/// Whether [rendered], the prompt a native conversation rendered for
/// [liteRtLmContentShapeProbeMessage], holds the text of that message as text.
///
/// From LiteRT-LM v0.18 the runtime hands every template content as a list of
/// parts. A template that reads content as a string then loses the text or
/// writes the list, `[{"text": "...", "type": "text"}]`, into the prompt;
/// neither counts.
bool liteRtLmRendersProbeText(String rendered) => rendered
    .replaceAll(_probeTextAsListItem, '')
    .contains(liteRtLmContentShapeProbeText);

/// Returns [template] behind a prelude that gives it the content of a message
/// as a string when that content is a single text part, as LiteRT-LM runtimes
/// before v0.18 did for a template that reads content as a string.
///
/// Other content stays as the runtime passed it. The prelude rebinds
/// `messages`, so it does not reach a template that reads the message of a
/// turn from `message` (the runtime's `is_appending_to_prefill` form).
String liteRtLmTextContentAdapter(String template) =>
    '$_textContentAdapterPrelude$template';

// Ends with a block tag and a newline. The runtime trims the newline after a
// block tag, so [template] starts on a line of its own, where leading
// whitespace is handled as at the start of a template.
const String _textContentAdapterPrelude =
    '{%- set llamadart_adapter = namespace(messages=[]) -%}'
    '{%- for llamadart_message in messages -%}'
    '{%- set llamadart_content = llamadart_message.content -%}'
    '{%- if llamadart_content is sequence'
    ' and llamadart_content is not string'
    ' and llamadart_content | length == 1'
    ' and llamadart_content[0] is mapping'
    " and llamadart_content[0].type == 'text'"
    ' and llamadart_content[0].text is string -%}'
    '{%- set llamadart_adapter.messages = llamadart_adapter.messages'
    ' + [dict(llamadart_message, content=llamadart_content[0].text)] -%}'
    '{%- else -%}'
    '{%- set llamadart_adapter.messages = llamadart_adapter.messages'
    ' + [llamadart_message] -%}'
    '{%- endif -%}'
    '{%- endfor -%}'
    '{%- set messages = llamadart_adapter.messages %}\n';

/// The Jinja chat template embedded in the `.litertlm` bundle at [path], or
/// null when the file cannot be read, is not a bundle this reader understands
/// or declares no template.
///
/// The native runtime exposes no accessor for it.
String? readLiteRtLmBundleChatTemplate(String path) {
  RandomAccessFile? file;
  try {
    file = File(path).openSync();
    final prefix = _read(file, 0, 32);
    if (ascii.decode(prefix.sublist(0, 8), allowInvalid: true) != 'LITERTLM') {
      return null;
    }
    final prefixData = ByteData.sublistView(prefix);
    final headerEnd = prefixData.getUint64(24, Endian.little);
    if (headerEnd <= 32 || headerEnd - 32 > _maxHeaderBytes) {
      return null;
    }
    final header = _FlatBuffer(_read(file, 32, headerEnd - 32));
    final sections = header.field(header.root, 1);
    final objects = sections == null
        ? null
        : header.field(header.indirect(sections), 0);
    if (objects == null) {
      return null;
    }
    for (final section in header.tables(objects)) {
      final type = header.field(section, 3);
      if (type == null || header.uint8(type) != _llmMetadataSectionType) {
        continue;
      }
      final begin = header.field(section, 1);
      final end = header.field(section, 2);
      if (begin == null || end == null) {
        return null;
      }
      final beginOffset = header.uint64(begin);
      final length = header.uint64(end) - beginOffset;
      if (length <= 0 || length > _maxMetadataBytes) {
        return null;
      }
      return _jinjaPromptTemplate(_read(file, beginOffset, length));
    }
    return null;
  } on FileSystemException {
    return null;
  } on FormatException {
    return null;
  } finally {
    file?.closeSync();
  }
}

Uint8List _read(RandomAccessFile file, int offset, int length) {
  file.setPositionSync(offset);
  final bytes = file.readSync(length);
  if (bytes.length != length) {
    throw const FormatException('Truncated LiteRT-LM bundle.');
  }
  return bytes;
}

String? _jinjaPromptTemplate(Uint8List metadata) {
  String? template;
  var offset = 0;

  int varint() {
    var value = 0;
    for (var shift = 0; shift < 64; shift += 7) {
      if (offset >= metadata.length) {
        throw const FormatException('Truncated LiteRT-LM metadata.');
      }
      final byte = metadata[offset++];
      value |= (byte & 0x7f) << shift;
      if (byte & 0x80 == 0) {
        return value;
      }
    }
    throw const FormatException('Malformed LiteRT-LM metadata.');
  }

  void skip(int length) {
    if (length < 0 || length > metadata.length - offset) {
      throw const FormatException('Truncated LiteRT-LM metadata.');
    }
    offset += length;
  }

  while (offset < metadata.length) {
    final key = varint();
    final field = key >> 3;
    switch (key & 0x7) {
      case 0:
        varint();
      case 1:
        skip(8);
      case 2:
        final length = varint();
        final start = offset;
        skip(length);
        if (field == _jinjaPromptTemplateField) {
          template = utf8.decode(metadata.sublist(start, offset));
        }
      case 5:
        skip(4);
      default:
        throw const FormatException('Malformed LiteRT-LM metadata.');
    }
  }
  return template;
}

/// Bounds-checked reads of the FlatBuffers encoding of a bundle header.
class _FlatBuffer {
  _FlatBuffer(Uint8List bytes) : _data = ByteData.sublistView(bytes);

  final ByteData _data;

  int get root => indirect(0);

  int uint8(int offset) => _data.getUint8(_checked(offset, 1));

  int uint64(int offset) => _data.getUint64(_checked(offset, 8), Endian.little);

  /// The position that the offset stored at [offset] points to.
  int indirect(int offset) =>
      offset + _data.getUint32(_checked(offset, 4), Endian.little);

  /// The position of field [index] of the table at [table], or null when the
  /// table omits it.
  int? field(int table, int index) {
    final vtable = table - _data.getInt32(_checked(table, 4), Endian.little);
    final slot = 4 + index * 2;
    if (slot + 2 > _data.getUint16(_checked(vtable, 2), Endian.little)) {
      return null;
    }
    final fieldOffset = _data.getUint16(
      _checked(vtable + slot, 2),
      Endian.little,
    );
    return fieldOffset == 0 ? null : table + fieldOffset;
  }

  /// The tables of the vector that the field at [vectorField] points to.
  Iterable<int> tables(int vectorField) sync* {
    final vector = indirect(vectorField);
    final count = _data.getUint32(_checked(vector, 4), Endian.little);
    for (var i = 0; i < count; i++) {
      yield indirect(vector + 4 + i * 4);
    }
  }

  int _checked(int offset, int length) {
    if (offset < 0 || offset > _data.lengthInBytes - length) {
      throw const FormatException('Malformed LiteRT-LM bundle header.');
    }
    return offset;
  }
}
