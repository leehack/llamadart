import 'dart:async';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio/src/widgets/download_activity_bar.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

class _ProgressStorage extends FakeStoragePort {
  final StreamController<StudioModelDownloadProgress> progress =
      StreamController<StudioModelDownloadProgress>.broadcast();
  final List<String> cancelled = <String>[];
  @override
  Stream<StudioModelDownloadProgress> get progressStream => progress.stream;
  @override
  void cancelDownload(String modelId) => cancelled.add(modelId);
  @override
  Future<void> dispose() async {
    await progress.close();
    await super.dispose();
  }
}

void main() {
  testWidgets('global activity survives navigation and exposes cancellation', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1560, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = _ProgressStorage();
    final deps = await buildTestDeps(storagePort: storage);
    addTearDown(deps.dispose);
    await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
    await tester.pumpAndSettle();
    final model = CuratedModelCatalog.models.first;
    storage.progress.add(
      StudioModelDownloadProgress(
        modelId: model.id,
        stage: ModelDownloadTaskStage.downloading,
        receivedBytes: 512 * 1024 * 1024,
        totalBytes: 1024 * 1024 * 1024,
        fraction: .5,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('50%'), findsOneWidget);
    for (final ws in <String>['coding', 'notes', 'models']) {
      await tester.tap(find.byKey(Key('nav_workspace_$ws')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('download_activity_bar')), findsOneWidget);
    }
    await tester.tap(find.byKey(const Key('open_downloads')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('50% · 512.0 MB / 1.0 GB'), findsOneWidget);
    await tester.tap(find.byKey(Key('cancel_download_${model.id}')));
    expect(storage.cancelled, <String>[model.id]);
    storage.progress.add(
      StudioModelDownloadProgress(
        modelId: model.id,
        stage: ModelDownloadTaskStage.cancelled,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Cancelled'), findsOneWidget);
    expect(find.byKey(Key('cancel_download_${model.id}')), findsNothing);
    await tester.tap(find.byTooltip('Close downloads'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Dismiss finished downloads'));
    await tester.pump();
    expect(find.byKey(const Key('download_activity_bar')), findsNothing);
  });

  testWidgets('narrow strip handles multiple tasks and terminal failures', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final storage = _ProgressStorage();
    final deps = await buildTestDeps(storagePort: storage);
    addTearDown(deps.dispose);
    await tester.pumpWidget(
      StudioScope(
        deps: deps,
        child: MaterialApp(
          home: Scaffold(
            body: Column(children: const <Widget>[DownloadActivityBar()]),
          ),
        ),
      ),
    );
    storage.progress.add(
      const StudioModelDownloadProgress(
        modelId: 'a',
        stage: ModelDownloadTaskStage.downloading,
        fraction: .2,
      ),
    );
    storage.progress.add(
      const StudioModelDownloadProgress(
        modelId: 'b',
        stage: ModelDownloadTaskStage.verifying,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('2 model downloads in progress'), findsOneWidget);
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      isNull,
    );
    await tester.tap(find.byKey(const Key('open_downloads')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Verifying files'), findsOneWidget);
    storage.progress.add(
      const StudioModelDownloadProgress(
        modelId: 'a',
        stage: ModelDownloadTaskStage.failed,
        errorMessage: 'Connection interrupted',
      ),
    );
    storage.progress.add(
      const StudioModelDownloadProgress(
        modelId: 'b',
        stage: ModelDownloadTaskStage.ready,
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Connection interrupted'), findsOneWidget);
    expect(find.text('Ready'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
