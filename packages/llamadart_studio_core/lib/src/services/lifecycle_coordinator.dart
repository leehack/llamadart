/// Async release callback invoked before desktop/mobile process termination.
typedef StudioReleaseHook = Future<void> Function();

/// Coordinates orderly shutdown of native engines (Metal, Vulkan, CUDA,
/// Stable Diffusion, Speech) before the host application exits.
///
/// On macOS, releasing `llama.cpp` Metal buffers while `exit()` runs triggers
/// `GGML_ASSERT` in Metal residency-set teardown unless awaited first.
class StudioLifecycleCoordinator {
  /// Creates an empty [StudioLifecycleCoordinator].
  StudioLifecycleCoordinator();

  final List<StudioReleaseHook> _hooks = <StudioReleaseHook>[];
  Future<void>? _inFlightShutdown;

  /// Registers a [hook] to run when [shutdownAll] is invoked.
  void register(StudioReleaseHook hook) {
    if (!_hooks.contains(hook)) {
      _hooks.add(hook);
    }
  }

  /// Unregisters a previously registered [hook].
  void unregister(StudioReleaseHook hook) {
    _hooks.remove(hook);
  }

  /// Disposes all registered resources in reverse registration order.
  ///
  /// Idempotent: concurrent callers await the same in-flight shutdown future.
  Future<void> shutdownAll() {
    return _inFlightShutdown ??= _runShutdown();
  }

  Future<void> _runShutdown() async {
    final snapshot = _hooks.reversed.toList(growable: false);
    for (final hook in snapshot) {
      try {
        await hook();
      } catch (_) {
        // Best-effort teardown so one failing engine never blocks others.
      }
    }
  }
}
