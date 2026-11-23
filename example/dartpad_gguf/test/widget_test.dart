import 'dart:async';

import 'package:dartpad_gguf_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';

void main() {
  late _FakeEngine engine;

  Future<void> openApp(WidgetTester tester) async {
    engine = _FakeEngine();
    await tester.pumpWidget(GgufApp(createEngine: () async => engine));
    await tester.tap(find.text('Load'));
    await tester.pump();
  }

  Future<void> generate(WidgetTester tester) async {
    engine.loaded.complete();
    await tester.pump();
    await tester.tap(find.text('Generate'));
    await tester.pump();
  }

  Future<void> finishStream(WidgetTester tester) async {
    await tester.pump();
    // Browser stream completion can run outside the widget test's fake clock.
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  }

  testWidgets('loads Stories15M, streams text and stops', (tester) async {
    await openApp(tester);
    expect(
      engine.source?.url?.path,
      endsWith(
        '/b6dd737497465570b5f5e962dbc9d9454ed1e0eb/stories15M_MOE-Q8_0.gguf',
      ),
    );
    engine.progress?.call(const ModelDownloadProgress.fraction(0.5));
    await tester.pump();
    expect(
      tester
          .widget<LinearProgressIndicator>(find.byType(LinearProgressIndicator))
          .value,
      0.5,
    );

    await tester.enterText(find.byType(TextField), 'Once upon a time');
    await generate(tester);
    expect(engine.prompt, 'Once upon a time');
    engine.output.add('There was');
    await tester.pump();
    expect(find.text('There was'), findsOneWidget);
    engine.output.add(' a fox.');
    await tester.pump();

    await tester.tap(find.text('Stop'));
    await finishStream(tester);
    expect(engine.output.hasListener, isFalse);
    expect(find.text('There was a fox.'), findsOneWidget);
    expect(find.text('Generate'), findsOneWidget);
  });

  testWidgets('shows typed load and generation errors', (tester) async {
    await openApp(tester);
    engine.loaded.completeError(LlamaModelException('Download failed'));
    await tester.pump();
    expect(find.text('Download failed'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsNothing);

    engine.loaded = Completer<void>();
    await tester.tap(find.text('Load'));
    await tester.pump();
    await generate(tester);
    engine.output.addError(LlamaInferenceException('Generation failed'));
    await finishStream(tester);
    expect(find.text('Generation failed'), findsOneWidget);
    expect(find.text('Generate'), findsOneWidget);
  });

  testWidgets('disposes the engine and its active generation', (tester) async {
    await openApp(tester);
    await generate(tester);
    expect(engine.output.hasListener, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
    expect(engine.disposed, isTrue);
    expect(engine.output.hasListener, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposes an engine that arrives after unmounting', (
    tester,
  ) async {
    engine = _FakeEngine();
    final created = Completer<LlamaEngine>();
    await tester.pumpWidget(GgufApp(createEngine: () => created.future));
    await tester.tap(find.text('Load'));
    await tester.pumpWidget(const SizedBox());

    created.complete(engine);
    await tester.pump();
    expect(engine.source, isNull);
    expect(engine.disposed, isTrue);
    expect(tester.takeException(), isNull);
  });
}

class _FakeEngine extends Fake implements LlamaEngine {
  final output = StreamController<String>.broadcast();
  Completer<void> loaded = Completer<void>();
  ModelDownloadProgressCallback? progress;
  ModelSource? source;
  String? prompt;
  bool disposed = false;

  @override
  Future<void> setModel(
    LlamaModel model, {
    ModelParams params = const ModelParams(),
    ModelLoadOptions download = ModelLoadOptions.defaults,
    ModelDownloadProgressCallback? onProgress,
  }) {
    source = model.source;
    progress = onProgress;
    return loaded.future;
  }

  @override
  Stream<String> generate(
    String prompt, {
    GenerationParams params = const GenerationParams(),
    List<LlamaContentPart>? parts,
  }) {
    this.prompt = prompt;
    return output.stream;
  }

  @override
  void cancelGeneration() => unawaited(output.close());

  @override
  Future<void> dispose() async {
    disposed = true;
    await output.close();
  }
}
