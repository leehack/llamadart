import 'package:meta/meta.dart';

/// Parsed `SKILL.md` agent skill following the Agent Skills YAML frontmatter
/// + Markdown instructions specification.
@immutable
class StudioSkill {
  /// Creates a [StudioSkill].
  const StudioSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.instructions,
    this.sourcePath,
    this.isBuiltIn = false,
    this.isDiscovered = false,
    this.enabled = false,
    this.license,
    this.compatibility,
  });

  /// Stable unique skill identifier.
  final String id;

  /// Canonical skill name (usually kebab-case from `SKILL.md` frontmatter).
  final String name;

  /// Concise description used for skill discovery and UI summaries.
  final String description;

  /// Full Markdown body injected into the system context when active.
  final String instructions;

  /// Filesystem path to `SKILL.md` when discovered from disk.
  final String? sourcePath;

  /// Whether shipped as a built-in Studio skill.
  final bool isBuiltIn;

  /// Whether discovered from a workspace or custom directory on disk.
  final bool isDiscovered;

  /// Whether currently toggled ON for Coding/Chat prompt injection.
  final bool enabled;

  /// Optional `license` frontmatter metadata.
  final String? license;

  /// Optional `compatibility` frontmatter metadata.
  final String? compatibility;

  /// Returns an updated copy of [StudioSkill].
  StudioSkill copyWith({
    String? name,
    String? description,
    String? instructions,
    String? sourcePath,
    bool? isBuiltIn,
    bool? isDiscovered,
    bool? enabled,
    String? license,
    String? compatibility,
  }) {
    return StudioSkill(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      instructions: instructions ?? this.instructions,
      sourcePath: sourcePath ?? this.sourcePath,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      isDiscovered: isDiscovered ?? this.isDiscovered,
      enabled: enabled ?? this.enabled,
      license: license ?? this.license,
      compatibility: compatibility ?? this.compatibility,
    );
  }

  /// Serializes custom user-created skill to JSON.
  Map<String, Object?> toJson() {
    return <String, Object?>{
      'id': id,
      'name': name,
      'description': description,
      'instructions': instructions,
      if (sourcePath != null) 'sourcePath': sourcePath,
      'isBuiltIn': isBuiltIn,
      'isDiscovered': isDiscovered,
      'enabled': enabled,
      if (license != null) 'license': license,
      if (compatibility != null) 'compatibility': compatibility,
    };
  }

  /// Restores a [StudioSkill] from JSON.
  factory StudioSkill.fromJson(Map<String, Object?> json) {
    return StudioSkill(
      id:
          (json['id'] as String?) ??
          'skill_${DateTime.now().microsecondsSinceEpoch}',
      name: (json['name'] as String?) ?? 'custom-skill',
      description: (json['description'] as String?) ?? '',
      instructions: (json['instructions'] as String?) ?? '',
      sourcePath: json['sourcePath'] as String?,
      isBuiltIn: (json['isBuiltIn'] as bool?) ?? false,
      isDiscovered: (json['isDiscovered'] as bool?) ?? false,
      enabled: (json['enabled'] as bool?) ?? false,
      license: json['license'] as String?,
      compatibility: json['compatibility'] as String?,
    );
  }

  /// Parses a `SKILL.md` file with optional `---` YAML frontmatter block.
  static StudioSkill parseMarkdown(
    String rawContent, {
    required String fallbackName,
    String? idOverride,
    String? sourcePath,
    bool isBuiltIn = false,
    bool isDiscovered = false,
    bool enabled = false,
  }) {
    final normalized = rawContent.replaceAll('\r\n', '\n').trimLeft();
    var name = fallbackName;
    var description = 'Custom SKILL.md agent instructions.';
    String? license;
    String? compatibility;
    var body = normalized.trim();

    if (normalized.startsWith('---\n') || normalized.startsWith('---\r\n')) {
      final closeIndex = normalized.indexOf('\n---', 3);
      if (closeIndex > 0) {
        final frontmatter = normalized.substring(4, closeIndex);
        body = normalized.substring(closeIndex + 4).trim();
        final parsedMeta = _parseSimpleYamlFrontmatter(frontmatter);
        if ((parsedMeta['name'] ?? '').isNotEmpty) {
          name = parsedMeta['name']!;
        }
        if ((parsedMeta['description'] ?? '').isNotEmpty) {
          description = parsedMeta['description']!;
        }
        if ((parsedMeta['license'] ?? '').isNotEmpty) {
          license = parsedMeta['license'];
        }
        if ((parsedMeta['compatibility'] ?? '').isNotEmpty) {
          compatibility = parsedMeta['compatibility'];
        }
      }
    }

    final cleanId =
        idOverride ??
        (sourcePath != null
            ? 'disk:${_slugify(sourcePath)}'
            : 'custom:${_slugify(name)}');

    return StudioSkill(
      id: cleanId,
      name: name.trim().isEmpty ? fallbackName : name.trim(),
      description: description.trim(),
      instructions: body,
      sourcePath: sourcePath,
      isBuiltIn: isBuiltIn,
      isDiscovered: isDiscovered,
      enabled: enabled,
      license: license,
      compatibility: compatibility,
    );
  }

  static Map<String, String> _parseSimpleYamlFrontmatter(String yaml) {
    final result = <String, String>{};
    final lines = yaml.split('\n');
    String? currentKey;
    final buffer = StringBuffer();

    void flushCurrent() {
      final key = currentKey;
      if (key != null) {
        result[key] = _stripQuotes(buffer.toString().trim());
      }
      currentKey = null;
      buffer.clear();
    }

    for (final rawLine in lines) {
      final trimmed = rawLine.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) {
        if (currentKey != null && buffer.isNotEmpty) {
          buffer.write('\n');
        }
        continue;
      }
      final isIndented = rawLine.startsWith(' ') || rawLine.startsWith('\t');
      if (!isIndented) {
        final colonIdx = rawLine.indexOf(':');
        if (colonIdx > 0) {
          flushCurrent();
          final key = rawLine.substring(0, colonIdx).trim();
          final valuePart = rawLine.substring(colonIdx + 1).trim();
          currentKey = key;
          if (valuePart != '|' && valuePart != '>') {
            buffer.write(valuePart);
          }
          continue;
        }
      }
      if (currentKey != null) {
        if (buffer.isNotEmpty) {
          buffer.write(' ');
        }
        buffer.write(trimmed);
      }
    }
    flushCurrent();
    return result;
  }

  static String _stripQuotes(String s) {
    if (s.length >= 2 &&
        ((s.startsWith('"') && s.endsWith('"')) ||
            (s.startsWith("'") && s.endsWith("'")))) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  static String _slugify(String raw) {
    final cleaned = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-');
    return cleaned.replaceAll(RegExp(r'^-+|-+$'), '');
  }

  /// Built-in developer skills shipped inside `llamadart Studio`.
  static const List<StudioSkill> builtInSkills = <StudioSkill>[
    StudioSkill(
      id: 'builtin:dart-flutter-engineer',
      name: 'dart-flutter-engineer',
      description:
          'Idiomatic Dart 3 / Flutter engineering standards: null safety, immutable models, and targeted verification.',
      instructions: '''
When writing or reviewing Dart or Flutter code:
1. Prefer small, immutable `@immutable` models with explicit `copyWith` and JSON serialization.
2. Read the existing file before proposing edits (`read_file` / `search_code`) so symbol names and imports match the codebase verbatim.
3. Keep business logic cleanly separated from Flutter `Widget` trees; do not import `dart:io` into platform-agnostic core libraries without conditional imports.
4. For patches, use `patch_file` with exact verbatim snippets and summarize changed files and verification steps accurately.''',
      isBuiltIn: true,
      enabled: true,
    ),
    StudioSkill(
      id: 'builtin:safe-code-reviewer',
      name: 'safe-code-reviewer',
      description:
          'Structured code review focusing on correctness bugs, boundary cases, resource leaks, and security.',
      instructions: '''
When reviewing code or proposing changes:
1. Inspect error paths, resource disposal (`dispose`, streams, file handles), and boundary checks before style nitpicks.
2. Flag path-traversal risks, unvalidated user inputs, and blocking synchronous I/O on UI threads.
3. Report concrete file paths and line numbers for every finding and include a minimal reproduction or fix.''',
      isBuiltIn: true,
    ),
    StudioSkill(
      id: 'builtin:concise-patch-planner',
      name: 'concise-patch-planner',
      description:
          'Enforces read-first workspace exploration and minimal surgical edits over speculative rewrites.',
      instructions: '''
Follow a disciplined read-search-patch loop:
1. Start by exploring directory layout (`list_files`) or searching symbols (`search_code`) instead of guessing paths.
2. Read only the relevant sections of target files before editing.
3. Apply the smallest complete patch needed and explain the behavioral impact concisely.''',
      isBuiltIn: true,
    ),
  ];
}
