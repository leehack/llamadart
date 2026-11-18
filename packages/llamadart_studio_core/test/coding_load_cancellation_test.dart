import 'dart:async';

import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

import 'studio_test_fakes.dart';

void main() {
  for (final lateError in [false, true]) {
    test(
      'Coding Stop during load preserves a newer turn (lateError=$lateError)',
      () async {
        final kv = InMemoryKeyValueStore();
        final shell = StudioShellController(keyValueStore: kv);
        final mcp = McpManager(keyValueStore: kv);
        final skills = SkillRegistry(keyValueStore: kv);
        final inference = _UnloadedInference();
        final entered = [Completer<void>(), Completer<void>()];
        final ready = [Completer<bool>(), Completer<bool>()];
        var loads = 0;
        final coding = CodingWorkspaceController(
          inferencePort: inference,
          shellController: shell,
          keyValueStore: kv,
          mcpManager: mcp,
          skillRegistry: skills,
          ensureModelReady: () {
            final index = loads++;
            entered[index].complete();
            return ready[index].future;
          },
        );
        addTearDown(() async {
          await coding.dispose();
          await skills.dispose();
          await mcp.dispose();
          await inference.dispose();
          await shell.dispose();
        });
        final first = coding.sendCodingPrompt('Stopped prompt');
        await entered[0].future;
        coding.cancelGeneration();
        expect(coding.activeStreamStore.state.isGenerating, isFalse);
        final second = coding.sendCodingPrompt('New prompt');
        await entered[1].future;
        if (lateError) {
          ready[0].completeError(StateError('old load failed'));
        } else {
          ready[0].complete(true);
        }
        await first;
        expect(inference.lastRequest, isNull);
        expect(coding.activeStreamStore.state.isGenerating, isTrue);
        expect(coding.state.lastError, isNull);
        ready[1].complete(true);
        await second;
        expect(inference.lastRequest!.history.last.text, 'New prompt');
        expect(
          coding.state.messages.where((m) => m.role == StudioRole.assistant),
          hasLength(1),
        );
        expect(coding.activeStreamStore.state.isGenerating, isFalse);
      },
    );
  }
}

class _UnloadedInference extends FakeInferencePort {
  final unloaded = StateStore<StudioRuntimeSnapshot>(
    const StudioRuntimeSnapshot(),
  );
  @override
  ReadOnlyStore<StudioRuntimeSnapshot> get runtimeStore => unloaded;
  @override
  Future<void> dispose() async {
    await unloaded.dispose();
    await super.dispose();
  }
}
