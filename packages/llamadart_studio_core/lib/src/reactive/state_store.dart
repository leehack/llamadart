import 'dart:async';

/// Read-only reactive state container consumable by Flutter, Jaspr, or CLI.
abstract interface class ReadOnlyStore<S> {
  /// Latest synchronous snapshot of the store state.
  S get state;

  /// Broadcast stream of subsequent state transitions after subscription.
  Stream<S> get stream;

  /// Selects a slice of [S] and emits only when the selected value changes.
  Stream<R> select<R>(
    R Function(S state) selector, {
    bool Function(R previous, R next)? equals,
  });
}

/// Mutable framework-agnostic state store with equality deduplication.
class StateStore<S> implements ReadOnlyStore<S> {
  /// Creates a [StateStore] seeded with [initialState].
  StateStore(S initialState, {bool Function(S previous, S next)? equals})
    : _state = initialState,
      _equals = equals ?? _defaultEquals;

  final bool Function(S previous, S next) _equals;
  final StreamController<S> _controller = StreamController<S>.broadcast();

  S _state;
  bool _isDisposed = false;

  static bool _defaultEquals<T>(T a, T b) => identical(a, b) || a == b;

  @override
  S get state => _state;

  @override
  Stream<S> get stream => _controller.stream;

  /// Whether [dispose] has been called on this store.
  bool get isDisposed => _isDisposed;

  /// Replaces the current state and notifies subscribers if it changed.
  void set(S nextState) {
    if (_isDisposed || _equals(_state, nextState)) {
      return;
    }
    _state = nextState;
    if (!_controller.isClosed) {
      _controller.add(nextState);
    }
  }

  /// Transforms the current state with [updater] and emits if changed.
  void update(S Function(S current) updater) {
    set(updater(_state));
  }

  @override
  Stream<R> select<R>(
    R Function(S state) selector, {
    bool Function(R previous, R next)? equals,
  }) {
    final comparator = equals ?? _defaultEquals<R>;
    return _controller.stream.map(selector).distinct(comparator);
  }

  /// Closes the underlying broadcast stream.
  Future<void> dispose() async {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    await _controller.close();
  }
}
