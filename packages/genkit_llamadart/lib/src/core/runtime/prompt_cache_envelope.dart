import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart' as llama;

import '../../api/prompt_cache_import_exception.dart';

const _magic = [0x4c, 0x44, 0x50, 0x43, 0x41, 0x43, 0x48, 0x45]; // LDPCACHE
const _version = 1;
const _prefixBytes = 16;

/// The decoded contents of an exported prompt cache.
final class PromptCacheEnvelope {
  PromptCacheEnvelope({
    required this.identity,
    required this.modelSha256,
    required this.tokens,
    required this.state,
  });

  final llama.LlamaStateIdentity identity;
  final String modelSha256;
  final List<int> tokens;
  final Uint8List state;

  /// `LDPCACHE`, a little-endian u32 version and header length, a UTF-8 JSON
  /// header, then the native state bytes. The header holds no prompt or path.
  Uint8List encode() {
    final header = utf8.encode(
      jsonEncode({
        'identity': {
          'runtimeBuild': identity.runtimeBuild,
          'sessionFormatVersion': identity.sessionFormatVersion,
          'contextSize': identity.contextSize,
          'contextConfigDigest': identity.contextConfigDigest,
        },
        'modelSha256': modelSha256,
        'tokens': tokens,
        'stateSha256': sha256.convert(state).toString(),
      }),
    );
    final out = BytesBuilder(copy: false)
      ..add(_magic)
      ..add(_u32(_version))
      ..add(_u32(header.length))
      ..add(header)
      ..add(state);
    return out.takeBytes();
  }

  /// Decodes [bytes], rejecting a foreign, newer, truncated or altered export.
  static PromptCacheEnvelope decode(Uint8List bytes) {
    if (bytes.length < _prefixBytes ||
        !Iterable<int>.generate(
          _magic.length,
        ).every((i) => bytes[i] == _magic[i])) {
      throw _corrupt();
    }
    final view = ByteData.sublistView(bytes);
    final version = view.getUint32(8, Endian.little);
    if (version != _version) {
      throw LlamaDartPromptCacheImportException(
        LlamaDartPromptCacheImportFailure.unsupportedVersion,
        'The prompt cache export uses unsupported format version $version.',
      );
    }
    final headerLength = view.getUint32(12, Endian.little);
    if (headerLength > bytes.length - _prefixBytes) throw _corrupt();
    final Map<String, Object?> header;
    try {
      header =
          jsonDecode(
                utf8.decode(
                  Uint8List.sublistView(
                    bytes,
                    _prefixBytes,
                    _prefixBytes + headerLength,
                  ),
                ),
              )
              as Map<String, Object?>;
      final identity = header['identity']! as Map<String, Object?>;
      final state = Uint8List.fromList(
        Uint8List.sublistView(bytes, _prefixBytes + headerLength),
      );
      if (state.isEmpty ||
          sha256.convert(state).toString() != header['stateSha256']) {
        throw _corrupt();
      }
      return PromptCacheEnvelope(
        identity: llama.LlamaStateIdentity(
          runtimeBuild: identity['runtimeBuild']! as String,
          sessionFormatVersion: identity['sessionFormatVersion']! as int,
          contextSize: identity['contextSize']! as int,
          contextConfigDigest: identity['contextConfigDigest']! as String,
        ),
        modelSha256: header['modelSha256']! as String,
        tokens: List<int>.unmodifiable(header['tokens']! as List<Object?>),
        state: state,
      );
    } on LlamaDartPromptCacheImportException {
      rethrow;
    } catch (_) {
      throw _corrupt();
    }
  }
}

Uint8List _u32(int value) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.little);

LlamaDartPromptCacheImportException _corrupt() =>
    LlamaDartPromptCacheImportException(
      LlamaDartPromptCacheImportFailure.corrupt,
      'The prompt cache export is truncated, altered or not a prompt cache.',
    );
