import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

void main() {
  for (final workspace in [StudioWorkspace.speech, StudioWorkspace.notes]) {
    for (final scenario in [
      'navigation',
      'unavailable',
      'supported',
      'disposed',
    ]) {
      testWidgets('${workspace.name} playback $scenario', (tester) async {
        final channels = _Channels(tester);
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
        late _Player player;
        var creations = 0;
        final playback = StudioAudioPlayback(
          unavailableReason: () => scenario == 'disposed'
              ? gate.future
              : Future.value(
                  scenario == 'unavailable'
                      ? 'Install gstreamer1.0-plugins-base'
                      : null,
                ),
          createPlayer: () {
            creations++;
            return player = _Player();
          },
        );
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
          await _play(tester, workspace);
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
          } else if (scenario == 'supported') {
            expect(player.plays, 1);
            player.state = PlayerState.completed;
            await tester.pumpAndSettle();
            await _play(tester, workspace);
            await tester.pumpAndSettle();
            expect(player.plays, 2);
            player.complete();
            await tester.pumpAndSettle();
            await _play(tester, workspace);
            await tester.pumpAndSettle();
            expect(player.plays, 3);
            expect(player.completionListeners, 1);
            expect(player.stateListeners, 1);
          }
          expect(deps.speechController.state.synthesizedHistory, hasLength(1));
          expect(deps.notebookController.state.selectedNote!.hasAudio, isTrue);
        }
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pumpAndSettle();
        expect(creations, scenario == 'supported' ? 1 : 0);
        expect(channels.creates, 0);
        if (scenario == 'supported') expect(player.disposals, 1);
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
    final first = playback.getOrCreate();
    final second = playback.getOrCreate();
    gate.complete(null);
    final players = await Future.wait([first, second]);

    expect(identical(players.first, players.last), isTrue);
    expect(probes, 1);
    expect(creations, 1);
    expect(channels.creates, 0);
    await playback.dispose();
  });
}

Future<void> _play(WidgetTester tester, StudioWorkspace workspace) async {
  final button = workspace == StudioWorkspace.speech
      ? find.widgetWithIcon(IconButton, Icons.play_circle_fill_rounded)
      : find.byKey(const Key('notebook_play_audio_button'));
  await tester.ensureVisible(button);
  await tester.pump();
  await tester.runAsync(() async {
    await tester.tap(button);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });
  await tester.pump();
}

class _Player implements AudioPlayer {
  final _completed = StreamController<void>.broadcast();
  final _states = StreamController<PlayerState>.broadcast();
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
  }
}

class _Channels {
  _Channels(this.tester) {
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
        return null;
      });
    }
  }
  final WidgetTester tester;
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
