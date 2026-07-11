import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart' show ModelDownloadController;
import 'package:llamadart_chat_example/services/model_download_ui_controller.dart';
import 'package:llamadart_chat_example/services/model_service_base.dart';

void main() {
  group('ModelDownloadUiController', () {
    test('runs queued downloads in FIFO order', () async {
      final controller = ModelDownloadUiController();
      addTearDown(controller.dispose);

      final first = controller.enqueueDownload(
        filename: 'first.gguf',
        displayName: 'First model',
      );
      final second = controller.enqueueDownload(
        filename: 'second.gguf',
        displayName: 'Second model',
      );
      final third = controller.enqueueDownload(
        filename: 'third.gguf',
        displayName: 'Third model',
      );

      expect(await first, isTrue);
      expect(controller.activeFilename, 'first.gguf');
      expect(controller.queuedCount, 2);
      expect(controller.listenableFor('second.gguf').value.queuePosition, 1);
      expect(controller.listenableFor('third.gguf').value.queuePosition, 2);

      controller.completeActiveDownload('first.gguf');
      expect(await second, isTrue);
      expect(controller.activeFilename, 'second.gguf');
      expect(controller.listenableFor('third.gguf').value.queuePosition, 1);

      controller.completeActiveDownload('second.gguf');
      expect(await third, isTrue);
      expect(controller.activeFilename, 'third.gguf');
      controller.completeActiveDownload('third.gguf');
      expect(controller.hasPendingDownloads, isFalse);
    });

    test('queue transitions clear stale transfer state', () async {
      final controller = ModelDownloadUiController();
      addTearDown(controller.dispose);
      const staleDetail = ModelDownloadProgress(
        overallProgress: 0.6,
        downloadedBytes: 6,
        totalBytes: 10,
        stage: ModelDownloadStage.model,
        stageIndex: 1,
        stageCount: 1,
        stageDownloadedBytes: 6,
        stageTotalBytes: 10,
      );

      controller.updateState('active.gguf', progress: 0.6, detail: staleDetail);
      await controller.enqueueDownload(
        filename: 'active.gguf',
        displayName: 'Active model',
      );

      final activeState = controller.listenableFor('active.gguf').value;
      expect(activeState.progress, 0);
      expect(activeState.detail, isNull);

      controller.updateState('queued.gguf', progress: 0.6, detail: staleDetail);
      controller.enqueueDownload(
        filename: 'queued.gguf',
        displayName: 'Queued model',
      );

      final queuedState = controller.listenableFor('queued.gguf').value;
      expect(queuedState.isQueued, isTrue);
      expect(queuedState.progress, 0);
      expect(queuedState.detail, isNull);
    });

    test('queued download can be removed before it starts', () async {
      final controller = ModelDownloadUiController();
      addTearDown(controller.dispose);

      await controller.enqueueDownload(
        filename: 'active.gguf',
        displayName: 'Active model',
      );
      final queued = controller.enqueueDownload(
        filename: 'queued.gguf',
        displayName: 'Queued model',
      );

      expect(controller.isQueued('queued.gguf'), isTrue);
      controller.cancel('queued.gguf');

      expect(await queued, isFalse);
      expect(controller.isQueued('queued.gguf'), isFalse);
      expect(controller.listenableFor('queued.gguf').value.isQueued, isFalse);
      expect(controller.pendingCount, 1);
    });

    test(
      'active download can be cancelled before controller registration',
      () async {
        final controller = ModelDownloadUiController();
        addTearDown(controller.dispose);

        await controller.enqueueDownload(
          filename: 'active.gguf',
          displayName: 'Active model',
        );
        final queued = controller.enqueueDownload(
          filename: 'queued.gguf',
          displayName: 'Queued model',
        );

        controller.cancel('active.gguf');

        expect(
          controller.listenableFor('active.gguf').value.isDownloading,
          isFalse,
        );
        expect(controller.activeFilename, 'active.gguf');
        expect(controller.canRegisterDownload('active.gguf'), isFalse);
        final lowLevelController = ModelDownloadController();
        final subscription = lowLevelController.snapshots.listen((_) {});
        addTearDown(subscription.cancel);
        addTearDown(lowLevelController.dispose);
        expect(
          controller.registerDownload(
            filename: 'active.gguf',
            controller: lowLevelController,
            subscription: subscription,
          ),
          isFalse,
        );
        controller.completeActiveDownload('active.gguf');
        expect(await queued, isTrue);
        expect(controller.activeFilename, 'queued.gguf');
        expect(
          controller.listenableFor('queued.gguf').value.isDownloading,
          isTrue,
        );
      },
    );

    test('queue mutations notify shell listeners once per operation', () async {
      final controller = ModelDownloadUiController();
      addTearDown(controller.dispose);
      var notifications = 0;
      controller.addListener(() => notifications += 1);

      await controller.enqueueDownload(
        filename: 'active.gguf',
        displayName: 'Active model',
      );
      expect(notifications, 1);

      final queued = controller.enqueueDownload(
        filename: 'queued.gguf',
        displayName: 'Queued model',
      );
      expect(notifications, 2);

      controller.cancel('queued.gguf');
      expect(await queued, isFalse);
      expect(notifications, 3);

      controller.completeActiveDownload('active.gguf');
      expect(notifications, 4);
    });

    test('disposeDownloads clears active and queued shell state', () async {
      final controller = ModelDownloadUiController();
      addTearDown(controller.dispose);

      await controller.enqueueDownload(
        filename: 'active.gguf',
        displayName: 'Active model',
      );
      final queued = controller.enqueueDownload(
        filename: 'queued.gguf',
        displayName: 'Queued model',
      );

      await controller.disposeDownloads();

      expect(await queued, isFalse);
      expect(controller.activeFilename, isNull);
      expect(controller.activeDisplayName, isNull);
      expect(controller.pendingCount, 0);
      expect(controller.hasPendingDownloads, isFalse);
      expect(
        controller.listenableFor('active.gguf').value.isDownloading,
        isFalse,
      );
      expect(controller.listenableFor('queued.gguf').value.isQueued, isFalse);
    });

    test('clearUiState resets active notifiers without disposing them', () {
      final controller = ModelDownloadUiController();
      addTearDown(controller.dispose);

      final notifier = controller.listenableFor('model.gguf');
      var notifications = 0;
      void listener() {
        notifications += 1;
      }

      notifier.addListener(listener);
      controller.updateState('model.gguf', isDownloading: true, progress: 0.5);

      controller.clearUiState();

      expect(notifier.value.isDownloading, isFalse);
      expect(notifier.value.progress, 0);
      expect(notifications, greaterThanOrEqualTo(2));

      notifier.removeListener(listener);
      controller.updateState('model.gguf', progress: 0.25);

      expect(notifier.value.progress, 0.25);
    });
  });
}
