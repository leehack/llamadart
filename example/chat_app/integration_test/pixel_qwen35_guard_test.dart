@Tags(['local-only', 'e2e'])
@Timeout(Duration(minutes: 20))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/android_litert_qualification_io.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:path_provider/path_provider.dart';

import 'support/pixel_qwen35_guard_support.dart';

final class _Usage extends LlamaEngineObserver {
  final List<LlamaOperationResult> results = [];
  @override
  LlamaOperationObserver? onStart(LlamaOperation operation) =>
      operation is LlamaChatOperation ||
          operation is LlamaTextCompletionOperation
      ? _Operation(results)
      : null;
}

final class _Operation extends LlamaOperationObserver {
  _Operation(this.results);
  final List<LlamaOperationResult> results;
  @override
  void onEnd(LlamaOperationResult result) => results.add(result);
}

Future<String> _hash(File file) => s24LiteRtFileHash(file);

Future<Map<String, dynamic>> _maps(
  Directory directory,
  Map binding, {
  required bool gpu,
}) async {
  final raw = await File('/proc/self/maps').readAsBytes();
  final observed = <String, String>{};
  final inventory = binding['libraries'] as Map;
  for (final line in utf8.decode(raw).split('\n')) {
    final match = RegExp(r'(/[^\n]*\.so)(?: \(deleted\))?$').firstMatch(line);
    if (match == null) continue;
    final path = match[1]!;
    final name = Uri.file(path).pathSegments.last;
    if (!inventory.containsKey(name)) continue;
    if (line.endsWith(' (deleted)') || path != '${directory.path}/$name') {
      throw StateError('Unbound or deleted native mapping');
    }
    await requireS24LiteRtFile(File(path), inventory[name] as Map);
    observed[name] = path;
  }
  for (final name in [
    'libllamadart.so',
    'libllama.so',
    if (gpu) 'libggml-vulkan.so',
  ]) {
    if (!observed.containsKey(name)) {
      throw StateError('Missing runtime mapping');
    }
  }
  return {'capture': captureS24LiteRtBytes(raw), 'verified_paths': observed};
}

void main() {
  final flutterBinding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Pixel Qwen3.5 restriction and unchanged C06 controls', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Text('Pixel Qwen3.5 guard')),
    );
    expect(Platform.isAndroid, isTrue);
    final cache = await getTemporaryDirectory();
    final config =
        jsonDecode(
              File(
                '${cache.path}/pixel_qwen35_guard_args.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(config['pid'], pid);
    expect(config['run_id'], pixelQwen35RunId);
    expect(config['device'], 'caiman');
    expect(config['device_model'], 'Pixel 9 Pro');
    expect(config['android_api'], 35);
    final output = Directory(config['output'] as String);
    final directory = Directory(config['native_directory'] as String);
    final bindingFile = File('${output.path}/binding.json');
    const compiledSha = String.fromEnvironment(
      'PIXEL_QWEN35_GUARD_BINDING_SHA256',
    );
    expect(config['binding_sha256'], compiledSha);
    expect(await _hash(bindingFile), compiledSha);
    final binding =
        jsonDecode(bindingFile.readAsStringSync()) as Map<String, dynamic>;
    expect(binding['schema'], 'pixel-qwen35-supported-cases.v2');
    expect(binding['run_id'], pixelQwen35RunId);
    expect(binding['native_tag'], 'v0.8.0-2');
    expect(binding['native_archive_sha256'], pixelQwen35NativeArchiveSha256);
    expect(binding['source_dirty'], isFalse);
    expect(binding['source_commit'], matches(RegExp(r'^[0-9a-f]{40}$')));
    for (final field in ['source_inventory_sha256', 'budget_receipt_sha256']) {
      expect(binding[field], matches(RegExp(r'^[0-9a-f]{64}$')));
    }
    expect(binding['model_sha256'], pixelQwen35ModelSha256);
    expect(binding['model_bytes'], pixelQwen35ModelBytes);
    expect(binding['max_minutes'], 20);
    expect(binding['max_cost_cents'], 250);
    expect(binding['retries'], 0);
    for (final name in [
      'LLAMADART_BACKEND',
      'LLAMADART_NATIVE_LIB_DIR',
      'LLAMADART_LITERT_LM_LIB_DIR',
      'LD_PRELOAD',
    ]) {
      expect(Platform.environment[name] ?? '', isEmpty);
    }
    final journal = File('${output.path}/journal.jsonl');
    expect(journal.existsSync(), isFalse);
    final watchdog = File(config['watchdog'] as String);
    final elapsed = Stopwatch()..start();
    var sequence = 0;
    void record(Map<String, dynamic> value) {
      final line =
          '${jsonEncode({'t_ms': elapsed.elapsedMilliseconds, ...value})}\n';
      if ((journal.existsSync() ? journal.lengthSync() : 0) +
              utf8.encode(line).length >
          8 * 1024 * 1024) {
        throw StateError('Guard journal exceeds size bound');
      }
      journal.writeAsStringSync(line, mode: FileMode.append, flush: true);
    }

    void arm(String step, {int seconds = 90, bool cleanup = false}) {
      if (!cleanup && elapsed.elapsed >= const Duration(minutes: 18)) {
        throw StateError('No new operation may start after 18 minutes');
      }
      final request = {
        'pid': pid,
        'nonce': config['nonce'],
        'step': '${sequence++}:$step',
        'timeout_ms': seconds * 1000,
      };
      final partial = File('${watchdog.path}.partial');
      partial.writeAsStringSync(jsonEncode(request), flush: true);
      partial.renameSync(watchdog.path);
      record({'event': 'stage_started', ...request});
    }

    final restrictions = <String>[];
    final correctness = <String>[];
    final completed = <String>[];
    final notRun = <String>[];
    Map<String, dynamic>? cpuReference;
    final requiredCases = pixelQwen35RequiredCases();
    record({
      'event': 'start',
      'device': config,
      'binding': binding,
      'historical_gpu_failure': 'repeated 8; retained FAIL',
      'retained_cpu_reference_failure': 'Cedar17 versus cedar17; retained FAIL',
      'scope': 'restriction assertions and prospective correctness only',
      'required_cases': requiredCases,
    });
    arm('input-and-payload-check');
    await requireS24LiteRtPayloads(directory, binding);
    final model = File('${cache.path}/firebase-model.gguf');
    await requireS24LiteRtFile(model, {
      'sha256': pixelQwen35ModelSha256,
      'bytes': pixelQwen35ModelBytes,
    });
    final profiles = <String, ValidationProfile>{};
    for (final backend in ['cpu', 'vulkan']) {
      final raw = await rootBundle.loadString(
        'packages/llamadart_validation/assets/profiles/chat-gguf-$backend.json',
      );
      expect(
        sha256.convert(utf8.encode(raw)).toString(),
        (binding['profile_sha256'] as Map)[backend],
      );
      final profile = ValidationProfile.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      expect(profile.model['sha256'], pixelQwen35ModelSha256);
      expect(profile.model['bytes'], pixelQwen35ModelBytes);
      profiles[backend] = profile;
    }
    final messages = <String>[];
    await LlamaLogging.configure(
      level: LlamaLogLevel.debug,
      nativeLevel: LlamaLogLevel.info,
      handler: (value) {
        messages.add(value.message);
        record({
          'event': 'dart_log',
          'level': value.level.name,
          'message': value.message,
        });
      },
    );

    Future<void> refused(
      String id,
      Future<Object?> Function() operation, {
      bool diagnostic = true,
    }) async {
      arm(id, seconds: 30);
      Object? error;
      try {
        await operation();
      } on Object catch (caught) {
        error = caught;
      }
      final pass = pixelQwen35TypedRefusal(error, diagnostic: diagnostic);
      record({
        'event': 'restriction_result',
        'case_id': id,
        'status': pass ? 'PASS' : 'FAIL',
        'error_type': error?.runtimeType.toString(),
        'message': error is LlamaException ? error.message : null,
        'requires_qwen35_diagnostic': diagnostic,
      });
      if (!pass) restrictions.add(id);
      completed.add(id);
    }

    Future<Object?> silent(Stream<String> stream) async {
      await for (final piece in stream) {
        if (piece.isNotEmpty) {
          record({
            'event': 'unexpected_restricted_output',
            'capture': captureS24LiteRtBytes(utf8.encode(piece)),
          });
          throw StateError('A restricted request emitted output');
        }
      }
      return null;
    }

    Future<void> cell(
      String id,
      String backend,
      int size, {
      bool history = false,
      bool probes = false,
      bool refuseLoad = false,
      bool zeroLayers = false,
    }) async {
      final gpu = backend == 'vulkan' && !zeroLayers;
      final profile = profiles[backend]!;
      final log = File('${output.path}/$id.stderr.log');
      if (log.existsSync()) {
        throw StateError('Fresh per-lifetime stderr required');
      }
      final stderr = S24LiteRtStderr.open(log);
      final observer = _Usage();
      final engine = LlamaEngine(LlamaBackend(), observers: [observer]);
      messages.clear();
      var loaded = false;
      try {
        arm('$id.load');
        Object? loadError;
        try {
          await engine.setModel(
            LlamaModel(ModelSource.path(model.path)),
            params: profile.loadParams.copyWith(
              microBatchSize: size,
              gpuLayers: zeroLayers ? 0 : profile.loadParams.gpuLayers,
              device: backend == 'vulkan'
                  ? ComputeDevice.gpu
                  : ComputeDevice.cpu,
            ),
          );
          loaded = true;
        } on Object catch (error) {
          loadError = error;
        }
        if (refuseLoad) {
          final pass = !loaded && pixelQwen35TypedRefusal(loadError);
          record({
            'event': 'restriction_result',
            'case_id': id,
            'status': pass ? 'PASS' : 'FAIL',
            'error_type': loadError?.runtimeType.toString(),
            'message': loadError is LlamaException ? loadError.message : null,
          });
          if (!pass) restrictions.add(id);
          completed.add(id);
          return;
        }
        if (loadError != null) throw loadError;
        expect(engine.isReady, isTrue);
        expect(engine.runtime, LlamaRuntime.llamaCpp);
        final architecture = (await engine
            .getMetadata())['general.architecture'];
        expect(architecture, 'qwen35');
        final name = await engine.getBackendName();
        final layers = await engine.getResolvedGpuLayers();
        expect(name.toLowerCase(), contains(gpu ? 'vulkan' : 'cpu'));
        expect(layers, gpu ? greaterThan(0) : 0);
        record({
          'event': 'load',
          'case_id': id,
          'backend': name,
          'gpu_layers': layers,
          'architecture': architecture,
          'micro_batch': size,
          'requested_backend': backend,
          'requested_gpu_layers': zeroLayers ? 0 : profile.loadParams.gpuLayers,
          'requested_device': backend == 'vulkan' ? 'gpu' : 'cpu',
          'mappings': await _maps(directory, binding, gpu: gpu),
        });
        if (gpu && !pixelQwen35RestrictedFacts(messages)) {
          throw StateError(
            'Actual unsafe/unproven capped device facts required',
          );
        }
        Future<void> arithmetic(String caseId) async {
          final isReference = caseId == 'cpu-original';
          if (!isReference && cpuReference == null) {
            notRun.add(caseId);
            record({
              'event': 'C04_result',
              'case_id': caseId,
              'status': 'NOT_RUN',
              'reason': 'cpu_reference_not_passed',
            });
            return;
          }
          arm('$caseId.C04.arithmetic', seconds: 120);
          expect(
            profile.fixtureText('arithmetic', 'prompt'),
            'What is 2 + 2? Reply with only the number.',
          );
          expect(profile.fixtureText('arithmetic', 'regex'), r'^4[.!]?$');
          final request = [
            LlamaChatMessage.fromText(
              role: LlamaChatRole.user,
              text: profile.fixtureText('arithmetic', 'prompt'),
            ),
          ];
          final rendered = await engine.chatTemplate(
            request,
            enableThinking: profile.enableThinking,
          );
          final inputIds = await engine.tokenize(rendered.prompt);
          final resultCount = observer.results.length;
          final content = StringBuffer();
          final thinking = StringBuffer();
          var terminal = false;
          var ordered = true;
          var terminals = 0;
          await for (final chunk in engine.create(
            request,
            params: profile.generationParams,
            enableThinking: profile.enableThinking,
          )) {
            for (final choice in chunk.choices) {
              if (terminal) ordered = false;
              content.write(choice.delta.content ?? '');
              thinking.write(choice.delta.thinking ?? '');
              if (choice.finishReason != null) {
                terminal = true;
                terminals++;
              }
            }
          }
          expect(observer.results.length, resultCount + 1);
          final result = observer.results.last;
          final text = content.toString();
          final usage = result.usage;
          final evidence = <String, dynamic>{
            'content': text,
            'visible_output_utf8': utf8.encode(text),
            'visible_output_retokenization_ids': await engine.tokenize(
              text,
              addSpecial: false,
            ),
            'thinking': thinking.toString(),
            'messages': request.map((m) => m.toJson()).toList(),
            'request_settings':
                Map<String, Object?>.from(profile.effectiveConfig)
                  ..remove('backend')
                  ..remove('gpu_layers_hint'),
            'rendered_prompt': rendered.prompt,
            'rendered_prompt_sha256': sha256
                .convert(utf8.encode(rendered.prompt))
                .toString(),
            'rendered_input_ids': inputIds,
            'input_tokenize_add_special': true,
            'visible_output_tokenize_add_special': false,
            'native_usage_counts': usage == null
                ? null
                : {
                    'prompt_tokens': usage.promptTokens,
                    'completion_tokens': usage.completionTokens,
                    'total_tokens': usage.totalTokens,
                  },
            'finish_reason': result.finishReason,
            'stream_completed': result.error == null && !result.cancelled,
            'ordered_terminal': ordered && terminals == 1,
          };
          final failures = pixelQwen35ArithmeticFailures(
            evidence,
            reference: isReference ? null : cpuReference,
            requireReference: !isReference,
          );
          record({
            'event': 'C04_result',
            'case_id': caseId,
            'status': failures.isEmpty ? 'PASS' : 'FAIL',
            'failures': failures,
            'reference_case': isReference ? null : 'cpu-original',
            'token_evidence':
                'public rendered input and visible-output retokenization; not sampled native IDs/EOG',
            'requested_micro_batch': size,
            ...evidence,
          });
          if (failures.isEmpty && isReference) cpuReference = evidence;
          if (failures.isNotEmpty) correctness.add(caseId);
          completed.add(caseId);
        }

        await arithmetic(id);
        if (history) {
          arm('$id.C06.history', seconds: 120);
          final historyMessages = [
            for (final roleAndField in [
              (LlamaChatRole.system, 'system'),
              (LlamaChatRole.user, 'user'),
              (LlamaChatRole.assistant, 'assistant'),
              (LlamaChatRole.user, 'prompt'),
            ])
              LlamaChatMessage.fromText(
                role: roleAndField.$1,
                text: profile.fixtureText('history', roleAndField.$2),
              ),
          ];
          final text = await engine
              .create(
                historyMessages,
                params: profile.generationParams,
                enableThinking: profile.enableThinking,
              )
              .text();
          final usage = observer.results.last.usage;
          final pass =
              pixelQwen35HistoryPass(text) &&
              (usage?.promptTokens ?? 0) > 0 &&
              (usage?.completionTokens ?? 0) > 0;
          record({
            'event': 'correctness_result',
            'case_id': '$id.C06.history',
            'status': pass ? 'PASS' : 'FAIL',
            'expected': 'cedar17',
            'content': text,
            'messages': historyMessages.map((m) => m.toJson()).toList(),
            'effective_config': profile.effectiveConfig,
            'usage': usage?.toJson(),
            'finish_reason': observer.results.last.finishReason,
          });
          if (!pass) correctness.add('$id.C06.history');
          completed.add('$id.C06.history');
        }
        if (probes) {
          final capabilities = await engine.capabilities;
          final embedding = await engine.embeddingCapabilities;
          record({
            'event': 'capabilities',
            'vision': capabilities.supportsVision,
            'audio': capabilities.supportsAudio,
            'speculative_strategies': capabilities.speculativeDecodingStrategies
                .map((s) => s.name)
                .toList(),
            'embedding': {
              'text': embedding.text,
              'image': embedding.image,
              'audio': embedding.audio,
            },
          });
          expect(capabilities.supportsVision, isFalse);
          expect(capabilities.supportsAudio, isFalse);
          expect(capabilities.speculativeDecodingStrategies, isEmpty);
          expect(embedding.text || embedding.image || embedding.audio, isFalse);
          for (final (modality, part) in <(String, LlamaContentPart)>[
            (
              'image',
              const LlamaImageContent(path: 'must-not-be-opened.image'),
            ),
            (
              'audio',
              const LlamaAudioContent(path: 'must-not-be-opened.audio'),
            ),
            ('video', LlamaVideoContent(path: 'must-not-be-opened.video')),
          ]) {
            await refused(
              'media.$modality',
              () => silent(
                engine.generate(
                  'hello',
                  params: const GenerationParams(maxTokens: 1),
                  parts: [part],
                ),
              ),
              diagnostic: part is! LlamaVideoContent,
            );
          }
          await refused(
            'speculation.legacy',
            () => silent(
              engine.generate(
                'hello',
                params: const GenerationParams(
                  maxTokens: 1,
                  speculativeDecoding: true,
                ),
              ),
            ),
          );
          for (final strategy in SpeculativeDecodingStrategy.values) {
            await refused(
              'speculation.${strategy.name}',
              () => silent(
                engine.generate(
                  'hello',
                  params: GenerationParams(
                    maxTokens: 1,
                    speculativeDecodingConfig: SpeculativeDecodingConfig(
                      strategy: strategy,
                    ),
                  ),
                ),
              ),
            );
          }
          await refused(
            'speculation.mixed',
            () => silent(
              engine.generate(
                'hello',
                params: GenerationParams(
                  maxTokens: 1,
                  speculativeDecodingConfig: SpeculativeDecodingConfig(
                    strategies: SpeculativeDecodingStrategy.values,
                  ),
                ),
              ),
            ),
          );
          await refused(
            'speculation.external-pre-io',
            () => silent(
              engine.generate(
                'hello',
                params: GenerationParams(
                  maxTokens: 1,
                  speculativeDecodingConfig:
                      SpeculativeDecodingConfig.draftSimple(
                        draftModel: ModelSource.path(
                          '${cache.path}/must-not-exist.gguf',
                        ),
                      ),
                ),
              ),
            ),
            diagnostic: false,
          );
          await refused('embedding.single', () => engine.embed('hello'));
          await refused('embedding.batch', () => engine.embedBatch(['hello']));
          await refused(
            'embedding.content',
            () => engine.embedContent(
              LlamaEmbeddingInput([const LlamaTextContent('hello')]),
            ),
            diagnostic: false,
          );
          await refused(
            'embedding.content-batch',
            () => engine.embedContentBatch([
              LlamaEmbeddingInput([const LlamaTextContent('hello')]),
            ]),
            diagnostic: false,
          );
        }
        if (probes) await arithmetic('$id.C04.post-refusal');
      } finally {
        arm('$id.dispose', seconds: 30, cleanup: true);
        await engine.dispose();
        stderr.close();
        final raw = await log.readAsBytes();
        final text = utf8.decode(raw);
        final unexpectedContext =
            refuseLoad &&
            RegExp(
              r'llama_context:|(?:sched_reserve|reserve_compute_meta):.*compute buffer',
            ).hasMatch(text);
        record({
          'event': 'lifetime_complete',
          'case_id': id,
          'is_disposed': engine.isDisposed,
          'is_ready': engine.isReady,
          'stderr': {
            'file': log.uri.pathSegments.last,
            'bytes': raw.length,
            'sha256': sha256.convert(raw).toString(),
          },
          'positive_vulkan_placement': gpu && loaded && !refuseLoad
              ? pixelQwen35VulkanPlacement(text)
              : null,
          'device_fact_logs': messages
              .where((m) => m.contains('Android Vulkan text prompt decode'))
              .toList(),
          'observed_native_n_ubatch': RegExp(
            r'n_ubatch\s*=\s*(\d+)',
          ).allMatches(text).map((m) => int.parse(m[1]!)).toList(),
          'unexpected_context_on_refused_load': unexpectedContext,
        });
        if (unexpectedContext) {
          restrictions.add('$id.native-context-created');
        }
        if (gpu && loaded && !refuseLoad && !pixelQwen35VulkanPlacement(text)) {
          throw StateError('Positive actual Mali Vulkan placement missing');
        }
        expect(engine.isDisposed, isTrue);
        expect(engine.isReady, isFalse);
      }
    }

    try {
      await cell('cpu-original', 'cpu', 0, history: true);
      await cell('gpu-default', 'vulkan', 0, history: true, probes: true);
      for (final size in pixelQwen35AcceptedSizes.where((n) => n > 0)) {
        await cell('gpu-size-$size', 'vulkan', size);
      }
      for (final size in pixelQwen35RefusedSizes) {
        await cell('gpu-refuse-$size', 'vulkan', size, refuseLoad: true);
      }
      await cell('cpu-size-32', 'cpu', 32);
      await cell('vulkan-zero-layers-size-32', 'vulkan', 32, zeroLayers: true);
      expect({...completed, ...notRun}, requiredCases.toSet());
      record({
        'event': 'complete',
        'restriction_failures': restrictions,
        'correctness_failures': correctness,
        'completed_cases': completed,
        'not_run_cases': notRun,
        'unexecuted_required_cases': pixelQwen35MissingCases(
          requiredCases,
          completed,
        ),
        'restriction_assertions_pass': restrictions.isEmpty,
        'correctness_pass': correctness.isEmpty,
        'qualified': false,
      });
      File(
        '${output.path}/watchdog.done',
      ).writeAsStringSync('done', flush: true);
      flutterBinding.reportData = {
        'restriction_failures': restrictions,
        'correctness_failures': correctness,
        'qualified': false,
        'journal_sha256': await _hash(journal),
      };
    } on Object catch (error) {
      record({
        'event': 'execution_failed',
        'unexecuted_required_cases': pixelQwen35MissingCases(
          requiredCases,
          completed,
        ),
        'error_type': error.runtimeType.toString(),
        'completed_cases': completed,
        'not_run_cases': notRun,
        'restriction_failures': restrictions,
        'correctness_failures': correctness,
        'qualified': false,
      });
      rethrow;
    } finally {
      await LlamaLogging.configure();
    }
    expect(notRun, isEmpty, reason: 'CPU C04 failure gates dependent parity');
    expect(restrictions, isEmpty);
    expect(correctness, isEmpty, reason: 'Original C06 failures remain FAIL');
  });
}
