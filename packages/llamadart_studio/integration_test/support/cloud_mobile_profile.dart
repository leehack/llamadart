import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'chat_diagnostics.dart';

/// Keeps the first curated load bounded before the fixture's post-load tuning.
StudioSettings cloudMobileSettings(StudioSettings settings) =>
    settings.copyWith(
      computeDevice: ComputeDevice.cpu,
      gpuLayers: 0,
      autoTuneHardware: false,
      contextSize: 2048,
      requestedContextSize: 2048,
      numberOfThreads: 2,
      numberOfThreadsBatch: 2,
      maxTokens: 32,
      temperature: 0,
      thinkingEnabled: false,
      toolsEnabled: false,
      enabledBuiltInTools: const [],
    );

/// Model Hub activation intentionally applies its curated preset. Reapply the
/// admitted fixture profile afterward, using the same reload as the Inspector.
Future<void> applyCloudMobileProfile(StudioDependencies deps) async {
  await deps.shellController.updateSettings(cloudMobileSettings);
  final settings = deps.shellController.state.settings;
  if (deps.modelHubController.runtimeStore.state.loadedEngineSignature !=
      settings.engineLoadSignature(isWeb: false)) {
    await deps.modelHubController.reloadActiveModel();
  }
}

/// Checks settings independently of requested diagnostic labels.
void expectCloudMobileSettings(StudioSettings settings) {
  expect(chatProfileSettings(settings), {
    'compute': 'cpu',
    'gpu_layers': 0,
    'auto_tune': false,
    'context': 2048,
    'requested_context': 2048,
    'threads': 2,
    'batch_threads': 2,
    'max_tokens': 32,
    'temperature': 0,
    'thinking': false,
    'tools': false,
    'built_in_tool_count': 0,
  });
}

/// Requires a ready engine loaded with the admitted fixture options.
void expectCloudMobileRuntime(
  StudioDependencies deps,
  RecordingInferencePort inference,
) {
  final settings = deps.shellController.state.settings;
  expectCloudMobileSettings(settings);
  final runtime = inference.runtimeStore.state;
  expect(runtime.isReady, isTrue);
  expect(runtime.activeDescriptor?.id, 'qwen3.5-0.8b-q4-k-m');
  expect(
    runtime.loadedEngineSignature,
    settings.engineLoadSignature(isWeb: false),
    reason: 'Send must use the reloaded admitted engine configuration.',
  );
  expect(inference.loadedSettings, isNotNull);
  expectCloudMobileSettings(inference.loadedSettings!);
  expect(inference.loadedEngineOptions, {
    'compute': 'cpu',
    'gpu_layers': 0,
    'context': 2048,
    'threads': 2,
    'batch_threads': 2,
  });
}

/// Grades the actual Send request and observed completion events.
void expectCloudMobileTurn(RecordingInferencePort inference) {
  expect(inference.lastRequest, isNotNull);
  final request = inference.lastRequest!;
  expectCloudMobileSettings(request.settings);
  expect(
    request.toolsEnabledOverride ?? request.settings.toolsEnabled,
    isFalse,
  );
  expect(request.extraTools, isEmpty);
  expect(inference.generationOptions, isNotNull);
  expect(inference.generationOptions!['max_tokens'], 32);
  expect(inference.generationOptions!['temperature'], 0);
  expect(inference.generationOptions!['thinking_budget'], isNull);
  expect(inference.thinkingEvents, 0);
  expect(inference.completedResult, isNotNull);
  final result = inference.completedResult!;
  expect(result.thinkingText ?? '', isEmpty);
  expect(result.toolInvocations, isEmpty);
  expect(result.metrics.generatedTokens, inInclusiveRange(0, 32));
}
