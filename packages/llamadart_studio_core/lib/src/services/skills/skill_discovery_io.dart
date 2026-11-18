import 'dart:io';

import 'package:path/path.dart' as p;

import '../../domain/studio_skill.dart';

/// Scans [workspaceRoot] standard agent skill folders (`.agents/skills`,
/// `.gemini/skills`, `.claude/skills`, `skills`) and [directories] for
/// `SKILL.md` bundles.
Future<List<StudioSkill>> discoverSkillsInDirectoriesImpl(
  List<String> directories, {
  String? workspaceRoot,
}) async {
  final candidateRoots = <String>{
    if (workspaceRoot != null && workspaceRoot.trim().isNotEmpty) ...<String>[
      p.join(workspaceRoot.trim(), '.agents', 'skills'),
      p.join(workspaceRoot.trim(), '.gemini', 'skills'),
      p.join(workspaceRoot.trim(), '.claude', 'skills'),
      p.join(workspaceRoot.trim(), 'skills'),
    ],
    for (final dir in directories)
      if (dir.trim().isNotEmpty) dir.trim(),
  };

  final seenPaths = <String>{};
  final skills = <StudioSkill>[];

  for (final rootPath in candidateRoots) {
    final rootDir = Directory(rootPath);
    if (!await rootDir.exists()) {
      continue;
    }

    // 1. Direct SKILL.md inside root.
    final directSkillFile = File(p.join(rootPath, 'SKILL.md'));
    if (await directSkillFile.exists()) {
      final canonical = p.canonicalize(directSkillFile.path);
      if (seenPaths.add(canonical)) {
        final parsed = await _tryReadSkillFile(
          directSkillFile,
          fallbackName: p.basename(rootPath),
        );
        if (parsed != null) {
          skills.add(parsed);
        }
      }
    }

    // 2. Immediate child skill folders (<root>/<skill-name>/SKILL.md).
    try {
      await for (final entity in rootDir.list(followLinks: false)) {
        if (entity is! Directory) {
          continue;
        }
        final skillFile = File(p.join(entity.path, 'SKILL.md'));
        if (!await skillFile.exists()) {
          continue;
        }
        final canonical = p.canonicalize(skillFile.path);
        if (!seenPaths.add(canonical)) {
          continue;
        }
        final parsed = await _tryReadSkillFile(
          skillFile,
          fallbackName: p.basename(entity.path),
        );
        if (parsed != null) {
          skills.add(parsed);
        }
      }
    } catch (_) {
      // Ignore unreadable directories.
    }
  }

  skills.sort((StudioSkill a, StudioSkill b) => a.name.compareTo(b.name));
  return skills;
}

Future<StudioSkill?> _tryReadSkillFile(
  File file, {
  required String fallbackName,
}) async {
  try {
    final content = await file.readAsString();
    if (content.trim().isEmpty) {
      return null;
    }
    return StudioSkill.parseMarkdown(
      content,
      fallbackName: fallbackName,
      sourcePath: file.path,
      isDiscovered: true,
    );
  } catch (_) {
    return null;
  }
}
