import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const _embd = 16;
const _ff = 16;
const _alignment = 32;

/// Writes a one-layer ModernBERT GGUF with random F32 weights and a
/// byte-fallback SentencePiece vocabulary to [path].
///
/// llama.cpp creates no KV cache for this architecture. [poolingType] is the
/// raw `llama_pooling_type` value; [classifierLabels] adds a
/// `cls.output.weight` head with one output per label.
File writeSyntheticModernBertGguf(
  String path, {
  int? poolingType,
  List<String>? classifierLabels,
  int contextLength = 1024,
  int seed = 0,
}) {
  final tokens = <String>[
    '<unk>',
    '<s>',
    '</s>',
    for (var byte = 0; byte < 256; byte++)
      '<0x${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}>',
  ];
  const arch = 'modern-bert';
  final metadata = <String, _GgufValue>{
    'general.architecture': _GgufValue.string(arch),
    '$arch.context_length': _GgufValue.uint32(contextLength),
    '$arch.embedding_length': _GgufValue.uint32(_embd),
    '$arch.feed_forward_length': _GgufValue.uint32(_ff),
    '$arch.block_count': _GgufValue.uint32(1),
    '$arch.attention.head_count': _GgufValue.uint32(2),
    '$arch.attention.layer_norm_epsilon': _GgufValue.float32(1e-5),
    '$arch.attention.causal': _GgufValue.boolean(false),
    if (poolingType != null)
      '$arch.pooling_type': _GgufValue.uint32(poolingType),
    if (classifierLabels != null)
      '$arch.classifier.output_labels': _GgufValue.strings(classifierLabels),
    'tokenizer.ggml.model': _GgufValue.string('llama'),
    'tokenizer.ggml.tokens': _GgufValue.strings(tokens),
    'tokenizer.ggml.scores': _GgufValue.float32s(
      List<double>.filled(tokens.length, 0),
    ),
    'tokenizer.ggml.token_type': _GgufValue.int32s([
      2,
      3,
      3,
      for (var byte = 0; byte < 256; byte++) 6,
    ]),
  };

  final random = math.Random(seed);
  List<double> weights(int count) => [
    for (var i = 0; i < count; i++) (random.nextDouble() - 0.5) * 0.2,
  ];
  List<double> ones(int count) => List<double>.filled(count, 1);
  final tensors = <String, (List<int>, List<double>)>{
    'token_embd.weight': (
      [_embd, tokens.length],
      weights(_embd * tokens.length),
    ),
    'token_embd_norm.weight': ([_embd], ones(_embd)),
    'output_norm.weight': ([_embd], ones(_embd)),
    'blk.0.attn_qkv.weight': ([_embd, 3 * _embd], weights(3 * _embd * _embd)),
    'blk.0.attn_output.weight': ([_embd, _embd], weights(_embd * _embd)),
    'blk.0.ffn_up.weight': ([_embd, 2 * _ff], weights(2 * _ff * _embd)),
    'blk.0.ffn_down.weight': ([_ff, _embd], weights(_ff * _embd)),
    'blk.0.ffn_norm.weight': ([_embd], ones(_embd)),
    if (classifierLabels != null)
      'cls.output.weight': (
        [_embd, classifierLabels.length],
        weights(_embd * classifierLabels.length),
      ),
  };

  final out = BytesBuilder(copy: false);
  final header = _GgufBytes()
    ..raw('GGUF'.codeUnits)
    ..uint32(3)
    ..uint64(tensors.length)
    ..uint64(metadata.length);
  for (final MapEntry(:key, :value) in metadata.entries) {
    header.string(key);
    value.write(header);
  }
  var offset = 0;
  for (final MapEntry(key: name, value: (shape, values)) in tensors.entries) {
    header
      ..string(name)
      ..uint32(shape.length);
    shape.forEach(header.uint64);
    header
      ..uint32(0)
      ..uint64(offset);
    offset = _align(offset + values.length * 4);
  }
  out.add(header.bytes);
  out.add(Uint8List(_align(out.length) - out.length));
  for (final (_, values) in tensors.values) {
    final data = Float32List.fromList(values).buffer.asUint8List();
    out
      ..add(data)
      ..add(Uint8List(_align(data.length) - data.length));
  }
  return File(path)..writeAsBytesSync(out.takeBytes());
}

int _align(int value) => (value + _alignment - 1) ~/ _alignment * _alignment;

final class _GgufValue {
  _GgufValue(this.write);

  _GgufValue.uint32(int value)
    : this(
        (out) => out
          ..uint32(4)
          ..uint32(value),
      );

  _GgufValue.float32(double value)
    : this(
        (out) => out
          ..uint32(6)
          ..float32(value),
      );

  _GgufValue.boolean(bool value)
    : this(
        (out) => out
          ..uint32(7)
          ..raw([value ? 1 : 0]),
      );

  _GgufValue.string(String value)
    : this(
        (out) => out
          ..uint32(8)
          ..string(value),
      );

  _GgufValue.strings(List<String> values)
    : this((out) {
        out
          ..uint32(9)
          ..uint32(8)
          ..uint64(values.length);
        values.forEach(out.string);
      });

  _GgufValue.float32s(List<double> values)
    : this((out) {
        out
          ..uint32(9)
          ..uint32(6)
          ..uint64(values.length);
        values.forEach(out.float32);
      });

  _GgufValue.int32s(List<int> values)
    : this((out) {
        out
          ..uint32(9)
          ..uint32(5)
          ..uint64(values.length);
        values.forEach(out.int32);
      });

  final void Function(_GgufBytes out) write;
}

final class _GgufBytes {
  final _builder = BytesBuilder();
  final _scratch = ByteData(8);

  Uint8List get bytes => _builder.toBytes();

  void raw(List<int> bytes) => _builder.add(bytes);

  void uint32(int value) {
    _scratch.setUint32(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 4));
  }

  void int32(int value) {
    _scratch.setInt32(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 4));
  }

  void uint64(int value) {
    _scratch.setUint64(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 8));
  }

  void float32(double value) {
    _scratch.setFloat32(0, value, Endian.little);
    _builder.add(_scratch.buffer.asUint8List(0, 4));
  }

  void string(String value) {
    final bytes = utf8.encode(value);
    uint64(bytes.length);
    _builder.add(bytes);
  }
}
