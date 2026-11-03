@TestOn('vm && (mac-os || linux)')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_legacy_service_client.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime_client_contract.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_service.dart';
import 'package:llamadart/src/core/speech/litert_lm_speech_to_text_driver_io.dart';
import 'package:test/test.dart';

LiteRtLmRuntimeClientContract _stagedSpeech(String? path) =>
    LiteRtLmLegacyServiceClient(
      createLiteRtLmSelectedRuntimeClient(
        libraryPath: path,
        allowV1: true,
        eager: true,
      ),
    );

LiteRtLmRuntimeClientContract _stagedOldMacSpeech(String? path) =>
    createLiteRtLmSelectedServiceClient(
      libraryPath: path,
      allowV1: true,
      macOsVersion: 'Version 13.7',
      eager: true,
    );

void main() {
  late Directory directory;
  final paths = <String, String>{};
  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('litert_selected_');
    for (final entry in {
      'legacy': 'c_api_legacy_service.c',
      'v1': 'c_api_v1_asr.c',
      'missing': 'c_api_version.c',
    }.entries) {
      final path =
          '${directory.path}/${entry.key}.${Platform.isMacOS ? 'dylib' : 'so'}';
      final result = await Process.run('cc', [
        '-shared',
        '-fPIC',
        '-pthread',
        'test/fixtures/litert_lm/${entry.value}',
        '-o',
        path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      paths[entry.key] = path;
    }
  });
  tearDownAll(() => directory.delete(recursive: true));

  test(
    'public facade remains lazy and keeps v1 production selection disabled',
    () async {
      final client = LiteRtLmRuntimeClient(libraryPath: paths['v1']);
      client.configureResponseThinkingTags(
        startTag: '<think>',
        endTag: '</think>',
      );
      expect(client.nativeSettlement, LiteRtLmNativeSettlement.settled);
      expect(client.supportsFinishReasons, isFalse);
      await expectLater(
        client.initialize(modelPath: 'unused', backend: 'cpu'),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'pending migration',
            contains('#1677'),
          ),
        ),
      );
      client.dispose();
    },
  );

  test(
    'staged discovery selects complete v1 without creating engines for probes',
    () {
      final client = createLiteRtLmSelectedRuntimeClient(
        libraryPath: paths['v1'],
        allowV1: true,
      );
      final library = DynamicLibrary.open(paths['v1']!);
      int live() => library.lookupFunction<Int Function(), int Function()>(
        'fixture_live',
      )();
      expect(client.supportsFinishReasons, isTrue);
      expect(client.supportsAsrBridge, isTrue);
      expect(live(), 0);
      client.dispose();
      expect(live(), 0);
    },
  );

  test(
    'staged facade routes actual engine creation and tokenizer through v1',
    () async {
      final client = createLiteRtLmSelectedRuntimeClient(
        libraryPath: paths['v1'],
        allowV1: true,
      );
      addTearDown(client.dispose);
      await client.initialize(
        modelPath: 'unused',
        backend: 'cpu',
        speculativeDecoding: false,
      );
      expect(client.tokenize('hello', addSpecial: false), [5, 104, 111]);
      expect(client.nativeSettlement, LiteRtLmNativeSettlement.settled);
    },
  );

  test(
    'service fresh capability and finish probes share staged selection without engines',
    () {
      final service = LiteRtLmService(
        runtimeClientFactory: () => createLiteRtLmSelectedServiceClient(
          libraryPath: paths['v1'],
          allowV1: true,
        ),
      );
      addTearDown(service.dispose);
      expect(service.reportsFinishReasons(), isTrue);
      expect(service.generationControls().penalties, isTrue);
      final library = DynamicLibrary.open(paths['v1']!);
      expect(
        library.lookupFunction<Int Function(), int Function()>(
          'fixture_live',
        )(),
        0,
      );
    },
  );

  test('staged discovery preserves legacy runtime and arities', () async {
    final client = createLiteRtLmSelectedRuntimeClient(
      libraryPath: paths['legacy'],
      allowV1: true,
    );
    expect(client.supportsAsrBridge, isFalse);
    await client.initialize(
      modelPath: 'unused',
      backend: 'cpu',
      speculativeDecoding: false,
    );
    client.dispose();
  });

  test('incomplete v1 refuses before any arity-bomb engine function', () async {
    final client = createLiteRtLmSelectedRuntimeClient(
      libraryPath: paths['missing'],
      allowV1: true,
    );
    await expectLater(
      client.initialize(modelPath: 'unused', backend: 'cpu'),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.message,
          'required symbols',
          contains('missing required'),
        ),
      ),
    );
    client.dispose();
  });

  test('public speech default retains typed pending-v1 guidance', () async {
    final support = await createLiteRtLmSpeechToTextDriver().probeSupport(
      libraryPath: paths['v1'],
    );
    expect(support.isSupported, isFalse);
    expect(support.unsupportedReason, contains('#1677'));
  });

  test(
    'same staged selector serves speech capability and receiving-isolate worker',
    () async {
      final driver = createLiteRtLmSpeechToTextDriverWithRuntime(_stagedSpeech);
      expect(
        (await driver.probeSupport(libraryPath: paths['v1'])).isSupported,
        isTrue,
      );
      final worker = await driver.start(
        LiteRtLmAsrRuntimeConfig.source(
          model: ModelSource.path('fixture.litertlm'),
          tokenizer: ModelSource.path('fixture.json'),
          modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
        ),
        libraryPath: paths['v1'],
      );
      final subscription = worker.updates.listen((_) {});
      try {
        expect(await worker.pushAudio(Float32List(4)), 4);
        expect(await worker.finish(), contains('final café'));
      } finally {
        await worker.dispose();
        await subscription.cancel();
      }
    },
  );

  test(
    'macOS 13 speech probe and receiving-isolate worker refuse before dlopen',
    () async {
      if (!Platform.isMacOS) return;
      final driver = createLiteRtLmSpeechToTextDriverWithRuntime(
        _stagedOldMacSpeech,
      );
      for (final path in [null, '/not-a-runtime.dylib']) {
        final support = await driver.probeSupport(libraryPath: path);
        expect(support.isSupported, isFalse);
        expect(support.unsupportedReason, contains('macOS 14'));
        await expectLater(
          driver.start(
            LiteRtLmAsrRuntimeConfig.source(
              model: ModelSource.path('fixture.litertlm'),
              tokenizer: ModelSource.path('fixture.json'),
              modelPreset: LiteRtLmAsrModelPreset.moonshineTiny,
            ),
            libraryPath: path,
          ),
          throwsA(
            isA<LlamaSpeechException>().having(
              (error) => error.details,
              'floor before load',
              contains('macOS 14'),
            ),
          ),
        );
      }
    },
  );

  test('macOS 13 refuses packaged and explicit discovery before dlopen', () {
    if (!Platform.isMacOS) return;
    for (final path in [null, '/not-a-runtime.dylib']) {
      expect(
        () => createLiteRtLmSelectedRuntimeClient(
          libraryPath: path,
          allowV1: true,
          macOsVersion: 'Version 13.7',
          eager: true,
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'floor before load',
            contains('macOS 14'),
          ),
        ),
      );
    }
  });
}
