import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:laya_tetris_example/laya/models.dart';
import 'package:laya_tetris_example/laya/store.dart';
import 'package:laya_tetris_example/main.dart';
import 'package:laya_tetris_example/players.dart';
import 'package:laya_tetris_example/realtime/bot.dart';
import 'package:llamadart/llamadart.dart';

String tile(WidgetTester tester, String label) {
  final column = find
      .ancestor(of: find.text(label), matching: find.byType(Column))
      .first;
  return tester
      .widgetList<Text>(
        find.descendant(of: column, matching: find.byType(Text)),
      )
      .last
      .data!;
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> pumpApp(
  WidgetTester tester,
  Size size, {
  Future<ModelStore> Function()? openStore,
  LayaLoader loadModels = LayaModels.load,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    LayaTetrisApp(
      openStore:
          openStore ?? () async => throw StateError('no model folder in tests'),
      loadModels: loadModels,
    ),
  );
  await tester.pump();
}

Future<void> choose(WidgetTester tester, String current, String next) async {
  await tester.tap(find.text(current));
  await settle(tester);
  await tester.tap(find.text(next).last);
  await settle(tester);
}

DropdownButton<T> picker<T>(WidgetTester tester, String label) =>
    tester.widget<DropdownButton<T>>(
      find.descendant(
        of: find.ancestor(
          of: find.text(label),
          matching: find.byType(InputDecorator),
        ),
        matching: find.byType(DropdownButton<T>),
      ),
    );

bool tunedSelectable(WidgetTester tester) => picker<RealtimePlayer>(
  tester,
  'Player',
).items!.singleWhere((i) => i.value == RealtimePlayer.layaTuned).enabled;

FilledButton startButton(WidgetTester tester) =>
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Start'));

Future<List<DecisionResult>> unused(List<DecisionRequest> requests) =>
    throw StateError('unexpected decision');

/// Hands out loads that the test completes, and logs loads and disposals.
class FakeLoader {
  final log = <String>[];
  final setups = <LayaSetup>[];
  final tokens = <ModelDownloadCancelToken?>[];
  final _loads = <Completer<LayaModels>>[];

  Future<LayaModels> call(
    LayaSetup setup, {
    ModelDownloadManager? downloads,
    ModelDownloadCancelToken? cancelToken,
    LayaLoadStatus? onStatus,
  }) {
    log.add('load ${setups.length}');
    setups.add(setup);
    tokens.add(cancelToken);
    return (_loads..add(Completer())).last.future;
  }

  void finish(
    int n, {
    LayaDecide base = unused,
    bool tuned = false,
    String? tunedError,
    Future<void>? disposal,
  }) => _loads[n].complete(
    LayaModels(
      base: base,
      tuned: tuned ? unused : null,
      tunedError: tunedError,
      backendName: 'Fake',
      deviceName: 'fake$n',
      loadMillis: 1,
      onDispose: () async {
        log.add('dispose $n');
        await disposal;
      },
    ),
  );
}

void main() {
  late Directory dir;
  late ModelStore store;
  late FakeLoader loader;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('laya_widget_');
    store = ModelStore(dir.path, tunedHeadUrl: '');
    loader = FakeLoader();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<void> pumpWithModels(WidgetTester tester) => pumpApp(
    tester,
    const Size(1280, 900),
    openStore: () async => store,
    loadModels: loader.call,
  );

  testWidgets('without models Laya waits and the heuristic bot plays', (
    tester,
  ) async {
    await pumpApp(tester, const Size(1280, 900));

    expect(find.text('Laya Tetris'), findsOneWidget);
    expect(find.textContaining('Model folder unavailable'), findsOneWidget);
    expect(find.textContaining('is waiting for Laya'), findsOneWidget);
    expect(startButton(tester).onPressed, isNull);

    await choose(tester, 'Laya yes/no checklist', 'Heuristic bot');
    expect(startButton(tester).onPressed, isNotNull);

    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(int.parse(tile(tester, 'Pieces')), greaterThan(0));
    expect(int.parse(tile(tester, 'Score')), greaterThan(0));
    expect(find.textContaining('Decisions'), findsOneWidget);
  });

  testWidgets('the phone layout fits a portrait screen', (tester) async {
    await pumpApp(tester, const Size(412, 915));
    expect(tester.takeException(), isNull);
    expect(find.text('Hold'), findsOneWidget);
    expect(find.text('Space'), findsOneWidget);
  });

  testWidgets('a setting change frees the models before loading new ones', (
    tester,
  ) async {
    await pumpWithModels(tester);
    loader.finish(0, disposal: Completer<void>().future);
    await settle(tester);
    expect(find.textContaining('on Fake (fake0)'), findsOneWidget);
    expect(startButton(tester).onPressed, isNotNull);

    await choose(tester, 'GPU (auto)', 'CPU');
    expect(loader.log, ['load 0', 'dispose 0']);
    expect(startButton(tester).onPressed, isNull);
  });

  testWidgets('the next load starts once the old models are freed', (
    tester,
  ) async {
    await pumpWithModels(tester);
    final disposal = Completer<void>();
    loader.finish(0, disposal: disposal.future);
    await settle(tester);

    await choose(tester, 'GPU (auto)', 'CPU');
    disposal.complete();
    await settle(tester);
    expect(loader.log, ['load 0', 'dispose 0', 'load 1']);
    expect(loader.setups[1].backend, GpuBackend.cpu);
  });

  testWidgets('a load superseded by a newer one is freed and never used', (
    tester,
  ) async {
    await pumpWithModels(tester);
    await choose(tester, 'Q8_0, 421 MB', 'F16, 791 MB');
    expect(loader.tokens[0]!.isCancelled, isTrue);

    loader.finish(0);
    await settle(tester);
    expect(loader.log, ['load 0', 'dispose 0', 'load 1']);
    expect(loader.setups[1].backbone.fileName, 'laya-F16.gguf');
    expect(find.textContaining('fake0'), findsNothing);

    loader.finish(1);
    await settle(tester);
    expect(
      find.textContaining('laya-F16.gguf on Fake (fake1)'),
      findsOneWidget,
    );
  });

  testWidgets('the tuned player needs a loaded tuned head', (tester) async {
    await pumpWithModels(tester);
    expect(tunedSelectable(tester), isFalse);
    expect(loader.setups[0].tunedHead, same(publishedTunedHead));

    loader.finish(0, tunedError: 'download failed');
    await settle(tester);
    expect(tunedSelectable(tester), isFalse);
    expect(
      find.textContaining('Tetris-tuned head failed: download failed'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Tap Reload models to try again'),
      findsOneWidget,
    );
    expect(find.textContaining(store.tunedHeadPath), findsOneWidget);

    File(store.tunedHeadPath).writeAsBytesSync([0]);
    await tester.tap(find.text('Reload models'));
    await settle(tester);
    expect(loader.setups[1].tunedHead?.path, store.tunedHeadPath);
    loader.finish(1, tunedError: 'bad file');
    await settle(tester);
    expect(tunedSelectable(tester), isFalse);
    expect(
      find.textContaining('Tetris-tuned head failed: bad file'),
      findsOneWidget,
    );
    expect(find.textContaining('delete it'), findsOneWidget);

    await tester.tap(find.text('Reload models'));
    await settle(tester);
    loader.finish(2, tuned: true);
    await settle(tester);
    expect(tunedSelectable(tester), isTrue);
    expect(find.text('Tetris-tuned head loaded'), findsOneWidget);
    expect(find.text('Reload models'), findsNothing);

    await choose(
      tester,
      'Laya yes/no checklist',
      RealtimePlayer.layaTuned.label,
    );
    File(store.tunedHeadPath).deleteSync();
    await choose(tester, 'GPU (auto)', 'CPU');
    expect(loader.setups[3].tunedHead, same(publishedTunedHead));
    loader.finish(3, tunedError: 'download failed');
    await settle(tester);
    expect(startButton(tester).onPressed, isNull);
    expect(find.textContaining('needs the Tetris-tuned head'), findsOneWidget);
  });

  testWidgets('a decision cut short by a reload shows no error', (
    tester,
  ) async {
    await pumpWithModels(tester);
    final decision = Completer<List<DecisionResult>>();
    loader.finish(0, base: (_) => decision.future);
    await settle(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await settle(tester);
    expect(find.text('Thinking…'), findsOneWidget);

    await choose(tester, 'GPU (auto)', 'CPU');
    decision.completeError(
      LlamaStateException('This DecisionEngine was disposed.'),
    );
    await settle(tester);
    expect(loader.log, ['load 0', 'dispose 0', 'load 1']);
    expect(find.textContaining('Last decision failed'), findsNothing);
  });

  testWidgets('the benchmark times the tuned head that loaded', (tester) async {
    await pumpWithModels(tester);
    loader.finish(0, tuned: true);
    await settle(tester);
    File(store.tunedHeadPath).writeAsBytesSync([0]);

    await tester.tap(find.text('Benchmark'));
    await settle(tester);
    expect(
      find.text('Benchmarking laya-Q8_0.gguf with the tuned head…'),
      findsOneWidget,
    );
    expect(loader.setups[1].head, same(publishedTunedHead));
  });

  testWidgets('the benchmark holds the game and the model settings', (
    tester,
  ) async {
    await pumpWithModels(tester);
    loader.finish(0, tunedError: 'download failed');
    await settle(tester);

    await tester.tap(find.text('Benchmark'));
    await settle(tester);
    expect(startButton(tester).onPressed, isNull);
    expect(find.text('Waiting for the benchmark'), findsOneWidget);
    expect(picker<GpuBackend>(tester, 'Compute').onChanged, isNull);
    expect(picker<LayaBackbone>(tester, 'Backbone').onChanged, isNull);
    expect(picker<int>(tester, 'CPU threads').onChanged, isNull);

    Future<List<DecisionResult>> timed(List<DecisionRequest> requests) async =>
        [
          DecisionResult(
            model: 'fake',
            answers: const {},
            usage: const DecisionUsage(inputTokens: 175, outputTokens: 0),
          ),
        ];
    for (var n = 1; n <= 5; n++) {
      expect(loader.setups, hasLength(n + 1));
      expect(loader.setups[n].head.fileName, baseHeadFile);
      loader.finish(n, base: timed);
      await settle(tester);
    }
    expect(
      find.textContaining('laya-Q8_0.gguf, base head, 175 tokens'),
      findsOneWidget,
    );
    expect(startButton(tester).onPressed, isNotNull);
    expect(picker<GpuBackend>(tester, 'Compute').onChanged, isNotNull);
  });
}
