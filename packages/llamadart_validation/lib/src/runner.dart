import 'dart:async';

import 'package:llamadart/llamadart.dart';

import 'manifest.dart';

/// Sink implemented by file, browser and Firebase host adapters.
typedef ValidationEventSink = Future<void> Function(Map<String, dynamic> event);

/// Injectable public-API boundary for model-free harness regression tests.
abstract interface class ValidationEngine {
  Future<void> load(String location, ValidationProfile profile);
  Future<void> unload();
  Future<void> dispose();
  void cancel();
  Future<Map<String, dynamic>> diagnostics();
  Future<List<int>> tokenize(String text);
  Future<String> detokenize(List<int> tokens);
  Future<Map<String, dynamic>> generate(
    String prompt,
    ValidationProfile profile, {
    bool raw = false,
    int? maxTokens,
    bool cancelAfterFirst = false,
    List<LlamaChatMessage>? history,
  });
}

/// Runs inference through the exported llamadart API on every platform.
class PublicValidationEngine implements ValidationEngine {
  LlamaEngine _engine = LlamaEngine(LlamaBackend());
  bool _disposed = false;

  @override
  Future<void> load(String location, ValidationProfile profile) async {
    profile.requireRunnable();
    if (_disposed) {
      _engine = LlamaEngine(LlamaBackend());
      _disposed = false;
    }
    await _engine.setLogLevel(LlamaLogLevel.info);
    await _engine.loadModel(location, modelParams: profile.loadParams);
    if (!_engine.isReady) {
      throw StateError('loadModel returned without readiness');
    }
  }

  @override
  Future<void> unload() => _engine.unloadModel();
  @override
  Future<void> dispose() async {
    await _engine.dispose();
    _disposed = true;
  }

  @override
  void cancel() => _engine.cancelGeneration();
  @override
  Future<List<int>> tokenize(String text) =>
      _engine.tokenize(text, addSpecial: false);
  @override
  Future<String> detokenize(List<int> tokens) => _engine.detokenize(tokens);

  @override
  Future<Map<String, dynamic>> diagnostics() async => {
    'backend_name': await _engine.getBackendName(),
    'reported_gpu_layers': await _engine.getResolvedGpuLayers(),
    'context_size': await _engine.getContextSize(),
    'model_metadata': await _engine.getMetadata(),
    // These public values can contain selector hints. They are not placement proof.
    'accelerator_execution_verified': false,
    'accelerator_evidence_reason':
        'requires correlated native driver/offload diagnostics',
  };

  @override
  Future<Map<String, dynamic>> generate(
    String prompt,
    ValidationProfile profile, {
    bool raw = false,
    int? maxTokens,
    bool cancelAfterFirst = false,
    List<LlamaChatMessage>? history,
  }) async {
    final text = StringBuffer();
    final thinking = StringBuffer();
    final finish = <String>[];
    var chunks = 0;
    int? firstUs;
    int? cancelUs;
    final params = profile.generationParams.copyWith(maxTokens: maxTokens);
    final watch = Stopwatch()..start();
    void append(String content) {
      if (content.isEmpty) return;
      firstUs ??= watch.elapsedMicroseconds;
      text.write(content);
      if (text.length > 65536) {
        cancel();
        throw StateError('Output exceeded the 64 KiB core limit');
      }
      if (cancelAfterFirst && cancelUs == null) {
        cancelUs = watch.elapsedMicroseconds;
        cancel();
      }
    }

    String? cancellationAbort;
    try {
      if (raw) {
        await for (final delta in _engine.generate(prompt, params: params)) {
          chunks++;
          append(delta);
        }
      } else {
        await for (final chunk in _engine.create(
          history ??
              [
                LlamaChatMessage.fromText(
                  role: LlamaChatRole.user,
                  text: prompt,
                ),
              ],
          params: params,
          enableThinking: false,
        )) {
          chunks++;
          for (final choice in chunk.choices) {
            append(choice.delta.content ?? '');
            thinking.write(choice.delta.thinking ?? '');
            if (thinking.length > 65536) {
              cancel();
              throw StateError('Thinking exceeded the 64 KiB core limit');
            }
            if (choice.finishReason != null) finish.add(choice.finishReason!);
          }
        }
      }
    } on LlamaInferenceException catch (error) {
      // The pinned WASM delegate surfaces cancellation as this explicit abort.
      if (cancelUs != null &&
          error.message == 'Generation failed' &&
          '${error.details}' == 'AbortError: Generation was cancelled.') {
        cancellationAbort = error.toString();
      } else {
        rethrow;
      }
    }
    watch.stop();
    // Tokenization and diagnostic reads occur after the timed region.
    int? estimatedTokens;
    try {
      estimatedTokens = (await tokenize(text.toString())).length;
    } catch (_) {}
    BackendPerfContextData? perf;
    try {
      perf = await _engine.getPerformanceContext();
    } catch (_) {}
    final wallMs = watch.elapsedMicroseconds / 1000;
    final nativeMs = perf?.decodeMs ?? perf?.evalMs;
    final nativeTokens = perf?.evalTokens;
    return {
      'prompt': prompt,
      if (history != null) 'messages': history.map((m) => m.toJson()).toList(),
      'max_tokens': params.maxTokens,
      'enable_thinking': false,
      'content': text.toString(),
      'thinking': thinking.toString(),
      'chunks': chunks,
      'finish_reasons': finish,
      'cancel_requested': cancelUs != null,
      'cancel_abort_observed': cancellationAbort != null,
      'cancel_abort': ?cancellationAbort,
      'cancel_to_done_ms': cancelUs == null
          ? null
          : (watch.elapsedMicroseconds - cancelUs!) / 1000,
      'metrics': {
        'wall_ms': wallMs,
        'ttfa_ms': firstUs == null ? null : firstUs! / 1000,
        'native_ttft_ms': null,
        'estimated_output_tokens': estimatedTokens,
        'token_count_source': 'retokenized visible output; not stream chunks',
        'estimated_wall_tps': wallMs > 0 && estimatedTokens != null
            ? estimatedTokens * 1000 / wallMs
            : null,
        'native_decode_tokens': nativeTokens,
        'native_decode_ms': nativeMs,
        'native_decode_tps':
            nativeMs != null &&
                nativeMs > 0 &&
                nativeTokens != null &&
                nativeTokens > 0
            ? nativeTokens * 1000 / nativeMs
            : null,
        'native_timing_source': perf == null
            ? null
            : 'getPerformanceContext per-request counters',
        'native_prompt_tokens': perf?.promptEvalTokens,
        'native_prompt_ms': perf?.promptEvalMs,
        'missing_native_metrics_reason': perf == null
            ? 'backend did not expose counters'
            : null,
      },
    };
  }
}

/// Single model/profile run. Assertion failures do not suppress later cases.
class ValidationRunner {
  ValidationRunner({
    required this.profile,
    required this.engine,
    required this.emit,
    this.caseTimeout = const Duration(seconds: 60),
  });

  final ValidationProfile profile;
  final ValidationEngine engine;
  final ValidationEventSink emit;
  final Duration caseTimeout;
  var _sequence = 0;
  var _cancelled = false;
  bool _closed = false;
  bool _poisoned = false;
  bool _settled = true;

  /// Request cancellation from the UI or host without marking success.
  void cancel() {
    _cancelled = true;
    engine.cancel();
  }

  /// Expanded obligations, including explicitly unimplemented release cases.
  List<String> get caseIds => [
    'C01.load',
    'C02.unicode',
    'C03.raw',
    if (profile.isChat) ...['C04.hello', 'C04.arithmetic', 'C06.history'],
    'C08.cancel',
    'C09.reload',
    'C10.limit',
    'C12.recovery',
    'B01.warmup',
    'B01.1',
    'B01.2',
    'B01.3',
    if (profile.selection == 'release') ...[
      'C05.thinking',
      'C07.tools',
      'C10.stop',
      'C11.batching',
      'C12.guards',
    ],
  ];

  /// Captures a run without pretending selector diagnostics prove GPU placement.
  Future<void> run(
    String location, {
    required String runId,
    required Map<String, dynamic> environment,
    Map<String, dynamic> preparation = const {},
  }) async {
    try {
      await emit({
        'type': 'manifest',
        'schema_version': 1,
        'run_id': runId,
        'profile': profile.toJson(),
        'profile_hash': jsonHash(profile.toJson()),
        'effective_config': profile.effectiveConfig,
        'config_hash': jsonHash(profile.effectiveConfig),
        'environment': environment,
        'preparation': preparation,
        'case_ids': caseIds,
        'started_at': DateTime.now().toUtc().toIso8601String(),
        'accelerator_evidence_required': profile.requiresAcceleratorProof,
      });
      var usable = false;
      var poisoned = false;
      for (final id in caseIds) {
        if (_cancelled || poisoned || (!usable && id != 'C01.load')) {
          await _record(id, 'NOT_RUN', {
            'reason': _cancelled
                ? 'cancelled'
                : poisoned
                ? 'prior_timeout'
                : 'model_load_failed',
          });
          continue;
        }
        if (id == 'C05.thinking' ||
            id == 'C07.tools' ||
            id == 'C10.stop' ||
            id == 'C11.batching' ||
            id == 'C12.guards') {
          await _record(id, 'NOT_RUN', {
            'reason': 'release feature pack not implemented',
          });
          continue;
        }
        await emit({
          'type': 'case_start',
          'case_id': id,
          'sequence': _sequence++,
        });
        final watch = Stopwatch()..start();
        try {
          _settled = false;
          final pending = _runCase(
            id,
            location,
          ).whenComplete(() => _settled = true);
          final actual = await pending.timeout(caseTimeout);
          if (id == 'C01.load') usable = true;
          final status = actual.remove('status') as String? ?? 'PASS';
          await _record(id, status, {
            ...actual,
            'elapsed_ms': watch.elapsedMicroseconds / 1000,
          });
        } on TimeoutException {
          poisoned = true;
          _poisoned = true;
          engine.cancel();
          await _record(id, 'ERROR', {
            'reason': 'case_timeout',
            'timeout_ms': caseTimeout.inMilliseconds,
          });
        } catch (error) {
          await _record(id, 'ERROR', {
            'reason': 'runtime_exception',
            'error_type': error.runtimeType.toString(),
            'message': redactDiagnostic('$error'),
          });
        }
      }
    } finally {
      _closed = true;
      try {
        await engine.dispose().timeout(const Duration(seconds: 10));
        await emit({
          'type': 'cleanup',
          'status': _settled ? 'PASS' : 'ERROR',
          if (!_settled)
            'message': 'Timed-out backend operation has not settled',
          'sequence': _sequence++,
        });
      } catch (error) {
        await emit({
          'type': 'cleanup',
          'status': 'ERROR',
          'sequence': _sequence++,
          'message': redactDiagnostic('$error'),
        });
      }
      await emit({
        'type': 'run_end',
        'sequence': _sequence++,
        'cancelled': _cancelled,
      });
    }
  }

  Future<void> _record(String id, String status, Map<String, dynamic> values) =>
      emit({
        'type': 'case',
        'case_id': id,
        'status': status,
        'sequence': _sequence++,
        ...values,
      });

  String get _shortPrompt => profile.isChat
      ? 'Reply with one short sentence saying hello.'
      : 'Once upon a time';

  Future<T> _checked<T>(Future<T> Function() operation) async {
    void check() {
      if (_closed || _poisoned || _cancelled) {
        throw StateError('Case no longer active');
      }
    }

    check();
    final result = await operation();
    check();
    return result;
  }

  Future<Map<String, dynamic>> _short() => _checked(
    () => engine.generate(_shortPrompt, profile, raw: !profile.isChat),
  );

  Map<String, dynamic> _nonempty(Map<String, dynamic> output) => {
    ...output,
    'expected': 'nonempty finite output',
    'status': (output['content'] as String).trim().isNotEmpty ? 'PASS' : 'FAIL',
  };

  Future<Map<String, dynamic>> _withDiagnostics(
    Map<String, dynamic> output,
  ) async {
    final diagnostics = await _checked(() => engine.diagnostics());
    final name = (diagnostics['backend_name'] as String? ?? '').toLowerCase();
    final runtimeResolved =
        name.startsWith('litert-lm') == (profile.runtime == 'litert');
    final metadata = diagnostics['model_metadata'] as Map? ?? {};
    final wasmCpu =
        name == 'wasm (prototype bridge)' &&
        metadata['llamadart.webgpu.n_gpu_layers'] == '0' &&
        metadata['llamadart.webgpu.core_variant'] == 'wasm32';
    final cpuResolved =
        (name.contains('cpu') || wasmCpu) &&
        !RegExp(r'cuda|metal|vulkan|\bgpu\b|\bnpu\b').hasMatch(name);
    return {
      ...output,
      'diagnostics': diagnostics,
      'status': !runtimeResolved || (profile.backend == 'cpu' && !cpuResolved)
          ? 'FAIL'
          : output['status'] as String? ?? 'PASS',
      if (!runtimeResolved)
        'reason': 'Resolved runtime does not match model format',
      if (runtimeResolved && profile.backend == 'cpu' && !cpuResolved)
        'reason': 'Explicit CPU profile did not resolve to CPU diagnostics',
    };
  }

  Future<Map<String, dynamic>> _runCase(String id, String location) async {
    switch (id) {
      case 'C01.load':
        await _checked(() => engine.load(location, profile));
        return _withDiagnostics({});
      case 'C02.unicode':
        const text = 'Montréal 👋\n한글 café';
        final tokens = await _checked(() => engine.tokenize(text));
        final decoded = await _checked(() => engine.detokenize(tokens));
        final prefix =
            (profile.fixtures['unicode'] as Map?)?['expected_prefix']
                as String? ??
            '';
        final expected = '$prefix$text';
        return {
          'input': text,
          'tokens': tokens,
          'decoded': decoded,
          'expected': expected,
          'tokenizer_prefix': prefix,
          'status': decoded == expected ? 'PASS' : 'FAIL',
        };
      case 'C03.raw':
        return _nonempty(
          await _checked(
            () => engine.generate('Once upon a time', profile, raw: true),
          ),
        );
      case 'C04.hello':
      case 'C04.arithmetic':
        final arithmetic = id.endsWith('arithmetic');
        final fixture =
            profile.fixtures[arithmetic ? 'arithmetic' : 'hello'] as Map?;
        final prompt =
            fixture?['prompt'] as String? ??
            (arithmetic
                ? 'What is 2 + 2? Reply with only the number.'
                : _shortPrompt);
        final expected =
            fixture?['regex'] as String? ??
            (arithmetic ? r'^4[.!]?$' : r'\bhello\b');
        final output = await _checked(() => engine.generate(prompt, profile));
        final text = (output['content'] as String).trim();
        return {
          ...output,
          'expected_regex': expected,
          'status':
              RegExp(expected, caseSensitive: false).hasMatch(text) &&
                  (output['thinking'] as String).isEmpty
              ? 'PASS'
              : 'FAIL',
        };
      case 'C06.history':
        const prompt = 'What is the secret code? Reply with only the code.';
        final output = await _checked(
          () => engine.generate(
            prompt,
            profile,
            history: const [
              LlamaChatMessage.fromText(
                role: LlamaChatRole.system,
                text: 'Remember the secret code exactly.',
              ),
              LlamaChatMessage.fromText(
                role: LlamaChatRole.user,
                text: 'The secret code is cedar17.',
              ),
              LlamaChatMessage.fromText(
                role: LlamaChatRole.assistant,
                text: 'I will remember the code.',
              ),
              LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt),
            ],
          ),
        );
        return {
          ...output,
          'expected': 'cedar17',
          'status': (output['content'] as String).trim() == 'cedar17'
              ? 'PASS'
              : 'FAIL',
        };
      case 'C08.cancel':
        final prompt = profile.isChat
            ? 'Write a long story about a fox. Continue for at least 500 words.'
            : 'Once upon a time';
        final control = await _checked(
          () => engine.generate(
            prompt,
            profile,
            raw: !profile.isChat,
            maxTokens: 256,
          ),
        );
        final output = await _checked(
          () => engine.generate(
            prompt,
            profile,
            raw: !profile.isChat,
            maxTokens: 256,
            cancelAfterFirst: true,
          ),
        );
        final recovery = await _short();
        final duration = output['cancel_to_done_ms'] as num?;
        final fullTokens =
            (control['metrics'] as Map?)?['native_decode_tokens'] as num?;
        final cancelledTokens =
            (output['metrics'] as Map?)?['native_decode_tokens'] as num?;
        final prefixMatches =
            (output['content'] as String).isNotEmpty &&
            (control['content'] as String).startsWith(
              output['content'] as String,
            );
        final nativeInterruption =
            fullTokens != null &&
            cancelledTokens != null &&
            cancelledTokens > 0 &&
            cancelledTokens < fullTokens;
        final interrupted =
            prefixMatches &&
            (nativeInterruption || output['cancel_abort_observed'] == true);

        return {
          ...output,
          'recovery': recovery,
          'uncancelled_control': control,
          'interruption_observed': interrupted,
          'status': output['cancel_requested'] != true || !interrupted
              ? 'NOT_RUN'
              : duration != null &&
                    duration <= 5000 &&
                    (recovery['content'] as String).trim().isNotEmpty
              ? 'PASS'
              : 'FAIL',
          'reason':
              'requires fewer native decoded tokens or an explicit cancellation abort, matching the seeded control prefix, prompt recovery and bounded cancellation latency',
        };
      case 'C09.reload':
        await _checked(() => engine.dispose());
        await _checked(() => engine.load(location, profile));
        return _withDiagnostics(_nonempty(await _short()));
      case 'C10.limit':
        final output = await _checked(
          () => engine.generate(
            _shortPrompt,
            profile,
            raw: !profile.isChat,
            maxTokens: 1,
          ),
        );
        final count =
            (output['metrics'] as Map)['native_decode_tokens'] as num?;
        return {
          ...output,
          'expected': 'at most one native decoded token',
          'status': count == null
              ? 'NOT_RUN'
              : count == 1
              ? 'PASS'
              : 'FAIL',
          if (count == null)
            'reason': 'native token counter unavailable; chunks are not tokens',
        };
      case 'C12.recovery':
        await _checked(() => engine.unload());
        String? errorType;
        try {
          await _checked(() => engine.load('$location.missing', profile));
        } on LlamaException catch (error) {
          errorType = error.runtimeType.toString();
        }
        await _checked(() => engine.unload());
        await _checked(() => engine.load(location, profile));
        final output = await _short();
        return _withDiagnostics({
          ...output,
          'rejected_error_type': errorType,
          'status':
              errorType != null &&
                  (output['content'] as String).trim().isNotEmpty
              ? 'PASS'
              : 'FAIL',
          'expected': 'typed missing-model error and valid recovery',
        });
      default:
        final prompt = profile.isChat
            ? 'List the numbers from one to twenty in English.'
            : 'Once upon a time';
        return {
          ..._nonempty(
            await _checked(
              () => engine.generate(prompt, profile, raw: !profile.isChat),
            ),
          ),
          'benchmark': true,
          'warmup': id == 'B01.warmup',
          'cohort': profile.isChat
              ? 'short-generation'
              : 'tiny-packaging-diagnostic',
        };
    }
  }
}

/// Bounds and removes common credential/path material from diagnostic exports.
String redactDiagnostic(String value) {
  final redacted = value
      .replaceAll(
        RegExp(r'bearer\s+[^\s]+', caseSensitive: false),
        'Bearer [redacted]',
      )
      .replaceAll(RegExp(r'https?://[^\s]+\?[^\s]+'), '[signed URL redacted]')
      .replaceAll(RegExp(r'/(?:Users|home)/[^\s/]+'), '/[user]');
  return redacted.length <= 8192
      ? redacted
      : '${redacted.substring(0, 8192)}[truncated]';
}
