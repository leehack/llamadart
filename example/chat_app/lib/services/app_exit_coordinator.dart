import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// Frees every native model before the app exits.
///
/// On macOS Metal, a model still allocated when the process exits aborts it
/// (`GGML_ASSERT([rsets->data count] == 0)` in ggml's Metal teardown), and
/// desktop quit never runs `State.dispose`. The app's one exit listener
/// calls [handleExitRequest], which awaits [releaseAll]: it runs every
/// release added with [addRelease] and waits for every release handed to
/// [track], so a model owned by a screen that is already gone is freed too.
class AppExitCoordinator {
  /// Longest [releaseAll] waits before the app exits anyway.
  ///
  /// A model load cannot be cancelled, so the release waits for it; this
  /// keeps a stuck load from blocking quit indefinitely.
  final Duration timeout;

  final List<Future<void> Function()> _releases = <Future<void> Function()>[];
  final Set<Future<void>> _pending = <Future<void>>{};
  Future<void>? _exit;

  /// Creates a coordinator that waits at most [timeout] for releases.
  AppExitCoordinator({this.timeout = const Duration(seconds: 30)});

  /// Whether [releaseAll] has started. The exit is never cancelled, so this
  /// stays true and no new model should load.
  bool get isExiting => _exit != null;

  /// Number of releases added with [addRelease] that still wait for the
  /// exit.
  @visibleForTesting
  int get releaseCount => _releases.length;

  /// Runs [release] when the app exits; the returned callback removes it.
  ///
  /// A release added after the exit started runs at once.
  VoidCallback addRelease(Future<void> Function() release) {
    if (isExiting) {
      track(Future<void>.sync(release));
      return () {};
    }
    _releases.add(release);
    return () => _releases.remove(release);
  }

  /// Makes the exit wait for [release], a release already running, such as
  /// one started by an owner that was disposed before the exit.
  void track(Future<void> release) {
    late final Future<void> pending;
    pending = release
        .catchError((Object error, StackTrace stackTrace) {
          debugPrint('A model release failed before exit: $error');
        })
        .whenComplete(() => _pending.remove(pending));
    _pending.add(pending);
  }

  /// The app's `AppLifecycleListener.onExitRequested`: frees every model,
  /// then lets the app exit. It never cancels the exit, so other exit
  /// listeners must not either.
  Future<AppExitResponse> handleExitRequest() async {
    await releaseAll();
    return AppExitResponse.exit;
  }

  /// Runs every added release and waits for every tracked one, at most
  /// [timeout]. Repeated calls share one exit.
  Future<void> releaseAll() => _exit ??= _releaseAll();

  Future<void> _releaseAll() async {
    final releases = List<Future<void> Function()>.of(_releases);
    _releases.clear();
    for (final release in releases) {
      track(Future<void>.sync(release));
    }
    try {
      await _drain().timeout(timeout);
    } on TimeoutException {
      debugPrint(
        'Exiting with ${_pending.length} model release(s) still running '
        'after ${timeout.inSeconds} s.',
      );
    }
  }

  Future<void> _drain() async {
    while (_pending.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_pending));
    }
  }
}
