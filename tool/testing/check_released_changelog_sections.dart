#!/usr/bin/env dart

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../release/pr_changelog.dart';
import '../release/pub_dev_api.dart';

export '../release/pr_changelog.dart' show isCoreReleasePrep;

const releasedChangelogs = <String>[
  'CHANGELOG.md',
  'website/docs/changelog/recent-releases.md',
];
const changelogArchive = 'doc/changelog_archive.md';
const changelogCutover = 'tool/release/changelog_pr_cutover.json';
const changelogSizeLimit = 256 * 1024;
const _recoveryDirectory = 'tool/release/recoveries';
const _ownerRepository = 'leehack/llamadart';

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

String? coreVersionFromPubspec(String text) =>
    _versionFromPubspec(text, 'llamadart');

String? _versionFromPubspec(String text, String package) {
  final version = RegExp(
    r'^version:[ \t]+([^\s]+)[ \t]*\r?$',
    multiLine: true,
  ).allMatches(text).toList();
  final names = RegExp(
    r'^name:[ \t]+([^\s]+)[ \t]*\r?$',
    multiLine: true,
  ).allMatches(text).toList();
  if (version.length == 1 && names.length == 1 && names.single[1] == package) {
    final value = version.single[1]!;
    if (coreReleaseVersion.hasMatch(value)) return value;
  }
  return null;
}

typedef _TreeEntry = ({String mode, String type, String id});
typedef _Change = ({
  String oldMode,
  String newMode,
  String oldId,
  String newId,
});
typedef GithubLookup =
    Future<Object?> Function(String endpoint, {required bool paginate});
typedef RecoveryTagLookup = Future<String> Function(List<String> refs);
typedef RecoveryPubGet = Future<PubDevResponse> Function(Uri uri);

class _Git {
  const _Git(this.root);
  final Directory root;

  String run(List<String> args) {
    final result = Process.runSync(
      'git',
      args,
      workingDirectory: root.path,
      stdoutEncoding: utf8,
    );
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

  Map<String, _Change> changes(String base, String head, {String? path}) {
    final result = Process.runSync(
      'git',
      [
        'diff',
        '--raw',
        '--no-abbrev',
        '--no-renames',
        '--no-ext-diff',
        '-z',
        base,
        head,
        '--',
        ?path,
      ],
      workingDirectory: root.path,
      stdoutEncoding: latin1,
    );
    if (result.exitCode != 0) throw StateError('Git tree comparison failed.');
    final rows = (result.stdout as String).split('\x00');
    return {
      for (var i = 0; i + 1 < rows.length; i += 2)
        rows[i + 1]: _change(rows[i]),
    };
  }

  _Change _change(String row) {
    final fields = row.substring(1).split(' ');
    return (
      oldMode: fields[0],
      newMode: fields[1],
      oldId: fields[2],
      newId: fields[3],
    );
  }

  List<String> firstParents(String sha) =>
      run(['rev-list', '--first-parent', sha]).trim().split('\n');

  List<String> parents(String sha) =>
      run(['show', '-s', '--format=%P', sha]).trim().split(' ');
}

typedef PublishedPatch = ({
  String version,
  String sha,
  Map<String, String> sections,
});

/// Reads release sections from patch tags forked at the previous minor tag.
List<PublishedPatch> readPublishedPatchSections(
  Directory root, {
  required String version,
  required String previousVersion,
  required String through,
}) {
  if (coreReleaseVersion.firstMatch(version)![3] != '0') return [];

  final previous = coreReleaseVersion.firstMatch(previousVersion)!;
  final line = '${previous[1]}.${previous[2]}';
  final git = _Git(root);
  final prefix = 'v$line.';
  final minorTag = '${prefix}0';
  final tags = git.run(['tag', '--list', '$prefix*']).trim().split('\n');
  if (!tags.contains(minorTag)) return [];
  final patchTags = tags.where((tag) {
    final patch = tag.substring(prefix.length);
    return RegExp(r'^[1-9][0-9]*$').hasMatch(patch);
  }).toList();
  if (patchTags.isEmpty) return [];

  String commit(String tag) =>
      git.run(['rev-parse', '--verify', 'refs/tags/$tag^{commit}']).trim();
  final minor = commit(minorTag);
  final chain = git.firstParents(through).toSet();
  if (!chain.contains(minor)) return [];

  // Git's version sort can be changed by local versionsort.suffix settings.
  BigInt patchNumber(String tag) => BigInt.parse(tag.substring(prefix.length));
  patchTags.sort((a, b) => patchNumber(b).compareTo(patchNumber(a)));
  final patches = <PublishedPatch>[];
  for (final tag in patchTags) {
    final sha = commit(tag);
    if (chain.contains(sha) ||
        git.firstParents(sha).firstWhere(chain.contains, orElse: () => '') !=
            minor) {
      continue;
    }
    final version = tag.substring(1);
    if (git.entry(sha, 'pubspec.yaml')?.mode != '100644' ||
        coreVersionFromPubspec(git.blob(sha, 'pubspec.yaml')) != version) {
      throw FormatException('Core tag $tag disagrees with its root pubspec.');
    }
    final sections = <String, String>{};
    for (final path in releasedChangelogs) {
      if (git.entry(sha, path)?.mode != '100644') {
        throw FormatException('$tag must contain a regular $path.');
      }
      final history = ChangelogHistory.parse(git.blob(sha, path));
      final section = history.sections.values.first;
      if (!section.startsWith('## $version\n') || !section.endsWith('\n')) {
        throw FormatException('$tag:$path must start with section $version.');
      }
      sections[path] = section;
    }
    patches.add((version: version, sha: sha, sections: sections));
  }
  return patches;
}

/// Determines the PR's release route and compares the real head with its merge
/// base. The event's immutable base SHA also anchors the activation boundary.
Future<List<String>> checkReleasedChangelogSections(
  Directory repoRoot,
  Map<String, Object?> event, {
  required String repository,
  void Function(String message)? log,
  GithubLookup lookup = recoveryGithubGet,
  RecoveryTagLookup tags = _ownerTags,
  RecoveryPubGet pub = _readRecoveryPub,
  String? proposedMerge,
}) async {
  final request = event['pull_request'];
  if (request is! Map) {
    throw StateError('The event has no pull request base SHA.');
  }
  final baseInfo = request['base'] as Map?;
  final base = baseInfo?['sha'];
  final baseRef = baseInfo?['ref'];
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
  final labels = _labels(request);
  final routedPrep = isCoreReleasePrep(
    labels: labels,
    headRef: ref,
    headRepository: headRepository,
    repository: repository,
  );
  final prep = routedPrep && _isCorePrepDiff(git, fork, head);
  log?.call('Core release prep: $prep');
  final records = _recoveryChanges(git.changes(fork, head));
  if (records.isNotEmpty) {
    if (repository != _ownerRepository ||
        headRepository != repository ||
        baseRef is! String ||
        fork != base ||
        routedPrep ||
        ref.startsWith('release/genkit_llamadart-') ||
        labels.contains('release-prep:genkit_llamadart')) {
      return [
        'Recovery requires an up-to-date ordinary same-repository PR onto the prep base.',
      ];
    }
    if (proposedMerge == null ||
        !_sha.hasMatch(proposedMerge) ||
        git.parents(proposedMerge).join(' ') != '$base $head') {
      return [
        'Recovery requires the tested merge with the event base and head as parents.',
      ];
    }
    try {
      final recovery = await _proveRecovery(
        git,
        base,
        proposedMerge,
        lookup,
        baseRef,
      );
      if (recovery == null ||
          git.run(['rev-parse', '$proposedMerge^{tree}']).trim() !=
              git.run(['rev-parse', '$head^{tree}']).trim()) {
        throw const FormatException(
          'The tested recovery tree differs from the PR head.',
        );
      }
      await _requireUnpublished(git, recovery, lookup, tags, pub);
      log?.call('Unpublished core prep recovery: ${recovery.prep}');
      return [];
    } on FormatException catch (error) {
      return [error.message];
    } on StateError catch (error) {
      return [error.message];
    }
  }
  return _checkTrees(git, fork, head, prep: prep, eventBase: base);
}

List<String> _labels(Map request) => [
  for (final label in request['labels'] as List? ?? const [])
    if (label is Map && label['name'] is String) label['name'] as String,
];

Map<String, _Change> _recoveryChanges(Map<String, _Change> changes) =>
    Map.fromEntries(
      changes.entries.where(
        (row) =>
            row.key == _recoveryDirectory ||
            row.key.startsWith('$_recoveryDirectory/'),
      ),
    );

typedef _Recovery = ({
  String version,
  String prep,
  String before,
  int pr,
  String previousTag,
  String previousRelease,
});

typedef RecoveredPrep = ({String prep, int pr, String recovery});

/// Verifies each introduction in the input window before collection can write.
Future<List<RecoveredPrep>> verifyPrepRecoveryIntroductions(
  Directory root,
  List<String> window,
  GithubLookup lookup, {
  String baseRef = 'main',
}) async {
  if (window.isEmpty) return [];
  final git = _Git(root);
  final recovered = <RecoveredPrep>[];
  final start = git.parents(window.first).first;
  final introductions = git
      .run([
        'rev-list',
        '--first-parent',
        '--full-history',
        '--reverse',
        '$start..${window.last}',
        '--',
        _recoveryDirectory,
      ])
      .trim()
      .split('\n');
  for (final commit in introductions.where((sha) => sha.isNotEmpty)) {
    final parents = git.parents(commit);
    final changes = git.changes(
      parents.first,
      commit,
      path: _recoveryDirectory,
    );
    if (changes.isEmpty) continue;
    if (parents.length != 1) {
      throw FormatException(
        'A recovery must be introduced by a single-parent $baseRef commit.',
      );
    }
    final recovery = (await _proveRecovery(
      git,
      parents.single,
      commit,
      lookup,
      baseRef,
    ))!;
    if (!window.contains(recovery.prep)) {
      throw const FormatException(
        'Recovery and failed prep must be in the same first-parent window.',
      );
    }
    recovered.add((prep: recovery.prep, pr: recovery.pr, recovery: commit));
  }
  return recovered;
}

Future<_Recovery?> _proveRecovery(
  _Git git,
  String base,
  String result,
  GithubLookup lookup,
  String baseRef,
) async {
  final changes = git.changes(base, result);
  final records = _recoveryChanges(changes);
  if (records.isEmpty) return null;
  if (records.length != 1 ||
      records.values.single.oldMode != '000000' ||
      records.values.single.newMode != '100644') {
    throw const FormatException(
      'Recovery must add one regular record and preserve all existing records.',
    );
  }
  final path = records.keys.single;
  final (version, prep, before, pr) = _readRecoveryRecord(git, result, path);
  if (baseRef != 'main') {
    final match = coreReleaseVersion.firstMatch(version)!;
    final line = '${match[1]}.${match[2]}';
    final patch = match[3];
    if (baseRef != 'release/$line.x' ||
        patch == '0' ||
        version != '$line.$patch') {
      throw FormatException(
        'Recovery version $version does not match the patch base $baseRef.',
      );
    }
  }
  for (final oldPath
      in git
          .run([
            'ls-tree',
            '-r',
            '--name-only',
            '-z',
            base,
            '--',
            _recoveryDirectory,
          ])
          .split('\x00')
          .where((path) => path.isNotEmpty)) {
    if (_readRecoveryRecord(git, base, oldPath).$1 == version) {
      throw FormatException(
        'Release $version already has a consumed recovery.',
      );
    }
  }
  await _proveRecoveryLanding(git, base, before, prep, pr, lookup, baseRef);
  final footprint = git.changes(prep, before);
  if (git.entry(before, changelogCutover)?.mode != '100644' ||
      footprint.containsKey(changelogCutover) ||
      _recoveryChanges(footprint).isNotEmpty ||
      !_isCorePrepDiff(git, before, prep)) {
    throw const FormatException(
      'Failed prep must bump core and preserve the cutover and recovery records.',
    );
  }
  if (changes.length != footprint.length + 1 ||
      footprint.entries.any((entry) => changes[entry.key] != entry.value)) {
    throw const FormatException(
      'Recovery tree must exactly invert the failed prep without overlapping later edits.',
    );
  }
  final previous = coreVersionFromPubspec(git.blob(before, 'pubspec.yaml'))!;
  final attempted = coreVersionFromPubspec(git.blob(prep, 'pubspec.yaml'));
  if (attempted != version || !_versionIncreases(previous, version)) {
    throw const FormatException(
      'Recovery marker must identify the attempted stable core version increase.',
    );
  }
  final tag = 'v$previous';
  final previousRelease = git.run([
    'rev-parse',
    '--verify',
    'refs/tags/$tag^{commit}',
  ]).trim();
  if (!git.firstParents(before).contains(previousRelease) ||
      git.entry(previousRelease, 'pubspec.yaml')?.mode != '100644' ||
      coreVersionFromPubspec(git.blob(previousRelease, 'pubspec.yaml')) !=
          previous) {
    throw FormatException(
      'Previous core tag $tag must match its package on the pre-prep first-parent chain.',
    );
  }
  _verifyPublishedHistory(git, previousRelease, before, previous);
  return (
    version: version,
    prep: prep,
    before: before,
    pr: pr,
    previousTag: tag,
    previousRelease: previousRelease,
  );
}

bool _versionIncreases(String previous, String next) {
  final old = coreReleaseVersion.firstMatch(previous)!;
  final current = coreReleaseVersion.firstMatch(next)!;
  for (var index = 1; index <= 3; index++) {
    final delta = BigInt.parse(
      current[index]!,
    ).compareTo(BigInt.parse(old[index]!));
    if (delta != 0) return delta > 0;
  }
  return false;
}

(String, String, String, int) _readRecoveryRecord(
  _Git git,
  String commit,
  String path,
) {
  if (git.entry(commit, path)?.mode != '100644') {
    throw const FormatException('Recovery records must be regular files.');
  }
  final source = git.blob(commit, path);
  if (jsonDecode(source)
      case {
        'version': final String version,
        'prep': final String prep,
        'before': final String before,
        'pr': final int pr,
      }
      when coreReleaseVersion.hasMatch(version) &&
          _sha.hasMatch(prep) &&
          _sha.hasMatch(before) &&
          pr > 0 &&
          path == '$_recoveryDirectory/$prep.json') {
    final canonical = jsonEncode({
      'version': version,
      'prep': prep,
      'before': before,
      'pr': pr,
    });
    if (source == '$canonical\n') return (version, prep, before, pr);
  }
  throw const FormatException(
    'Invalid canonical unpublished prep recovery record.',
  );
}

Future<void> _proveRecoveryLanding(
  _Git git,
  String base,
  String before,
  String prep,
  int pr,
  GithubLookup lookup,
  String baseRef,
) async {
  final detail = await lookup(
    'repos/$_ownerRepository/pulls/$pr',
    paginate: false,
  );
  if (detail
      case {
        'number': int number,
        'merged': true,
        'merge_commit_sha': String merged,
        'base': {
          'ref': final String pullBase,
          'repo': {'full_name': _ownerRepository},
        },
        'head': {
          'ref': final String ref,
          'repo': {'full_name': _ownerRepository},
        },
      }
      when number == pr &&
          merged == prep &&
          pullBase == baseRef &&
          !ref.startsWith('release/genkit_llamadart-')) {
    final byBranch = isCoreReleasePrep(
      labels: const [],
      headRef: ref,
      headRepository: _ownerRepository,
      repository: _ownerRepository,
    );
    if (!byBranch && !await _wasPrepLabeled(lookup, pr, prep)) {
      throw FormatException('PR #$pr was outside core prep routing at merge.');
    }
  } else {
    throw FormatException(
      'PR #$pr does not identify the same-repository $baseRef prep at $prep.',
    );
  }
  final branchRef = 'refs/heads/$baseRef';
  final pages = await _recoveryPages(
    lookup,
    'activity?ref=${Uri.encodeQueryComponent(branchRef)}'
    '&activity_type=pr_merge&per_page=100',
  );
  final matches = <int, String>{};
  for (final row in pages) {
    if (row
        case {
          'id': final int id,
          'ref': final String ref,
          'activity_type': 'pr_merge',
          'after': final String after,
          'before': final String previous,
        }
        when id > 0 &&
            ref == branchRef &&
            _sha.hasMatch(previous) &&
            _sha.hasMatch(after)) {
      if (after != prep) continue;
      if (matches.containsKey(id) && matches[id] != previous) {
        throw FormatException('Conflicting GitHub activity for prep $prep.');
      }
      matches[id] = previous;
    } else {
      throw FormatException('Malformed GitHub $baseRef merge activity.');
    }
  }
  if (matches.length != 1 ||
      matches.values.single != before ||
      git.parents(prep).join(' ') != before ||
      !git.firstParents(base).contains(prep)) {
    throw FormatException(
      'GitHub activity must prove one $baseRef commit from $before to $prep.',
    );
  }
}

Future<bool> _wasPrepLabeled(GithubLookup lookup, int pr, String prep) async {
  final timeline = await _recoveryPages(
    lookup,
    'issues/$pr/timeline?per_page=100',
  );
  var labeled = false;
  bool? atMerge;
  for (final event in timeline) {
    switch (event) {
      case {'event': 'merged', 'commit_id': String sha} when sha == prep:
        if (atMerge != null) {
          throw FormatException('Conflicting merged events for PR #$pr.');
        }
        atMerge = labeled;
      case {'event': 'labeled', 'label': {'name': 'release-prep'}}:
        labeled = true;
      case {'event': 'unlabeled', 'label': {'name': 'release-prep'}}:
        labeled = false;
    }
  }
  return atMerge == true;
}

Future<List<Map>> _recoveryPages(GithubLookup lookup, String endpoint) async {
  final response = await lookup(
    'repos/$_ownerRepository/$endpoint',
    paginate: true,
  );
  if (response is! List ||
      response.isEmpty ||
      response.any((page) => page is! List || page.any((row) => row is! Map))) {
    throw const FormatException(
      'Incomplete or malformed paginated GitHub response.',
    );
  }
  return [for (final page in response.cast<List>()) ...page.cast<Map>()];
}

void _verifyPublishedHistory(
  _Git git,
  String release,
  String before,
  String version,
) {
  ChangelogHistory read(String sha, String path) {
    if (git.entry(sha, path)?.mode != '100644') {
      throw FormatException(
        'Published history requires a regular file at $path.',
      );
    }
    return ChangelogHistory.parse(
      git.blob(sha, path),
      allowUnreleased:
          sha == release && version == '0.20.2' && path != changelogArchive,
    );
  }

  List<MapEntry<String, String>> numbered(ChangelogHistory history) => [
    for (final row in history.sections.entries)
      if (row.key != 'Unreleased') row,
  ];
  final oldRoot = numbered(read(release, releasedChangelogs.first));
  final oldArchive = numbered(read(release, changelogArchive));
  final root = numbered(read(before, releasedChangelogs.first));
  final archive = numbered(read(before, changelogArchive));
  final oldDocs = numbered(read(release, releasedChangelogs.last));
  final docs = numbered(read(before, releasedChangelogs.last));
  final parts = coreReleaseVersion.firstMatch(version)!;
  final retained = retainedReleaseHeadings(
    [...oldRoot, ...oldArchive].map((row) => '## ${row.key}'),
    major: int.parse(parts[1]!),
    minor: int.parse(parts[2]!),
  ).toSet();
  if (root.first.key != version ||
      docs.first.key != version ||
      root.length > oldRoot.length ||
      !_sameSections([...oldRoot, ...oldArchive], [...root, ...archive]) ||
      !_sameSections(
        oldDocs.where((row) => retained.contains('## ${row.key}')).toList(),
        docs,
      )) {
    throw const FormatException(
      'The pre-prep numbered changelogs must preserve the previous published history.',
    );
  }
}

Future<void> _requireUnpublished(
  _Git git,
  _Recovery recovery,
  GithubLookup lookup,
  RecoveryTagLookup tags,
  RecoveryPubGet pub,
) async {
  final remotePrevious = await _tagSha(tags, recovery.previousTag);
  if (remotePrevious != recovery.previousRelease) {
    throw FormatException(
      'Owner tag ${recovery.previousTag} disagrees with the previous release.',
    );
  }
  final before = _companionVersions(git, recovery.before);
  final prep = _companionVersions(git, recovery.prep);
  final released = _companionVersions(git, recovery.previousRelease);
  if (!prep.keys.toSet().containsAll({...before.keys, ...released.keys})) {
    throw const FormatException(
      'Cannot confirm every existing Apple companion in the prep tree.',
    );
  }
  final attempted = <String, String>{'llamadart': recovery.version, ...prep};
  final newTags = <String>{};
  for (final entry in attempted.entries) {
    final name = entry.key;
    final version = entry.value;
    final tag = name == 'llamadart' ? 'v$version' : '$name-v$version';
    final oldVersion = before[name] == version && released[name] == version;
    final sha = await _tagSha(tags, tag);
    if (sha != null && (!oldVersion || sha == recovery.prep)) {
      throw FormatException(
        'Owner tag $tag already exists at $sha; reconcile publication.',
      );
    }
    final response = await pub(pubDevVersionUri(name, version));
    if (response.status == HttpStatus.ok && oldVersion) {
      if (jsonDecode(response.body) case {
        'version': String actual,
        'pubspec': {'name': String package},
      } when actual == version && package == name) {
        continue;
      }
      throw FormatException('Malformed pub.dev response for $name $version.');
    }
    if (response.status != HttpStatus.notFound) {
      throw FormatException(
        'pub.dev $name $version returned HTTP ${response.status}; cannot establish absence.',
      );
    }
    if (jsonDecode(response.body) case {'error': {'code': 'NotFound'}}) {
      if (sha == null) newTags.add(tag);
    } else {
      throw FormatException('Malformed pub.dev 404 for $name $version.');
    }
  }
  for (final row in await _recoveryPages(lookup, 'releases?per_page=100')) {
    if (row['tag_name'] case final String tag when tag.isNotEmpty) {
      if (newTags.contains(tag)) {
        throw FormatException(
          'GitHub Release for $tag already exists; reconcile publication.',
        );
      }
    } else {
      throw const FormatException('Malformed GitHub Releases response.');
    }
  }
}

Map<String, String> _companionVersions(_Git git, String sha) {
  final paths = git
      .run(['ls-tree', '-r', '--name-only', '-z', sha, '--', 'packages'])
      .split('\x00');
  final names = <String>{};
  for (final path in paths) {
    final parts = path.split('/');
    if (parts.length == 3 &&
        parts[2] == 'pubspec.yaml' &&
        const {
          'llamadart_llama_cpp_flutter',
          'llamadart_litert_lm_flutter',
          'llamadart_stable_diffusion_flutter',
        }.contains(parts[1])) {
      names.add(parts[1]);
    }
    if (parts.length == 5 &&
        parts[2] == 'darwin' &&
        parts[1] == parts[3] &&
        parts[4] == 'Package.swift') {
      names.add(parts[1]);
    }
  }
  final found = <String, String>{};
  for (final name in names) {
    final pubspec = 'packages/$name/pubspec.yaml';
    final version = git.entry(sha, pubspec)?.mode == '100644'
        ? _versionFromPubspec(git.blob(sha, pubspec), name)
        : null;
    if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name) || version == null) {
      throw FormatException(
        'Cannot determine publication identity for $pubspec.',
      );
    }
    found[name] = version;
  }
  return found;
}

Future<PubDevResponse> _readRecoveryPub(Uri uri) =>
    pubDevGet(uri, followRedirects: false);

Future<String?> _tagSha(RecoveryTagLookup lookup, String tag) async {
  final ref = 'refs/tags/$tag';
  final peeled = '$ref^{}';
  final result = await lookup([ref, peeled]);
  final refs = <String, String>{};
  for (final line in const LineSplitter().convert(result)) {
    final fields = line.split('\t');
    if (fields.length != 2 ||
        !_sha.hasMatch(fields[0]) ||
        ![ref, peeled].contains(fields[1]) ||
        refs.containsKey(fields[1])) {
      throw FormatException('Malformed owner ref response for $tag.');
    }
    refs[fields[1]] = fields[0];
  }
  if (refs.containsKey(peeled) && !refs.containsKey(ref)) {
    throw FormatException('Incomplete owner ref response for $tag.');
  }
  return refs[peeled] ?? refs[ref];
}

Future<String> _ownerTags(List<String> refs) => _readProcess('git', [
  'ls-remote',
  '--tags',
  'https://github.com/$_ownerRepository.git',
  ...refs,
], 'Owner tag lookup');

Future<Object?> recoveryGithubGet(
  String endpoint, {
  required bool paginate,
}) async => jsonDecode(
  await _readProcess('gh', [
    'api',
    '--hostname',
    'github.com',
    '--method',
    'GET',
    if (paginate) ...['--paginate', '--slurp'],
    endpoint,
  ], 'GitHub lookup'),
);

Future<String> _readProcess(
  String executable,
  List<String> args,
  String description,
) async {
  final process = await Process.start(
    executable,
    args,
    environment: const {'GIT_TERMINAL_PROMPT': '0'},
  );
  final output = process.stdout.transform(utf8.decoder).join();
  final diagnostics = process.stderr.drain<void>();
  try {
    final status = await process.exitCode.timeout(const Duration(seconds: 90));
    await diagnostics;
    final body = await output;
    if (status != 0) {
      throw FormatException('$description failed (exit $status).');
    }
    return body;
  } on TimeoutException {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    await Future.wait([output, diagnostics]);
    throw FormatException('$description timed out.');
  }
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
  if (_recoveryChanges(git.changes(base, candidate)).isNotEmpty) {
    return ['Core prep must preserve all unpublished prep recovery records.'];
  }
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
  final List<PublishedPatch> patches;
  try {
    patches = readPublishedPatchSections(
      git.root,
      version: version,
      previousVersion: root.sections.keys.first,
      through: base,
    );
  } on FormatException catch (error) {
    return [error.message];
  } on StateError catch (error) {
    return [error.message.toString()];
  }
  final patchesByVersion = {for (final patch in patches) patch.version: patch};
  final expectedVersions = patchesByVersion.keys.join('\n');
  final imports = <String, List<MapEntry<String, String>>>{};
  for (final path in releasedChangelogs) {
    final sections = next[path]!.sections.entries
        .skip(1)
        .takeWhile((entry) => !old[path]!.sections.containsKey(entry.key))
        .toList();
    if (sections.map((entry) => entry.key).join('\n') != expectedVersions) {
      return [
        '$path must import exactly the published patch tags in descending order.',
      ];
    }
    for (final entry in sections) {
      if (entry.value != patchesByVersion[entry.key]?.sections[path]) {
        return ['$path section ${entry.key} must match v${entry.key} exactly.'];
      }
    }
    imports[path] = sections;
  }
  final [rootImports, docsImports] = [
    for (final path in releasedChangelogs) imports[path]!,
  ];
  final historical = [...root.sections.entries, ...archive.sections.entries];
  final candidate = [
    ...newRoot.sections.entries.skip(1 + rootImports.length),
    ...newArchive.sections.entries,
  ];
  final versions = historical.map((entry) => entry.key).toList();
  if (versions.toSet().length != versions.length ||
      versions.contains(version) ||
      !newRoot.sections.values.first.startsWith('## $version\n') ||
      !newDocs.sections.values.first.startsWith('## $version\n') ||
      newRoot.sections.length > root.sections.length + 1 + patches.length ||
      !_sameSections(historical, candidate) ||
      !newArchive.sections.keys.toSet().containsAll(archive.sections.keys)) {
    return [
      'Core prep must prepend the new release and preserve numbered history exactly.',
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
      rootImports.map((entry) => entry.value).join() +
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
  final docsKeys = newDocs.sections.keys.skip(1 + docsImports.length).toList();
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

Future<void> main(List<String> arguments) async {
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
      problems = await checkReleasedChangelogSections(
        Directory.current,
        event,
        repository: environment['GITHUB_REPOSITORY']!,
        proposedMerge: environment['GITHUB_SHA'],
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
  } on Exception {
    stderr.writeln('Could not complete unpublished prep recovery checks.');
    exitCode = 1;
  }
}
