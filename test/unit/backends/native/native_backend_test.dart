@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/backends/backend.dart';
import 'package:llamadart/src/backends/native/native_backend.dart';
import 'package:llamadart/src/core/engine/engine.dart';
import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/config/log_level.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:test/test.dart';

void main() {
  test('default native backend factory returns the format router', () async {
    final backend = LlamaBackend();

    try {
      expect(backend, isA<NativeAutoBackend>());
      expect(await backend.getBackendName(), 'Native auto');
      expect(backend.supportsUrlLoading, isFalse);
    } finally {
      await backend.dispose();
    }
  });

  test('routes GGUF and unknown formats to llama.cpp', () async {
    final llama = _FakeBackend(handle: 11);
    final litert = _FakeBackend(handle: 22);
    final backend = NativeAutoBackend(
      llamaCppFactory: () => llama,
      liteRtLmFactory: () => litert,
    );

    try {
      await backend.setLogLevel(LlamaLogLevel.debug);

      expect(
        await backend.modelLoad(
          '/models/gemma-4-E2B-it-Q4_K_S.gguf',
          const ModelParams(),
        ),
        11,
      );
      expect(llama.loadedPaths, ['/models/gemma-4-E2B-it-Q4_K_S.gguf']);
      expect(llama.logLevels, [LlamaLogLevel.debug]);
      expect(litert.loadedPaths, isEmpty);

      expect(
        await backend.modelLoad('/models/model.bin', const ModelParams()),
        11,
      );
      expect(llama.loadedPaths, [
        '/models/gemma-4-E2B-it-Q4_K_S.gguf',
        '/models/model.bin',
      ]);
      expect(llama.disposeCount, 0);
    } finally {
      await backend.dispose();
    }
  });

  test(
    'routes litertlm bundles to LiteRT-LM and disposes switched delegate',
    () async {
      final llama = _FakeBackend(handle: 11);
      final litert = _FakeBackend(handle: 22);
      final backend = NativeAutoBackend(
        llamaCppFactory: () => llama,
        liteRtLmFactory: () => litert,
      );

      try {
        await backend.modelLoad('/models/model.gguf', const ModelParams());
        expect(llama.loadedPaths, ['/models/model.gguf']);

        expect(
          await backend.modelLoad(
            '/models/gemma-4-E2B-it.litertlm',
            const ModelParams(),
          ),
          22,
        );
        expect(llama.disposeCount, 1);
        expect(litert.loadedPaths, ['/models/gemma-4-E2B-it.litertlm']);
        expect(await backend.getBackendName(), 'fake-22');
      } finally {
        await backend.dispose();
      }
    },
  );

  test('high-level engine loads litertlm with the default backend', () async {
    final tempDir = await Directory.systemTemp.createTemp(
      'llamadart_native_auto_litert_',
    );
    final modelFile = File('${tempDir.path}/model.litertlm');
    await modelFile.writeAsString('fake model');
    final engine = LlamaEngine(LlamaBackend());

    try {
      await engine.loadModel(
        modelFile.path,
        modelParams: const ModelParams(preferredBackend: GpuBackend.cpu),
      );

      expect(await engine.getBackendName(), 'LiteRT-LM cpu');
      expect(engine.isReady, isTrue);
    } finally {
      await engine.dispose();
      await tempDir.delete(recursive: true);
    }
  });
}

class _FakeBackend implements LlamaBackend {
  final int handle;
  final List<String> loadedPaths = <String>[];
  final List<LlamaLogLevel> logLevels = <LlamaLogLevel>[];
  int disposeCount = 0;

  _FakeBackend({required this.handle});

  @override
  bool get isReady => loadedPaths.isNotEmpty && disposeCount == 0;

  @override
  bool get supportsUrlLoading => false;

  @override
  Future<int> modelLoad(String path, ModelParams params) async {
    loadedPaths.add(path);
    return handle;
  }

  @override
  Future<String> getBackendName() async => 'fake-$handle';

  @override
  Future<void> setLogLevel(LlamaLogLevel level) async {
    logLevels.add(level);
  }

  @override
  Future<void> dispose() async {
    disposeCount += 1;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
