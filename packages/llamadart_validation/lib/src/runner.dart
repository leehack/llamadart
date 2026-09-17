import 'dart:async';
import 'dart:convert';

import 'package:llamadart/llamadart.dart';

import 'case_catalog.dart';
import 'manifest.dart';
import 'npu_evidence.dart';

/// Sink implemented by file, browser and Firebase host adapters.
typedef ValidationEventSink = Future<void> Function(Map<String, dynamic> event);

/// Injectable public-API boundary for model-free harness regression tests.
abstract interface class ValidationEngine {
  /// Whether the adapter executes in a browser, independent of profile input.
  bool get isWeb;
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
    int? streamBatchTokens,
    int? streamBatchBytes,
    bool cancelAfterFirst = false,
    List<LlamaChatMessage>? history,
  });
}

/// Runs inference through the exported llamadart API on every platform.
class PublicValidationEngine implements ValidationEngine {
  /// Uses the public engine; a factory allows isolated adapter verification.
  PublicValidationEngine({this.npu, LlamaEngine Function()? engineFactory})
    : _engineFactory = engineFactory ?? (() => LlamaEngine(LlamaBackend()));
  final NpuExecutionMonitor? npu;
  final LlamaEngine Function() _engineFactory;
  late LlamaEngine _engine = _engineFactory();
  @override
  bool get isWeb => const bool.fromEnvironment('dart.library.js_interop');
  bool _disposed = false;

  @override
  Future<void> load(String location, ValidationProfile profile) async {
    profile.requireRunnable(verifiedAndroidNpuHost: npu != null);
    if (_disposed) {
      _engine = _engineFactory();
      _disposed = false;
    }
    await _engine.setLogLevel(LlamaLogLevel.info);
    await _engine.loadModel(
      location,
      modelParams: profile.loadParams.copyWith(
        liteRtLmDispatchLibDir: npu?.dispatchDirectory,
      ),
    );
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
    if (npu != null) 'npu_identity': npu!.identity,
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
    int? streamBatchTokens,
    int? streamBatchBytes,
    bool cancelAfterFirst = false,
    List<LlamaChatMessage>? history,
  }) async {
    final text = StringBuffer();
    final thinking = StringBuffer();
    final finish = <String>[];
    final toolDeltas = <Map<String, dynamic>>[];
    var toolBytes = 0;
    var ordered = true;
    var chunks = 0;
    int? firstUs;
    int? cancelUs;
    final params = profile.generationParams.copyWith(
      maxTokens: maxTokens,
      streamBatchTokenThreshold: streamBatchTokens,
      streamBatchByteThreshold: streamBatchBytes,
    );
    final npuBefore = npu?.snapshot();
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
          enableThinking: profile.enableThinking,
        )) {
          chunks++;
          for (final choice in chunk.choices) {
            if (choice.index != 0 || finish.isNotEmpty) ordered = false;
            for (final tool
                in choice.delta.toolCalls ?? <LlamaCompletionChunkToolCall>[]) {
              final data = tool.toJson();
              toolBytes += utf8.encode(jsonEncode(data)).length;
              if (toolBytes > 65536) {
                cancel();
                throw StateError('Tool deltas exceeded the 64 KiB core limit');
              }
              toolDeltas.add(data);
            }
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
    final npuAfter = npu?.snapshot();
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
      'enable_thinking': profile.enableThinking,
      if (npuBefore != null && npuAfter != null)
        'npu_execution': npuGenerationEvidence(npuBefore, npuAfter),
      'content': text.toString(),
      'thinking': thinking.toString(),
      'chunks': chunks,
      'finish_reasons': finish,
      'tool_call_deltas': toolDeltas,
      'stream_completed': cancellationAbort == null,
      'completion_order_valid':
          ordered && (raw ? finish.isEmpty : finish.length == 1),
      'stream_batch_tokens': params.streamBatchTokenThreshold,
      'stream_batch_bytes': params.streamBatchByteThreshold,
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

  /// Expanded obligations shared with the independent report validator.
  List<String> get caseIds => profile.caseIds;

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
        'schema_version': 2,
        'run_id': runId,
        'profile': profile.toJson(),
        'profile_hash': jsonHash(profile.toJson()),
        'effective_config': profile.effectiveConfig,
        'config_hash': jsonHash(profile.effectiveConfig),
        'environment': environment,
        'preparation': preparation,
        'case_ids': caseIds,
        'catalog': profile.catalog,
        'catalog_hash': jsonHash(profile.catalog),
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
        if (!validationCase(id).implemented) {
          await _record(id, 'NOT_RUN', {
            'reason': 'selected case or reference fixture not implemented',
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
        'case_version': validationCase(id).version,
        'fixture_hash': jsonHash(profile.caseFixtures(id)),
        'status': status,
        'sequence': _sequence++,
        ...values,
      });

  String get _shortPrompt => profile.isChat
      ? profile.fixtureText('hello', 'prompt')
      : profile.fixtureText('raw', 'prompt');

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

  Future<Map<String, dynamic>> _batching() async {
    if (profile.nativeReference ||
        profile.backend == 'npu' ||
        (engine.isWeb && profile.runtime != 'litert')) {
      return {
        'status': 'NOT_RUN',
        'reason': profile.nativeReference
            ? 'Direct native control bypasses public worker batching'
            : profile.backend == 'npu'
            ? 'NPU runtime-default sampling has no qualified deterministic parity control'
            : 'GGUF browser worker batching is not a qualified native-worker control',
      };
    }
    final fixture = profile.fixtures['batching'] as Map;
    final tokens = fixture['token_threshold'] as int;
    final bytes = fixture['byte_threshold'] as int;
    final defaults = profile.generationParams;
    Future<Map<String, dynamic>> generate({
      int? tokenThreshold,
      int? byteThreshold,
    }) => _checked(
      () => engine.generate(
        _shortPrompt,
        profile,
        raw: !profile.isChat,
        streamBatchTokens: tokenThreshold,
        streamBatchBytes: byteThreshold,
      ),
    );
    final control = await generate();
    if (engine.isWeb) {
      final rejected = <Map<String, dynamic>>[];
      for (final option in [
        'streamBatchTokenThreshold',
        'streamBatchByteThreshold',
      ]) {
        try {
          final output = await generate(
            tokenThreshold: option == 'streamBatchTokenThreshold'
                ? tokens
                : null,
            byteThreshold: option == 'streamBatchByteThreshold' ? bytes : null,
          );
          rejected.add({'option': option, 'rejected': false, 'output': output});
        } on LlamaUnsupportedException catch (error) {
          rejected.add({
            'option': option,
            'rejected': error.toString().contains(option),
            'error_type': error.runtimeType.toString(),
            'message': redactDiagnostic(error.toString()),
          });
        }
      }
      final recovery = await generate();
      return {
        'control': control,
        'rejected_options': rejected,
        'recovery': recovery,
        'coverage': 'litert_web_native_option_rejection_and_recovery',
        'status':
            rejected.every((entry) => entry['rejected'] == true) &&
                _validBatchOutput(control) &&
                _validBatchOutput(recovery)
            ? 'PASS'
            : 'FAIL',
        'expected':
            'Each native batching option is rejected with a named typed error; default requests still complete',
      };
    }
    final batched = await generate(
      tokenThreshold: tokens,
      byteThreshold: bytes,
    );
    final recovery = await generate();
    final outputs = [control, batched, recovery];
    final configMatches =
        control['stream_batch_tokens'] == defaults.streamBatchTokenThreshold &&
        control['stream_batch_bytes'] == defaults.streamBatchByteThreshold &&
        batched['stream_batch_tokens'] == tokens &&
        batched['stream_batch_bytes'] == bytes &&
        recovery['stream_batch_tokens'] == defaults.streamBatchTokenThreshold &&
        recovery['stream_batch_bytes'] == defaults.streamBatchByteThreshold;
    final equal = outputs.every(
      (output) =>
          output['content'] == control['content'] &&
          output['thinking'] == control['thinking'] &&
          canonicalJson(output['finish_reasons']) ==
              canonicalJson(control['finish_reasons']),
    );
    final tools = outputs.any(
      (output) =>
          output['tool_call_deltas'] is List &&
          (output['tool_call_deltas'] as List).isNotEmpty,
    );
    return {
      'control': control,
      'batched': batched,
      'recovery': recovery,
      'coverage': 'native_text_and_thinking_reconstruction',
      'configurations_verified': configMatches,
      'reconstruction_equal': equal,
      'status': tools
          ? 'NOT_RUN'
          : configMatches && equal && outputs.every(_validBatchOutput)
          ? 'PASS'
          : 'FAIL',
      'expected':
          'Same nonempty content, thinking and finish reasons with ordered completion; default configuration recovers; chunk count may differ',
      if (tools)
        'reason':
            'Tool emissions require the separately qualified C07 tool fixture',
    };
  }

  bool _validBatchOutput(Map<String, dynamic> output) =>
      output['content'] is String &&
      (output['content'] as String).trim().isNotEmpty &&
      output['thinking'] is String &&
      output['finish_reasons'] is List &&
      output['tool_call_deltas'] is List &&
      output['stream_completed'] == true &&
      output['completion_order_valid'] == true &&
      output['cancel_requested'] == false;

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
        final text = profile.fixtureText('unicode', 'input');
        final tokens = await _checked(() => engine.tokenize(text));
        final decoded = await _checked(() => engine.detokenize(tokens));
        final prefix = profile.fixtureText('unicode', 'expected_prefix');
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
            () => engine.generate(
              profile.fixtureText('raw', 'prompt'),
              profile,
              raw: true,
            ),
          ),
        );
      case 'C04.hello':
      case 'C04.arithmetic':
        final arithmetic = id.endsWith('arithmetic');
        final fixture = arithmetic ? 'arithmetic' : 'hello';
        final prompt = profile.fixtureText(fixture, 'prompt');
        final expected = profile.fixtureText(fixture, 'regex');
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
      case 'C06.history.public_system_wire':
      case 'C06.history.no_system':
      case 'C06.history.combined':
        final prompt = profile.fixtureText('history', 'prompt');
        final system = profile.fixtureText('history', 'system');
        final literalSystem = id == 'C06.history.public_system_wire';
        final combined = id == 'C06.history.combined';
        final messages = [
          if (id != 'C06.history.no_system')
            LlamaChatMessage.fromText(
              role: LlamaChatRole.system,
              text: literalSystem
                  ? jsonEncode({
                      'role': 'system',
                      'content': [
                        {'type': 'text', 'text': system},
                      ],
                    })
                  : system,
            ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: profile.fixtureText('history', 'user'),
          ),
          LlamaChatMessage.fromText(
            role: LlamaChatRole.assistant,
            text: profile.fixtureText('history', 'assistant'),
          ),
          LlamaChatMessage.fromText(role: LlamaChatRole.user, text: prompt),
        ];
        final selectedPrompt = combined
            ? messages.map((message) => message.content).join('\n')
            : prompt;
        final output = await _checked(
          () => engine.generate(
            selectedPrompt,
            profile,
            history: combined ? null : messages,
          ),
        );
        return {
          ...output,
          if (profile.historyControls) 'history_control': id,
          'expected': profile.fixtureText('history', 'expected'),
          'status':
              (output['content'] as String).trim() ==
                  profile.fixtureText('history', 'expected')
              ? 'PASS'
              : 'FAIL',
        };
      case 'C08.cancel':
        final prompt = profile.isChat
            ? profile.fixtureText('cancel', 'chat_prompt')
            : profile.fixtureText('raw', 'prompt');
        final control = await _checked(
          () => engine.generate(
            prompt,
            profile,
            raw: !profile.isChat,
            maxTokens: (profile.fixtures['cancel'] as Map)['max_tokens'] as int,
          ),
        );
        final output = await _checked(
          () => engine.generate(
            prompt,
            profile,
            raw: !profile.isChat,
            maxTokens: (profile.fixtures['cancel'] as Map)['max_tokens'] as int,
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
                    duration <=
                        (profile.fixtures['cancel'] as Map)['deadline_ms'] &&
                    (recovery['content'] as String).trim().isNotEmpty
              ? 'PASS'
              : 'FAIL',
          'reason':
              'requires fewer native decoded tokens or an explicit cancellation abort, matching the seeded control prefix, prompt recovery and bounded cancellation latency',
        };
      case 'C09.reload':
      case 'C09.reload.second':
        await _checked(() => engine.dispose());
        await _checked(() => engine.load(location, profile));
        return _withDiagnostics(_nonempty(await _short()));
      case 'C10.limit':
        final output = await _checked(
          () => engine.generate(
            _shortPrompt,
            profile,
            raw: !profile.isChat,
            maxTokens: (profile.fixtures['limit'] as Map)['max_tokens'] as int,
          ),
        );
        final count =
            (output['metrics'] as Map)['native_decode_tokens'] as num?;
        return {
          ...output,
          'expected': 'at most one native decoded token',
          'status': count == null
              ? 'NOT_RUN'
              : count ==
                    (profile.fixtures['limit']
                        as Map)['expected_native_decode_tokens']
              ? 'PASS'
              : 'FAIL',
          if (count == null)
            'reason': 'native token counter unavailable; chunks are not tokens',
        };
      case 'C11.batching':
        return _batching();
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
      case 'B01.warmup':
      case 'B01.1':
      case 'B01.2':
      case 'B01.3':
        final prompt = profile.isChat
            ? profile.fixtureText('benchmark', 'chat_prompt')
            : profile.fixtureText('raw', 'prompt');
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
      default:
        throw StateError('No implementation for catalog case $id');
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
