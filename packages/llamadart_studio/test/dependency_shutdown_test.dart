import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  test(
    'app exit releases MCP while an async generator awaits its tool',
    () async {
      final events = <String>[];
      final manager = _BlockingMcp(events);
      final inference = _AwaitingToolInference(events);
      final kv = InMemoryKeyValueStore();
      final deps = await StudioDependencies.fromPorts(
        keyValueStore: kv,
        conversationStore: KeyValueConversationStore(kv),
        mcpManager: manager,
        storagePort: _ShutdownStorage(events),
        inferencePort: inference,
        speechPort: FakeSpeechPort(),
        imagePort: FakeImagePort(),
        playgroundPort: FakePlaygroundPort(),
      );
      await deps.shellController.updateSettings(
        (s) => s.copyWith(toolsEnabled: true, enableMcpInChat: true),
      );
      final turn = deps.chatController.sendMessage('Inspect');
      await manager.entered.future.timeout(const Duration(seconds: 2));
      try {
        await deps.lifecycleCoordinator.shutdownAll().timeout(
          const Duration(seconds: 2),
        );
        await turn.timeout(const Duration(seconds: 2));
        expect(events, [
          'cancel generation',
          'dispose MCP',
          'detach generator',
          'dispose inference',
          'dispose storage',
        ]);
      } finally {
        // A failing shutdown assertion must not leave a suspended test fixture.
        if (!manager.release.isCompleted) manager.release.complete(null);
        await deps.dispose();
        await turn;
      }
    },
  );

  test(
    'app exit cancels active turns before ports and releases storage last',
    () async {
      final events = <String>[];
      final inference = _ShutdownInference(events);
      final storage = _ShutdownStorage(events);
      final deps = await buildTestDeps(
        inferencePort: inference,
        storagePort: storage,
      );
      final turn = deps.chatController.sendMessage('Keep generating');
      await inference.subscribed.future;
      await Future.wait([
        // The shell's app-exit path calls the coordinator directly.
        deps.lifecycleCoordinator.shutdownAll(),
        deps.dispose(),
      ]);
      await turn.timeout(const Duration(seconds: 2));
      expect(events, [
        'cancel generation',
        'detach stream',
        'dispose inference',
        'dispose storage',
      ]);
      await inference.stream.close();
    },
  );
}

class _ShutdownInference extends FakeInferencePort {
  _ShutdownInference(this.events) {
    stream = StreamController<StudioTurnEvent>(
      onListen: () => subscribed.complete(),
      onCancel: () => events.add('detach stream'),
    );
  }

  final List<String> events;
  final Completer<void> subscribed = Completer<void>();
  late final StreamController<StudioTurnEvent> stream;

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) =>
      stream.stream;

  @override
  void cancelGeneration() => events.add('cancel generation');

  @override
  Future<void> dispose() async {
    events.add('dispose inference');
    await super.dispose();
  }
}

class _ShutdownStorage extends FakeStoragePort {
  _ShutdownStorage(this.events);
  final List<String> events;

  @override
  Future<void> dispose() async {
    events.add('dispose storage');
    await super.dispose();
  }
}

class _BlockingMcp extends McpManager {
  _BlockingMcp(this.events) : super(keyValueStore: InMemoryKeyValueStore());
  final List<String> events;
  final entered = Completer<void>();
  final release = Completer<Object?>();

  @override
  List<ToolDefinition> buildActiveToolDefinitions() => [
    ToolDefinition(
      name: 'inspect',
      description: 'Inspect',
      parameters: [],
      handler: (_) async {
        entered.complete();
        return release.future;
      },
    ),
  ];

  @override
  Future<void> dispose() async {
    events.add('dispose MCP');
    if (!release.isCompleted) release.complete(null);
    await super.dispose();
  }
}

class _AwaitingToolInference extends FakeInferencePort {
  _AwaitingToolInference(this.events);
  final List<String> events;

  @override
  Stream<StudioTurnEvent> streamTurn(StudioTurnRequest request) async* {
    try {
      await request.extraTools.single.invoke({});
      yield const StudioTextDeltaEvent('Completed');
    } finally {
      events.add('detach generator');
    }
  }

  @override
  void cancelGeneration() => events.add('cancel generation');

  @override
  Future<void> dispose() async {
    events.add('dispose inference');
    await super.dispose();
  }
}
