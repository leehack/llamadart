import 'dart:convert';
import 'dart:typed_data';

import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:genkit_llamadart/src/core/runtime/prompt_cache_envelope.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:test/test.dart';

final _identity = llama.LlamaStateIdentity(
  runtimeBuild: 'llamadart-native-build/1;owner=abc;backends=cpu',
  sessionFormatVersion: 11,
  contextSize: 512,
  contextConfigDigest: 'digest',
);

Uint8List _encoded() => PromptCacheEnvelope(
  identity: _identity,
  modelSha256: 'model-sha',
  tokens: const [1, 15, 300],
  state: Uint8List.fromList([7, 8, 9, 10]),
).encode();

Matcher _refused(LlamaDartPromptCacheImportFailure failure) => throwsA(
  isA<LlamaDartPromptCacheImportException>().having(
    (e) => e.failure,
    'failure',
    failure,
  ),
);

void main() {
  test('round-trips identity, model digest, tokens and state', () {
    final decoded = PromptCacheEnvelope.decode(_encoded());

    expect(decoded.identity, _identity);
    expect(decoded.modelSha256, 'model-sha');
    expect(decoded.tokens, [1, 15, 300]);
    expect(decoded.state, [7, 8, 9, 10]);
  });

  test('starts with the format tag and version 1', () {
    final bytes = _encoded();

    expect(ascii.decode(bytes.sublist(0, 8)), 'LDPCACHE');
    expect(ByteData.sublistView(bytes).getUint32(8, Endian.little), 1);
  });

  test('rejects foreign, truncated and altered bytes as corrupt', () {
    final valid = _encoded();
    final headerEnd =
        16 + ByteData.sublistView(valid).getUint32(12, Endian.little);
    final cases = <String, Uint8List>{
      'empty': Uint8List(0),
      'foreign magic': Uint8List.fromList(valid)..[0] = 0,
      'short prefix': valid.sublist(0, 12),
      'header past end': Uint8List.fromList(valid)
        ..buffer.asByteData().setUint32(12, valid.length, Endian.little),
      'no state': valid.sublist(0, headerEnd),
      'altered state': Uint8List.fromList(valid)..[valid.length - 1] ^= 1,
      'truncated state': valid.sublist(0, valid.length - 1),
      'altered header': Uint8List.fromList(valid)..[17] ^= 0x20,
    };
    for (final MapEntry(:key, :value) in cases.entries) {
      expect(
        () => PromptCacheEnvelope.decode(value),
        _refused(LlamaDartPromptCacheImportFailure.corrupt),
        reason: key,
      );
    }
  });

  test('rejects an empty runtime build as corrupt', () {
    final valid = _encoded();
    final headerLength = ByteData.sublistView(
      valid,
    ).getUint32(12, Endian.little);
    final header =
        jsonDecode(utf8.decode(valid.sublist(16, 16 + headerLength)))
            as Map<String, Object?>;
    (header['identity']! as Map<String, Object?>)['runtimeBuild'] = '';
    final rewritten = utf8.encode(jsonEncode(header));
    final bytes = Uint8List.fromList([
      ...valid.sublist(0, 12),
      ...(Uint8List(4)
        ..buffer.asByteData().setUint32(0, rewritten.length, Endian.little)),
      ...rewritten,
      ...valid.sublist(16 + headerLength),
    ]);

    expect(
      () => PromptCacheEnvelope.decode(bytes),
      _refused(LlamaDartPromptCacheImportFailure.corrupt),
    );
  });

  test('rejects another format version by name', () {
    final bytes = _encoded()
      ..buffer.asByteData().setUint32(8, 2, Endian.little);

    expect(
      () => PromptCacheEnvelope.decode(bytes),
      _refused(LlamaDartPromptCacheImportFailure.unsupportedVersion),
    );
  });
}
