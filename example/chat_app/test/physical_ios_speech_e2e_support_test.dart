import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/services/audio_recording_service.dart';

import '../integration_test/support/physical_ios_speech_e2e_support.dart';

Map<String, String> _validEnv() {
  return <String, String>{
    'IOS_SPEECH_QWEN3_ASR_MODEL_PATH': '/models/qwen3_asr.gguf',
    'IOS_SPEECH_QWEN3_ASR_MODEL_SHA256':
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    'IOS_SPEECH_QWEN3_ASR_MMPROJ_PATH': '/models/qwen3_asr_mmproj.gguf',
    'IOS_SPEECH_QWEN3_ASR_MMPROJ_SHA256':
        'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
    'IOS_SPEECH_ASR_AUDIO_PATH': '/fixtures/speech.wav',
    'IOS_SPEECH_ASR_AUDIO_SHA256':
        '1111111111111111111111111111111111111111111111111111111111111111',
    'IOS_SPEECH_ASR_EXPECTED_TRANSCRIPT': 'hello world from speech test',
    'IOS_SPEECH_MIC_DURATION_SECONDS': '3',
    'IOS_SPEECH_MIC_EXPECTED_TRANSCRIPT': 'testing microphone input',
    'IOS_SPEECH_LITERT_ASR_MODEL_PATH': '/models/moonshine_tiny.tflite',
    'IOS_SPEECH_LITERT_ASR_MODEL_SHA256':
        '2222222222222222222222222222222222222222222222222222222222222222',
    'IOS_SPEECH_LITERT_ASR_TOKENIZER_PATH': '/models/tokenizer.json',
    'IOS_SPEECH_LITERT_ASR_TOKENIZER_SHA256':
        '3333333333333333333333333333333333333333333333333333333333333333',
    'IOS_SPEECH_LITERT_ASR_PRESET': 'moonshine-tiny',
    'IOS_SPEECH_LITERT_ASR_AUDIO_PATH': '/fixtures/litert_speech.wav',
    'IOS_SPEECH_LITERT_ASR_AUDIO_SHA256':
        '4444444444444444444444444444444444444444444444444444444444444444',
    'IOS_SPEECH_LITERT_ASR_EXPECTED_TRANSCRIPT':
        'litert streaming speech recognition',
    'IOS_SPEECH_QWEN3_TTS_MODEL_PATH': '/models/qwen3_tts.gguf',
    'IOS_SPEECH_QWEN3_TTS_MODEL_SHA256':
        '5555555555555555555555555555555555555555555555555555555555555555',
    'IOS_SPEECH_QWEN3_TTS_MMPROJ_PATH': '/models/qwen3_tts_mmproj.gguf',
    'IOS_SPEECH_QWEN3_TTS_MMPROJ_SHA256':
        '6666666666666666666666666666666666666666666666666666666666666666',
    'IOS_SPEECH_TTS_TEXT': 'Hello from physical iOS speech synthesis test.',
    'IOS_SPEECH_TTS_OUTPUT_PATH': '/tmp/output_tts.wav',
    'IOS_SPEECH_TTS_EXPECTED_TRANSCRIPT':
        'hello from physical ios speech synthesis test',
    'IOS_SPEECH_LITERT_LM_MODEL_PATH': '/models/dummy.litertlm',
    'IOS_SPEECH_LITERT_LM_MODEL_SHA256':
        '7777777777777777777777777777777777777777777777777777777777777777',
  };
}

PhysicalIosSpeechConfig _copyConfigWithPaths(
  PhysicalIosSpeechConfig source, {
  String? qwen3AsrModelPath,
  String? ttsOutputPath,
}) {
  return PhysicalIosSpeechConfig(
    qwen3AsrModelPath: qwen3AsrModelPath ?? source.qwen3AsrModelPath,
    qwen3AsrModelSha256: source.qwen3AsrModelSha256,
    qwen3AsrMmprojPath: source.qwen3AsrMmprojPath,
    qwen3AsrMmprojSha256: source.qwen3AsrMmprojSha256,
    asrAudioPath: source.asrAudioPath,
    asrAudioSha256: source.asrAudioSha256,
    asrExpectedTranscript: source.asrExpectedTranscript,
    micDurationSeconds: source.micDurationSeconds,
    micExpectedTranscript: source.micExpectedTranscript,
    liteRtAsrModelPath: source.liteRtAsrModelPath,
    liteRtAsrModelSha256: source.liteRtAsrModelSha256,
    liteRtAsrTokenizerPath: source.liteRtAsrTokenizerPath,
    liteRtAsrTokenizerSha256: source.liteRtAsrTokenizerSha256,
    liteRtAsrPreset: source.liteRtAsrPreset,
    liteRtAsrAudioPath: source.liteRtAsrAudioPath,
    liteRtAsrAudioSha256: source.liteRtAsrAudioSha256,
    liteRtAsrExpectedTranscript: source.liteRtAsrExpectedTranscript,
    qwen3TtsModelPath: source.qwen3TtsModelPath,
    qwen3TtsModelSha256: source.qwen3TtsModelSha256,
    qwen3TtsMmprojPath: source.qwen3TtsMmprojPath,
    qwen3TtsMmprojSha256: source.qwen3TtsMmprojSha256,
    ttsText: source.ttsText,
    ttsOutputPath: ttsOutputPath ?? source.ttsOutputPath,
    ttsExpectedTranscript: source.ttsExpectedTranscript,
    liteRtLmModelPath: source.liteRtLmModelPath,
    liteRtLmModelSha256: source.liteRtLmModelSha256,
    resolvedAppCacheDirectoryPath: source.resolvedAppCacheDirectoryPath,
  );
}

Future<PhysicalIosSpeechConfig> _createResolvedAppCacheConfig(
  Directory cacheDirectory,
) async {
  final env = _validEnv()
    ..['IOS_SPEECH_QWEN3_ASR_MODEL_PATH'] = '@appcache/inputs/qwen3_asr.gguf'
    ..['IOS_SPEECH_QWEN3_ASR_MMPROJ_PATH'] =
        '@appcache/inputs/qwen3_asr_mmproj.gguf'
    ..['IOS_SPEECH_ASR_AUDIO_PATH'] = '@appcache/inputs/asr.wav'
    ..['IOS_SPEECH_LITERT_ASR_MODEL_PATH'] =
        '@appcache/inputs/litert_asr.tflite'
    ..['IOS_SPEECH_LITERT_ASR_TOKENIZER_PATH'] =
        '@appcache/inputs/tokenizer.json'
    ..['IOS_SPEECH_LITERT_ASR_AUDIO_PATH'] = '@appcache/inputs/litert_asr.wav'
    ..['IOS_SPEECH_QWEN3_TTS_MODEL_PATH'] = '@appcache/inputs/qwen3_tts.gguf'
    ..['IOS_SPEECH_QWEN3_TTS_MMPROJ_PATH'] =
        '@appcache/inputs/qwen3_tts_mmproj.gguf'
    ..['IOS_SPEECH_LITERT_LM_MODEL_PATH'] = '@appcache/inputs/chat.litertlm'
    ..['IOS_SPEECH_TTS_OUTPUT_PATH'] = '@appcache/output/tts.wav';
  final resolved = await resolvePhysicalIosSpeechCachePaths(
    PhysicalIosSpeechConfig.fromMap(env),
    cacheDirectory: () async => cacheDirectory,
  );
  for (final artifact in resolved.artifacts) {
    final file = File(artifact.path);
    await file.parent.create(recursive: true);
    await file.writeAsString(artifact.label, flush: true);
  }
  return resolved;
}

/// Rebuilds a WAV buffer with one header field overwritten so malformed
/// metadata cases can be asserted precisely.
Uint8List _withUint32(Uint8List source, int offset, int value) {
  final copy = Uint8List.fromList(source);
  ByteData.sublistView(copy).setUint32(offset, value, Endian.little);
  return copy;
}

Uint8List _withUint16(Uint8List source, int offset, int value) {
  final copy = Uint8List.fromList(source);
  ByteData.sublistView(copy).setUint16(offset, value, Endian.little);
  return copy;
}

Map<String, Object?> _decodeResultLine(String line) {
  const prefix = 'RESULT physical_ios_speech ';
  expect(line, startsWith(prefix));
  return jsonDecode(line.substring(prefix.length)) as Map<String, Object?>;
}

void main() {
  group('PhysicalIosSpeechConfig', () {
    test('parses valid full configuration successfully', () {
      final config = PhysicalIosSpeechConfig.fromMap(_validEnv());
      expect(config.qwen3AsrModelPath, equals('/models/qwen3_asr.gguf'));
      expect(config.micDurationSeconds, equals(3));
      expect(
        config.liteRtAsrPreset,
        equals(LiteRtLmAsrModelPreset.moonshineTiny),
      );
      expect(
        config.ttsText,
        equals('Hello from physical iOS speech synthesis test.'),
      );
    });

    test('rejects missing required configuration key', () {
      final env = _validEnv()..remove('IOS_SPEECH_QWEN3_ASR_MODEL_PATH');
      expect(
        () => PhysicalIosSpeechConfig.fromMap(env),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('IOS_SPEECH_QWEN3_ASR_MODEL_PATH'),
          ),
        ),
      );
    });

    test('rejects empty configuration value', () {
      final env = _validEnv()..['IOS_SPEECH_TTS_TEXT'] = '   ';
      expect(
        () => PhysicalIosSpeechConfig.fromMap(env),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('IOS_SPEECH_TTS_TEXT'),
          ),
        ),
      );
    });

    test('rejects invalid hex SHA-256 digest format', () {
      final invalidDigests = [
        '0123456789abcdef',
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0',
        '0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef',
        '0123456789xyzdef0123456789abcdef0123456789abcdef0123456789abcdef',
      ];

      for (final badDigest in invalidDigests) {
        final env = _validEnv()
          ..['IOS_SPEECH_QWEN3_ASR_MODEL_SHA256'] = badDigest;
        expect(
          () => PhysicalIosSpeechConfig.fromMap(env),
          throwsA(isA<ArgumentError>()),
          reason: 'Should reject digest: $badDigest',
        );
      }
    });

    test('rejects non-positive and non-numeric mic duration', () {
      for (final bad in <String>['0', '-5', 'three', '2.5', '']) {
        final env = _validEnv()..['IOS_SPEECH_MIC_DURATION_SECONDS'] = bad;
        expect(
          () => PhysicalIosSpeechConfig.fromMap(env),
          throwsA(isA<ArgumentError>()),
          reason: 'Should reject mic duration: "$bad"',
        );
      }
    });

    test('rejects unknown LiteRT ASR preset name', () {
      final env = _validEnv()
        ..['IOS_SPEECH_LITERT_ASR_PRESET'] = 'whisper-large';
      expect(
        () => PhysicalIosSpeechConfig.fromMap(env),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects remote, relative, colliding, and unsafe output paths', () {
      for (final badPath in <String>[
        'https://example.invalid/model.gguf',
        'relative/model.gguf',
      ]) {
        final env = _validEnv()..['IOS_SPEECH_QWEN3_ASR_MODEL_PATH'] = badPath;
        expect(
          () => PhysicalIosSpeechConfig.fromMap(env),
          throwsA(isA<ArgumentError>()),
          reason: 'Only absolute local on-device paths are valid: $badPath',
        );
      }

      final colliding = _validEnv()
        ..['IOS_SPEECH_TTS_OUTPUT_PATH'] =
            _validEnv()['IOS_SPEECH_QWEN3_TTS_MODEL_PATH']!;
      expect(
        () => PhysicalIosSpeechConfig.fromMap(colliding),
        throwsA(isA<ArgumentError>()),
        reason: 'The disposable WAV output must never overwrite an input.',
      );
    });

    test('caps microphone capture duration', () {
      final env = _validEnv()..['IOS_SPEECH_MIC_DURATION_SECONDS'] = '31';
      expect(
        () => PhysicalIosSpeechConfig.fromMap(env),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('App-cache relative path defines', () {
    test('accepts @appcache references alongside absolute paths', () {
      final env = _validEnv()
        ..['IOS_SPEECH_QWEN3_ASR_MODEL_PATH'] = '@appcache/models/asr.gguf'
        ..['IOS_SPEECH_TTS_OUTPUT_PATH'] = '@appcache/out/tts.wav';

      final config = PhysicalIosSpeechConfig.fromMap(env);
      expect(config.qwen3AsrModelPath, equals('@appcache/models/asr.gguf'));
      expect(config.usesAppCachePaths, isTrue);
      expect(
        PhysicalIosSpeechConfig.fromMap(_validEnv()).usesAppCachePaths,
        isFalse,
      );
    });

    test('rejects unsafe @appcache relative paths', () {
      const unsafe = <String>[
        '@appcache/../escape.gguf',
        '@appcache/models/../../escape.gguf',
        '@appcache/./model.gguf',
        '@appcache/models/./model.gguf',
        '@appcache/',
        '@appcache',
        '@appcache//model.gguf',
        '@appcache/models//model.gguf',
        '@appcache/models/',
        '@appcache/models\\model.gguf',
        '@appcache/https://example.invalid/model.gguf',
        '@appcache/models/model.gguf?download=1',
        '@appcache/models/model.gguf#fragment',
        '@appcache//',
        '@appcache/~/model.gguf',
        '@appcache/~root/model.gguf',
        ' @appcache/models/model.gguf',
        '@appcache/models/model.gguf ',
        '@appcache/ models/model.gguf',
        '@appcache/models /model.gguf',
      ];

      for (final badPath in unsafe) {
        final env = _validEnv()..['IOS_SPEECH_QWEN3_ASR_MODEL_PATH'] = badPath;
        expect(
          () => PhysicalIosSpeechConfig.fromMap(env),
          throwsA(isA<ArgumentError>()),
          reason: 'Should reject app-cache path: "$badPath"',
        );
      }
    });

    test('rejects a differently cased app-cache marker', () {
      for (final marker in <String>[
        '@AppCache/models/asr.gguf',
        '@APPCACHE/models/asr.gguf',
        '@Appcache/models/asr.gguf',
      ]) {
        final env = _validEnv()..['IOS_SPEECH_QWEN3_ASR_MODEL_PATH'] = marker;
        expect(
          () => PhysicalIosSpeechConfig.fromMap(env),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message.toString(),
              'message',
              contains('@appcache/'),
            ),
          ),
          reason: 'Ambiguous marker casing must fail closed: "$marker"',
        );
      }
    });

    test('rejects unsafe absolute paths', () {
      const unsafe = <String>[
        '/',
        '/models/../../etc/passwd',
        '/models/./asr.gguf',
        '/models//asr.gguf',
        '/models/',
        r'/models\asr.gguf',
        '/~/models/asr.gguf',
        '/models/asr:stream.gguf',
        '/models/asr.gguf?download=1',
        '/models/asr.gguf#fragment',
        ' /models/asr.gguf',
        '/models/asr.gguf ',
        'file:///models/asr.gguf',
      ];

      for (final badPath in unsafe) {
        final env = _validEnv()..['IOS_SPEECH_QWEN3_ASR_MODEL_PATH'] = badPath;
        expect(
          () => PhysicalIosSpeechConfig.fromMap(env),
          throwsA(isA<ArgumentError>()),
          reason: 'Should reject absolute path: "$badPath"',
        );
      }
    });

    test('resolves references against the runtime cache directory', () async {
      final env = _validEnv()
        ..['IOS_SPEECH_QWEN3_ASR_MODEL_PATH'] = '@appcache/models/asr.gguf'
        ..['IOS_SPEECH_LITERT_LM_MODEL_PATH'] = '@appcache/dummy.litertlm'
        ..['IOS_SPEECH_TTS_OUTPUT_PATH'] = '@appcache/out/tts.wav';

      final resolved = await resolvePhysicalIosSpeechCachePaths(
        PhysicalIosSpeechConfig.fromMap(env),
        cacheDirectory: () async =>
            Directory('/var/mobile/Containers/Data/Application/NEW-UUID/Cache'),
      );

      expect(
        resolved.qwen3AsrModelPath,
        equals(
          '/var/mobile/Containers/Data/Application/NEW-UUID/Cache/models/'
          'asr.gguf',
        ),
      );
      expect(
        resolved.liteRtLmModelPath,
        equals(
          '/var/mobile/Containers/Data/Application/NEW-UUID/Cache/'
          'dummy.litertlm',
        ),
      );
      expect(
        resolved.ttsOutputPath,
        equals(
          '/var/mobile/Containers/Data/Application/NEW-UUID/Cache/out/tts.wav',
        ),
      );
      expect(
        resolved.qwen3AsrMmprojPath,
        equals('/models/qwen3_asr_mmproj.gguf'),
        reason: 'Safe absolute paths must survive resolution unchanged.',
      );
      expect(resolved.usesAppCachePaths, isFalse);
      expect(resolved.micDurationSeconds, equals(3));
      expect(
        resolved.liteRtAsrPreset,
        equals(LiteRtLmAsrModelPreset.moonshineTiny),
      );
    });

    test('never consults path_provider for an all-absolute config', () async {
      var lookups = 0;
      final resolved = await resolvePhysicalIosSpeechCachePaths(
        PhysicalIosSpeechConfig.fromMap(_validEnv()),
        cacheDirectory: () async {
          lookups++;
          return Directory('/unused');
        },
      );

      expect(lookups, isZero);
      expect(resolved.ttsOutputPath, equals('/tmp/output_tts.wav'));
    });

    test('rejects an unusable runtime cache directory', () async {
      final config = PhysicalIosSpeechConfig.fromMap(
        _validEnv()..['IOS_SPEECH_TTS_OUTPUT_PATH'] = '@appcache/out/tts.wav',
      );

      for (final directory in <String>[
        '',
        '   ',
        'relative/cache',
        '/',
        '/var/../root/cache',
        '/var/cache//app',
        ' /var/cache/app',
        '/var/cache/app ',
        '@appcache/nested',
      ]) {
        await expectLater(
          resolvePhysicalIosSpeechCachePaths(
            config,
            cacheDirectory: () async => Directory(directory),
          ),
          throwsA(isA<ArgumentError>()),
          reason: 'Should reject cache directory: "$directory"',
        );
      }
    });

    test('tolerates a trailing separator on the cache directory', () async {
      final resolved = await resolvePhysicalIosSpeechCachePaths(
        PhysicalIosSpeechConfig.fromMap(
          _validEnv()..['IOS_SPEECH_TTS_OUTPUT_PATH'] = '@appcache/out/tts.wav',
        ),
        cacheDirectory: () async => Directory('/Containers/Cache/'),
      );

      expect(resolved.ttsOutputPath, equals('/Containers/Cache/out/tts.wav'));
    });

    test('rejects an output that collides only after resolution', () async {
      final env = _validEnv()
        ..['IOS_SPEECH_QWEN3_TTS_MODEL_PATH'] = '/Containers/Cache/TTS.wav'
        ..['IOS_SPEECH_TTS_OUTPUT_PATH'] = '@appcache/tts.wav';

      // The two specs differ textually, so only post-resolution comparison can
      // stop the harness from deleting a pinned input during cleanup.
      final config = PhysicalIosSpeechConfig.fromMap(env);

      await expectLater(
        resolvePhysicalIosSpeechCachePaths(
          config,
          cacheDirectory: () async => Directory('/Containers/Cache'),
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'Post-resolution comparison must ignore path casing.',
      );
    });

    test('rejects an input/output collision that differs only by case', () {
      final env = _validEnv()
        ..['IOS_SPEECH_TTS_OUTPUT_PATH'] = '/models/QWEN3_TTS.gguf'
        ..['IOS_SPEECH_QWEN3_TTS_MODEL_PATH'] = '/models/qwen3_tts.gguf';

      expect(
        () => PhysicalIosSpeechConfig.fromMap(env),
        throwsA(isA<ArgumentError>()),
        reason: 'The on-device container may fold case into one file.',
      );
    });

    test('rejects duplicate immutable input paths ignoring case', () {
      final env = _validEnv()
        ..['IOS_SPEECH_QWEN3_ASR_MODEL_PATH'] = '/models/shared.gguf'
        ..['IOS_SPEECH_QWEN3_ASR_MMPROJ_PATH'] = '/MODELS/SHARED.GGUF';

      expect(
        () => PhysicalIosSpeechConfig.fromMap(env),
        throwsA(isA<ArgumentError>()),
        reason: 'Every checksum pin must identify one unambiguous input file.',
      );
    });

    test('refuses artifact access before resolution', () async {
      final config = PhysicalIosSpeechConfig.fromMap(
        _validEnv()
          ..['IOS_SPEECH_ASR_AUDIO_PATH'] = '@appcache/fixtures/speech.wav',
      );
      final visited = <String>[];

      await expectLater(
        config.validateArtifacts(
          verify: (artifact) async => visited.add(artifact.label),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('asrAudio'), contains('@appcache/')),
          ),
        ),
      );
      await expectLater(
        config.validateArtifactsCollectingFailures(
          verify: (artifact) async => visited.add(artifact.label),
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        visited,
        isEmpty,
        reason: 'No artifact may be opened while a path is unresolved.',
      );
    });

    test(
      'direct construction cannot bypass path and collision checks',
      () async {
        final valid = PhysicalIosSpeechConfig.fromMap(_validEnv());
        final invalidConfigs = <PhysicalIosSpeechConfig>[
          _copyConfigWithPaths(
            valid,
            qwen3AsrModelPath: '/models/../private/input.gguf',
          ),
          _copyConfigWithPaths(
            valid,
            qwen3AsrModelPath: '@AppCache/models/input.gguf',
          ),
          _copyConfigWithPaths(valid, ttsOutputPath: '/MODELS/QWEN3_ASR.GGUF'),
        ];

        for (final config in invalidConfigs) {
          final visited = <String>[];
          await expectLater(
            config.validateArtifacts(
              verify: (artifact) async => visited.add(artifact.label),
            ),
            throwsA(anyOf(isA<ArgumentError>(), isA<StateError>())),
          );
          expect(
            visited,
            isEmpty,
            reason: 'Every path check must finish before the first file read.',
          );
        }
      },
    );
  });

  group('Canonical speech filesystem layout', () {
    late Directory tempDir;
    late Directory cacheDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp(
        'speech_e2e_layout_test_',
      );
      cacheDir = Directory('${tempDir.path}/cache');
      await cacheDir.create();
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('canonicalizes cache paths after runtime resolution', () async {
      final resolved = await _createResolvedAppCacheConfig(cacheDir);

      final canonical = await canonicalizePhysicalIosSpeechFilesystemLayout(
        resolved,
      );
      final canonicalRoot = await cacheDir.resolveSymbolicLinks();

      expect(canonical.resolvedAppCacheDirectoryPath, canonicalRoot);
      expect(canonical.qwen3AsrModelPath, startsWith('$canonicalRoot/'));
      expect(canonical.ttsOutputPath, '$canonicalRoot/output/tts.wav');
      expect(await File(canonical.ttsOutputPath).exists(), isFalse);
    });

    test(
      'rejects an input symlink that escapes the runtime cache',
      () async {
        final resolved = await _createResolvedAppCacheConfig(cacheDir);
        final model = File(resolved.qwen3AsrModelPath);
        final outside = File('${tempDir.path}/outside.gguf');
        await outside.writeAsString('outside', flush: true);
        await model.delete();
        await Link(model.path).create(outside.path);

        await expectLater(
          canonicalizePhysicalIosSpeechFilesystemLayout(resolved),
          throwsA(isA<StateError>()),
        );
      },
      skip: Platform.isWindows
          ? 'Creating symbolic links requires additional Windows privileges.'
          : false,
    );

    test(
      'rejects a symlinked output parent below the cache root',
      () async {
        final resolved = await _createResolvedAppCacheConfig(cacheDir);
        final outside = Directory('${tempDir.path}/outside')..createSync();
        await Link('${cacheDir.path}/output').create(outside.path);

        await expectLater(
          canonicalizePhysicalIosSpeechFilesystemLayout(resolved),
          throwsA(isA<StateError>()),
        );
      },
      skip: Platform.isWindows ? 'Symlink privileges are not portable.' : false,
    );

    test('writes exclusively and deletes only the canonical output', () async {
      final resolved = await _createResolvedAppCacheConfig(cacheDir);
      final canonical = await canonicalizePhysicalIosSpeechFilesystemLayout(
        resolved,
      );
      final bytes = Uint8List.fromList(<int>[1, 2, 3, 4]);

      final output = await writePhysicalIosSpeechOutputExclusive(
        canonical,
        bytes,
      );
      expect(await output.readAsBytes(), bytes);
      await expectLater(
        writePhysicalIosSpeechOutputExclusive(canonical, bytes),
        throwsA(isA<StateError>()),
      );

      await deletePhysicalIosSpeechOutput(canonical);
      expect(await output.exists(), isFalse);
    });

    test(
      'refuses to delete an output replaced by a symbolic link',
      () async {
        final resolved = await _createResolvedAppCacheConfig(cacheDir);
        final canonical = await canonicalizePhysicalIosSpeechFilesystemLayout(
          resolved,
        );
        final target = File('${tempDir.path}/do_not_delete.wav');
        await target.writeAsBytes(<int>[9], flush: true);
        await Directory(canonical.ttsOutputPath).parent.create(recursive: true);
        await Link(canonical.ttsOutputPath).create(target.path);

        await expectLater(
          deletePhysicalIosSpeechOutput(canonical),
          throwsA(isA<StateError>()),
        );
        expect(await target.exists(), isTrue);
      },
      skip: Platform.isWindows ? 'Symlink privileges are not portable.' : false,
    );
  });

  group('Compile-time define map', () {
    test('exposes exactly the declared keys', () {
      expect(
        physicalIosSpeechCompileTimeDefines.keys.toSet(),
        equals(physicalIosSpeechDefineKeys.toSet()),
      );
      expect(
        physicalIosSpeechCompileTimeDefines,
        hasLength(physicalIosSpeechDefineKeys.length),
      );
      expect(physicalIosSpeechDefineKeys, hasLength(26));
      for (final key in physicalIosSpeechDefineKeys) {
        expect(key, startsWith('IOS_SPEECH_'));
      }
    });

    test('fails closed when no --dart-define values were supplied', () {
      expect(
        () => PhysicalIosSpeechConfig.fromEnvironment(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message.toString(),
            'message',
            contains('IOS_SPEECH_'),
          ),
        ),
      );
    });
  });

  group('Artifact checksum verification', () {
    test('enumerates every immutable artifact exactly once', () {
      final config = PhysicalIosSpeechConfig.fromMap(_validEnv());
      final artifacts = config.artifacts;
      expect(artifacts, hasLength(9));
      expect(
        artifacts.map((a) => a.label).toSet(),
        equals(<String>{
          'qwen3AsrModel',
          'qwen3AsrMmproj',
          'asrAudio',
          'liteRtAsrModel',
          'liteRtAsrTokenizer',
          'liteRtAsrAudio',
          'qwen3TtsModel',
          'qwen3TtsMmproj',
          'liteRtLmModel',
        }),
      );
      expect(artifacts.map((a) => a.path).toSet(), hasLength(9));
    });

    test('streams hashes strictly sequentially, never concurrently', () async {
      final config = PhysicalIosSpeechConfig.fromMap(_validEnv());
      final order = <String>[];
      var inFlight = 0;
      var maxInFlight = 0;

      await config.validateArtifacts(
        verify: (artifact) async {
          inFlight++;
          if (inFlight > maxInFlight) {
            maxInFlight = inFlight;
          }
          order.add(artifact.label);
          await Future<void>.delayed(Duration.zero);
          inFlight--;
        },
      );

      expect(
        maxInFlight,
        equals(1),
        reason: 'Multi-GB artifacts must not be hashed concurrently.',
      );
      expect(order, hasLength(9));
      expect(order.first, equals('qwen3AsrModel'));
    });

    test('stops at the first failing artifact and names it', () async {
      final config = PhysicalIosSpeechConfig.fromMap(_validEnv());
      final visited = <String>[];

      await expectLater(
        config.validateArtifacts(
          verify: (artifact) async {
            visited.add(artifact.label);
            if (artifact.label == 'asrAudio') {
              throw StateError('Checksum mismatch for "${artifact.path}"');
            }
          },
        ),
        throwsA(isA<StateError>()),
      );

      expect(visited, equals(['qwen3AsrModel', 'qwen3AsrMmproj', 'asrAudio']));
    });

    test(
      'collects every artifact failure while remaining sequential',
      () async {
        final config = PhysicalIosSpeechConfig.fromMap(_validEnv());
        final visited = <String>[];
        var inFlight = 0;
        var maxInFlight = 0;

        final failures = await config.validateArtifactsCollectingFailures(
          verify: (artifact) async {
            inFlight++;
            maxInFlight = math.max(maxInFlight, inFlight);
            visited.add(artifact.label);
            await Future<void>.delayed(Duration.zero);
            inFlight--;
            if (artifact.label == 'asrAudio' ||
                artifact.label == 'liteRtLmModel') {
              throw StateError('secret path ${artifact.path}');
            }
          },
        );

        expect(visited, hasLength(9));
        expect(maxInFlight, 1);
        expect(failures.keys, {'asrAudio', 'liteRtLmModel'});
        expect(failures.values.join(' '), isNot(contains('/fixtures/')));
        expect(failures.values.join(' '), isNot(contains('/models/')));
        expect(
          () => requireValidSpeechArtifacts(failures, const {'asrAudio'}),
          throwsA(isA<StateError>()),
        );
        expect(
          () => requireValidSpeechArtifacts(failures, const {'qwen3TtsModel'}),
          returnsNormally,
        );
      },
    );
  });

  group('Transcript Normalization', () {
    test('normalizes whitespace, casing, and trimming exactly', () {
      expect(
        normalizeSpeechTranscript('  Hello   World  \n\t from   Dart  '),
        equals('hello world from dart'),
      );
      expect(
        normalizeSpeechTranscript('TESTING  1  2  3'),
        equals('testing 1 2 3'),
      );
      expect(normalizeSpeechTranscript(''), equals(''));
      expect(normalizeSpeechTranscript('   \n\t  '), equals(''));
      expect(
        normalizeSpeechTranscript('  Exact   Punctuation, Preserved!  '),
        equals('exact punctuation, preserved!'),
      );
    });

    test('does not use substring or contains matching', () {
      final actual = normalizeSpeechTranscript('hello world');
      final expected = normalizeSpeechTranscript('hello');
      expect(actual == expected, isFalse);
    });

    test('exact comparison accepts only normalized equality', () {
      expect(
        () => expectExactNormalizedTranscript(
          actual: '  Hello   World ',
          expected: 'hello world',
          label: 'row1.fixture',
        ),
        returnsNormally,
      );
      expect(
        () => expectExactNormalizedTranscript(
          actual: 'hello world!',
          expected: 'hello world',
          label: 'row1.fixture',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => expectExactNormalizedTranscript(
          actual: 'hello world extra',
          expected: 'hello world',
          label: 'row1.fixture',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('mismatch diagnostics never leak transcript content', () {
      Object? captured;
      try {
        expectExactNormalizedTranscript(
          actual: 'the launch codes are alpha bravo',
          expected: 'entirely different phrase',
          label: 'row1.fixture',
        );
      } catch (error) {
        captured = error;
      }

      expect(captured, isA<StateError>());
      final message = (captured! as StateError).message;
      expect(message, contains('row1.fixture'));
      expect(message, contains('actualSha'));
      expect(message, contains('expectedSha'));
      for (final word in <String>[
        'launch',
        'codes',
        'alpha',
        'bravo',
        'entirely',
        'different',
        'phrase',
      ]) {
        expect(
          message.toLowerCase(),
          isNot(contains(word)),
          reason: 'Diagnostic must not echo transcript token "$word".',
        );
      }
    });

    test('fingerprints are stable, short, and normalization-insensitive', () {
      final a = transcriptFingerprint('  Hello   World  ');
      final b = transcriptFingerprint('hello world');
      expect(a, equals(b));
      expect(a, hasLength(12));
      expect(a, matches(RegExp(r'^[0-9a-f]{12}$')));
      expect(a, isNot(equals(transcriptFingerprint('hello worlds'))));
    });
  });

  group('Diagnostic sanitization', () {
    test('collapses whitespace, strips control characters, and truncates', () {
      final sanitized = sanitizeSpeechDiagnostic(
        'line one\nline\ttwo   spaced',
      );
      expect(sanitized, equals('line one line two spaced'));

      final long = sanitizeSpeechDiagnostic('x' * 400, maxLength: 32);
      expect(long, hasLength(32));
      expect(long, endsWith('...'));
    });

    test('produces a non-empty placeholder for blank input', () {
      expect(sanitizeSpeechDiagnostic('   \n  '), equals('<empty>'));
    });

    test('error diagnostics fingerprint rather than echo sensitive text', () {
      final diagnostic = safeSpeechErrorDiagnostic(
        StateError(
          'https://user:secret@example.invalid/private/model.gguf '
          'the launch phrase is never printable',
        ),
      );

      expect(diagnostic, startsWith('StateError#'));
      expect(diagnostic, matches(RegExp(r'^[A-Za-z0-9_]+#[0-9a-f]{12}$')));
      expect(diagnostic, isNot(contains('https://')));
      expect(diagnostic, isNot(contains('secret')));
      expect(diagnostic, isNot(contains('launch')));
    });
  });

  group('Bounded awaits', () {
    test('event collection remains awaitable after a stream error', () async {
      final events = collectSpeechEvents<int>(
        Stream<int>.error(StateError('event failure')),
      );

      await expectLater(events, throwsA(isA<StateError>()));
    });

    test('returns the value when the future settles in time', () async {
      final value = await awaitBounded(
        Future<int>.value(7),
        const Duration(seconds: 5),
        'unit value',
      );
      expect(value, equals(7));
    });

    test(
      'throws an actionable TimeoutException naming the operation',
      () async {
        await expectLater(
          awaitBounded(
            Completer<void>().future,
            const Duration(milliseconds: 20),
            'row2.session.done',
          ),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.message ?? '',
              'message',
              allOf(contains('row2.session.done'), contains('20')),
            ),
          ),
        );
      },
    );

    test(
      'requires an operation to remain active before cancellation',
      () async {
        final completer = Completer<void>();
        await expectLater(
          requireStillActiveBeforeCancellation(
            completer.future,
            Duration.zero,
            'row1.cancel',
          ),
          completes,
        );

        await expectLater(
          requireStillActiveBeforeCancellation(
            Future<void>.value(),
            Duration.zero,
            'row1.cancel',
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('cleanup always runs without masking the primary failure', () async {
      var cleanupRan = false;
      await expectLater(
        runWithSpeechCleanup(
          body: () async => throw const AudioRecordingException(
            AudioRecordingFailure.permissionDenied,
            'permission denied',
          ),
          cleanup: () async {
            cleanupRan = true;
            throw StateError('cleanup failed');
          },
        ),
        throwsA(
          isA<AudioRecordingException>().having(
            (error) => error.failure,
            'failure',
            AudioRecordingFailure.permissionDenied,
          ),
        ),
      );
      expect(cleanupRan, isTrue);

      await expectLater(
        runWithSpeechCleanup(
          body: () async {},
          cleanup: () async => throw StateError('cleanup failed'),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Streaming SHA-256 Verification', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('speech_e2e_sha_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('computes exact streaming SHA-256 for a file', () async {
      final testFile = File('${tempDir.path}/test.bin');
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      testFile.writeAsBytesSync(bytes, flush: true);

      final expectedDigest = sha256.convert(bytes).toString();
      final computed = await computeFileSha256(testFile.path);

      expect(computed, equals(expectedDigest));
    });

    test('validates file checksum successfully on match', () async {
      final testFile = File('${tempDir.path}/match.bin');
      final bytes = Uint8List.fromList([10, 20, 30, 40]);
      testFile.writeAsBytesSync(bytes, flush: true);

      final expectedDigest = sha256.convert(bytes).toString();
      await expectLater(
        validateFileChecksum(testFile.path, expectedDigest),
        completes,
      );
    });

    test('bounds hashing without leaving the artifact locked', () async {
      final testFile = File('${tempDir.path}/timeout.bin');
      testFile.writeAsBytesSync(List<int>.filled(1024, 7), flush: true);

      await expectLater(
        computeFileSha256(testFile.path, timeout: Duration.zero),
        throwsA(isA<TimeoutException>()),
      );
      await expectLater(testFile.delete(), completes);
    });

    test('throws on checksum mismatch', () async {
      final testFile = File('${tempDir.path}/mismatch.bin');
      testFile.writeAsBytesSync([1, 2, 3], flush: true);

      const wrongDigest =
          '0000000000000000000000000000000000000000000000000000000000000000';
      await expectLater(
        validateFileChecksum(testFile.path, wrongDigest),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Checksum mismatch'),
          ),
        ),
      );
    });

    test('throws when file does not exist', () async {
      await expectLater(
        validateFileChecksum(
          '${tempDir.path}/nonexistent.bin',
          '0000000000000000000000000000000000000000000000000000000000000000',
        ),
        throwsA(isA<FileSystemException>()),
      );
    });

    test(
      'refuses to hash through an artifact symlink',
      () async {
        final target = File('${tempDir.path}/target.bin');
        await target.writeAsBytes(<int>[1, 2, 3], flush: true);
        final link = Link('${tempDir.path}/artifact.bin');
        await link.create(target.path);

        await expectLater(
          computeFileSha256(link.path),
          throwsA(isA<FileSystemException>()),
        );
        expect(await target.exists(), isTrue);
      },
      skip: Platform.isWindows ? 'Symlink privileges are not portable.' : false,
    );
  });

  group('PCM16 WAV Parsing and Validation', () {
    test('WAV creation rejects invalid metadata and ragged frames', () {
      expect(
        () => createPcm16WavBytes(
          samples: const <int>[1],
          sampleRate: 0,
          channels: 1,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => createPcm16WavBytes(
          samples: const <int>[1],
          sampleRate: 16000,
          channels: 0,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => createPcm16WavBytes(
          samples: const <int>[1, 2, 3],
          sampleRate: 16000,
          channels: 2,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => createPcm16WavBytes(
          samples: const <int>[40000],
          sampleRate: 16000,
          channels: 1,
        ),
        throwsA(isA<ArgumentError>()),
        reason: 'PCM16 creation must not silently wrap out-of-range samples.',
      );
    });

    test('validates 16 kHz mono PCM16 WAV and decodes to Float32List', () {
      final samples = <int>[100, -100, 200, -200, 300, -300];
      final wav = createPcm16WavBytes(
        samples: samples,
        sampleRate: 16000,
        channels: 1,
      );

      final info = validatePcm16Wav(
        wav,
        expectedSampleRate: 16000,
        expectedChannels: 1,
      );

      expect(info.sampleRate, equals(16000));
      expect(info.channels, equals(1));
      expect(info.sampleFrames, equals(6));
      expect(info.peakAmplitude, equals(300));
      expect(info.durationSeconds, closeTo(6 / 16000, 0.00001));

      final floatSamples = decodePcm16WavToFloat32(
        wav,
        expectedSampleRate: 16000,
        expectedChannels: 1,
      );

      expect(floatSamples.length, equals(6));
      expect(floatSamples[0], closeTo(100 / 32768.0, 0.0001));
      expect(floatSamples[1], closeTo(-100 / 32768.0, 0.0001));
      expect(floatSamples[4], closeTo(300 / 32768.0, 0.0001));
    });

    test('validates 24 kHz mono PCM16 TTS WAV format and signal', () {
      final samples = List<int>.generate(2400, (i) => ((i % 100) * 100) - 5000);
      final wav = createPcm16WavBytes(
        samples: samples,
        sampleRate: 24000,
        channels: 1,
      );

      final info = validatePcm16Wav(
        wav,
        expectedSampleRate: 24000,
        expectedChannels: 1,
      );

      expect(info.sampleRate, equals(24000));
      expect(info.channels, equals(1));
      expect(info.sampleFrames, equals(2400));
      expect(info.durationSeconds, closeTo(0.1, 0.0001));
      expect(info.peakAmplitude, greaterThan(0));
      expect(info.rmsAmplitude, greaterThan(0));
    });

    test('rejects silent WAV when requireNonSilent is true', () {
      final silentWav = createPcm16WavBytes(
        samples: List<int>.filled(1600, 0),
        sampleRate: 16000,
        channels: 1,
      );

      expect(
        () => validatePcm16Wav(
          silentWav,
          expectedSampleRate: 16000,
          expectedChannels: 1,
          requireNonSilent: true,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects invalid sample rate and channel count', () {
      final wav = createPcm16WavBytes(
        samples: [100, 200],
        sampleRate: 44100,
        channels: 2,
      );

      expect(
        () => validatePcm16Wav(
          wav,
          expectedSampleRate: 16000,
          expectedChannels: 1,
        ),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects malformed, empty, and truncated WAV files', () {
      expect(
        () => validatePcm16Wav(Uint8List.fromList('not a wav file'.codeUnits)),
        throwsA(isA<FormatException>()),
      );

      final validWav = createPcm16WavBytes(
        samples: [100, 200, 300],
        sampleRate: 16000,
        channels: 1,
      );
      expect(
        () => validatePcm16Wav(validWav.sublist(0, 30)),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => validatePcm16Wav(Uint8List(0)),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects a RIFF size field inconsistent with the file length', () {
      final wav = createPcm16WavBytes(
        samples: [100, 200, 300, 400],
        sampleRate: 16000,
        channels: 1,
      );

      expect(
        () => validatePcm16Wav(_withUint32(wav, 4, wav.length + 512)),
        throwsA(isA<FormatException>()),
        reason: 'Oversized RIFF size must be rejected.',
      );
      expect(
        () => validatePcm16Wav(_withUint32(wav, 4, 8)),
        throwsA(isA<FormatException>()),
        reason: 'Undersized RIFF size must be rejected.',
      );
    });

    test('rejects a data chunk whose declared length is inconsistent', () {
      final wav = createPcm16WavBytes(
        samples: [100, 200, 300, 400],
        sampleRate: 16000,
        channels: 1,
      );

      expect(
        () => validatePcm16Wav(_withUint32(wav, 40, 0)),
        throwsA(isA<FormatException>()),
        reason: 'Empty data chunk must be rejected.',
      );
      expect(
        () => validatePcm16Wav(_withUint32(wav, 40, 7)),
        throwsA(isA<FormatException>()),
        reason: 'Odd data length cannot hold whole PCM16 samples.',
      );
      expect(
        () => validatePcm16Wav(_withUint32(wav, 40, wav.length)),
        throwsA(isA<FormatException>()),
        reason: 'Data chunk overrunning the file must be rejected.',
      );
    });

    test('rejects a data length that is not a whole number of frames', () {
      final stereo = createPcm16WavBytes(
        samples: [100, 200, 300, 400],
        sampleRate: 16000,
        channels: 2,
      );
      // 6 bytes = 3 samples = 1.5 stereo frames.
      final ragged = _withUint32(_withUint32(stereo, 4, 42), 40, 6);

      expect(
        () => validatePcm16Wav(ragged, expectedChannels: 2),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects inconsistent fmt metadata', () {
      final wav = createPcm16WavBytes(
        samples: [100, 200, 300, 400],
        sampleRate: 16000,
        channels: 1,
      );

      expect(
        () => validatePcm16Wav(_withUint16(wav, 22, 0)),
        throwsA(isA<FormatException>()),
        reason: 'Zero channels must be rejected before any division.',
      );
      expect(
        () => validatePcm16Wav(_withUint32(wav, 24, 0)),
        throwsA(isA<FormatException>()),
        reason: 'Zero sample rate must be rejected before duration math.',
      );
      expect(
        () => validatePcm16Wav(_withUint32(wav, 28, 12345)),
        throwsA(isA<FormatException>()),
        reason: 'byteRate must agree with rate * channels * bytesPerSample.',
      );
      expect(
        () => validatePcm16Wav(_withUint16(wav, 32, 9)),
        throwsA(isA<FormatException>()),
        reason: 'blockAlign must agree with channels * bytesPerSample.',
      );
      expect(
        () => validatePcm16Wav(_withUint16(wav, 34, 24)),
        throwsA(isA<FormatException>()),
        reason: 'Only 16-bit PCM is accepted.',
      );
      expect(
        () => validatePcm16Wav(_withUint16(wav, 20, 3)),
        throwsA(isA<FormatException>()),
        reason: 'Only uncompressed PCM format 1 is accepted.',
      );
    });

    test('rejects trailing bytes after the final chunk', () {
      final wav = createPcm16WavBytes(
        samples: [100, 200, 300, 400],
        sampleRate: 16000,
        channels: 1,
      );
      final padded = Uint8List(wav.length + 3)..setRange(0, wav.length, wav);
      final withRiffSize = _withUint32(padded, 4, padded.length - 8);

      expect(
        () => validatePcm16Wav(withRiffSize),
        throwsA(isA<FormatException>()),
      );
    });

    test('rejects data before fmt and a missing odd-chunk pad byte', () {
      final wav = createPcm16WavBytes(
        samples: [100, 200, 300, 400],
        sampleRate: 16000,
        channels: 1,
      );
      final reordered = Uint8List(wav.length)
        ..setRange(0, 12, wav)
        ..setRange(12, wav.length - 24, wav, 36)
        ..setRange(wav.length - 24, wav.length, wav, 12);
      expect(
        () => validatePcm16Wav(reordered),
        throwsA(isA<FormatException>()),
        reason: 'Strict PCM WAV requires fmt before the audio data chunk.',
      );

      final missingPad = Uint8List(wav.length + 9)
        ..setRange(0, wav.length, wav)
        ..setRange(wav.length, wav.length + 4, 'JUNK'.codeUnits);
      final missingPadData = ByteData.sublistView(missingPad)
        ..setUint32(wav.length + 4, 1, Endian.little)
        ..setUint8(wav.length + 8, 7)
        ..setUint32(4, missingPad.length - 8, Endian.little);
      expect(missingPadData.getUint8(wav.length + 8), 7);
      expect(
        () => validatePcm16Wav(missingPad),
        throwsA(isA<FormatException>()),
        reason: 'Odd-sized RIFF chunks require a physical pad byte.',
      );
    });

    test('rejects a WAV that declares no data chunk at all', () {
      final wav = createPcm16WavBytes(
        samples: [100, 200],
        sampleRate: 16000,
        channels: 1,
      );
      final headerOnly = Uint8List.fromList(wav.sublist(0, 36));
      final fixed = _withUint32(headerOnly, 4, headerOnly.length - 8);

      expect(() => validatePcm16Wav(fixed), throwsA(isA<FormatException>()));
    });

    test('decoding also enforces strict metadata and non-silence', () {
      final wav = createPcm16WavBytes(
        samples: [100, 200, 300, 400],
        sampleRate: 16000,
        channels: 1,
      );

      expect(
        () => decodePcm16WavToFloat32(_withUint32(wav, 40, 7)),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => decodePcm16WavToFloat32(
          createPcm16WavBytes(
            samples: List<int>.filled(64, 0),
            sampleRate: 16000,
            channels: 1,
          ),
        ),
        throwsA(isA<FormatException>()),
        reason: 'A silent ASR fixture is not usable input.',
      );
    });
  });

  group('Bounded PCM chunking', () {
    test('splits samples into bounded chunks covering every sample', () {
      final samples = Float32List.fromList(
        List<double>.generate(4001, (i) => i / 4001.0),
      );
      final chunks = chunkPcmSamples(samples, 1600).toList();

      expect(chunks, hasLength(3));
      expect(chunks[0], hasLength(1600));
      expect(chunks[1], hasLength(1600));
      expect(chunks[2], hasLength(801));
      expect(
        chunks.fold<int>(0, (sum, c) => sum + c.length),
        equals(samples.length),
      );
      expect(chunks.every((c) => c.length <= 1600), isTrue);
    });

    test('rejects an empty buffer and a non-positive chunk size', () {
      expect(
        () => chunkPcmSamples(Float32List(0), 1600).toList(),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => chunkPcmSamples(Float32List(10), 0).toList(),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('TTS result plausibility', () {
    test('accepts a coherent frame, sample, and duration relation', () {
      expect(
        () => validateTtsResultPlausibility(
          framesGenerated: 24000,
          maxFrames: 48000,
          sampleFrames: 24000,
          sampleRateHz: 24000,
          channelCount: 1,
          duration: const Duration(seconds: 1),
          label: 'row3.synthesis',
        ),
        returnsNormally,
      );
    });

    test('rejects zero frames and frames beyond the configured maximum', () {
      expect(
        () => validateTtsResultPlausibility(
          framesGenerated: 0,
          maxFrames: 48000,
          sampleFrames: 0,
          sampleRateHz: 24000,
          channelCount: 1,
          duration: Duration.zero,
          label: 'row3.synthesis',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => validateTtsResultPlausibility(
          framesGenerated: 48001,
          maxFrames: 48000,
          sampleFrames: 48001,
          sampleRateHz: 24000,
          channelCount: 1,
          duration: const Duration(seconds: 2),
          label: 'row3.synthesis',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects a duration that contradicts the sample count', () {
      expect(
        () => validateTtsResultPlausibility(
          framesGenerated: 24000,
          maxFrames: 48000,
          sampleFrames: 24000,
          sampleRateHz: 24000,
          channelCount: 1,
          duration: const Duration(seconds: 9),
          label: 'row3.synthesis',
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('does not confuse codec frames with decoded PCM sample frames', () {
      expect(
        () => validateTtsResultPlausibility(
          framesGenerated: 512,
          maxFrames: 512,
          sampleFrames: 240000,
          sampleRateHz: 24000,
          channelCount: 1,
          duration: const Duration(seconds: 10),
          label: 'row3.synthesis',
        ),
        returnsNormally,
        reason:
            'TextToSpeechResult.framesGenerated counts audio-codec frames, '
            'not decoded PCM sample frames.',
      );
    });

    test('rejects degenerate rate, channel, and sample values', () {
      expect(
        () => validateTtsResultPlausibility(
          framesGenerated: 10,
          maxFrames: 100,
          sampleFrames: 10,
          sampleRateHz: 0,
          channelCount: 1,
          duration: const Duration(milliseconds: 1),
          label: 'row3.synthesis',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => validateTtsResultPlausibility(
          framesGenerated: 10,
          maxFrames: 100,
          sampleFrames: 0,
          sampleRateHz: 24000,
          channelCount: 1,
          duration: const Duration(milliseconds: 1),
          label: 'row3.synthesis',
        ),
        throwsA(isA<StateError>()),
      );
      expect(
        () => validateTtsResultPlausibility(
          framesGenerated: 10,
          maxFrames: 100,
          sampleFrames: 10,
          sampleRateHz: 24000,
          channelCount: 0,
          duration: const Duration(milliseconds: 1),
          label: 'row3.synthesis',
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('Result Reporting and Count Validation', () {
    test('emits one machine-readable JSON RESULT record', () {
      final row = SpeechE2ERowResult(
        id: 'llama_cpp_qwen3_asr',
        status: SpeechE2ERowStatus.pass,
        backend: 'llama.cpp Metal',
        duration: const Duration(milliseconds: 1250),
        digestIdentifiers: {'model': '01234567', 'mmproj': '89abcdef'},
        assertionSummary: 'verified caps, transcribed fixture, verified mic',
      );

      final decoded = _decodeResultLine(row.toResultLine());
      expect(decoded['id'], equals('llama_cpp_qwen3_asr'));
      expect(decoded['status'], equals('PASS'));
      expect(decoded['backend'], equals('llama.cpp Metal'));
      expect(decoded['elapsedMs'], equals(1250));
      expect(
        decoded['digests'],
        equals({'model': '01234567', 'mmproj': '89abcdef'}),
      );
      expect(
        decoded['assertions'],
        equals('verified caps, transcribed fixture, verified mic'),
      );
      expect(decoded.containsKey('error'), isFalse);
      expect(decoded.containsKey('action'), isFalse);
    });

    test('serializes fingerprinted errors and action markers', () {
      final row = SpeechE2ERowResult(
        id: 'litert_lm_streaming_asr',
        status: SpeechE2ERowStatus.unavailable,
        backend: 'LiteRT-LM "CPU" backend',
        duration: const Duration(milliseconds: 40),
        error: const AudioRecordingException(
          AudioRecordingFailure.permissionDenied,
          'Microphone "access" denied\nby the user at /private/path.',
        ),
        actionMarker: microphonePermissionActionMarker,
      );

      final line = row.toResultLine();
      expect(line, isNot(contains('\n')));

      final decoded = _decodeResultLine(line);
      expect(decoded['status'], equals('UNAVAILABLE'));
      expect(decoded['backend'], equals('LiteRT-LM "CPU" backend'));
      expect(
        decoded['error'],
        equals('AudioRecordingException:permissionDenied'),
      );
      expect(line, isNot(contains('/private/path')));
      expect(line, isNot(contains('access')));
      expect(decoded['action'], equals(microphonePermissionActionMarker));
    });

    test('validates strict summary counts on expected 3 PASS, 1 UNSUPPORTED', () {
      final rows = [
        SpeechE2ERowResult(
          id: 'llama_cpp_qwen3_asr',
          status: SpeechE2ERowStatus.pass,
          backend: 'llama.cpp Metal',
          duration: const Duration(seconds: 2),
        ),
        SpeechE2ERowResult(
          id: 'litert_lm_streaming_asr',
          status: SpeechE2ERowStatus.pass,
          backend: 'LiteRT-LM ASR CPU',
          duration: const Duration(seconds: 1),
        ),
        SpeechE2ERowResult(
          id: 'llama_cpp_qwen3_tts',
          status: SpeechE2ERowStatus.pass,
          backend: 'llama.cpp Metal',
          duration: const Duration(seconds: 3),
        ),
        SpeechE2ERowResult(
          id: 'litert_lm_tts',
          status: SpeechE2ERowStatus.unsupported,
          backend: 'LiteRT-LM',
          duration: const Duration(milliseconds: 50),
        ),
      ];

      final summary = SpeechE2ESummary(rows);
      expect(summary.total, equals(4));
      expect(summary.passCount, equals(3));
      expect(summary.unsupportedCount, equals(1));
      expect(summary.failCount, equals(0));
      expect(summary.unavailableCount, equals(0));

      expect(() => summary.validateRowIds(), returnsNormally);
      expect(() => summary.validateStrictCounts(), returnsNormally);

      expect(
        summary.toSummaryLine(),
        equals(
          'SUMMARY physical_ios_speech total=4 pass=3 unsupported=1 fail=0 unavailable=0',
        ),
      );
    });

    test(
      'rejects summary when counts do not match expected strict standard',
      () {
        final failureRows = [
          SpeechE2ERowResult(
            id: 'llama_cpp_qwen3_asr',
            status: SpeechE2ERowStatus.pass,
            backend: 'backend1',
            duration: Duration.zero,
          ),
          SpeechE2ERowResult(
            id: 'litert_lm_streaming_asr',
            status: SpeechE2ERowStatus.fail,
            backend: 'backend2',
            duration: Duration.zero,
          ),
          SpeechE2ERowResult(
            id: 'litert_lm_tts',
            status: SpeechE2ERowStatus.unsupported,
            backend: 'backend3',
            duration: Duration.zero,
          ),
        ];

        final summary = SpeechE2ESummary(failureRows);
        expect(
          () => summary.validateStrictCounts(),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('rejects duplicate row identifiers', () {
      final summary = SpeechE2ESummary([
        for (final id in <String>[
          'llama_cpp_qwen3_asr',
          'llama_cpp_qwen3_asr',
          'llama_cpp_qwen3_tts',
          'litert_lm_tts',
        ])
          SpeechE2ERowResult(
            id: id,
            status: SpeechE2ERowStatus.pass,
            backend: 'b',
            duration: Duration.zero,
          ),
      ]);

      expect(
        () => summary.validateRowIds(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('Duplicate'), contains('llama_cpp_qwen3_asr')),
          ),
        ),
      );
    });

    test('rejects missing and unknown row identifiers', () {
      final missing = SpeechE2ESummary([
        SpeechE2ERowResult(
          id: 'llama_cpp_qwen3_asr',
          status: SpeechE2ERowStatus.pass,
          backend: 'b',
          duration: Duration.zero,
        ),
      ]);
      expect(
        () => missing.validateRowIds(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('Missing'),
          ),
        ),
      );

      final unknown = SpeechE2ESummary([
        for (final id in <String>[...speechE2ERowIds, 'rogue_row'])
          SpeechE2ERowResult(
            id: id,
            status: SpeechE2ERowStatus.pass,
            backend: 'b',
            duration: Duration.zero,
          ),
      ]);
      expect(
        () => unknown.validateRowIds(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('rogue_row'),
          ),
        ),
      );
    });

    test('declares exactly the four canonical row identifiers', () {
      expect(speechE2ERowIds, hasLength(4));
      expect(
        speechE2ERowIds,
        containsAll(<String>[
          'llama_cpp_qwen3_asr',
          'litert_lm_streaming_asr',
          'llama_cpp_qwen3_tts',
          'litert_lm_tts',
        ]),
      );
    });
  });

  group('Cancellation and Classification Helpers', () {
    test('distinguishes physical iOS app paths without private FFI', () {
      expect(
        isPhysicalIosApplicationExecutablePath(
          '/private/var/containers/Bundle/Application/INSTALL-ID/'
          'Runner.app/Runner',
        ),
        isTrue,
      );
      expect(
        isPhysicalIosApplicationExecutablePath(
          '/var/containers/Bundle/Application/INSTALL-ID/'
          'Runner.app/Frameworks/App.framework/App',
        ),
        isTrue,
      );
      for (final path in <String>[
        '/Users/test/Library/Developer/CoreSimulator/Devices/DEVICE/data/'
            'Containers/Bundle/Application/INSTALL-ID/Runner.app/Runner',
        '/private/var/mobile/Containers/Data/Application/INSTALL-ID/Runner',
        '/private/var/containers/Bundle/Application/INSTALL-ID/Runner',
        '/private/var/containers/Bundle/Application/INSTALL-ID/Runner.app',
        '/private/var/containers/Bundle/Application//Runner.app/Runner',
        '/private/var/containers/Bundle/Application/INSTALL-ID/'
            'Runner.app/../Runner',
        '/private/var/containers/Bundle/Application/INSTALL-ID/.app/Runner',
        '',
      ]) {
        expect(
          isPhysicalIosApplicationExecutablePath(path),
          isFalse,
          reason: 'Must reject non-device executable path: "$path"',
        );
      }
    });

    test(
      'requires exact runtime backend families and canonicalizes labels',
      () {
        expect(
          requireSpeechBackendIdentity(
            'Metal',
            SpeechE2EBackendKind.llamaCppMetal,
          ),
          'llama.cpp Metal',
        );
        expect(
          requireSpeechBackendIdentity(
            'LiteRT-LM ASR CPU',
            SpeechE2EBackendKind.liteRtLmAsrCpu,
          ),
          'LiteRT-LM ASR CPU',
        );
        expect(
          requireSpeechBackendIdentity(
            'LiteRT-LM CPU',
            SpeechE2EBackendKind.liteRtLm,
          ),
          'LiteRT-LM',
        );
        expect(
          () => requireSpeechBackendIdentity(
            'LiteRT-LM Metal',
            SpeechE2EBackendKind.llamaCppMetal,
          ),
          throwsA(isA<StateError>()),
        );
        expect(
          () => requireSpeechBackendIdentity(
            'Metal',
            SpeechE2EBackendKind.liteRtLm,
          ),
          throwsA(isA<StateError>()),
        );
      },
    );

    test('verifies STT and TTS cancellation terminal states', () {
      const sttCancelled = SpeechToTextCompletion.cancelled();
      expect(verifySttCancellation(sttCancelled), isTrue);

      final sttCompleted = SpeechToTextCompletion.completed(
        const SpeechToTextResult(text: 'test'),
      );
      expect(verifySttCancellation(sttCompleted), isFalse);

      const ttsCancelled = TextToSpeechCompletion.cancelled();
      expect(verifyTtsCancellation(ttsCancelled), isTrue);

      final ttsCompleted = TextToSpeechCompletion.completed(
        TextToSpeechResult(
          samples: Float32List(0),
          sampleRateHz: 24000,
          channelCount: 1,
          framesGenerated: 0,
          truncated: false,
        ),
      );
      expect(verifyTtsCancellation(ttsCompleted), isFalse);
    });

    test('requires real generation progress before cancelling', () {
      expect(
        shouldCancelOnTtsProgress(
          const TextToSpeechProgressEvent(
            phase: TextToSpeechProgressPhase.processingPrompt,
            promptTokensRemaining: 12,
            framesGenerated: 0,
            truncated: false,
          ),
        ),
        isFalse,
        reason: 'Prompt-phase progress is not evidence of real synthesis.',
      );
      expect(
        shouldCancelOnTtsProgress(
          const TextToSpeechProgressEvent(
            phase: TextToSpeechProgressPhase.generating,
            promptTokensRemaining: 0,
            framesGenerated: 0,
            truncated: false,
          ),
        ),
        isFalse,
        reason: 'Generation phase without frames is not real progress yet.',
      );
      expect(
        shouldCancelOnTtsProgress(
          const TextToSpeechProgressEvent(
            phase: TextToSpeechProgressPhase.generating,
            promptTokensRemaining: 0,
            framesGenerated: 128,
            truncated: false,
          ),
        ),
        isTrue,
      );
    });

    test('classifies LiteRT-LM unsupported TTS capabilities correctly', () {
      const unsupportedCaps = TextToSpeechCapabilities(
        isSupported: false,
        unsupportedReason:
            'The active backend does not expose dedicated text-to-speech.',
        backendName: 'LiteRT-LM',
      );

      final status = classifyLiteRtLmTtsSupport(unsupportedCaps);
      expect(status, equals(SpeechE2ERowStatus.unsupported));

      const unexpectedlySupported = TextToSpeechCapabilities(
        isSupported: true,
        backendName: 'LiteRT-LM',
      );
      expect(
        () => classifyLiteRtLmTtsSupport(unexpectedlySupported),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('unexpectedly supported'),
          ),
        ),
      );

      const blankReason = TextToSpeechCapabilities(
        isSupported: false,
        unsupportedReason: '   ',
        backendName: 'LiteRT-LM',
      );
      expect(
        () => classifyLiteRtLmTtsSupport(blankReason),
        throwsA(isA<StateError>()),
      );

      const wrongBackend = TextToSpeechCapabilities(
        isSupported: false,
        unsupportedReason: 'No TTS implementation.',
        backendName: 'Metal',
      );
      expect(
        () => classifyLiteRtLmTtsSupport(wrongBackend),
        throwsA(isA<StateError>()),
        reason: 'An unsupported llama.cpp route is not LiteRT-LM evidence.',
      );
    });

    test('verifies typed LiteRT-LM TTS synthesis error', () {
      final unsupportedException = LlamaUnsupportedException('TTS unsupported');
      expect(verifyLiteRtLmTtsSynthesisError(unsupportedException), isTrue);

      expect(
        () => verifyLiteRtLmTtsSynthesisError(Exception('Generic failure')),
        throwsA(isA<StateError>()),
      );
      Object? sanitizedFailure;
      try {
        verifyLiteRtLmTtsSynthesisError(
          Exception(
            'https://user:token@example.invalid/model '
            'private transcript words',
          ),
        );
      } catch (error) {
        sanitizedFailure = error;
      }
      expect(sanitizedFailure, isA<StateError>());
      expect(sanitizedFailure.toString(), isNot(contains('https://')));
      expect(sanitizedFailure.toString(), isNot(contains('token')));
      expect(sanitizedFailure.toString(), isNot(contains('transcript words')));
      expect(
        () => verifyLiteRtLmTtsSynthesisError(
          LlamaStateException('Load a projector first.'),
        ),
        throwsA(isA<StateError>()),
        reason: 'A state error is a defect, not an unsupported classification.',
      );
    });

    test('classifies microphone permission denial as UNAVAILABLE', () {
      const denied = AudioRecordingException(
        AudioRecordingFailure.permissionDenied,
        'Microphone permission was denied.',
      );

      expect(
        classifySpeechRowFailure(denied),
        equals(SpeechE2ERowStatus.unavailable),
      );
      expect(
        speechRowFailureMarker(denied),
        equals(microphonePermissionActionMarker),
      );
    });

    test('classifies an unsupported recorder as UNAVAILABLE', () {
      const unsupported = AudioRecordingException(
        AudioRecordingFailure.unsupported,
        'No recorder on this runtime.',
      );

      expect(
        classifySpeechRowFailure(unsupported),
        equals(SpeechE2ERowStatus.unavailable),
      );
      expect(speechRowFailureMarker(unsupported), isNotNull);
    });

    test('classifies semantic, backend, and config defects as FAIL', () {
      const startFailed = AudioRecordingException(
        AudioRecordingFailure.startFailed,
        'Recorder could not start.',
      );
      expect(
        classifySpeechRowFailure(startFailed),
        equals(SpeechE2ERowStatus.fail),
      );
      expect(speechRowFailureMarker(startFailed), isNull);

      expect(
        classifySpeechRowFailure(StateError('transcript mismatch')),
        equals(SpeechE2ERowStatus.fail),
      );
      expect(
        classifySpeechRowFailure(
          ArgumentError.value('', 'IOS_SPEECH_TTS_TEXT', 'missing'),
        ),
        equals(SpeechE2ERowStatus.fail),
      );
      expect(
        classifySpeechRowFailure(
          TimeoutException('row1.fixture.done exceeded 600s'),
        ),
        equals(SpeechE2ERowStatus.fail),
      );
      expect(
        classifySpeechRowFailure(LlamaUnsupportedException('nope')),
        equals(SpeechE2ERowStatus.fail),
      );
    });
  });
}
