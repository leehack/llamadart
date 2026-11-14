import '../../domain/studio_skill.dart';
import 'skill_discovery_stub.dart'
    if (dart.library.io) 'skill_discovery_io.dart'
    as impl;

/// Discovers `SKILL.md` files across workspace and user-registered skill
/// directories (`dart:io` on desktop/mobile; empty list on Web).
Future<List<StudioSkill>> discoverSkillsInDirectories(
  List<String> directories, {
  String? workspaceRoot,
}) {
  return impl.discoverSkillsInDirectoriesImpl(
    directories,
    workspaceRoot: workspaceRoot,
  );
}
