import 'dart:convert';

import 'package:meta/meta.dart';

import '../../domain/studio_skill.dart';
import '../../ports/key_value_store.dart';
import '../../ports/studio_context_ports.dart';
import '../../reactive/state_store.dart';
import 'skill_discovery.dart';

/// Immutable snapshot of Studio's Agent Skills (`SKILL.md`) catalog.
@immutable
class SkillRegistryState {
  /// Creates a [SkillRegistryState].
  const SkillRegistryState({
    this.skills = const <StudioSkill>[],
    this.customDirectories = const <String>[],
    this.workspaceRoot,
  });

  /// Combined built-in, custom, and discovered `SKILL.md` skills.
  final List<StudioSkill> skills;

  /// User-registered directories scanned for `SKILL.md` files.
  final List<String> customDirectories;

  /// Active workspace root scanned for project `.agents/skills`, `.gemini/skills`, etc.
  final String? workspaceRoot;

  /// Skills currently toggled ON.
  List<StudioSkill> get activeSkills =>
      skills.where((StudioSkill s) => s.enabled).toList(growable: false);

  /// Returns an updated copy of [SkillRegistryState].
  SkillRegistryState copyWith({
    List<StudioSkill>? skills,
    List<String>? customDirectories,
    String? workspaceRoot,
    bool clearWorkspaceRoot = false,
  }) {
    return SkillRegistryState(
      skills: skills ?? this.skills,
      customDirectories: customDirectories ?? this.customDirectories,
      workspaceRoot: clearWorkspaceRoot
          ? null
          : (workspaceRoot ?? this.workspaceRoot),
    );
  }
}

/// Manages built-in, custom, and filesystem-discovered Agent Skills (`SKILL.md`)
/// and formats active instructions for Coding and Chat inference turns.
class SkillRegistry implements StudioWorkspaceSkillCoordinator {
  /// Creates a [SkillRegistry].
  SkillRegistry({required KeyValueStore keyValueStore}) : _kv = keyValueStore;

  static const String _enabledIdsKey = 'studio.skills.enabled_ids.v1';
  static const String _customSkillsKey = 'studio.skills.custom.v1';
  static const String _directoriesKey = 'studio.skills.directories.v1';

  final KeyValueStore _kv;
  final StateStore<SkillRegistryState> _store = StateStore<SkillRegistryState>(
    const SkillRegistryState(),
  );

  List<StudioSkill> _customSkills = <StudioSkill>[];
  List<StudioSkill> _discoveredSkills = <StudioSkill>[];
  Set<String> _enabledIds = <String>{'builtin:dart-flutter-engineer'};
  bool _hasPersistedEnabledIds = false;

  /// Reactive skills store.
  @override
  ReadOnlyStore<SkillRegistryState> get store => _store;

  /// Current snapshot.
  @override
  SkillRegistryState get state => _store.state;

  /// Loads persisted skill toggles, custom skills, and directories.
  Future<void> initialize({String? workspaceRoot}) async {
    final rawEnabled = await _kv.readString(_enabledIdsKey);
    if (rawEnabled != null && rawEnabled.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawEnabled);
        if (decoded is List) {
          _enabledIds = decoded.whereType<String>().toSet();
          _hasPersistedEnabledIds = true;
        }
      } catch (_) {}
    }

    final rawCustom = await _kv.readString(_customSkillsKey);
    if (rawCustom != null && rawCustom.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawCustom);
        if (decoded is List) {
          _customSkills = decoded
              .whereType<Map<String, Object?>>()
              .map(StudioSkill.fromJson)
              .toList();
        }
      } catch (_) {}
    }

    var dirs = <String>[];
    final rawDirs = await _kv.readString(_directoriesKey);
    if (rawDirs != null && rawDirs.isNotEmpty) {
      try {
        final decoded = jsonDecode(rawDirs);
        if (decoded is List) {
          dirs = decoded.whereType<String>().toList(growable: false);
        }
      } catch (_) {}
    }

    _store.update(
      (SkillRegistryState s) =>
          s.copyWith(customDirectories: dirs, workspaceRoot: workspaceRoot),
    );
    await refreshDiscoveredSkills(workspaceRoot: workspaceRoot);
  }

  /// Rescans [workspaceRoot] (if set) and all registered skill folders.
  @override
  Future<void> refreshDiscoveredSkills({String? workspaceRoot}) async {
    final nextRoot = workspaceRoot ?? _store.state.workspaceRoot;
    _discoveredSkills = await discoverSkillsInDirectories(
      _store.state.customDirectories,
      workspaceRoot: nextRoot,
    );
    if (!_hasPersistedEnabledIds) {
      for (final builtIn in StudioSkill.builtInSkills) {
        if (builtIn.enabled) {
          _enabledIds.add(builtIn.id);
        }
      }
    }
    _rebuildState(workspaceRoot: nextRoot);
  }

  /// Registers a folder containing `SKILL.md` sub-bundles and rescans.
  Future<void> addSkillDirectory(String directoryPath) async {
    final trimmed = directoryPath.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final nextDirs = <String>{
      ..._store.state.customDirectories,
      trimmed,
    }.toList(growable: false);
    _store.update(
      (SkillRegistryState s) => s.copyWith(customDirectories: nextDirs),
    );
    await _kv.writeString(_directoriesKey, jsonEncode(nextDirs));
    await refreshDiscoveredSkills();
  }

  /// Removes a custom skill folder and rescans.
  Future<void> removeSkillDirectory(String directoryPath) async {
    final nextDirs = _store.state.customDirectories
        .where((String d) => d != directoryPath)
        .toList(growable: false);
    _store.update(
      (SkillRegistryState s) => s.copyWith(customDirectories: nextDirs),
    );
    await _kv.writeString(_directoriesKey, jsonEncode(nextDirs));
    await refreshDiscoveredSkills();
  }

  /// Toggles whether skill [skillId] is injected into inference turns.
  Future<void> setSkillEnabled(String skillId, bool enabled) async {
    _hasPersistedEnabledIds = true;
    if (enabled) {
      _enabledIds.add(skillId);
    } else {
      _enabledIds.remove(skillId);
    }
    await _kv.writeString(
      _enabledIdsKey,
      jsonEncode(_enabledIds.toList(growable: false)),
    );
    _rebuildState();
  }

  /// Creates or updates a custom in-app skill from raw `SKILL.md` Markdown or
  /// structured fields, enabling it automatically.
  Future<StudioSkill> saveCustomSkill({
    String? id,
    required String name,
    required String description,
    required String instructions,
    bool enableImmediately = true,
  }) async {
    final cleanName = name.trim().isEmpty ? 'custom-skill' : name.trim();
    final skillId = id ?? 'custom:${DateTime.now().microsecondsSinceEpoch}';
    final created = StudioSkill(
      id: skillId,
      name: cleanName,
      description: description.trim(),
      instructions: instructions.trim(),
      enabled: enableImmediately,
    );
    _customSkills = <StudioSkill>[
      created,
      for (final existing in _customSkills)
        if (existing.id != skillId) existing,
    ];
    if (enableImmediately) {
      _hasPersistedEnabledIds = true;
      _enabledIds.add(skillId);
      await _kv.writeString(
        _enabledIdsKey,
        jsonEncode(_enabledIds.toList(growable: false)),
      );
    }
    await _kv.writeString(
      _customSkillsKey,
      jsonEncode(
        _customSkills
            .map((StudioSkill s) => s.toJson())
            .toList(growable: false),
      ),
    );
    _rebuildState();
    return created;
  }

  /// Imports a raw `SKILL.md` Markdown document into custom skills.
  Future<StudioSkill> importSkillMarkdown(
    String rawMarkdown, {
    String fallbackName = 'imported-skill',
    bool enableImmediately = true,
  }) async {
    final parsed = StudioSkill.parseMarkdown(
      rawMarkdown,
      fallbackName: fallbackName,
    );
    return saveCustomSkill(
      name: parsed.name,
      description: parsed.description,
      instructions: parsed.instructions,
      enableImmediately: enableImmediately,
    );
  }

  /// Deletes a user-created custom skill.
  Future<void> deleteCustomSkill(String skillId) async {
    _customSkills = _customSkills
        .where((StudioSkill s) => s.id != skillId)
        .toList();
    _enabledIds.remove(skillId);
    await _kv.writeString(
      _customSkillsKey,
      jsonEncode(
        _customSkills
            .map((StudioSkill s) => s.toJson())
            .toList(growable: false),
      ),
    );
    await _kv.writeString(
      _enabledIdsKey,
      jsonEncode(_enabledIds.toList(growable: false)),
    );
    _rebuildState();
  }

  /// Formats all currently enabled skills into a compact system prompt block.
  @override
  String buildActiveSkillsSystemContext() {
    final active = _store.state.activeSkills;
    if (active.isEmpty) {
      return '';
    }
    final buf = StringBuffer('<active_skills>\n');
    for (final skill in active) {
      buf
        ..writeln('## Skill: ${skill.name}')
        ..writeln(
          skill.description.isEmpty ? '' : 'Summary: ${skill.description}\n',
        )
        ..writeln(skill.instructions.trim())
        ..writeln();
    }
    buf.write('</active_skills>');
    return buf.toString().trim();
  }

  void _rebuildState({String? workspaceRoot}) {
    final merged = <StudioSkill>[
      for (final s in StudioSkill.builtInSkills)
        s.copyWith(enabled: _enabledIds.contains(s.id)),
      for (final s in _discoveredSkills)
        s.copyWith(enabled: _enabledIds.contains(s.id)),
      for (final s in _customSkills)
        s.copyWith(enabled: _enabledIds.contains(s.id)),
    ];
    _store.update(
      (SkillRegistryState s) => s.copyWith(
        skills: List<StudioSkill>.unmodifiable(merged),
        workspaceRoot: workspaceRoot ?? s.workspaceRoot,
      ),
    );
  }

  /// Disposes internal reactive store.
  Future<void> dispose() => _store.dispose();
}
