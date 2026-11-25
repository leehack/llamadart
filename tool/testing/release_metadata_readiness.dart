import 'package:yaml/yaml.dart';

import 'check_released_changelog_sections.dart';

/// Fixed existing evidence for a core patch release with unchanged runtime pins.
const releaseMetadataRow = 'release-metadata-verification';
const releaseMetadataTest =
    'test/unit/tooling/verify_release_docs_companion_pins_test.dart';
const releaseMetadataVerifier =
    'tool/testing/verify_release_docs_versions.dart';
const releaseMetadataCommand =
    'dart run tool/testing/verify_release_docs_versions.dart --release-prep && '
    'dart test -p vm -j 1 $releaseMetadataTest';

/// Only current release documentation, not policy or versioned/MDX documents.
const releaseMetadataDocs = <String>{
  'CHANGELOG.md',
  'README.md',
  'website/docs/changelog/recent-releases.md',
  'website/docs/getting-started/installation.md',
  'packages/llamadart_llama_cpp_flutter/README.md',
  'packages/llamadart_litert_lm_flutter/README.md',
  'packages/llamadart_stable_diffusion_flutter/README.md',
};
const releaseMetadataLocks = <String, String>{
  'example/chat_app/pubspec.lock': '../..',
  'packages/llamadart_validation/pubspec.lock': '../..',
  'website/examples/observability/pubspec.lock': '../../..',
};
final Set<String> releaseMetadataPaths = Set<String>.unmodifiable({
  'pubspec.yaml',
  ...releaseMetadataLocks.keys,
  ...releaseMetadataDocs,
});

/// A literal Git blob and its mode; no candidate code is executed.
typedef ReadinessFile = ({String mode, String contents});
typedef ReadinessFilePair = ({ReadinessFile base, ReadinessFile head});

/// Validates a deliberately narrow core-only patch release transformation.
///
/// Companion version bumps, new files, pin updates and broader release work
/// remain on the ordinary changed-production-test route. All pairs must come
/// from the evaluator's exact Git base/head, never from the evidence JSON.
String? validateReleaseMetadata(Map<String, ReadinessFilePair> files) {
  if (!files.keys.toSet().containsAll(releaseMetadataPaths) ||
      files.keys.any((path) => !releaseMetadataPaths.contains(path))) {
    return 'Metadata release requires the complete fixed core pubspec, three generated '
        'consumer locks and current release-document inventory.';
  }
  for (final entry in files.entries) {
    if (entry.value.base.mode != '100644' ||
        entry.value.head.mode != '100644') {
      return 'Metadata release requires unchanged non-executable regular-file '
          'modes: ${entry.key}.';
    }
  }
  final core = releasePubspecVersionChange(files['pubspec.yaml']!, 'llamadart');
  if (core == null) {
    return 'Only the next core patch version scalar may change in pubspec; '
        'dependencies, SDK, hooks, overrides and other bytes must stay identical.';
  }
  final oldVersion = core.previous;
  final newVersion = core.next;
  final oldParts = oldVersion.split('.').map(int.parse).toList();
  final newParts = newVersion.split('.').map(int.parse).toList();
  if (oldParts[0] != newParts[0] ||
      oldParts[1] != newParts[1] ||
      oldParts[2] + 1 != newParts[2]) {
    return 'Only the next core patch version scalar may change in pubspec.';
  }

  for (final entry in releaseMetadataLocks.entries) {
    if (!matchesReleaseLockVersions(files[entry.key]!, {
      'llamadart': (version: core, relativePath: entry.value),
    })) {
      return 'Generated consumer lock ${entry.key} may change only the matching '
          'local llamadart version; package inventory, paths, hashes and SDK '
          'must stay identical.';
    }
  }
  for (final path in releaseMetadataDocs) {
    final pair = files[path];
    if (pair == null) continue;
    var baseProse = pair.base.contents;
    var headProse = pair.head.contents;
    if (path.endsWith('README.md') || path.endsWith('installation.md')) {
      final dependencies = RegExp(
        r'^\s+llamadart:\s+\^([^\s#]+)',
        multiLine: true,
      ).allMatches(pair.head.contents).toList();
      if (dependencies.isEmpty ||
          dependencies.any((match) => match.group(1) != newVersion) ||
          _companionConstraints(pair.base.contents) !=
              _companionConstraints(pair.head.contents)) {
        return 'Current installation snippets must use the new core patch '
            'and preserve already-prepared companion constraints: $path.';
      }
    }
    if (path == 'CHANGELOG.md' ||
        path == 'website/docs/changelog/recent-releases.md') {
      try {
        final old = ChangelogHistory.parse(baseProse);
        final next = ChangelogHistory.parse(headProse);
        if (old.sections.keys.first != oldVersion ||
            next.sections.keys.first != newVersion ||
            old.preamble != next.preamble ||
            old.sections.values.join() != next.sections.values.skip(1).join()) {
          return 'Release changelogs must prepend the next patch and preserve '
              'all existing bytes: $path.';
        }
        final before = _baselineIdentity(old.sections.values.first);
        final after = _baselineIdentity(next.sections.values.first);
        if (before == null || after != before) {
          return 'Metadata release must preserve the previous runtime baseline: $path.';
        }
        baseProse = old.preamble;
        headProse = next.preamble + next.sections.values.first;
      } on FormatException {
        return 'Invalid release changelog: $path.';
      }
    }
    // This exception is for Markdown prose/code examples, not active MDX.
    // Deny active contexts altogether: fragment equality cannot establish JS
    // equivalence (template literal attributes or script bodies can change).
    if (_activeFragments(baseProse) != '' ||
        _activeFragments(headProse) != '' ||
        _frontMatter(pair.base.contents) != _frontMatter(pair.head.contents) ||
        (path != 'CHANGELOG.md' &&
            path != 'website/docs/changelog/recent-releases.md' &&
            _runtimeIdentities(pair.base.contents) !=
                _runtimeIdentities(pair.head.contents))) {
      return 'Metadata release docs require inactive Markdown, unchanged '
          'frontmatter and unchanged runtime identities: $path.';
    }
  }
  return null;
}

typedef ReleaseVersionChange = ({String previous, String next});
typedef LockedReleaseVersion = ({
  ReleaseVersionChange version,
  String relativePath,
});

/// Accepts a canonical top-level package version bump as the only byte change.
ReleaseVersionChange? releasePubspecVersionChange(
  ReadinessFilePair pair,
  String package,
) {
  final previous = _packageVersion(pair.base.contents, package);
  final next = _packageVersion(pair.head.contents, package);
  if (previous == null ||
      next == null ||
      previous == next ||
      pair.base.contents.replaceFirst(
            RegExp('^version: ${RegExp.escape(previous)}\$', multiLine: true),
            'version: $next',
          ) !=
          pair.head.contents) {
    return null;
  }
  return (previous: previous, next: next);
}

String? _packageVersion(String source, String package) {
  try {
    final parsed = loadYaml(source);
    final matches = RegExp(
      r'^version: (0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
      multiLine: true,
    ).allMatches(source).toList();
    if (parsed is! YamlMap ||
        parsed['name'] != package ||
        matches.length != 1) {
      return null;
    }
    final version = matches.single.group(0)!.substring('version: '.length);
    return parsed['version'] == version ? version : null;
  } on YamlException {
    return null;
  }
}

/// Checks that only the listed checkout-local package versions changed.
bool matchesReleaseLockVersions(
  ReadinessFilePair pair,
  Map<String, LockedReleaseVersion> changes,
) {
  if (changes.isEmpty) return false;
  final Object? parsed;
  try {
    parsed = loadYaml(pair.base.contents);
  } on YamlException {
    return false;
  }
  if (parsed is! YamlMap || parsed['packages'] is! YamlMap) return false;
  final packages = parsed['packages'] as YamlMap;
  var expected = pair.base.contents;
  for (final entry in changes.entries) {
    final package = packages[entry.key];
    final version = entry.value.version;
    if (package is! YamlMap ||
        package['source'] != 'path' ||
        package['version'] != version.previous) {
      return false;
    }
    final description = package['description'];
    if (description is! YamlMap ||
        description['path'] != entry.value.relativePath ||
        description['relative'] != true) {
      return false;
    }
    final block = RegExp(
      '^  ${RegExp.escape(entry.key)}:\n'
      r'(?:    [^\n]*\n|      [^\n]*\n)*',
      multiLine: true,
    ).allMatches(expected).toList();
    final oldLine = RegExp(
      '^    version: "${RegExp.escape(version.previous)}"\$',
      multiLine: true,
    );
    if (block.length != 1 || oldLine.allMatches(block.single[0]!).length != 1) {
      return false;
    }
    final match = block.single;
    expected = expected.replaceRange(
      match.start,
      match.end,
      match[0]!.replaceFirst(oldLine, '    version: "${version.next}"'),
    );
  }
  return expected == pair.head.contents;
}

String? _activeFragments(String source) {
  final prose = StringBuffer();
  String? fence;
  for (final line in source.split('\n')) {
    final marker = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$').firstMatch(line);
    if (fence != null) {
      if (marker != null &&
          marker.group(1)![0] == fence[0] &&
          marker.group(1)!.length >= fence.length &&
          marker.group(2)!.trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    if (marker != null) {
      if ((marker.group(1)![0] == '`' && marker.group(2)!.contains('`')) ||
          marker.group(2)!.toLowerCase().contains('mdx-code-block')) {
        return null;
      }
      fence = marker.group(1)!;
      continue;
    }
    // Mask only matching inline backtick runs. Unmatched or escaped delimiters
    // never hide syntax. This keeps fenced/inline-to-active changes observable.
    var offset = 0;
    while (offset < line.length) {
      if (line[offset] != '`') {
        prose.write(line[offset++]);
        continue;
      }
      var slashes = 0;
      for (var index = offset - 1; index >= 0 && line[index] == r'\'; index--) {
        slashes++;
      }
      var end = offset;
      while (end < line.length && line[end] == '`') {
        end++;
      }
      final delimiter = line.substring(offset, end);
      int? closing;
      if (slashes.isEven) {
        var candidate = end;
        while ((candidate = line.indexOf('`', candidate)) >= 0) {
          var after = candidate;
          while (after < line.length && line[after] == '`') {
            after++;
          }
          if (after - candidate == delimiter.length) {
            closing = after;
            break;
          }
          candidate = after;
        }
      }
      if (closing == null) {
        prose.write(delimiter);
        offset = end;
      } else {
        prose.write(' ');
        offset = closing;
      }
    }
    prose.writeln();
  }
  if (fence != null) return null;
  return RegExp(
    r'<[^>]*>|\{[^}]*\}|^\s*(?:import|export)\b[^\n]*',
    multiLine: true,
  ).allMatches(prose.toString()).map((match) => match.group(0)).join('\n');
}

String _frontMatter(String source) =>
    RegExp(r'^---\n[\s\S]*?\n---\n').firstMatch(source)?.group(0) ?? '';

String? _baselineIdentity(String section) {
  final baseline = RegExp(
    r'^Runtime baseline: native llama\.cpp `([^`]+)` and Web use upstream '
    r'`([^`]+@[a-f0-9]{40})`; native LiteRT-LM uses `([^`]+)` and '
    r'stable-diffusion uses `([^`]+)`\. Web LiteRT-LM uses `(@litert-lm/core@[^`]+)`\. '
    r'Manifest SHA-256: `([a-f0-9]{64})`\.$',
    multiLine: true,
  ).allMatches(section).toList();
  return baseline.length == 1 ? baseline.single[0] : null;
}

String _runtimeIdentities(String source) {
  final identities = RegExp(
    r'\bv[0-9]+\.[0-9]+\.[0-9]+(?:[-.][A-Za-z0-9]+)*\b|'
    r'\bb[0-9]+(?:[-.][A-Za-z0-9]+)*\b|\b[0-9a-f]{40,64}\b',
  ).allMatches(source).map((match) => match.group(0)!).toSet().toList()..sort();
  return identities.join('\n');
}

String _companionConstraints(String source) =>
    RegExp(
          r'^\s+(llamadart_(?:llama_cpp|litert_lm)_flutter):\s+\^([^\s#]+)',
          multiLine: true,
        )
        .allMatches(source)
        .map((match) => '${match.group(1)}:${match.group(2)}')
        .join('\n');
