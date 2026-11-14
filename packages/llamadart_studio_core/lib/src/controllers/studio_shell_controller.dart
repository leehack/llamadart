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

  /// Returns an updated copy of [StudioShellState].
  StudioShellState copyWith({
    bool? initialized,
    StudioWorkspace? activeWorkspace,
    StudioSettings? settings,
    BootRecoveryAlert? bootRecoveryAlert,
    bool clearBootRecoveryAlert = false,
    bool? commandPaletteOpen,
  }) {
    return StudioShellState(
      initialized: initialized ?? this.initialized,
      activeWorkspace: activeWorkspace ?? this.activeWorkspace,
      settings: settings ?? this.settings,
      bootRecoveryAlert: clearBootRecoveryAlert
          ? null
          : (bootRecoveryAlert ?? this.bootRecoveryAlert),
      commandPaletteOpen: commandPaletteOpen ?? this.commandPaletteOpen,
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

  /// Switches the active Studio workspace.
  @override
  void selectWorkspace(StudioWorkspace workspace) {
    _store.update(
      (StudioShellState s) =>
          s.copyWith(activeWorkspace: workspace, commandPaletteOpen: false),
    );
  }

  /// Toggles the right-hand Session Inspector panel.
  Future<void> toggleInspector() async {
    await updateSettings(
      (StudioSettings s) => s.copyWith(inspectorOpen: !s.inspectorOpen),
    );
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
  Future<void> dispose() => _store.dispose();
}
