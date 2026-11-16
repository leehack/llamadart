// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  testWidgets(
    'Web Expert exposes honored batching and explains managed controls',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final kv = InMemoryKeyValueStore();
      final deps = await StudioDependencies.fromPorts(
        keyValueStore: kv,
        conversationStore: KeyValueConversationStore(kv),
        storagePort: FakeStoragePort(),
        inferencePort: FakeInferencePort(),
        speechPort: FakeSpeechPort(),
        imagePort: FakeImagePort(),
        playgroundPort: FakePlaygroundPort(),
        isWeb: true,
      );
      addTearDown(deps.dispose);
      await deps.shellController.updateSettings(
        (s) => s.copyWith(inspectorExpertMode: true),
      );
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      expect(find.textContaining('manages cache'), findsOneWidget);
      expect(find.text('KV Cache Quantization (K / V)'), findsNothing);
      expect(find.text('Decode Threads (n_threads)'), findsNothing);
      expect(find.text('Memory-Map Weights (use_mmap)'), findsNothing);
      expect(
        find.byKey(const Key('inspector_advanced_engine_tile')),
        findsNothing,
      );
      final batch = find.byKey(const Key('inspector_batch_size_512'));
      await tester.ensureVisible(batch);
      await tester.tap(batch);
      await tester.pumpAndSettle();
      expect(
        deps.shellController.state.settings
            .toModelParams(format: ModelFormat.gguf, isWeb: true)
            .batchSize,
        512,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('GGUF NPU target is disabled with a runtime explanation', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1360, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final deps = await buildTestDeps();
    addTearDown(deps.dispose);
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await tester.pumpAndSettle();
    final selector = tester.widget<SegmentedButton<ComputeDevice>>(
      find.byWidgetPredicate(
        (widget) => widget is SegmentedButton<ComputeDevice>,
      ),
    );
    final npu = selector.segments.singleWhere(
      (segment) => segment.value == ComputeDevice.npu,
    );
    expect(npu.enabled, isFalse);
    expect(npu.tooltip, contains('LiteRT-LM'));
  });
}
