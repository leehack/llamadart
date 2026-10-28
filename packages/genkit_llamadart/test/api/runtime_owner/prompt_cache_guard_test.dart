@TestOn('vm')
library;

import 'dart:typed_data';

import 'package:genkit_llamadart/genkit_llamadart.dart';
import 'package:llamadart/llamadart.dart' as llama;
import 'package:test/test.dart';

import '../../core/runtime/test_support/fake_runtime.dart';

void main() {
  test(
    'custom cache runtimes reject before model or filesystem access',
    () async {
      final runtime = FakeRuntime();
      final pool = LlamaDartRuntimePool(
        model: const LlamaModelDefinition(
          name: 'guard',
          modelPath: '/SECRET/missing.gguf',
        ),
        runtimeFactory: () => runtime,
        enablePromptCache: true,
      );
      addTearDown(pool.close);
      await expectLater(
        pool.open(),
        throwsA(
          predicate<Object>(
            (e) =>
                e is LlamaUnsupportedException &&
                !e.toString().contains('SECRET'),
          ),
        ),
      );
      expect(runtime.initializeCount, 0);
      expect(runtime.disposeCount, 1);
    },
  );

  test('disabled prompt caches never evaluate custom runtimes', () async {
    final runtime = FakeRuntime()
      ..capabilitySnapshot = const llama.LlamaEngineCapabilities(
        isSupported: true,
        runtime: llama.LlamaRuntime.llamaCpp,
      );
    final pool = LlamaDartRuntimePool(
      model: const LlamaModelDefinition(
        name: 'guard',
        modelPath: '/SECRET/missing.gguf',
      ),
      runtimeFactory: () => runtime,
    );
    addTearDown(pool.close);
    final owner = await pool.open();
    await expectLater(
      owner.cachePrompt('never evaluates'),
      throwsA(isA<LlamaUnsupportedException>()),
    );
    expect(runtime.generateCallCount, 0);
    expect(runtime.disposeCount, 1);
  });

  test('prompt cache export requires prompt caches', () {
    expect(
      () => LlamaDartRuntimePool(
        model: const LlamaModelDefinition(
          name: 'guard',
          modelPath: '/SECRET/missing.gguf',
        ),
        enablePromptCacheExport: true,
      ),
      throwsArgumentError,
    );
  });

  test(
    'import without export rejects before runtime or bytes access',
    () async {
      final runtime = FakeRuntime()
        ..capabilitySnapshot = const llama.LlamaEngineCapabilities(
          isSupported: true,
          runtime: llama.LlamaRuntime.llamaCpp,
        );
      final pool = LlamaDartRuntimePool(
        model: const LlamaModelDefinition(
          name: 'guard',
          modelPath: '/SECRET/missing.gguf',
        ),
        runtimeFactory: () => runtime,
      );
      addTearDown(pool.close);
      final owner = await pool.open();
      await expectLater(
        owner.importPromptCache(Uint8List(0), prompt: 'never tokenized'),
        throwsA(
          predicate<Object>(
            (e) =>
                e is LlamaUnsupportedException &&
                !e.toString().contains('SECRET'),
          ),
        ),
      );
      expect(owner.isClosed, isFalse);
      expect(runtime.generateCallCount, 0);
    },
  );
}
