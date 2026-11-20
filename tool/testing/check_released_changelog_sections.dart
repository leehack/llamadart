#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

import '../release/pr_changelog.dart';

export '../release/pr_changelog.dart' show isCoreReleasePrep;

const releasedChangelogs = <String>[
  'CHANGELOG.md',
  'website/docs/changelog/recent-releases.md',
];
const changelogArchive = 'doc/changelog_archive.md';
const changelogCutover = 'tool/release/changelog_pr_cutover.json';
const changelogSizeLimit = 256 * 1024;

final _unreleasedHeading = RegExp(
  r'^ {0,3}##[ \t]+Unreleased(?:[ \t]+#+)?[ \t]*$',
  multiLine: true,
);
final _sha = RegExp(r'^[a-f0-9]{40}$');
final _releaseHeading = RegExp(
  r'^ {0,3}##(?:[ \t]+([^\r\n]*)|(?=\r?$))',
  multiLine: true,
);

bool hasUnreleasedHeading(String text) => _unreleasedHeading.hasMatch(text);

/// Splits a changelog without normalizing the bytes in its sections.
class ChangelogHistory {
  const ChangelogHistory(this.preamble, this.sections);

  final String preamble;
  final Map<String, String> sections;

  static ChangelogHistory parse(String source, {bool allowUnreleased = false}) {
    final heads = _releaseHeading.allMatches(source).toList();
    if (heads.isEmpty) {
      throw const FormatException('Changelog has no release headings.');
    }
    final sections = <String, String>{};
    for (final (index, head) in heads.indexed) {
      final version = head[1]?.trim() ?? '';
      if (version == 'Unreleased'
          ? !allowUnreleased || index != 0
          : !coreReleaseVersion.hasMatch(version)) {
        throw FormatException('Unexpected changelog heading: $version.');
      }
      if (sections.containsKey(version)) {
        throw FormatException('Duplicate changelog heading: $version.');
      }
      sections[version] = source.substring(
        head.start,
        index + 1 < heads.length ? heads[index + 1].start : source.length,
      );
    }
    return ChangelogHistory(source.substring(0, heads.first.start), sections);
  }

  String get text => preamble + sections.values.join();
}

String archiveBoundary(String preamble, String from, String to) => preamble
    .replaceFirst(
      'Releases before $from are in the',
      'Releases before $to are in the',
    )
    .replaceFirst(
      'Releases of `llamadart` before $from, moved verbatim from',
      'Releases of `llamadart` before $to, moved verbatim from',
    );

String recentReleasesPreamble(String legacy) => legacy
    .replaceFirst(
      'Release notes for the unreleased changes and the current and previous llamadart minor',
      'Release notes for the current and previous llamadart minor',
    )
    .replaceFirst(
      'This page keeps the unreleased changes and the current and previous minor',
      'This page keeps the current and previous minor',
    );

/// Release headings in the current series and the latest earlier series that
/// actually shipped. This also retains the last minor of the previous major
/// when the current minor is zero; missing patch numbers are never invented.
List<String> retainedReleaseHeadings(
  Iterable<String> headings, {
  required int major,
  required int minor,
}) {
  final releases = <(String, int, int)>[];
  final version = RegExp(r'^## (\d+)\.(\d+)\.\d+\S*\s*$');
  (int, int)? previous;
  for (final heading in headings) {
    final match = version.firstMatch(heading);
    if (match == null) continue;
    final series = (int.parse(match[1]!), int.parse(match[2]!));
    releases.add((heading.trim(), series.$1, series.$2));
    if ((series.$1 < major || (series.$1 == major && series.$2 < minor)) &&
        (previous == null ||
            series.$1 > previous.$1 ||
            (series.$1 == previous.$1 && series.$2 > previous.$2))) {
      previous = series;
    }
  }
  return [
    for (final (heading, releaseMajor, releaseMinor) in releases)
      if ((releaseMajor == major && releaseMinor == minor) ||
          (releaseMajor, releaseMinor) == previous)
        heading,
  ];
}

String? coreVersionFromPubspec(String text) {
  final version = RegExp(
    r'^version:[ \t]+([^\s]+)[ \t]*\r?$',
    multiLine: true,
  ).allMatches(text).toList();
  final name = RegExp(r'^name:[ \t]+llamadart[ \t]*\r?$', multiLine: true);
  if (version.length == 1 && name.hasMatch(text)) {
    final value = version.single[1]!;
    if (coreReleaseVersion.hasMatch(value)) return value;
  }
  return null;
}

typedef _TreeEntry = ({String mode, String type, String id});

class _Git {
  const _Git(this.root);
  final Directory root;

  String run(List<String> args) {
    final result = Process.runSync('git', args, workingDirectory: root.path);
    if (result.exitCode != 0) throw StateError('Git ${args.first} failed.');
    return result.stdout as String;
  }

  _TreeEntry? entry(String sha, String path) {
    final row = run(['ls-tree', '-z', sha, '--', path]);
    if (row.isEmpty) return null;
    final fields = row.split('\t').first.split(' ');
    return (mode: fields[0], type: fields[1], id: fields[2]);
  }

  String blob(String sha, String path) => run(['show', '$sha:$path']);
}

/// Determines the PR's release route and compares the real head with its merge
/// base. The event's immutable base SHA also anchors the activation boundary.
List<String> checkReleasedChangelogSections(
  Directory repoRoot,
  Map<String, Object?> event, {
  required String repository,
  void Function(String message)? log,
}) {
  final request = event['pull_request'];
  if (request is! Map) {
    throw StateError('The event has no pull request base SHA.');
  }
  final base = (request['base'] as Map?)?['sha'];
  final headInfo = request['head'] as Map?;
  final head = headInfo?['sha'];
  final ref = headInfo?['ref'];
  final headRepository = (headInfo?['repo'] as Map?)?['full_name'];
  if (base is! String ||
      head is! String ||
      ref is! String ||
      headRepository is! String) {
    throw StateError(
      'The event has no pull request head SHA, ref or repository.',
    );
  }
  if (!_sha.hasMatch(base) || !_sha.hasMatch(head)) {
    throw StateError('The event must identify full Git commit SHAs.');
  }
  final git = _Git(repoRoot);
  final fork = git.run(['merge-base', base, head]).trim();
  final prep =
      isCoreReleasePrep(
        labels: [
          for (final label in request['labels'] as List? ?? const [])
            if (label is Map && label['name'] is String)
              label['name'] as String,
        ],
        headRef: ref,
        headRepository: headRepository,
        repository: repository,
      ) &&
      _isCorePrepDiff(git, fork, head);
  log?.call('Core release prep: $prep');
  return _checkTrees(git, fork, head, prep: prep, eventBase: base);
}

bool _isCorePrepDiff(_Git git, String base, String head) {
  final paths = git
      .run(['diff', '--no-renames', '--name-only', '-z', base, head])
      .split('\x00');
  final oldPubspec = git.entry(base, 'pubspec.yaml');
  final pubspec = git.entry(head, 'pubspec.yaml');
  return paths.contains('pubspec.yaml') &&
      !paths.any((path) => path.startsWith('packages/genkit_llamadart/')) &&
      oldPubspec?.mode == '100644' &&
      pubspec?.mode == '100644' &&
      coreVersionFromPubspec(git.blob(base, 'pubspec.yaml')) != null &&
      coreVersionFromPubspec(git.blob(head, 'pubspec.yaml')) != null &&
      coreVersionFromPubspec(git.blob(base, 'pubspec.yaml')) !=
          coreVersionFromPubspec(git.blob(head, 'pubspec.yaml'));
}

/// Validates the release artifacts on a candidate tree or landed squash.
List<String> checkReleasePrepTrees(
  Directory root,
  String base,
  String candidate,
) {
  if (!_sha.hasMatch(base) || !_sha.hasMatch(candidate)) {
    throw StateError('Release prep requires full Git commit SHAs.');
  }
  final git = _Git(root);
  if (!_isCorePrepDiff(git, base, candidate)) {
    return ['Core prep must bump the root version and exclude Genkit changes.'];
  }
  return _checkTrees(git, base, candidate, prep: true, eventBase: base);
}

List<String> _checkTrees(
  _Git git,
  String base,
  String head, {
  required bool prep,
  required String eventBase,
}) {
  final oldMarker = git.entry(base, changelogCutover);
  final newMarker = git.entry(head, changelogCutover);
  if (!prep && oldMarker == null && newMarker != null) {
    return _activation(git, base, head, eventBase);
  }
  if (oldMarker != newMarker || prep && oldMarker?.mode != '100644') {
    return ['$changelogCutover must stay unchanged.'];
  }
  final files = [...releasedChangelogs, changelogArchive];
  if (!prep) {
    return [
      for (final path in files)
        if (git.entry(base, path) != git.entry(head, path))
          '$path is written only by core release prep. Put notes in the PR body.',
    ];
  }

  final version = coreVersionFromPubspec(git.blob(head, 'pubspec.yaml'))!;
  final parts = coreReleaseVersion.firstMatch(version)!;
  final old = <String, ChangelogHistory>{};
  final next = <String, ChangelogHistory>{};
  for (final path in files) {
    final oldEntry = git.entry(base, path);
    final nextEntry = git.entry(head, path);
    if (oldEntry?.mode != '100644' || nextEntry?.mode != oldEntry?.mode) {
      return ['$path must retain its regular file mode.'];
    }
    try {
      old[path] = ChangelogHistory.parse(git.blob(base, path));
      next[path] = ChangelogHistory.parse(git.blob(head, path));
    } on FormatException catch (e) {
      return ['$path: ${e.message}'];
    }
  }
  final [root, docs, archive] = [for (final path in files) old[path]!];
  final [newRoot, newDocs, newArchive] = [
    for (final path in files) next[path]!,
  ];
  final historical = [...root.sections.entries, ...archive.sections.entries];
  final candidate = [
    ...newRoot.sections.entries.skip(1),
    ...newArchive.sections.entries,
  ];
  final versions = historical.map((entry) => entry.key).toList();
  if (versions.toSet().length != versions.length ||
      versions.contains(version) ||
      !newRoot.sections.values.first.startsWith('## $version\n') ||
      !newDocs.sections.values.first.startsWith('## $version\n') ||
      newRoot.sections.length > root.sections.length + 1 ||
      !_sameSections(historical, candidate) ||
      !newArchive.sections.keys.toSet().containsAll(archive.sections.keys)) {
    return [
      'Core prep must prepend exactly one release and preserve numbered history exactly.',
    ];
  }

  final boundary = root.sections.keys.last;
  final newBoundary = newRoot.sections.keys.last;
  final moved = newArchive.sections.length > archive.sections.length;
  final rootPrefix = moved
      ? archiveBoundary(root.preamble, boundary, newBoundary)
      : root.preamble;
  final archivePrefix = moved
      ? archiveBoundary(archive.preamble, boundary, newBoundary)
      : archive.preamble;
  if (newRoot.preamble != rootPrefix ||
      newArchive.preamble != archivePrefix ||
      newDocs.preamble != docs.preamble) {
    return ['Core prep must preserve changelog preambles.'];
  }
  final hypotheticalRoot =
      root.preamble +
      newRoot.sections.values.first +
      root.sections.values.join();
  if (utf8.encode(newRoot.text).length > changelogSizeLimit ||
      moved && utf8.encode(hypotheticalRoot).length <= changelogSizeLimit ||
      moved &&
          utf8.encode(newRoot.text + newArchive.sections.values.first).length <=
              changelogSizeLimit) {
    return [
      'Core prep may move only the history required by the pub.dev size limit.',
    ];
  }

  final retained = retainedReleaseHeadings(
    ['## $version', for (final v in versions) '## $v'],
    major: int.parse(parts[1]!),
    minor: int.parse(parts[2]!),
  ).skip(1).map((heading) => heading.substring(3)).toList();
  final docsKeys = newDocs.sections.keys.skip(1).toList();
  if (docsKeys.join('\n') != retained.join('\n') ||
      docsKeys.any((v) => docs.sections[v] != newDocs.sections[v])) {
    return [
      'Docs changelog must preserve the retained published sections exactly.',
    ];
  }
  return [];
}

bool _sameSections(
  List<MapEntry<String, String>> old,
  List<MapEntry<String, String>> next,
) =>
    old.length == next.length &&
    old.indexed.every(
      (item) =>
          item.$2.key == next[item.$1].key &&
          item.$2.value == next[item.$1].value,
    );

const _unionRules = '''
# Keep both sides' `## Unreleased` bullets in local merges and rebases. Union
# keeps both sides of any conflicting edit too, so resolve release-prep edits
# by hand (see website/docs/maintainers/release-workflow.md).
/CHANGELOG.md merge=union
/website/docs/changelog/recent-releases.md merge=union

''';

List<String> _activation(_Git git, String base, String head, String eventBase) {
  final marker = jsonDecode(git.blob(head, changelogCutover));
  final previous = coreVersionFromPubspec(git.blob(base, 'pubspec.yaml'));
  if (base != eventBase ||
      git.entry(head, changelogCutover)?.mode != '100644' ||
      marker is! Map ||
      marker.length != 2 ||
      marker['commit'] != base ||
      marker['tag'] != 'v$previous' ||
      previous == null ||
      !git
          .run(['rev-list', '--first-parent', base])
          .split('\n')
          .contains(
            git.run([
              'rev-parse',
              '--verify',
              'refs/tags/v$previous^{commit}',
            ]).trim(),
          )) {
    return [
      'Cutover must identify the last legacy main and its first-parent core tag.',
    ];
  }

  final legacy = <ChangelogHistory>[];
  for (final path in releasedChangelogs) {
    if (git.entry(base, path)?.mode != '100644' ||
        git.entry(head, path)?.mode != '100644') {
      return ['$path must retain its regular file mode at cutover.'];
    }
    final old = ChangelogHistory.parse(
      git.blob(base, path),
      allowUnreleased: true,
    );
    legacy.add(old);
    if (old.sections.keys.firstOrNull != 'Unreleased' ||
        old.sections.keys.skip(1).firstOrNull != previous ||
        git.blob(head, path) !=
            (path == releasedChangelogs.last
                    ? recentReleasesPreamble(old.preamble)
                    : old.preamble) +
                old.sections.values.skip(1).join()) {
      return [
        'Cutover may remove only the legacy notes and prescribed pending wording in $path.',
      ];
    }
  }
  legacySeedNotes(legacy.first, legacy.last);
  if (git.entry(base, changelogArchive) != git.entry(head, changelogArchive) ||
      git.entry(base, '.gitattributes')?.mode != '100644' ||
      git.entry(head, '.gitattributes')?.mode != '100644' ||
      !git.blob(base, '.gitattributes').contains(_unionRules) ||
      git.blob(head, '.gitattributes') !=
          git.blob(base, '.gitattributes').replaceFirst(_unionRules, '')) {
    return [
      'Cutover must preserve the archive and remove only the core union rules.',
    ];
  }
  return [];
}

/// The existing normalized bridge wording is the only cross-file text exemption.
List<String> legacySeedNotes(ChangelogHistory root, ChangelogHistory docs) {
  String body(ChangelogHistory history) {
    final section = history.sections['Unreleased'];
    if (section == null) {
      throw const FormatException('Missing legacy Unreleased section.');
    }
    return section.substring(section.indexOf('\n') + 1);
  }

  final core = body(root);
  final site = body(docs);
  final bridgeLine = RegExp(
    r'^[*-] .*\bdefault WebGPU bridge assets\b',
    multiLine: true,
  );
  final normalized = core.replaceAllMapped(
    bridgeLine,
    (match) => match[0]!
        .replaceFirst(RegExp(r'^\* '), '- ')
        .replaceFirst('the default WebGPU', 'default WebGPU'),
  );
  if (normalized.trimRight() != site.trimRight()) {
    throw const FormatException(
      'Legacy Unreleased entries differ between changelogs.',
    );
  }
  if (core.trim().isEmpty) return [];
  final bullets = RegExp(r'^[*-] ', multiLine: true).allMatches(core).toList();
  if (bullets.isEmpty ||
      core.substring(0, bullets.first.start).trim().isNotEmpty) {
    throw const FormatException(
      'Legacy Unreleased section must start with a bullet.',
    );
  }
  return [
    for (final (index, bullet) in bullets.indexed)
      core
          .substring(
            bullet.end,
            index + 1 < bullets.length ? bullets[index + 1].start : core.length,
          )
          .replaceFirst(RegExp(r'(?:\r?\n[ \t]*)+$'), ''),
  ];
}

void main(List<String> arguments) {
  final environment = Platform.environment;
  try {
    final List<String> problems;
    if (arguments case ['--prep', final base, final candidate]) {
      problems = checkReleasePrepTrees(Directory.current, base, candidate);
    } else if (arguments.isNotEmpty) {
      throw const FormatException(
        'Usage: check_released_changelog_sections.dart [--prep BASE CANDIDATE]',
      );
    } else if (environment['GITHUB_EVENT_NAME'] != 'pull_request') {
      return;
    } else {
      final event = jsonDecode(
        File(environment['GITHUB_EVENT_PATH']!).readAsStringSync(),
      );
      problems = checkReleasedChangelogSections(
        Directory.current,
        event,
        repository: environment['GITHUB_REPOSITORY']!,
        log: stdout.writeln,
      );
    }
    if (problems.isNotEmpty) {
      stderr.writeln(problems.join('\n'));
      exitCode = 1;
    } else {
      stdout.writeln('Core changelog policy verified.');
    }
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on FileSystemException catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
