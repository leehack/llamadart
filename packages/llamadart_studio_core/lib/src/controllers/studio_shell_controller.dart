import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:meta/meta.dart';

import '../domain/studio_settings.dart';
import '../domain/studio_workspace.dart';
import '../ports/key_value_store.dart';
import '../ports/studio_context_ports.dart';
import '../reactive/state_store.dart';
import '../services/boot_guard_service.dart';

/// Immutable shell UI and global settings state.
@immutable
class StudioShellState {
  /// Creates a [StudioShellState].
  const StudioShellState({
    this.initialized = false,
    this.activeWorkspace = StudioWorkspace.chat,
    this.settings = const StudioSettings(),
    this.bootRecoveryAlert,
    this.commandPaletteOpen = false,
    this.inspectorVisibility = const {},
  });

  /// Whether persisted settings and boot guard state have finished loading.
  final bool initialized;

  /// Active Studio workspace tab/route.
  final StudioWorkspace activeWorkspace;

  /// Persisted global Studio settings.
  final StudioSettings settings;

  /// Non-null when the previous launch crashed or OOM'd mid-model-load.
  final BootRecoveryAlert? bootRecoveryAlert;

  /// Whether the `Cmd/Ctrl+K` Command Palette overlay is open.
  final bool commandPaletteOpen;

  /// Session-local inspector preferences for each workspace.
  final Map<StudioWorkspace, bool> inspectorVisibility;

  /// Whether the inspector should be visible in the active workspace.
  bool get inspectorVisible =>
      inspectorVisibility[activeWorkspace] ??
      (activeWorkspace == StudioWorkspace.chat && settings.inspectorOpen);

  /// Returns an updated copy of [StudioShellState].
  StudioShellState copyWith({
    bool? initialized,
    StudioWorkspace? activeWorkspace,
    StudioSettings? settings,
    BootRecoveryAlert? bootRecoveryAlert,
    bool clearBootRecoveryAlert = false,
    bool? commandPaletteOpen,
    Map<StudioWorkspace, bool>? inspectorVisibility,
  }) {
    return StudioShellState(
      initialized: initialized ?? this.initialized,
      activeWorkspace: activeWorkspace ?? this.activeWorkspace,
      settings: settings ?? this.settings,
      bootRecoveryAlert: clearBootRecoveryAlert
          ? null
          : (bootRecoveryAlert ?? this.bootRecoveryAlert),
      commandPaletteOpen: commandPaletteOpen ?? this.commandPaletteOpen,
      inspectorVisibility: inspectorVisibility ?? this.inspectorVisibility,
    );
  }
}

/// Manages Studio workspace routing, persisted [StudioSettings], Command
/// Palette state, and crash-safe startup inspection.
class StudioShellController
    implements StudioModelHubSettingsPort, StudioWorkspaceNavigator {
  /// Creates a [StudioShellController].
  StudioShellController({
    required KeyValueStore keyValueStore,
    BootGuardService? bootGuard,
  }) : _kv = keyValueStore,
       _bootGuard = bootGuard ?? BootGuardService(keyValueStore);

  static const String _settingsKey = 'studio.settings.v1';

  final KeyValueStore _kv;
  final BootGuardService _bootGuard;
  final StateStore<StudioShellState> _store = StateStore<StudioShellState>(
    const StudioShellState(),
  );

  /// Reactive shell state store.
  ReadOnlyStore<StudioShellState> get store => _store;

  /// Current shell state snapshot.
  StudioShellState get state => _store.state;

  @override
  StudioSettings get currentSettings => _store.state.settings;

  /// Shared [BootGuardService] used by model loaders.
  @override
  BootGuardService get bootGuard => _bootGuard;

  /// Loads persisted settings and inspects the crash sentinel.
  Future<void> initialize() async {
    final recovery = await _bootGuard.inspectStartupAndClear();
    var restored = const StudioSettings();
    final rawSettings = await _kv.readString(_settingsKey);
    if (rawSettings != null && rawSettings.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawSettings) as Map<String, Object?>;
        restored = StudioSettings.fromJson(decoded);
      } catch (error, stackTrace) {
        developer.log(
          'Failed to parse persisted StudioSettings; resetting to defaults.',
          name: 'llamadart_studio_core.StudioShellController',
          error: error,
          stackTrace: stackTrace,
        );
        restored = const StudioSettings();
      }
    }

    if (recovery != null) {
      // Safe Mode: disable auto-loading the offending model on this boot.
      restored = restored.copyWith(autoLoadLastModel: false);
    }

    _store.set(
      StudioShellState(
        initialized: true,
        settings: restored,
        bootRecoveryAlert: recovery,
      ),
    );
  }

  Object? _exitGuardOwner;
  Future<bool> Function()? _exitGuard;
  Future<bool>? _pendingExit;
  int _navigationEpoch = 0;
  bool _disposed = false;

  /// Registers the mounted workspace's save/capture guard.
  void registerWorkspaceExitGuard(Object owner, Future<bool> Function() guard) {
    _exitGuardOwner = owner;
    _exitGuard = guard;
  }

  /// Removes a guard only when it still belongs to [owner].
  void clearWorkspaceExitGuard(Object owner) {
    if (identical(_exitGuardOwner, owner)) {
      _exitGuardOwner = null;
      _exitGuard = null;
    }
  }

  /// Finishes capture and saves drafts before navigation or application exit.
  /// A failed guard refuses exit; the workspace presents recovery feedback.
  Future<bool> prepareWorkspaceExit() {
    if (_pendingExit case final pending?) return pending;
    final guard = _exitGuard;
    if (guard == null) return Future.value(true);
    final operation = () async {
      try {
        return await guard();
      } catch (error, stackTrace) {
        developer.log(
          'Workspace exit was refused after a save failure.',
          name: 'llamadart_studio_core.shell',
          stackTrace: stackTrace,
        );
        return false;
      }
    }();
    _pendingExit = operation;
    unawaited(
      operation.then((_) {
        if (identical(_pendingExit, operation)) _pendingExit = null;
      }),
    );
    return operation;
  }

  /// Switches workspaces after the current capture/draft has been protected.
  @override
  Future<void> selectWorkspace(StudioWorkspace workspace) async {
    final epoch = ++_navigationEpoch;
    if (workspace == state.activeWorkspace || _disposed) return;
    if (_exitGuard != null && !await prepareWorkspaceExit()) return;
    if (_disposed || epoch != _navigationEpoch) return;
    _store.update(
      (s) => s.copyWith(activeWorkspace: workspace, commandPaletteOpen: false),
    );
  }

  /// Toggles the active workspace's Session Inspector without crowding others.
  Future<void> toggleInspector() async {
    final workspace = state.activeWorkspace;
    final visible = !state.inspectorVisible;
    _store.update(
      (s) => s.copyWith(
        inspectorVisibility: Map.unmodifiable({
          ...s.inspectorVisibility,
          workspace: visible,
        }),
      ),
    );
    if (workspace == StudioWorkspace.chat) {
      await updateSettings((s) => s.copyWith(inspectorOpen: visible));
    }
  }

  /// Cycles or sets the UI appearance mode.
  Future<void> setAppearance(StudioAppearance appearance) async {
    await updateSettings(
      (StudioSettings s) => s.copyWith(appearance: appearance),
    );
  }

  /// Opens or closes the `Cmd/Ctrl+K` Command Palette.
  void setCommandPaletteOpen(bool open) {
    _store.update((StudioShellState s) => s.copyWith(commandPaletteOpen: open));
  }

  /// Dismisses the Safe Mode boot recovery banner.
  void dismissBootRecoveryAlert() {
    _store.update(
      (StudioShellState s) => s.copyWith(clearBootRecoveryAlert: true),
    );
  }

  /// Applies [transform] to [StudioSettings] and persists to [KeyValueStore].
  @override
  Future<void> updateSettings(
    StudioSettings Function(StudioSettings current) transform,
  ) async {
    final next = transform(_store.state.settings);
    _store.update((StudioShellState s) => s.copyWith(settings: next));
    await _kv.writeString(_settingsKey, jsonEncode(next.toJson()));
  }

  /// Disposes internal reactive streams.
  Future<void> dispose() async {
    _disposed = true;
    _navigationEpoch++;
    _exitGuard = null;
    _exitGuardOwner = null;
    await _store.dispose();
  }
}
