import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  testWidgets('Web default audio probe permits lazy playback', (tester) async {
    final channels = _Channels(tester);
    addTearDown(channels.dispose);
    late _Player player;
    var creations = 0;
    final playback = StudioAudioPlayback(
      createPlayer: () {
        creations++;
        return player = _Player();
      },
    );
    addTearDown(playback.dispose);
    await tester.runAsync(() async {
      final ready = playback.getOrCreate().then<Object?>(
        (value) => value,
        onError: (Object error) => error,
      );
      await expectLater(ready, completion(isA<AudioPlayer>()));
      expect(await ready, same(player));
      await expectLater(playback.getOrCreate(), completion(same(player)));
      expect(creations, 1);
      expect(channels.creates, 0);
      await player.play(BytesSource(Uint8List(44)));
      expect(player.plays, 1);
      final stopped = player.onPlayerStateChanged.first;
      await player.stop();
      await expectLater(stopped, completion(PlayerState.stopped));
      await playback.dispose();
      await playback.dispose();
      expect(player.disposals, 1);
      await expectLater(playback.getOrCreate(), completion(isNull));
    });
  }, skip: !kIsWeb);

  for (final workspace in [StudioWorkspace.speech, StudioWorkspace.notes]) {
    for (final scenario in [
      'navigation',
      'unavailable',
      'supported',
      'disposed',
      if (workspace == StudioWorkspace.notes && !kIsWeb) 'delayed WAV',
      if (workspace == StudioWorkspace.notes && !kIsWeb)
        'failed assertion cleanup',
    ]) {
      testWidgets('${workspace.name} playback $scenario', (tester) async {
        final delayed = scenario == 'delayed WAV';
        final failWhilePending = scenario == 'failed assertion cleanup';
        final supported =
            scenario == 'supported' || delayed || failWhilePending;
        final channels = _Channels(
          tester,
          holdTemporaryRequest: failWhilePending ? 1 : (delayed ? 3 : null),
        );
        addTearDown(channels.dispose);
        final deps = await buildTestDeps();
        addTearDown(deps.dispose);
        await deps.speechController.loadTtsModel(
          CuratedModelCatalog.byId('qwen3-tts-1.7b-base-q4-k-m')!,
        );
        await deps.speechController.synthesizeText(text: 'Playback test');
        await deps.notebookController.createNote(
          title: 'Recorded note',
          audioWavBytes: Uint8List(44),
        );
        final gate = Completer<String?>();
        final probeStarted = Completer<void>();
        final playerCreated = Completer<_Player>();
        late _Player player;
        var creations = 0;
        int? playsWhileBlocked;
        var fixtureFailureObserved = false;
        final playback = StudioAudioPlayback(
          unavailableReason: () {
            if (!probeStarted.isCompleted) probeStarted.complete();
            return scenario == 'disposed'
                ? gate.future
                : Future.value(
                    scenario == 'unavailable'
                        ? 'Install gstreamer1.0-plugins-base'
                        : null,
                  );
          },
          createPlayer: () {
            creations++;
            player = _Player();
            playerCreated.complete(player);
            return player;
          },
        );
        var cleaned = false;
        Future<void> cleanup() async {
          if (cleaned) return;
          cleaned = true;
          await tester.pumpWidget(const SizedBox.shrink());
          if (!gate.isCompleted) gate.complete(null);
          channels.releaseTemporaryDirectory();
          await _waitFor(
            tester,
            Future.wait([playback.dispose(), channels.recorderDisposed.future])
                .then((_) {}),
          );
          await tester.pumpAndSettle();
        }

        addTearDown(cleanup);
        Future<void> waitForPlay(int count) async {
          final current = await playerCreated.future;
          await current.waitForPlays(count);
        }

        try {
          await tester.pumpWidget(
            StudioScope(
              deps: deps,
              child: MaterialApp(
                theme: StudioTheme.dark(),
                home: Scaffold(
                  body: workspace == StudioWorkspace.speech
                      ? SpeechWorkspaceView(audioPlayback: playback)
                      : NotebookWorkspaceView(audioPlayback: playback),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(channels.creates, 0);
          if (scenario != 'navigation') {
            await _play(
              tester,
              workspace,
              waitFor: failWhilePending
                  ? () => channels.temporaryDirectoryBlocked.future
                  : supported
                  ? () => waitForPlay(1)
                  : () => probeStarted.future,
            );
            if (failWhilePending) {
              throw TestFailure('Owned pending-playback assertion failure');
            }
            if (scenario == 'disposed') {
              await tester.pumpWidget(const SizedBox());
              gate.complete(null);
            }
            await tester.pumpAndSettle();
            if (scenario == 'unavailable') {
              expect(
                find.textContaining('Install gstreamer1.0-plugins-base'),
                findsOneWidget,
              );
            } else if (supported) {
              expect(player.plays, 1);
              player.state = PlayerState.completed;
              await tester.pumpAndSettle();
              await _play(tester, workspace, waitFor: () => waitForPlay(2));
              await tester.pumpAndSettle();
              expect(player.plays, 2);
              player.complete();
              await tester.pumpAndSettle();
              await _play(
                tester,
                workspace,
                waitFor: () => waitForPlay(3),
                beforeWait: delayed
                    ? () async {
                        await channels.temporaryDirectoryBlocked.future.timeout(
                          const Duration(seconds: 5),
                        );
                        playsWhileBlocked = player.plays;
                        channels.releaseTemporaryDirectory();
                      }
                    : null,
              );
              await tester.pumpAndSettle();
              expect(player.plays, 3);
              if (delayed) expect(playsWhileBlocked, 2);
              expect(player.completionListeners, 1);
              expect(player.stateListeners, 1);
            }
            expect(
              deps.speechController.state.synthesizedHistory,
              hasLength(1),
            );
            expect(
              deps.notebookController.state.selectedNote!.hasAudio,
              isTrue,
            );
          }
        } on TestFailure catch (error) {
          if (!failWhilePending ||
              error.message != 'Owned pending-playback assertion failure') {
            rethrow;
          }
          fixtureFailureObserved = true;
        } finally {
          await cleanup();
        }
        if (failWhilePending) {
          expect(fixtureFailureObserved, isTrue);
          expect(player.plays, 0);
        }
        expect(creations, supported ? 1 : 0);
        expect(channels.creates, 0);
        if (supported) expect(player.disposals, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets('concurrent requests share one preflight and player', (
    tester,
  ) async {
    final channels = _Channels(tester);
    addTearDown(channels.dispose);
    final gate = Completer<String?>();
    var probes = 0;
    var creations = 0;
    final playback = StudioAudioPlayback(
      unavailableReason: () {
        probes++;
        return gate.future;
      },
      createPlayer: () {
        creations++;
        return _Player();
      },
    );
    try {
      final first = playback.getOrCreate();
      final second = playback.getOrCreate();
      gate.complete(null);
      final players = await Future.wait([first, second]);

      expect(identical(players.first, players.last), isTrue);
      expect(probes, 1);
      expect(creations, 1);
      expect(channels.creates, 0);
    } finally {
      await playback.dispose();
    }
  });
}

Future<void> _play(
  WidgetTester tester,
  StudioWorkspace workspace, {
  required Future<void> Function() waitFor,
  Future<void> Function()? beforeWait,
}) async {
  final button = workspace == StudioWorkspace.speech
      ? find.widgetWithIcon(IconButton, Icons.play_circle_fill_rounded)
      : find.byKey(const Key('notebook_play_audio_button'));
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.tap(button);
  final completion = waitFor();
  if (beforeWait != null) await _waitFor(tester, beforeWait());
  await _waitFor(tester, completion);
  await tester.pump();
}

Future<void> _waitFor(WidgetTester tester, Future<void> completion) async {
  var done = false;
  Object? failure;
  StackTrace? failureStack;
  unawaited(
    completion.then<void>(
      (_) {
        done = true;
      },
      onError: (Object error, StackTrace stack) {
        failure = error;
        failureStack = stack;
        done = true;
      },
    ),
  );
  final elapsed = Stopwatch()..start();
  while (!done) {
    if (elapsed.elapsed > const Duration(seconds: 5)) {
      throw TimeoutException('Audio test did not reach its completion signal.');
    }
    await tester.pump();
    // Advance real IO without starving callbacks on Flutter's fake clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}

class _Player implements AudioPlayer {
  final _completed = StreamController<void>.broadcast();
  final _states = StreamController<PlayerState>.broadcast();
  final _played = StreamController<int>.broadcast();
  Future<void> waitForPlays(int count) async {
    if (plays >= count) return;
    await _played.stream.firstWhere((value) => value >= count);
  }

  int plays = 0;
  int disposals = 0;
  int completionListeners = 0;
  int stateListeners = 0;
  void complete() => _completed.add(null);
  @override
  Stream<void> get onPlayerComplete {
    completionListeners++;
    return _completed.stream;
  }

  @override
  Stream<PlayerState> get onPlayerStateChanged {
    stateListeners++;
    return _states.stream;
  }

  @override
  set state(PlayerState value) => _states.add(value);
  @override
  Future<void> stop() async {
    state = PlayerState.stopped;
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await _completed.close();
    await _states.close();
    await _played.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<void> play(
    Source source, {
    double? volume,
    double? balance,
    AudioContext? ctx,
    Duration? position,
    PlayerMode? mode,
  }) async {
    plays++;
    _played.add(plays);
  }
}

class _Channels {
  _Channels(this.tester, {this.holdTemporaryRequest}) {
    for (final name in [
      'xyz.luan/audioplayers.global',
      'xyz.luan/audioplayers.global/events',
      'xyz.luan/audioplayers',
      'com.llfbandit.record/messages',
      'plugins.flutter.io/path_provider',
    ]) {
      final channel = MethodChannel(name);
      channels.add(channel);
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (name == 'plugins.flutter.io/path_provider') {
          temporaryRequests++;
          if (temporaryRequests == holdTemporaryRequest) {
            temporaryDirectoryBlocked.complete();
            await _releaseTemporaryDirectory.future;
          }
          return '.dart_tool/studio_playback_test';
        }
        if (call.method == 'create') {
          final args = call.arguments as Map;
          final audio = name == 'xyz.luan/audioplayers';
          if (audio) creates++;
          final event = MethodChannel(
            audio
                ? 'xyz.luan/audioplayers/events/${args['playerId']}'
                : 'com.llfbandit.record/events/${args['recorderId']}',
          );
          channels.add(event);
          messenger.setMockMethodCallHandler(event, (_) async => null);
        }
        if (name == 'xyz.luan/audioplayers' && call.method == 'dispose') {
          disposes++;
        }
        if (name == 'com.llfbandit.record/messages' &&
            call.method == 'dispose') {
          if (!recorderDisposed.isCompleted) recorderDisposed.complete();
        }
        return null;
      });
    }
  }
  final WidgetTester tester;
  final int? holdTemporaryRequest;
  int temporaryRequests = 0;
  final temporaryDirectoryBlocked = Completer<void>();
  final _releaseTemporaryDirectory = Completer<void>();
  final recorderDisposed = Completer<void>();
  void releaseTemporaryDirectory() {
    if (!_releaseTemporaryDirectory.isCompleted) {
      _releaseTemporaryDirectory.complete();
    }
  }

  final List<MethodChannel> channels = [];
  int creates = 0;
  int disposes = 0;
  TestDefaultBinaryMessenger get messenger =>
      tester.binding.defaultBinaryMessenger;
  void dispose() {
    for (final channel in channels) {
      messenger.setMockMethodCallHandler(channel, null);
    }
  }
}
