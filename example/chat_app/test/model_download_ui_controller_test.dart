import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/services/model_download_ui_controller.dart';

void main() {
  group('ModelDownloadUiController', () {
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
