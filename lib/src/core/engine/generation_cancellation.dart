import 'dart:async';

import 'engine.dart';

/// Package-internal record of [LlamaEngine.cancelGeneration] calls.
///
/// A generation stream runs setup (template rendering, media checks) before
/// it reaches the backend, and the backend can only cancel work it has
/// started. This lets a request honour a cancel issued after its stream was
/// listened to but before it reached the backend.
class GenerationCancellation {
  static final Expando<GenerationCancellation> _instances =
      Expando<GenerationCancellation>('llamadart.generationCancellation');

  int _epoch = 0;
  bool Function()? _inherited;

  GenerationCancellation._();

  /// Returns the record shared by every caller of [engine].
  factory GenerationCancellation.forEngine(LlamaEngine engine) =>
      _instances[engine] ??= GenerationCancellation._();

  /// Cancels every request whose stream has been listened to.
  void cancel() {
    _epoch += 1;
  }

  /// Returns the stream [start] builds for one request.
  ///
  /// The check passed to [start] reports whether [cancel] ran after the
  /// returned stream was listened to, or whether the check passed to [inherit]
  /// around this call reports a cancel.
  Stream<T> request<T>(Stream<T> Function(bool Function() isCancelled) start) {
    final inherited = _inherited;
    int? listenedAt;
    bool isCancelled() =>
        (inherited?.call() ?? false) ||
        (listenedAt != null && listenedAt != _epoch);
    return _ListenHookStream<T>(start(isCancelled), () {
      listenedAt ??= _epoch;
    });
  }

  /// Calls [create], passing [isCancelled] to every [request] it makes.
  R inherit<R>(bool Function() isCancelled, R Function() create) {
    final previous = _inherited;
    _inherited = isCancelled;
    try {
      return create();
    } finally {
      _inherited = previous;
    }
  }
}

class _ListenHookStream<T> extends Stream<T> {
  final Stream<T> _source;
  final void Function() _onListen;

  _ListenHookStream(this._source, this._onListen);

  @override
  StreamSubscription<T> listen(
    void Function(T event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _onListen();
    return _source.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}
