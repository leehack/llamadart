import 'dart:convert';
import 'dart:io';

import 'package:pub_semver/pub_semver.dart';

import '../testing/check_released_changelog_sections.dart';
import '../testing/release_metadata_readiness.dart';
import '../testing/verify_release_docs_versions.dart';
import 'collect_pr_changelog.dart';
import 'pr_changelog.dart';

const _repository = 'leehack/llamadart';
const _mainRef = 'refs/remotes/origin/main';
const _releasePrefix = 'refs/remotes/origin/release/';
const _recoveryDirectory = 'tool/release/recoveries';
const _usage =
    'Usage: dart tool/release/patch_branch.dart backport-guard --event\n'
    '   or: dart tool/release/patch_branch.dart parity --main REV '
    '[--line M.m --branch REV] [--require-closed-forward-ports]';

const _linePattern = r'(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)';
final _releaseRef = RegExp(r'^release/([0-9]+\.[0-9]+)\.x$');
final _prepPubspecs = {
  'pubspec.yaml': 'llamadart',
  for (final companion in companionSwiftPins)
    companion.pubspecPath: companion.package,
};

// Patch preps v0.20.1–v0.20.8 and the v0.21.0 prep changed these release
// files. Exact paths keep unrelated docs and code out of the exemption.
const _prepPaths = {
  ...releaseMetadataDocs,
  changelogArchive,
  'MIGRATION.md',
  'example/chat_app/pubspec.lock',
  'example/dartpad_gguf/README.md',
  'packages/llamadart_litert_lm_flutter/CHANGELOG.md',
  'packages/llamadart_litert_lm_flutter/pubspec.yaml',
  'packages/llamadart_llama_cpp_flutter/CHANGELOG.md',
  'packages/llamadart_llama_cpp_flutter/pubspec.yaml',
  'packages/llamadart_stable_diffusion_flutter/CHANGELOG.md',
  'packages/llamadart_stable_diffusion_flutter/pubspec.yaml',
  'packages/llamadart_validation/pubspec.lock',
  'pubspec.yaml',
  'website/docs/examples/dartpad-gguf.md',
  'website/docs/guides/image-generation.md',
  'website/docs/integrations/choosing-an-api.md',
  'website/docs/platforms/apple-setup.md',
  'website/examples/observability/pubspec.lock',
};
final _line = RegExp('^$_linePattern\$');
final _patchTag = RegExp(r'^v(' + _linePattern + r')\.[1-9][0-9]*$');
final _sha = RegExp(r'^[a-f0-9]{40}$');
final _prSuffix = RegExp(r' \(#([1-9][0-9]*)\)$');
final _backportLink = RegExp(
  r'^Backport of https://github\.com/' + _repository + r'/pull/([1-9][0-9]*)$',
);
final _cherryPick = RegExp(r'^\(cherry picked from commit ([a-f0-9]{40})\)$');
final _forwardLink = RegExp(
  r'^Forward-port: https://github\.com/' +
      _repository +
      r'/issues/([1-9][0-9]*)$',
);
final _recoveryPath = RegExp('^$_recoveryDirectory/([a-f0-9]{40})\\.json\$');

Future<void> main(List<String> args) async {
  try {
    stdout.write(await runPatchBranch(args));
  } on _UsageError catch (error) {
    stderr.writeln(error.message);
    exitCode = 64;
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on FileSystemException {
    stderr.writeln('Could not read the pull request event or Git repository.');
    exitCode = 1;
  } on ProcessException {
    stderr.writeln('Could not launch Git or the GitHub CLI.');
    exitCode = 1;
  }
}

/// Runs the release guards against local Git and an injectable GitHub lookup.
Future<String> runPatchBranch(
  List<String> args, {
  Directory? directory,
  Object? event,
  GithubLookup? lookup,
}) async {
  final git = _Git(directory ?? Directory.current);
  final github = lookup ?? recoveryGithubGet;
  if (args case ['backport-guard', '--event']) {
    return _guard(git, event ?? _readEvent(), github);
  }
  if (args.isEmpty || args.first != 'parity') throw const _UsageError();
  final options = _ParityOptions.parse(args.skip(1).toList());
  git.requireFullHistory();
  return _parity(git, options, github);
}

class _UsageError extends FormatException {
  const _UsageError() : super(_usage);
}

Object? _readEvent() {
  final path = Platform.environment['GITHUB_EVENT_PATH'];
  if (path == null || path.isEmpty) {
    throw const FormatException('GITHUB_EVENT_PATH is required.');
  }
  return jsonDecode(File(path).readAsStringSync());
}

Future<String> _guard(_Git git, Object? event, GithubLookup lookup) async {
  final request = event is Map ? event['pull_request'] : null;
  final baseInfo = request is Map ? request['base'] : null;
  if (request is! Map ||
      baseInfo is! Map ||
      baseInfo['ref'] is! String ||
      (baseInfo['ref'] as String).isEmpty) {
    throw const FormatException('The event has no pull request base ref.');
  }
  final base = baseInfo['ref'] as String;
  final line = _releaseRef.firstMatch(base)?[1];
  if (line == null) return '';
  if (baseInfo['repo'] case {
    'full_name': final String repository,
  } when repository == _repository) {
    final head = request['head'];
    if (head case {
      'ref': final String ref,
      'repo': {'full_name': final String headRepository},
    }) {
      final labels = request['labels'];
      if (isCoreReleasePrep(
        labels: [
          if (labels is List)
            for (final label in labels)
              if (label case {'name': final String name}) name,
        ],
        headRef: ref,
        headRepository: headRepository,
        repository: repository,
      )) {
        final baseSha = baseInfo['sha'];
        final headSha = head['sha'];
        if (baseSha is! String ||
            !_sha.hasMatch(baseSha) ||
            headSha is! String ||
            !_sha.hasMatch(headSha)) {
          throw const FormatException(
            'Core release prep requires full base and head SHAs.',
          );
        }
        git.requireFullHistory();
        final fork = git.text(['merge-base', baseSha, headSha]).trim();
        _requirePrepScope(git, fork, headSha, line);
        return 'Core release prep.\n';
      }
    }
  } else {
    throw const FormatException(
      'The pull request base repository is unexpected.',
    );
  }

  final body = request['body'];
  final metadata = _Metadata.parse(body is String ? body : '', required: true);
  if (metadata.issue case final String issue) {
    await _verifyIssue(lookup, issue, requiredState: 'open');
    return 'Linked forward-port issue #$issue verified.\n';
  }

  git.requireFullHistory();
  final history = _MainHistory(git, _mainRef);
  final source = metadata.source!;
  final number = metadata.pr!;
  history.requireSource(line, source);
  final mainCommit = readLandedReleaseCommit(git.directory, source);
  _requirePrNumber(mainCommit.subject, number, source);
  final authored = body as String;
  final section = parsePrChangelog(authored);
  _compareCore(section, parseLandedPrChangelog(mainCommit.body));
  if (!section.outsideLines.contains(metadata.backportLine) ||
      !section.outsideLines.contains(metadata.sourceLine)) {
    throw const FormatException(
      'Backport metadata must be standalone body lines.',
    );
  }
  final detail = await lookup(
    'repos/$_repository/pulls/$number',
    paginate: false,
  );
  if (detail case {
    'number': final int actual,
    'base': {'ref': 'main', 'repo': {'full_name': _repository}},
    'body': final String original,
  } when actual.toString() == number) {
    final stripped = _lines(authored)
        .where(
          (line) =>
              line != metadata.backportLine && line != metadata.sourceLine,
        )
        .join('\n');
    if (stripped.trimRight() == _lines(original).join('\n').trimRight()) {
      return 'Backport of #$number verified.\n';
    }
  }
  throw FormatException(
    'Copy the authored body of main PR #$number before adding the backport lines.',
  );
}

void _requirePrepScope(
  _Git git,
  String base,
  String head,
  String line, {
  String? tag,
}) {
  final paths = git
      .text([
        'diff',
        '--no-renames',
        '--ignore-submodules=none',
        '--name-only',
        '-z',
        base,
        head,
        '--',
      ])
      .split('\x00')
      .where((path) => path.isNotEmpty)
      .toList();
  final extra = paths.where((path) => !_prepPaths.contains(path));
  if (extra.isNotEmpty) {
    throw FormatException(
      'Core release prep changes unrelated files: ${extra.join(', ')}.',
    );
  }

  ReadinessFilePair read(String path) =>
      (base: git.releaseFile(base, path), head: git.releaseFile(head, path));
  final core = releasePubspecVersionChange(read('pubspec.yaml'), 'llamadart');
  if (core == null) {
    throw const FormatException(
      'Release prep may change only the version scalar in pubspec.yaml.',
    );
  }
  final previous = Version.parse(core.previous);
  final next = Version(previous.major, previous.minor, previous.patch + 1);
  if ('${previous.major}.${previous.minor}' != line ||
      core.next != next.toString() ||
      (tag != null && tag != 'v$next')) {
    throw FormatException(
      'Core pubspec.yaml must advance to the next patch on release/$line.x'
      '${tag == null ? '' : ' at tag $tag'}. Found ${core.previous} -> ${core.next}.',
    );
  }

  final versions = <String, ReleaseVersionChange>{'llamadart': core};
  for (final path in paths) {
    final package = _prepPubspecs[path];
    if (package == 'llamadart' || releaseMetadataLocks.containsKey(path)) {
      continue;
    }
    if (package == null) {
      git.requireRegularReleaseFile(base, path, allowMissing: true);
      git.requireRegularReleaseFile(head, path);
      continue;
    }
    final version = releasePubspecVersionChange(
      read(path),
      package,
      companionCore: next,
    );
    if (version == null) {
      throw FormatException(
        'Release prep may change only the version and raise the core floor within the release line in $path.',
      );
    }
    final companion = Version.parse(version.next);
    if (companion.major != next.major ||
        companion.minor != next.minor ||
        companion <= Version.parse(version.previous)) {
      throw FormatException(
        'Companion version $companion in $path must increase from '
        '${version.previous} within release/$line.x.',
      );
    }
    versions[package] = version;
  }
  for (final path in paths) {
    final corePath = releaseMetadataLocks[path];
    if (corePath == null) continue;
    final updates = <String, LockedReleaseVersion>{
      if (versions['llamadart'] case final core?)
        'llamadart': (version: core, relativePath: corePath),
      if (path == 'example/chat_app/pubspec.lock')
        for (final companion in companionSwiftPins)
          if (versions[companion.package] case final version?)
            companion.package: (
              version: version,
              relativePath: '../../${companion.root}',
            ),
    };
    if (!matchesReleaseLockVersions(read(path), updates)) {
      throw FormatException(
        'Release prep may change only matching local package versions in $path.',
      );
    }
  }
}

List<String> _lines(String text) => text.replaceAll('\r\n', '\n').split('\n');

class _Metadata {
  const _Metadata({
    this.pr,
    this.source,
    this.issue,
    this.backportLine,
    this.sourceLine,
  });

  final String? pr;
  final String? source;
  final String? issue;
  final String? backportLine;
  final String? sourceLine;

  static _Metadata parse(String body, {bool required = false}) {
    final lines = _lines(body);
    final backports = lines
        .where((line) => line.startsWith('Backport of'))
        .toList();
    final sources = lines
        .where((line) => line.startsWith('(cherry picked from commit'))
        .toList();
    final forwards = lines
        .where((line) => line.startsWith('Forward-port:'))
        .toList();
    if (forwards.isNotEmpty) {
      final issue = forwards.length == 1
          ? (_forwardLink.firstMatch(forwards.single)?[1])
          : null;
      if (issue == null || backports.isNotEmpty || sources.isNotEmpty) {
        throw const FormatException(
          'Provide one standalone Forward-port: link to a repository issue, without backport lines.',
        );
      }
      return _Metadata(issue: issue);
    }
    if (!required && backports.isEmpty && sources.isEmpty) {
      return const _Metadata();
    }
    if (backports.length > 1 || sources.length > 1) {
      throw const FormatException(
        'Provide exactly one Backport of line and one cherry picked from commit line.',
      );
    }
    final pr = backports.isEmpty
        ? null
        : _backportLink.firstMatch(backports.single)?[1];
    if (pr == null) {
      throw const FormatException(
        'Add a Backport of link to the main PR or a Forward-port: issue link.',
      );
    }
    final source = sources.isEmpty
        ? null
        : _cherryPick.firstMatch(sources.single)?[1];
    if (source == null) {
      throw const FormatException(
        'Add a (cherry picked from commit <full main SHA>) line.',
      );
    }
    return _Metadata(
      pr: pr,
      source: source,
      backportLine: backports.single,
      sourceLine: sources.single,
    );
  }
}

void _requirePrNumber(String subject, String number, String source) {
  if (_prSuffix.firstMatch(subject)?[1] != number) {
    throw FormatException('Main commit $source does not end with (#$number).');
  }
}

Future<void> _verifyIssue(
  GithubLookup lookup,
  String issue, {
  required String requiredState,
}) async {
  final detail = await lookup(
    'repos/$_repository/issues/$issue',
    paginate: false,
  );
  if (detail is! Map ||
      detail['number'].toString() != issue ||
      detail.containsKey('pull_request') ||
      (detail['state'] != 'open' && detail['state'] != 'closed')) {
    throw FormatException('Forward-port issue #$issue could not be verified.');
  }
  if (detail['state'] != requiredState) {
    throw FormatException(
      'Forward-port issue #$issue is ${detail['state']}; expected $requiredState.',
    );
  }
}

void _compareCore(PrChangelog backport, PrChangelog main) {
  List<String> core(PrChangelog section) => [
    for (final bullet in section.bullets)
      if (bullet.target == 'core') bullet.text,
  ];
  final left = core(backport);
  final right = core(main);
  if (backport.reason != main.reason ||
      left.length != right.length ||
      left.indexed.any((entry) => entry.$2 != right[entry.$1])) {
    throw const FormatException(
      'The core Changelog bullets or N/A reason differ from the main commit.',
    );
  }
}

class _ParityOptions {
  const _ParityOptions(this.main, this.line, this.branch, this.requireClosed);

  final String main;
  final String? line;
  final String? branch;
  final bool requireClosed;

  static _ParityOptions parse(List<String> args) {
    final values = <String, String>{};
    var requireClosed = false;
    for (var index = 0; index < args.length; index++) {
      final option = args[index];
      if (option == '--require-closed-forward-ports' && !requireClosed) {
        requireClosed = true;
      } else if (const {'--main', '--line', '--branch'}.contains(option) &&
          !values.containsKey(option) &&
          index + 1 < args.length &&
          args[index + 1].isNotEmpty &&
          !args[index + 1].startsWith('-')) {
        values[option] = args[++index];
      } else {
        throw const _UsageError();
      }
    }
    final main = values['--main'];
    final line = values['--line'];
    final branch = values['--branch'];
    if (main == null ||
        (line == null) != (branch == null) ||
        (line != null && !_line.hasMatch(line))) {
      throw const _UsageError();
    }
    return _ParityOptions(main, line, branch, requireClosed);
  }
}

class _MainHistory {
  _MainHistory(this.git, String revision) : tip = git.resolve(revision) {
    positions = {
      for (final (index, sha) in git.firstParents(tip).indexed) sha: index,
    };
  }

  final _Git git;
  final String tip;
  late final Map<String, int> positions;
  final _minorTags = <String, String>{};

  String minor(String line) => _minorTags.putIfAbsent(line, () {
    final String sha;
    try {
      sha = git.resolve('refs/tags/v$line.0');
    } on FormatException {
      throw FormatException('Cannot resolve minor tag v$line.0.');
    }
    if (!positions.containsKey(sha)) {
      throw FormatException(
        'v$line.0 is absent from the main first-parent chain.',
      );
    }
    return sha;
  });

  void requireSource(String line, String source) {
    final start = positions[minor(line)]!;
    final position = positions[source];
    if (position == null) {
      throw FormatException(
        '$source is absent from the main first-parent chain.',
      );
    }
    if (position >= start) {
      throw FormatException('$source is already included in v$line.0.');
    }
  }
}

Future<String> _parity(
  _Git git,
  _ParityOptions options,
  GithubLookup lookup,
) async {
  final main = _MainHistory(git, options.main);
  final tags = <String, Map<String, String>>{};
  final tips = <String, Map<String, String>>{};
  for (final tag in git.lines(['tag', '--list', 'v*'])) {
    final line = _patchTag.firstMatch(tag)?[1];
    if (line == null || (options.line != null && options.line != line)) {
      continue;
    }
    final sha = git.resolve('refs/tags/$tag');
    if (main.positions.containsKey(sha)) continue;
    (tags[line] ??= {})[tag] = sha;
    if (options.line == null) (tips[line] ??= {})[tag] = sha;
  }
  if (options.line case final String line) {
    tips[line] = {options.branch!: git.resolve(options.branch!)};
  } else {
    for (final ref in git.lines([
      'for-each-ref',
      '--format=%(refname)',
      _releasePrefix,
    ])) {
      final name = ref.substring('refs/remotes/origin/'.length);
      final line = _releaseRef.firstMatch(name)?[1];
      if (line != null) (tips[line] ??= {})[name] = git.resolve(ref);
    }
  }

  final output = StringBuffer();
  final failures = <String>[];
  for (final line in tips.keys.toList()..sort()) {
    final start = main.minor(line);
    final publishedTags = <String, List<String>>{};
    for (final tag in (tags[line] ?? const <String, String>{}).entries) {
      (publishedTags[tag.value] ??= []).add(tag.key);
    }
    final published = publishedTags.keys.toSet();
    Future<Map<String, String>>? mainPatches;
    final sources = <String, String>{};
    final patchIds = <String, String?>{};
    for (final tip in tips[line]!.entries) {
      final chain = git.firstParents(tip.value);
      final boundary = chain.indexOf(start);
      if (boundary < 0) {
        failures.add(
          '${tip.key}: v$line.0 is absent from the release first-parent chain.',
        );
        continue;
      }
      final window = chain.take(boundary).toList().reversed.toList();
      final recovered = _recoveries(git, line, start, window, published);
      final uncached = window.where((sha) => !patchIds.containsKey(sha));
      if (uncached.isNotEmpty) {
        final ids = await git.patchIds('$start..${tip.value}');
        for (final sha in uncached.toList()) {
          patchIds[sha] = ids[sha];
        }
      }
      output.writeln('${tip.key} (${tip.value}):');
      for (final sha in window) {
        final commit = readLandedReleaseCommit(git.directory, sha);
        try {
          if (commit.parents > 1) {
            throw const FormatException(
              'Patch release history cannot contain merge commits.',
            );
          }
          final String kind;
          if (publishedTags[sha] case final releaseTags?) {
            if (releaseTags.length != 1) {
              throw FormatException(
                'Conflicting patch tags for one prep: ${releaseTags.join(', ')}.',
              );
            }
            _requirePrepScope(git, '$sha^', sha, line, tag: releaseTags.single);
            kind = 'prep';
          } else if (recovered.containsKey(sha)) {
            kind = recovered[sha]!;
          } else {
            final metadata = _Metadata.parse(commit.rawBody);
            if (metadata.source case final String source) {
              main.requireSource(line, source);
              final original = readLandedReleaseCommit(git.directory, source);
              _requirePrNumber(original.subject, metadata.pr!, source);
              _compareCore(
                parseLandedPrChangelog(commit.body),
                parseLandedPrChangelog(original.body),
              );
              final originalId = sources[source] ??=
                  (await git.patchIds('$source^!'))[source] ?? '';
              kind = patchIds[sha] == originalId
                  ? 'backport exact'
                  : 'backport adapted';
            } else if (metadata.issue case final String issue) {
              if (options.requireClosed) {
                await _verifyIssue(lookup, issue, requiredState: 'closed');
              }
              kind = 'forward-port #$issue';
            } else {
              final patch = patchIds[sha];
              if (patch == null ||
                  !(await (mainPatches ??= git.patchIds(
                    '$start..${main.tip}',
                    firstParent: false,
                  ))).containsValue(patch)) {
                throw const FormatException('missing from main');
              }
              kind = 'equivalent';
            }
          }
          output.writeln('$sha $kind ${commit.subject}');
        } on FormatException catch (error) {
          failures.add('${tip.key}: $sha ${commit.subject}: ${error.message}');
        }
      }
    }
  }
  if (failures.isNotEmpty) throw FormatException(failures.toSet().join('\n'));
  output.writeln('Patch branch parity verified.');
  return output.toString();
}

Map<String, String> _recoveries(
  _Git git,
  String line,
  String start,
  List<String> window,
  Set<String> published,
) {
  if (window.isEmpty) return {};
  final positions = {for (final (index, sha) in window.indexed) sha: index};
  final recovered = <String, String>{};
  final candidates = git.lines([
    'rev-list',
    '--first-parent',
    '--full-history',
    '--reverse',
    '$start..${window.last}',
    '--',
    _recoveryDirectory,
  ]);
  for (final recovery in candidates) {
    final paths = git
        .text([
          'diff',
          '--name-only',
          '--no-renames',
          '-z',
          '$recovery^',
          recovery,
          '--',
          _recoveryDirectory,
        ])
        .split('\x00')
        .where((path) => path.isNotEmpty)
        .toList();
    if (paths.length != 1) continue;
    final path = paths.single;
    final prep = _recoveryPath.firstMatch(path)?[1];
    if (prep == null ||
        !positions.containsKey(prep) ||
        positions[prep]! >= positions[recovery]! ||
        published.contains(prep) ||
        recovered.containsKey(prep)) {
      continue;
    }
    final entry = git.text(['ls-tree', recovery, '--', path]);
    if (!entry.startsWith('100644 blob ') ||
        git.text(['ls-tree', '$recovery^', '--', path]).isNotEmpty) {
      continue;
    }
    final before = git.resolve('$prep^');
    final record = git.text(['show', '$recovery:$path']);
    final Object? data;
    try {
      data = jsonDecode(record);
    } on FormatException {
      continue;
    }
    if (data
        case {
          'version': final String version,
          'prep': final String recordedPrep,
          'before': final String recordedBefore,
          'pr': final int pr,
        }
        when _patchTag.firstMatch('v$version')?[1] == line &&
            recordedPrep == prep &&
            recordedBefore == before &&
            pr > 0 &&
            record ==
                '${jsonEncode({'version': version, 'prep': prep, 'before': before, 'pr': pr})}\n') {
      final versionBefore = coreVersionFromPubspec(
        git.text(['show', '$before:pubspec.yaml']),
      );
      final versionAfter = coreVersionFromPubspec(
        git.text(['show', '$prep:pubspec.yaml']),
      );
      if (versionBefore == null ||
          versionBefore == version ||
          versionAfter != version) {
        continue;
      }
      // The collector verifies GitHub landing provenance. Parity also needs
      // local proof that neither commit leaves unrelated changes on the line.
      final inverse = git.rawDiff(prep, before);
      if (inverse == git.rawDiff('$recovery^', recovery, excluding: path)) {
        recovered[prep] = 'recovered-prep';
        recovered[recovery] = 'recovery';
      }
    }
  }
  return recovered;
}

class _Git {
  const _Git(this.directory);

  final Directory directory;

  String text(List<String> arguments) {
    final result = Process.runSync(
      'git',
      arguments,
      workingDirectory: directory.path,
    );
    if (result.exitCode != 0) {
      throw FormatException(
        'Git ${arguments.first} failed (exit ${result.exitCode}).',
      );
    }
    return result.stdout as String;
  }

  List<String> lines(List<String> arguments) =>
      _lines(text(arguments)).where((line) => line.isNotEmpty).toList();

  String resolve(String revision) {
    final sha = text([
      'rev-parse',
      '--verify',
      '--end-of-options',
      '$revision^{commit}',
    ]).trim();
    if (!_sha.hasMatch(sha)) {
      throw const FormatException('Expected a full Git SHA.');
    }
    return sha;
  }

  void requireFullHistory() {
    if (text(['rev-parse', '--is-shallow-repository']).trim() != 'false') {
      throw const FormatException('Patch branch checks need full Git history.');
    }
    if (text(['rev-parse', '--show-prefix']).trim().isNotEmpty) {
      throw const FormatException(
        'Run the patch branch checks from the repository root.',
      );
    }
  }

  List<String> firstParents(String tip) =>
      lines(['rev-list', '--first-parent', tip]);

  void requireRegularReleaseFile(
    String revision,
    String path, {
    bool allowMissing = false,
  }) {
    final entry = text(['ls-tree', '-z', revision, '--', path]);
    if (allowMissing && entry.isEmpty) return;
    if (!entry.startsWith('100644 blob ') || !entry.endsWith('\t$path\x00')) {
      throw FormatException(
        'Release prep requires an existing regular file: $path.',
      );
    }
  }

  ReadinessFile releaseFile(String revision, String path) {
    requireRegularReleaseFile(revision, path);
    return (mode: '100644', contents: text(['show', '$revision:$path']));
  }

  String rawDiff(String from, String to, {String? excluding}) => text([
    'diff',
    '--raw',
    '--no-abbrev',
    '--no-renames',
    '-z',
    from,
    to,
    '--',
    if (excluding != null) ':(exclude,literal)$excluding',
  ]);

  Future<Map<String, String>> patchIds(
    String range, {
    bool firstParent = true,
  }) async {
    final log = await Process.start('git', [
      'log',
      if (firstParent) '--first-parent',
      '--no-merges',
      '--format=commit %H',
      '--no-decorate',
      '--no-notes',
      '--no-show-signature',
      '--no-color',
      '--no-ext-diff',
      '--no-textconv',
      '--no-renames',
      '--binary',
      '--full-index',
      '-p',
      range,
      '--',
    ], workingDirectory: directory.path);
    final patch = await Process.start('git', [
      'patch-id',
      '--stable',
    ], workingDirectory: directory.path);
    final output = patch.stdout.transform(utf8.decoder).join();
    await Future.wait([
      log.exitCode,
      patch.exitCode,
      log.stderr.drain<void>(),
      patch.stderr.drain<void>(),
      output,
      () async {
        await patch.stdin.addStream(log.stdout);
        await patch.stdin.close();
      }(),
    ]);
    if (await log.exitCode != 0 || await patch.exitCode != 0) {
      throw const FormatException('Git patch-id computation failed.');
    }
    return {
      for (final row in _lines(await output))
        if (row.split(' ') case [
          final id,
          final sha,
        ] when _sha.hasMatch(id) && _sha.hasMatch(sha))
          sha: id,
    };
  }
}
