import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

import 'package:llamadart_chat_example/models/chat_settings.dart';
import 'package:llamadart_chat_example/providers/chat_provider.dart';
import 'package:llamadart_chat_example/services/app_exit_coordinator.dart';
import 'package:llamadart_chat_example/services/chat_service.dart';

import 'mocks.dart';

void main() {
  Future<bool> isDone(Future<void> future) async {
    var done = false;
    unawaited(future.whenComplete(() => done = true));
    await pumpEventQueue();
    return done;
  }

  Future<bool> isDoneAfterPump(WidgetTester tester, Future<void> future) async {
    var done = false;
    unawaited(future.whenComplete(() => done = true));
    await tester.pump();
    return done;
  }

  AppExitCoordinator listenForAppExit({Duration? timeout}) {
    final exitCoordinator = timeout == null
        ? AppExitCoordinator()
        : AppExitCoordinator(timeout: timeout);
    final listener = AppLifecycleListener(
      onExitRequested: exitCoordinator.handleExitRequest,
    );
    addTearDown(listener.dispose);
    return exitCoordinator;
  }

  group('AppExitCoordinator', () {
    testWidgets('lets the app exit only after every release finishes', (
      tester,
    ) async {
      final exitCoordinator = listenForAppExit();
      final first = Completer<void>();
      final second = Completer<void>();
      exitCoordinator
        ..addRelease(() => first.future)
        ..addRelease(() => second.future);

      final exit = tester.binding.handleRequestAppExit();
      expect(await isDoneAfterPump(tester, exit), isFalse);
      first.complete();
      expect(await isDoneAfterPump(tester, exit), isFalse);
      second.complete();

      expect(await exit, AppExitResponse.exit);
    });

    testWidgets('makes a second exit request wait for the first release', (
      tester,
    ) async {
      final exitCoordinator = listenForAppExit();
      final release = Completer<void>();
      var releases = 0;
      exitCoordinator.addRelease(() {
        releases += 1;
        return release.future;
      });

      final first = tester.binding.handleRequestAppExit();
      final second = tester.binding.handleRequestAppExit();

      expect(await isDoneAfterPump(tester, second), isFalse);
      release.complete();
      expect(await first, AppExitResponse.exit);
      expect(await second, AppExitResponse.exit);
      expect(releases, 1);
    });

    test('waits for a release tracked after its owner is gone', () async {
      final exitCoordinator = AppExitCoordinator();
      final ownerRelease = Completer<void>();
      exitCoordinator.track(ownerRelease.future);

      final exit = exitCoordinator.releaseAll();

      expect(await isDone(exit), isFalse);
      ownerRelease.complete();
      await exit;
    });

    test('waits for a release tracked while the exit runs', () async {
      final exitCoordinator = AppExitCoordinator();
      final first = Completer<void>();
      final late = Completer<void>();
      exitCoordinator.addRelease(() => first.future);

      final exit = exitCoordinator.releaseAll();
      exitCoordinator.track(late.future);
      first.complete();

      expect(await isDone(exit), isFalse);
      late.complete();
      await exit;
    });

    test('runs a release added after the exit started', () async {
      final exitCoordinator = AppExitCoordinator();
      final blocker = Completer<void>();
      exitCoordinator.track(blocker.future);
      final exit = exitCoordinator.releaseAll();
      var ran = false;

      exitCoordinator.addRelease(() async => ran = true);
      blocker.complete();
      await exit;

      expect(ran, isTrue);
      expect(exitCoordinator.isExiting, isTrue);
    });

    test('does not run a removed release', () async {
      final exitCoordinator = AppExitCoordinator();
      var ran = false;
      final remove = exitCoordinator.addRelease(() async => ran = true);

      remove();
      await exitCoordinator.releaseAll();

      expect(ran, isFalse);
    });

    test('still waits for the other releases when one fails', () async {
      final exitCoordinator = AppExitCoordinator();
      final other = Completer<void>();
      exitCoordinator
        ..addRelease(() => throw StateError('dispose failed'))
        ..addRelease(() => other.future);

      final exit = exitCoordinator.releaseAll();

      expect(await isDone(exit), isFalse);
      other.complete();
      await exit;
    });

    testWidgets('exits after the timeout when a release never finishes', (
      tester,
    ) async {
      final exitCoordinator = listenForAppExit(
        timeout: const Duration(seconds: 30),
      );
      exitCoordinator.addRelease(() => Completer<void>().future);

      final exit = tester.binding.handleRequestAppExit();
      await tester.pump(const Duration(seconds: 29));
      expect(await isDoneAfterPump(tester, exit), isFalse);
      await tester.pump(const Duration(seconds: 1));

      expect(await exit, AppExitResponse.exit);
    });
  });

  group('ChatProvider.shutdown', () {
    test('makes a second call wait until the chat engine is freed', () async {
      final chatService = _GatedDisposeChatService();
      final provider = ChatProvider(
        chatService: chatService,
        settingsService: MockSettingsService(),
      );

      final first = provider.shutdown();
      final second = provider.shutdown();

      expect(await isDone(second), isFalse);
      chatService.disposeGate.complete();
      await first;
      await second;
      expect(chatService.disposeCalls, 1);
    });

    test('frees the chat engine when an earlier step fails', () async {
      final chatService = _GatedDisposeChatService()..disposeGate.complete();
      final provider = ChatProvider(
        chatService: chatService,
        settingsService: _FailingSaveSettingsService(),
      );

      await expectLater(provider.shutdown(), throwsA(isA<StateError>()));

      expect(chatService.disposeCalls, 1);
    });
  });

  group('ChatService', () {
    test('refuses to load a model after dispose', () async {
      final engine = MockLlamaEngine();
      final service = ChatService(engine: engine);

      await service.dispose();

      await expectLater(
        service.init(const ChatSettings(modelPath: 'model.gguf')),
        throwsA(isA<LlamaStateException>()),
      );
      await expectLater(
        service.loadMultimodalProjector('mmproj.gguf'),
        throwsA(isA<LlamaStateException>()),
      );
      expect(engine.lastLoadedModelPath, isNull);
      expect(engine.loadMultimodalProjectorCalls, 0);
    });
  });
}

class _GatedDisposeChatService extends MockChatService {
  final Completer<void> disposeGate = Completer<void>();
  int disposeCalls = 0;

  @override
  Future<void> dispose() async {
    disposeCalls += 1;
    await disposeGate.future;
  }
}

class _FailingSaveSettingsService extends MockSettingsService {
  @override
  Future<void> saveSettings(ChatSettings newSettings) async {
    throw StateError('disk full');
  }
}
