import 'dart:async';
import 'dart:io';

/// The signals that stop the server: SIGINT everywhere, plus SIGTERM where
/// Dart can watch it (not on Windows).
List<ProcessSignal> shutdownSignals({bool? isWindows}) => [
  ProcessSignal.sigint,
  if (!(isWindows ?? Platform.isWindows)) ProcessSignal.sigterm,
];

/// Waits until one of [shutdownSignals] is received.
Future<void> waitForShutdownSignal() {
  final completer = Completer<void>();
  final subscriptions = <StreamSubscription<ProcessSignal>>[];

  void completeIfNeeded() {
    if (completer.isCompleted) {
      return;
    }

    completer.complete();
    for (final subscription in subscriptions) {
      subscription.cancel();
    }
  }

  for (final signal in shutdownSignals()) {
    subscriptions.add(signal.watch().listen((_) => completeIfNeeded()));
  }

  return completer.future;
}
