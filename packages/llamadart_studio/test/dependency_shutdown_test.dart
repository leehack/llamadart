import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
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
