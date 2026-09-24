import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/core/engine/generation_cancellation.dart';
import 'package:test/test.dart';

void main() {
  late LlamaEngine engine;
  late GenerationCancellation cancellation;

  setUp(() {
    engine = LlamaEngine(LlamaBackend());
    cancellation = GenerationCancellation.forEngine(engine);
  });

  tearDown(() => engine.dispose());

  /// Returns a request stream and a reader of its check.
  (Stream<int>, bool Function()) request() {
    late bool Function() check;
    final stream = cancellation.request((isCancelled) {
      check = isCancelled;
      return Stream<int>.fromIterable(const <int>[1, 2]);
    });
    return (stream, check);
  }

  test('is shared by every caller of one engine', () {
    expect(GenerationCancellation.forEngine(engine), same(cancellation));
    final other = LlamaEngine(LlamaBackend());
    addTearDown(other.dispose);
    expect(GenerationCancellation.forEngine(other), isNot(same(cancellation)));
  });

  test('reports a cancel issued after listen', () async {
    final (stream, isCancelled) = request();
    final events = stream.toList();
    expect(isCancelled(), isFalse);

    cancellation.cancel();

    expect(isCancelled(), isTrue);
    expect(await events, <int>[1, 2]);
  });

  test('ignores a cancel issued before listen', () async {
    final (stream, isCancelled) = request();
    cancellation.cancel();

    final events = stream.toList();

    expect(isCancelled(), isFalse);
    expect(await events, <int>[1, 2]);
  });

  test('passes an inherited check to requests made inside inherit', () {
    var outerCancelled = false;
    late bool Function() inner;
    cancellation.inherit(() => outerCancelled, () {
      final (stream, isCancelled) = request();
      stream.listen(null);
      inner = isCancelled;
    });
    final (outside, outsideCancelled) = request();
    outside.listen(null);

    expect(inner(), isFalse);
    outerCancelled = true;
    expect(inner(), isTrue);
    expect(outsideCancelled(), isFalse);
  });

  test('forwards errors and pause to the source stream', () async {
    final source = StreamController<int>();
    addTearDown(source.close);
    final stream = cancellation.request((_) => source.stream);
    final errors = <Object>[];

    final subscription = stream.listen(null, onError: errors.add);
    source.addError(StateError('boom'));
    await Future<void>.delayed(Duration.zero);
    subscription.pause();

    expect(errors.single, isA<StateError>());
    expect(source.isPaused, isTrue);
    await subscription.cancel();
    expect(source.hasListener, isFalse);
  });
}
