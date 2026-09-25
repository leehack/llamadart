import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:llamadart_chat_example/validation/controller.dart';
import 'package:llamadart_chat_example/validation/host.dart';

class PreparationHost implements ValidationHost {
  @override
  ValidationEngine createEngine(ValidationProfile profile) =>
      throw StateError('Preparation did not finish');
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

class DecisionHost extends PreparationHost {
  final events = <Map<String, dynamic>>[];
  @override
  ValidationEngine createEngine(ValidationProfile profile) => TokenOnlyEngine();
  @override
  Future<({String path, Map<String, dynamic> evidence})> prepare(
    ValidationProfile profile,
  ) async => (path: 'laya-F16.gguf', evidence: <String, dynamic>{});
  @override
  Future<void> emit(Map<String, dynamic> event) async => events.add(event);
  @override
  void cancelPreparation() {}
}

class TokenOnlyEngine implements ValidationEngine {
  @override
  bool get isWeb => false;
  @override
  Future<void> load(String location, ValidationProfile profile) async {}
  @override
  Future<void> unload() async {}
  @override
  Future<void> dispose() async {}
  @override
  void cancel() {}
  @override
  Future<Map<String, dynamic>> diagnostics() async => {'backend_name': 'CPU'};
  @override
  Future<List<int>> tokenize(String text) async => const [];
  @override
  Future<String> detokenize(List<int> tokens) async => '';
  @override
  Future<Map<String, dynamic>> generate(
    String prompt,
    ValidationProfile profile, {
    bool raw = false,
    int? maxTokens,
    int? streamBatchTokens,
    int? streamBatchBytes,
    bool cancelAfterFirst = false,
    List<LlamaChatMessage>? history,
    List<String>? stopSequences,
    bool? enableThinking,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
  }) => throw StateError('not a text model');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('decision runs compare tokens against the bundled reference, which '
      'errors when absent or altered', () async {
    final host = DecisionHost();
    final controller = ValidationController(host: host);
    await controller.run('decision-gguf-cpu');
    final tokenizer = host.events.singleWhere(
      (event) => event['case_id'] == 'D02.tokenizer' && event['type'] == 'case',
    );
    expect(tokenizer['status'], 'FAIL');
    expect(tokenizer['pieces'], 97);
    controller.dispose();
  });
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
