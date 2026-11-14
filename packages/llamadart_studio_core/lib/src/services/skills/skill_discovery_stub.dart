import '../../domain/studio_skill.dart';

/// Web stub returning no filesystem skills.
Future<List<StudioSkill>> discoverSkillsInDirectoriesImpl(
  List<String> directories, {
  String? workspaceRoot,
}) async => const <StudioSkill>[];
