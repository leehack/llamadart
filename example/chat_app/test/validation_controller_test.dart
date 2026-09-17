import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:llamadart_chat_example/validation/controller.dart';
import 'package:llamadart_chat_example/validation/host.dart';

class PreparationHost implements ValidationHost {
  final started = Completer<void>();
  final pending = Completer<({String path, Map<String, dynamic> evidence})>();
  bool cancelled = false;
  bool finishFails = false;
  @override
  String get outputLocation => 'test';
  @override
  Future<void> start(String id) async {}
  @override
  Future<({String path, Map<String, dynamic> evidence})> prepare(
    ValidationProfile profile,
  ) {
    started.complete();
    return pending.future;
  }

  @override
  void cancelPreparation() {
    cancelled = true;
    if (!pending.isCompleted) {
      pending.completeError(StateError('cancelled download'));
    }
  }

  @override
  Future<void> emit(Map<String, dynamic> event) async {}
  @override
  Future<ValidationReport> finish() async {
    if (finishFails) throw StateError('disk full');
    return ValidationReport.parse('');
  }

  @override
  Future<void> export(String name, String text) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'cancelling model preparation restores idle and retains incomplete report',
    () async {
      final host = PreparationHost();
      final controller = ValidationController(host: host);
      final run = controller.run('tiny-gguf-cpu');
      await host.started.future;
      expect(controller.running, true);
      controller.cancel();
      await run;
      expect(host.cancelled, true);
      expect(controller.running, false);
      expect(controller.report?.qualified, false);
      controller.dispose();
    },
  );
  test(
    'disposing during preparation cannot notify a disposed controller',
    () async {
      final host = PreparationHost();
      final controller = ValidationController(host: host);
      final run = controller.run('tiny-gguf-cpu');
      await host.started.future;
      controller.dispose();
      await run;
      expect(controller.running, false);
    },
  );
  test('failed report persistence still releases running state', () async {
    final host = PreparationHost()..finishFails = true;
    final controller = ValidationController(host: host);
    final run = controller.run('tiny-gguf-cpu');
    await host.started.future;
    controller.cancel();
    await run;
    expect(controller.running, false);
    expect(controller.error, contains('Report persistence failed'));
    controller.dispose();
  });
}
