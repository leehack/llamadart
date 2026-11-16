@Tags(<String>['local-only'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

// Explicit opt-in, no downloads:
// STUDIO_SOAK_CHAT_MODEL=/existing/model.gguf
// STUDIO_SOAK_EVIDENCE=/absolute/evidence.json
// Defaults: 5 cycles, 1 warmup, 2 ordinary turns per cycle, CPU, 2 threads.
// STUDIO_SOAK_CYCLES / STUDIO_SOAK_WARMUP_CYCLES / STUDIO_SOAK_TURNS
// STUDIO_SOAK_GPU_LAYERS (0 means CPU) / STUDIO_SOAK_MAX_RSS_GROWTH_MIB
// The default RSS gate is 256 MiB above the first post-warmup teardown sample.
// RSS is the whole Dart process, including allocator caches and Dart GC timing;
// it does not prove native/GPU allocation ownership or physical reclamation.
// No forced GC, allocator flush, model-cache deletion, or RSS subtraction occurs.

int _option(String name, int fallback, {int minimum = 0}) {
  final raw = Platform.environment[name];
  final value = raw == null ? fallback : int.tryParse(raw);
  if (value == null || value < minimum) {
    throw ArgumentError('$name must be an integer >= $minimum.');
  }
  return value;
}

Future<String> _coreSourceDigest() async {
  final files = await Directory('lib')
      .list(recursive: true, followLinks: false)
      .where((entry) => entry is File && entry.path.endsWith('.dart'))
      .cast<File>()
      .toList();
  files.sort((a, b) => a.path.compareTo(b.path));
  final manifest = <String>[];
  for (final file in files) {
    manifest.add('${file.path}:${await sha256.bind(file.openRead()).first}');
  }
  return sha256.convert(utf8.encode(manifest.join('\n'))).toString();
}

void main() {
  final modelPath = Platform.environment['STUDIO_SOAK_CHAT_MODEL'];
  test(
    'real model survives repeated load chat cancel recovery and teardown',
    () async {
      final model = File(modelPath!);
      expect(
        await model.exists(),
        isTrue,
        reason: 'An existing local GGUF is required.',
      );
      final cycles = _option('STUDIO_SOAK_CYCLES', 5, minimum: 3);
      final warmup = _option('STUDIO_SOAK_WARMUP_CYCLES', 1, minimum: 1);
      final turns = _option('STUDIO_SOAK_TURNS', 2, minimum: 1);
      final gpuLayers = _option('STUDIO_SOAK_GPU_LAYERS', 0);
      final growthLimit =
          _option('STUDIO_SOAK_MAX_RSS_GROWTH_MIB', 256) * 1024 * 1024;
      expect(warmup, lessThan(cycles - 1));
      final root = await Directory.systemTemp.createTemp('studio_native_soak_');
      final evidenceFile = File(
        Platform.environment['STUDIO_SOAK_EVIDENCE'] ??
            '${root.parent.path}/studio-soak-${DateTime.now().microsecondsSinceEpoch}.json',
      );
      final samples = <Map<String, Object?>>[];
      final report = <String, Object?>{
        'kind': 'studio-runtime-endurance-v1',
        'startedAt': DateTime.now().toUtc().toIso8601String(),
        'platform': Platform.operatingSystem,
        'dartVersion': Platform.version,
        'coreSourceSha256': await _coreSourceDigest(),
        'harnessSha256':
            (await sha256
                    .bind(
                      File('test/local_runtime_endurance_test.dart').openRead(),
                    )
                    .first)
                .toString(),
        'modelSha256': (await sha256.bind(model.openRead()).first).toString(),
        'modelBytes': await model.length(),
        'cycles': cycles,
        'warmupCycles': warmup,
        'turnsPerCycle': turns,
        'gpuLayers': gpuLayers,
        'threads': 2,
        'maxRssGrowthBytes': growthLimit,
        'rssScope': 'whole-process; allocator caches and Dart GC are included',
        'taskCountScope':
            'harness-owned controllers and stream subscriptions; not OS/native threads',
        'samples': samples,
        'completed': false,
      };
      try {
        int? baseline;
        for (var cycle = 0; cycle < cycles; cycle++) {
          final sample = await _cycle(
            root.path,
            model.path,
            cycle,
            turns,
            gpuLayers,
          );
          // Allow asynchronous close callbacks to settle; this is not a GC request.
          await Future<void>.delayed(const Duration(milliseconds: 250));
          sample['afterTeardownRssBytes'] = ProcessInfo.currentRss;
          sample['processMaxRssBytes'] = ProcessInfo.maxRss;
          samples.add(sample);
          if (cycle == warmup) baseline = ProcessInfo.currentRss;
          if (cycle >= warmup) {
            final growth = ProcessInfo.currentRss - baseline!;
            sample['growthFromPostWarmupBytes'] = growth;
            expect(
              growth,
              lessThanOrEqualTo(growthLimit),
              reason:
                  'Post-warmup process RSS growth exceeded the configured gate.',
            );
          }
          print('STUDIO_SOAK_SAMPLE ${jsonEncode(sample)}');
        }
        report['completed'] = true;
      } finally {
        report['finishedAt'] = DateTime.now().toUtc().toIso8601String();
        await evidenceFile.parent.create(recursive: true);
        await evidenceFile.writeAsString(
          const JsonEncoder.withIndent('  ').convert(report),
          flush: true,
        );
        print('STUDIO_SOAK_EVIDENCE ${evidenceFile.path}');
        await root.delete(recursive: true);
      }
    },
    skip: modelPath == null
        ? 'Set STUDIO_SOAK_CHAT_MODEL to an explicit existing local model.'
        : false,
    timeout: const Timeout(Duration(minutes: 45)),
  );
}

Future<Map<String, Object?>> _cycle(
  String root,
  String model,
  int cycle,
  int turns,
  int gpuLayers,
) async {
  final kv = InMemoryKeyValueStore();
  final shell = StudioShellController(keyValueStore: kv);
  final store = createDefaultConversationStore(
    fallbackKeyValueStore: kv,
    directoryPath: root,
  );
  final port = DirectLlamaInferencePort();
  final chat = ChatWorkspaceController(
    conversationStore: store,
    inferencePort: port,
    shellController: shell,
  );
  final sample = <String, Object?>{
    'cycle': cycle,
    'beforeLoadRssBytes': ProcessInfo.currentRss,
  };
  StreamSubscription<ActiveTurnStreamState>? subscription;
  var activeSubscriptions = 0;
  try {
    await shell.initialize();
    final settings = StudioSettings(
      computeDevice: gpuLayers == 0 ? ComputeDevice.cpu : ComputeDevice.gpu,
      gpuLayers: gpuLayers,
      autoTuneHardware: false,
      contextSize: 4096,
      requestedContextSize: 4096,
      numberOfThreads: 2,
      numberOfThreadsBatch: 2,
      maxTokens: 96,
      temperature: 0,
      thinkingEnabled: false,
      toolsEnabled: false,
      enabledBuiltInTools: const [],
    );
    await shell.updateSettings((_) => settings);
    await port.loadModel(
      assets: ResolvedModelAssets(
        descriptor: StudioModelDescriptor(
          id: 'soak-local',
          name: 'Explicit local soak model',
          description: 'Operator-selected runtime endurance model.',
          category: StudioModelCategory.chat,
          filename: 'model.gguf',
          sourceUri: model,
        ),
        primarySource: ModelSource.path(model),
      ),
      settings: settings,
      isWeb: false,
    );
    expect(port.runtimeStore.state.isReady, isTrue);
    sample['backendName'] = port.runtimeStore.state.backendName;
    sample['resolvedGpuLayers'] = port.runtimeStore.state.resolvedGpuLayers;
    sample['resolvedContextSize'] = port.runtimeStore.state.resolvedContextSize;
    sample['runtimeMetadata'] = port.runtimeStore.state.metadata;
    if (gpuLayers > 0) {
      expect(
        port.runtimeStore.state.resolvedGpuLayers,
        greaterThan(0),
        reason: 'A requested GPU soak requires verified GPU-layer offload.',
      );
    }
    sample['afterLoadRssBytes'] = ProcessInfo.currentRss;
    await chat.initialize();
    for (var turn = 0; turn < turns; turn++) {
      await chat.sendMessage('Reply with the word READY.');
      expect(chat.state.lastTurnError, isNull);
      expect(
        chat.state.activeConversation!.activeBranch.last.text.trim(),
        isNotEmpty,
      );
      expect(port.isBusy, isFalse);
    }
    var requestedCancel = false;
    subscription = chat.activeStreamStore.stream.listen((state) {
      if (!requestedCancel && state.isGenerating && state.tokensGenerated > 0) {
        requestedCancel = true;
        chat.stopGeneration();
      }
    });
    activeSubscriptions++;
    await chat.sendMessage(
      'Count upward from one to one hundred, one number per line.',
    );
    await subscription.cancel();
    subscription = null;
    activeSubscriptions--;
    expect(requestedCancel, isTrue);
    expect(chat.activeStreamStore.state.isGenerating, isFalse);
    expect(port.isBusy, isFalse);
    await chat.sendMessage('Reply with the word RECOVERED.');
    expect(chat.state.lastTurnError, isNull);
    expect(
      chat.state.activeConversation!.activeBranch.last.text.trim(),
      isNotEmpty,
    );
    sample['completedOrdinaryTurns'] = turns;
    sample['cancelRequests'] = 1;
    sample['recoveredTurns'] = 1;
    sample['retainedConversationCountBeforeClear'] =
        chat.state.conversations.length;
    sample['retainedMessageCountBeforeClear'] = chat.state.conversations
        .fold<int>(0, (n, c) => n + c.nodes.length);
    sample['withRetainedChatRssBytes'] = ProcessInfo.currentRss;
    await chat.dispose();
    await store.clearAll();
    expect(await store.loadAll(), isEmpty);
    sample['persistedConversationsAfterClear'] = 0;
    await port.unloadModel();
    expect(port.runtimeStore.state.phase, StudioEnginePhase.unloaded);
    expect(port.isBusy, isFalse);
    sample['enginePhaseAfterUnload'] = port.runtimeStore.state.phase.name;
    sample['activeEngineOperationsAfterUnload'] = port.isBusy ? 1 : 0;
    sample['afterUnloadRssBytes'] = ProcessInfo.currentRss;
  } finally {
    await subscription?.cancel();
    await chat.dispose();
    await port.dispose();
    await shell.dispose();
  }
  for (final stream in <Stream<Object?>>[
    chat.store.stream,
    chat.activeStreamStore.stream,
    shell.store.stream,
    port.runtimeStore.stream,
  ]) {
    expect(await stream.isEmpty.timeout(const Duration(seconds: 2)), isTrue);
  }
  expect(port.engine.isDisposed, isTrue);
  expect(port.isBusy, isFalse);
  sample['closedControllerStoresAfterDispose'] = 4;
  sample['engineDisposed'] = port.engine.isDisposed;
  sample['activeEngineOperationsAfterDispose'] = port.isBusy ? 1 : 0;
  sample['ownedSubscriptionsAfterDispose'] = activeSubscriptions;
  expect(activeSubscriptions, 0);
  return sample;
}
