import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  Future<BenchmarkRunSummary> benchmark(_UsageEngine engine) async {
    final shared = _SharedEngine(engine);
    final port = DirectLlamaPlaygroundPort(sharedChatPort: shared);
    addTearDown(() async {
      await port.dispose();
      await shared.runtime.dispose();
      await engine.dispose();
    });
    return port.runBenchmark(targetDecodeTokens: 8);
  }

  test(
    'benchmark prefers final completion usage over raw text and diagnostics',
    () async {
      final engine = _UsageEngine(usage: true, diagnostics: _diagnostics(67));
      final result = await benchmark(engine);
      expect(result.promptTokens, 43);
      expect(result.generatedTokens, 8);
      expect(engine.diagnosticReads, 0);
    },
  );

  test(
    'benchmark falls back to evaluated diagnostics when usage is absent',
    () async {
      final engine = _UsageEngine(usage: false, diagnostics: _diagnostics(57));
      final result = await benchmark(engine);
      expect(result.promptTokens, 57);
      expect(engine.diagnosticReads, 1);
    },
  );

  test(
    'benchmark refuses to present a raw-text estimate as evaluated tokens',
    () async {
      final engine = _UsageEngine(usage: false);
      await expectLater(
        benchmark(engine),
        throwsA(isA<LlamaUnsupportedException>()),
      );
      expect(engine.diagnosticReads, 1);
    },
  );
}

BackendPerfContextData _diagnostics(int tokens) => BackendPerfContextData(
  loadMs: 0,
  promptEvalMs: 1,
  evalMs: 1,
  sampleMs: 1,
  promptEvalTokens: tokens,
  evalTokens: 8,
  sampleCount: 8,
  reusedGraphs: 0,
);

class _SharedEngine implements SharedLlamaEngineProvider {
  _SharedEngine(this.engine);
  final LlamaEngine engine;
  final runtime = StateStore<StudioRuntimeSnapshot>(
    const StudioRuntimeSnapshot(
      phase: StudioEnginePhase.ready,
      activeModelLabel: 'Fixture model',
      backendName: 'Fixture backend',
    ),
  );
  @override
  bool get isEngineReady => true;
  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => runtime;
  @override
  Future<T> runExclusiveOnEngine<T>(
    String label,
    Future<T> Function(LlamaEngine) action,
  ) => action(engine);
}

class _UsageEngine extends LlamaEngine {
  _UsageEngine({required this.usage, this.diagnostics})
    : super(FakeSpeculativeFallbackBackend());
  final bool usage;
  final BackendPerfContextData? diagnostics;
  int diagnosticReads = 0;

  @override
  Future<int> getTokenCount(String text) async => 17;

  @override
  Future<BackendPerfContextData?> getPerformanceContext() async {
    diagnosticReads++;
    return diagnostics;
  }

  @override
  Stream<LlamaCompletionChunk> create(
    List<LlamaChatMessage> messages, {
    GenerationParams? params,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    bool parallelToolCalls = false,
    bool enableThinking = true,
    Map<String, dynamic>? responseFormat,
    String? sourceLangCode,
    String? targetLangCode,
    Map<String, dynamic>? chatTemplateKwargs,
    DateTime? templateNow,
  }) async* {
    await Future<void>.delayed(const Duration(milliseconds: 2));
    yield LlamaCompletionChunk(
      id: 'fixture',
      object: 'chat.completion.chunk',
      created: 0,
      model: 'fixture',
      choices: [
        LlamaCompletionChunkChoice(
          index: 0,
          delta: LlamaCompletionChunkDelta(content: 'answer'),
        ),
      ],
      usage: usage
          ? const LlamaGenerationUsage(promptTokens: 21, completionTokens: 1)
          : null,
    );
    yield LlamaCompletionChunk(
      id: 'fixture',
      object: 'chat.completion.chunk',
      created: 0,
      model: 'fixture',
      choices: const [],
      usage: usage
          ? const LlamaGenerationUsage(promptTokens: 43, completionTokens: 8)
          : null,
    );
  }
}
