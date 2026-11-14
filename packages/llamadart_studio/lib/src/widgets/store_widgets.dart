import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

/// Subscribes to a pure-Dart [ReadOnlyStore] and rebuilds [builder] whenever
/// its state changes.
class StoreBuilder<S> extends StatefulWidget {
  /// Creates a [StoreBuilder].
  const StoreBuilder({super.key, required this.store, required this.builder});

  /// Reactive store to observe.
  final ReadOnlyStore<S> store;

  /// Widget builder receiving the latest synchronous snapshot.
  final Widget Function(BuildContext context, S state) builder;

  @override
  State<StoreBuilder<S>> createState() => _StoreBuilderState<S>();
}

class _StoreBuilderState<S> extends State<StoreBuilder<S>> {
  StreamSubscription<S>? _sub;
  late S _value;

  @override
  void initState() {
    super.initState();
    _value = widget.store.state;
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant StoreBuilder<S> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      _sub?.cancel();
      _value = widget.store.state;
      _subscribe();
    }
  }

  void _subscribe() {
    _sub = widget.store.stream.listen((S next) {
      if (mounted) {
        setState(() => _value = next);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

/// Subscribes to a selected slice `R` of a [ReadOnlyStore], rebuilding ONLY
/// when the selected value changes.
class StoreSelector<S, R> extends StatefulWidget {
  /// Creates a [StoreSelector].
  const StoreSelector({
    super.key,
    required this.store,
    required this.selector,
    required this.builder,
  });

  /// Source store.
  final ReadOnlyStore<S> store;

  /// Pure projection function extracting slice `R`.
  final R Function(S state) selector;

  /// Widget builder invoked only when `R` changes.
  final Widget Function(BuildContext context, R value) builder;

  @override
  State<StoreSelector<S, R>> createState() => _StoreSelectorState<S, R>();
}

class _StoreSelectorState<S, R> extends State<StoreSelector<S, R>> {
  StreamSubscription<R>? _sub;
  late R _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.selector(widget.store.state);
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant StoreSelector<S, R> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.store, widget.store)) {
      _sub?.cancel();
      _selected = widget.selector(widget.store.state);
      _subscribe();
    }
  }

  void _subscribe() {
    _sub = widget.store.select(widget.selector).listen((R next) {
      if (mounted) {
        setState(() => _selected = next);
      }
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _selected);
}
