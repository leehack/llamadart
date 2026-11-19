import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../testing/check_released_changelog_sections.dart';
import '../testing/verify_release_docs_versions.dart';
import 'pr_changelog.dart';

const _repository = 'leehack/llamadart';
const _cutoverPath = 'tool/release/changelog_pr_cutover.json';
const _nativePins = 'lib/src/hook/native_release_pins.dart';
const _bridgePins = 'tool/testing/check_webgpu_bridge_tag.dart';
const _manifestPin = 'lib/src/web_setup/web_bridge_setup.dart';
const _bridgeDefault = 'scripts/fetch_webgpu_bridge_assets.sh';
const _modulePin = 'example/chat_app/web/index.html';
const _root = 'CHANGELOG.md';
const _docs = 'website/docs/changelog/recent-releases.md';
const _archive = 'doc/changelog_archive.md';
const _sizeLimit = 256 * 1024;

final _version = RegExp(
  r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)'
  r'(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$',
);
final _sha = RegExp(r'^[a-f0-9]{40}$');
final _prNumber = RegExp(r'\(#([1-9][0-9]*)\)$');
final _reverts = RegExp(
  r'^(?:This reverts commit ([a-f0-9]{40})\.|Reverts-Commit: ([a-f0-9]{40}))$',
);
final _githubRevert = RegExp(
  r'^Reverts ([A-Za-z0-9-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*)$',
);
final _trailerContinuation = RegExp(r'^[ \t\r\v\f]');
final _docsCut = RegExp(r'^docs: cut version (\S+)$');
final _releaseHeading = RegExp(r'^##[ \t]+([^\r\n]+)', multiLine: true);
final _bridgeClaim = RegExp(
  r'^(?:Aligned (?:the )?default WebGPU bridge assets to|'
  r'Keep (?:the )?default WebGPU bridge assets at) `(v\d+\.\d+\.\d+)`',
);

typedef GithubLookup =
    Future<Object?> Function(String endpoint, {required bool paginate});

Future<void> main(List<String> args) async {
  try {
    stdout.write(await runPrChangelogCollector(args));
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
  } on FileSystemException {
    stderr.writeln('Could not read or update the changelog files.');
    exitCode = 1;
  } on ProcessException {
    stderr.writeln('Could not launch Git or the GitHub CLI.');
    exitCode = 1;
  }
}

/// Collect and optionally write a draft. The lookup implements read-only REST
/// GET, returning one decoded object or a list of decoded pages.
Future<String> runPrChangelogCollector(
  List<String> args, {
  Directory? directory,
  GithubLookup? lookup,
}) async {
  final options = _Options.parse(args);
  final git = _Git(directory ?? Directory.current);
  if (git.text(['rev-parse', '--is-shallow-repository']).trim() != 'false') {
    throw const FormatException('The collector needs full Git history.');
  }
  if (git.text(['rev-parse', '--show-prefix']).trim().isNotEmpty) {
    throw const FormatException('Run the collector from the repository root.');
  }
  final through = git.resolve(options.through);
  final chain = git
      .text(['rev-list', '--first-parent', '--reverse', through])
      .trim()
      .split('\n');
  final start = _releaseTag(git, options.from);
  final startIndex = chain.indexOf(start);
  if (startIndex < 0 || options.from == 'v${options.version}') {
    throw const FormatException(
      '--from must be a previous first-parent release.',
    );
  }

  final marker = jsonDecode(git.blob(through, _cutoverPath));
  if (marker case {
    'tag': final String tag,
    'commit': final String cutover,
  } when _sha.hasMatch(cutover)) {
    final markerIndex = chain.indexOf(cutover);
    final tagIndex = chain.indexOf(_releaseTag(git, tag));
    if (tagIndex < 0 ||
        startIndex < tagIndex ||
        markerIndex < tagIndex ||
        markerIndex + 1 >= chain.length) {
      throw const FormatException('Invalid first-parent cutover boundary.');
    }
    final activation = chain[markerIndex + 1];
    final activationMarker = jsonDecode(git.blob(activation, _cutoverPath));
    final activationCommit = git.commit(activation);
    if (activationMarker is! Map ||
        activationMarker['commit'] != cutover ||
        activationMarker['tag'] != tag ||
        activationCommit.parents != 1 ||
        !_prNumber.hasMatch(activationCommit.subject) ||
        _readChangelog(activationCommit.body)?.reason == null) {
      throw const FormatException(
        'Cutover marker must be introduced by its N/A activation commit.',
      );
    }
    if (git.hasBlob(cutover, _cutoverPath)) {
      throw const FormatException('The cutover marker predates activation.');
    }
    final legacy = startIndex <= markerIndex
        ? _legacySeed(git, cutover)
        : <String>[];
    final first = startIndex <= markerIndex ? markerIndex : startIndex;
    final window = chain.skip(first + 1).toList();
    final collector = _Collector(git, chain, window, lookup ?? _githubGet);
    final entries = await collector.collect();
    final root = _Changelog.parse(git.blob(through, _root));
    final docs = _Changelog.parse(git.blob(through, _docs));
    final archive = _Changelog.parse(git.blob(through, _archive));
    if (root.sections.keys.first != options.from.substring(1)) {
      throw const FormatException(
        '--from does not match the latest pinned changelog heading.',
      );
    }
    final canonical = [
      ...legacy,
      for (final entry in entries)
        if (entry.disposition == 'included')
          for (final bullet in entry.section!.bullets)
            if (bullet.target == 'core') bullet.text,
    ];
    final pins = _Pins.read(git, through);
    final oldBridge = _bridgeTag(git.blob(start, _bridgeDefault));
    final generated = _render(
      options,
      root,
      docs,
      archive,
      canonical,
      pins,
      oldBridge,
    );

    var result = generated;
    if (options.curated case final path?) {
      final reviewed = parsePrChangelog(
        '## Changelog\n${File(path).readAsStringSync()}',
      );
      if (reviewed.bullets.any((bullet) => bullet.target != 'core')) {
        throw const FormatException('Curated notes must use core bullets.');
      }
      result = _render(
        options,
        root,
        docs,
        archive,
        reviewed.bullets.map((bullet) => bullet.text).toList(),
        pins,
        oldBridge,
      );
    }

    if (options.write) {
      final gitDir = git.text(['rev-parse', '--absolute-git-dir']).trim();
      final lock = File('$gitDir/cps-changelog-write.lock');
      try {
        lock.createSync(exclusive: true);
      } on FileSystemException {
        throw const FormatException(
          'Could not acquire the changelog write lock.',
        );
      }
      try {
        _writeChanges(git, through, result.files, generated.files);
      } finally {
        lock.deleteSync();
      }
    }
    return [
      'From: ${options.from}@$start',
      'Through: $through',
      for (final text in legacy)
        jsonEncode({
          'sha': cutover,
          'source': 'legacy-seed',
          'target': 'core',
          'text': text,
        }),
      for (final entry in entries) jsonEncode(entry.toJson()),
      ...collector.warnings,
      '',
      result.draft,
    ].join('\n');
  }
  throw const FormatException(
    'Invalid cutover marker. Expected a full commit SHA and core release tag.',
  );
}

class _Options {
  const _Options(
    this.version,
    this.from,
    this.through,
    this.write,
    this.curated,
  );

  final String version;
  final String from;
  final String through;
  final bool write;
  final String? curated;

  static _Options parse(List<String> args) {
    const usage =
        'Usage: collect_pr_changelog.dart --version V --from vPREVIOUS '
        '--through BASE [--write] [--curated FILE]';
    final values = <String, String>{};
    var write = false;
    for (var i = 0; i < args.length; i++) {
      final flag = args[i];
      if (flag == '--write' && !write) {
        write = true;
      } else if (const {
            '--version',
            '--from',
            '--through',
            '--curated',
          }.contains(flag) &&
          !values.containsKey(flag) &&
          i + 1 < args.length &&
          !args[i + 1].startsWith('--')) {
        values[flag] = args[++i];
      } else {
        throw const FormatException(usage);
      }
    }
    if (values case {
      '--version': final String version,
      '--from': final String from,
      '--through': final String through,
    } when _version.hasMatch(version)) {
      return _Options(version, from, through, write, values['--curated']);
    }
    throw const FormatException(usage);
  }
}

class _Git {
  _Git(this.directory);

  final Directory directory;

  ProcessResult run(List<String> args, {bool bytes = false}) => Process.runSync(
    'git',
    args,
    workingDirectory: directory.path,
    stdoutEncoding: bytes ? null : utf8,
  );

  String text(List<String> args, {String? error}) {
    final result = run(args);
    if (result.exitCode != 0) {
      throw FormatException(error ?? 'Git ${args.first} failed.');
    }
    return result.stdout as String;
  }

  String resolve(String revision) {
    final sha = text([
      'rev-parse',
      '--verify',
      '--end-of-options',
      '$revision^{commit}',
    ], error: 'Cannot resolve the requested commit or tag.').trim();
    if (!_sha.hasMatch(sha)) {
      throw const FormatException('Expected a full Git SHA.');
    }
    return sha;
  }

  String blob(String sha, String path) =>
      text(['show', '$sha:$path'], error: 'Missing $path at $sha.');

  bool hasBlob(String sha, String path) =>
      run(['cat-file', '-e', '$sha:$path']).exitCode == 0;

  ({
    String subject,
    String body,
    String trailers,
    bool mixedTrailers,
    int parents,
  })
  commit(String sha) {
    // The folded records mark Git's parsed key/value pairs, including the
    // same trailers exposed by interpret-trailers --parse (which unfolds).
    final fields = text([
      'show',
      '-s',
      '--format=%s%x00%P%x00%B%x00%(trailers:only)%x00%(trailers)%x00'
          '%(trailers:separator=%x1e,key_value_separator=%x1f)%x00',
      sha,
    ]).split('\x00');
    if (fields.length != 7) {
      throw FormatException('Cannot read commit $sha.');
    }
    final (message, mixedTrailers) = fields[3].isEmpty
        ? (fields[2], false)
        : _stripTrailers(sha, fields[2], fields[4], fields[5]);
    return (
      subject: fields[0],
      body: landedPrBody(message),
      trailers: fields[3],
      mixedTrailers: mixedTrailers,
      parents: fields[1].isEmpty ? 0 : fields[1].split(' ').length,
    );
  }

  (String, bool) _stripTrailers(
    String sha,
    String message,
    String block,
    String records,
  ) {
    Never unaligned() =>
        throw FormatException('Cannot safely separate Git trailers at $sha.');

    final start = message.lastIndexOf('\n$block') + 1;
    if (block.isEmpty ||
        start == 0 ||
        message.substring(start + block.length).trim().isNotEmpty ||
        block.contains('\x1e') ||
        block.contains('\x1f')) {
      unaligned();
    }
    final raw = block.replaceFirst(RegExp(r'\n$'), '').split('\n');
    final retained = <String>[];
    var index = 0;
    for (final record in records.split('\x1e')) {
      if (index >= raw.length) unaligned();
      final line = raw[index++];
      if (record.contains('\x1f')) {
        if (_trailerContinuation.hasMatch(line)) unaligned();
        while (index < raw.length &&
            _trailerContinuation.hasMatch(raw[index])) {
          index++;
        }
      } else {
        if (line.trimRight() != record.trimRight()) unaligned();
        retained.add(line);
      }
    }
    if (index != raw.length) unaligned();
    return (
      message.substring(0, start) + retained.join('\n'),
      retained.isNotEmpty,
    );
  }

  bool inverseOf(String sha, String target) {
    String? diff(String from, String to) {
      final result = run([
        'diff',
        '--binary',
        '--full-index',
        '--no-renames',
        '--no-ext-diff',
        '--no-textconv',
        '--no-color',
        from,
        to,
        '--',
      ], bytes: true);
      final data = result.stdout as List<int>;
      return result.exitCode == 0 && data.isNotEmpty
          ? base64Encode(data)
          : null;
    }

    final inverse = diff(target, '$target^');
    return inverse != null && inverse == diff('$sha^', sha);
  }
}

String _releaseTag(_Git git, String tag) {
  if (!tag.startsWith('v') || !_version.hasMatch(tag.substring(1))) {
    throw const FormatException(
      '--from and cutover must use a canonical stable core tag.',
    );
  }
  final sha = git.resolve('refs/tags/$tag');
  final pubspec = git.blob(sha, 'pubspec.yaml');
  final releaseVersion = _singleMatch(
    pubspec,
    RegExp(r'^version:[ \t]*(\S+)[ \t]*\r?$', multiLine: true),
    'root pubspec version',
  );
  if (releaseVersion != tag.substring(1) ||
      !RegExp(
        r'^name:[ \t]+llamadart[ \t]*\r?$',
        multiLine: true,
      ).hasMatch(pubspec)) {
    throw FormatException('Core tag $tag disagrees with its root pubspec.');
  }
  return sha;
}

PrChangelog? _readChangelog(String body) {
  try {
    return parsePrChangelog(body);
  } on FormatException {
    return null;
  }
}

List<String> _legacySeed(_Git git, String sha) {
  final root = _Changelog.parse(git.blob(sha, _root), allowUnreleased: true);
  final docs = _Changelog.parse(git.blob(sha, _docs), allowUnreleased: true);
  final rootPending = root.sections['Unreleased'];
  final docsPending = docs.sections['Unreleased'];
  if (rootPending == null || docsPending == null) {
    throw const FormatException('Missing legacy Unreleased section.');
  }
  final body = _sectionBody(rootPending);
  if (docsChangelogDriftProblems(
    {'Unreleased': body},
    {'Unreleased': _sectionBody(docsPending)},
  ).isNotEmpty) {
    throw const FormatException(
      'Legacy Unreleased entries differ between changelogs.',
    );
  }
  if (body.trim().isEmpty) return [];
  final bullets = RegExp(r'^[*-] ', multiLine: true).allMatches(body).toList();
  if (bullets.isEmpty ||
      body.substring(0, bullets.first.start).trim().isNotEmpty) {
    throw const FormatException(
      'Legacy Unreleased section must start with a bullet.',
    );
  }
  return [
    for (final (index, bullet) in bullets.indexed)
      body
          .substring(
            bullet.end,
            index + 1 < bullets.length ? bullets[index + 1].start : body.length,
          )
          .replaceFirst(RegExp(r'(?:\r?\n[ \t]*)+$'), ''),
  ];
}

class _Entry {
  _Entry(
    this.sha,
    this.pr,
    this.source,
    this.disposition, {
    this.section,
    this.targets = const [],
  });

  final String sha;
  final int? pr;
  final String source;
  String disposition;
  final PrChangelog? section;
  final List<String> targets;
  late final String? sectionSha256 = switch (section) {
    final section? =>
      sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'reason': section.reason,
                'bullets': _bulletRows(section),
              }),
            ),
          )
          .toString(),
    null => null,
  };

  Map<String, Object?> toJson() {
    final section = this.section;
    return {
      'sha': sha,
      'pr': pr,
      'source': source,
      'disposition': disposition,
      if (section != null) ...{
        'sectionSha256': sectionSha256,
        if (section.reason != null) 'reason': section.reason,
        if (section.bullets.isNotEmpty) 'bullets': _bulletRows(section),
      },
      if (targets.isNotEmpty) 'reverts': targets,
    };
  }

  List<Map<String, String>> _bulletRows(PrChangelog section) => [
    for (final bullet in section.bullets)
      {'target': bullet.target, 'text': bullet.text},
  ];
}

typedef _Pull = ({int number, String mergeSha});

_Pull? _mergedMainPull(Object? data) {
  if (data
      case {
        'number': final int number,
        'merge_commit_sha': final String sha,
        'merged_at': final String mergedAt,
        'base': {'ref': 'main', 'repo': {'full_name': final String repository}},
      }
      when number > 0 &&
          _sha.hasMatch(sha) &&
          mergedAt.isNotEmpty &&
          repository.toLowerCase() == _repository) {
    return (number: number, mergeSha: sha);
  }
  return null;
}

class _Collector {
  _Collector(this.git, this.chain, this.window, this.lookup)
    : positions = Map.fromEntries(
        chain.indexed.map((entry) => MapEntry(entry.$2, entry.$1)),
      );

  final _Git git;
  final List<String> chain;
  final List<String> window;
  final GithubLookup lookup;
  final Map<String, int> positions;
  final warnings = <String>[];
  final _associations = <String, Future<Set<_Pull>>>{};
  final _details = <int, Future<Object?>>{};

  Future<List<_Entry>> collect() async {
    final rows = <_Entry>[];
    final seen = <int, _Entry>{};
    for (final sha in window) {
      final commit = git.commit(sha);
      final number = int.tryParse(
        _prNumber.firstMatch(commit.subject)?[1] ?? '',
      );
      if (commit.mixedTrailers) {
        _warn(sha, number, 'kept non-trailer lines in the Git trailer block.');
      }
      if (commit.parents != 1) {
        _warn(sha, number, 'unsupported main commit shape.');
        rows.add(_Entry(sha, number, 'git', 'unresolved'));
        continue;
      }
      final landed = _readChangelog(commit.body);
      if (landed == null &&
          number == null &&
          _generatedDocs(sha, commit.subject)) {
        rows.add(_Entry(sha, null, 'git', 'generated-docs'));
        continue;
      }
      if (landed != null && number != null) {
        rows.add(_row(sha, number, 'git', landed, commit.trailers, seen));
      } else {
        final fallback = await _fallback(sha, number, landed);
        if (fallback != null) {
          rows.add(
            _row(
              sha,
              fallback.$1,
              landed == null ? 'api' : 'git',
              fallback.$2,
              landed == null ? '' : commit.trailers,
              seen,
            ),
          );
        } else {
          rows.add(_Entry(sha, number, 'api', 'unresolved'));
        }
      }
    }
    _applyReverts(rows);
    return rows;
  }

  _Entry _row(
    String sha,
    int number,
    String source,
    PrChangelog section,
    String trailers,
    Map<int, _Entry> seen,
  ) {
    final first = seen[number];
    final disposition = first != null
        ? 'duplicate-pr'
        : section.reason != null
        ? 'n/a'
        : 'included';
    final targets = {
      for (final line in [
        ...section.outsideLines,
        ...const LineSplitter().convert(trailers),
      ])
        if (_reverts.firstMatch(line) case final marker?)
          (marker[1] ?? marker[2])!,
    }.toList();
    for (final line in section.outsideLines) {
      if (_githubRevert.firstMatch(line) case final marker?) {
        _warn(sha, number, 'GitHub revert of ${marker[1]} needs review.');
      }
    }
    final row = _Entry(
      sha,
      number,
      source,
      disposition,
      section: section,
      targets: targets,
    );
    if (first == null) {
      seen[number] = row;
    } else if (first.sectionSha256 != row.sectionSha256) {
      _warn(
        sha,
        number,
        'Changelog section differs from ${first.sha}. Kept the first section.',
      );
    }
    return row;
  }

  void _applyReverts(List<_Entry> rows) {
    final bySha = {for (final row in rows) row.sha: row};
    final keepForReview = <String>{};
    for (final row in rows.reversed) {
      if (row.targets.isEmpty ||
          row.disposition == 'duplicate-pr' ||
          row.disposition == 'exact-revert' ||
          row.disposition == 'reverted') {
        continue;
      }
      final target = row.targets.length == 1 ? bySha[row.targets.single] : null;
      if (target != null &&
          positions[target.sha]! < positions[row.sha]! &&
          row.source == 'git' &&
          row.section!.bullets.length <= 1 &&
          target.source == 'git' &&
          !keepForReview.contains(row.sha) &&
          !keepForReview.contains(target.sha) &&
          target.pr != null &&
          target.section != null &&
          target.disposition != 'duplicate-pr' &&
          git.inverseOf(row.sha, target.sha)) {
        target.disposition = 'reverted';
        row.disposition = 'exact-revert';
      } else {
        keepForReview.addAll([row.sha, ...row.targets]);
        final targetLabel = target?.pr == null
            ? ''
            : ' (target #${target!.pr})';
        _warn(
          row.sha,
          row.pr,
          'revert of ${row.targets.join(', ')}$targetLabel needs review. Kept its notes.',
        );
      }
    }
  }

  bool _generatedDocs(String sha, String subject) {
    final version = _docsCut.firstMatch(subject)?[1];
    if (version == null) return false;
    final String tagCommit;
    try {
      tagCommit = _releaseTag(git, 'v$version');
    } on FormatException {
      return false;
    }
    final tagIndex = positions[tagCommit];
    if (tagIndex == null || tagIndex >= positions[sha]!) return false;
    final paths = git
        .text([
          'diff-tree',
          '--no-commit-id',
          '--name-only',
          '--no-renames',
          '-r',
          '-z',
          '$sha^',
          sha,
        ])
        .split('\x00')
        .where((path) => path.isNotEmpty)
        .toList();
    return paths.isNotEmpty &&
        paths.every(
          (path) =>
              path == 'website/versions.json' ||
              path.startsWith('website/versioned_docs/') ||
              path.startsWith('website/versioned_sidebars/'),
        );
  }

  Future<(int, PrChangelog)?> _fallback(
    String sha,
    int? subjectNumber,
    PrChangelog? landed,
  ) async {
    final candidates = await _associated(sha, subjectNumber);
    final matches = <_Pull>[];
    for (final candidate in candidates) {
      final exact =
          candidate.mergeSha == sha &&
          (subjectNumber == null || subjectNumber == candidate.number);
      if (exact || await _sameRebaseBatch(sha, candidate)) {
        matches.add(candidate);
      }
    }
    if (matches.length > 1) {
      final numbers = matches.map((pull) => '#${pull.number}').join(', ');
      throw FormatException(
        '${_location(sha, subjectNumber)}: ambiguous merged main PR associations ($numbers).',
      );
    }
    if (matches.isEmpty) {
      if (candidates.any((pull) => pull.number == subjectNumber)) {
        throw FormatException(
          '${_location(sha, subjectNumber)}: PR association has the wrong merge commit.',
        );
      }
      _warn(sha, subjectNumber, 'no matching merged main PR association.');
      return null;
    }
    final pull = matches.single;
    final detail = await _details.putIfAbsent(
      pull.number,
      () => _get('pulls/${pull.number}', sha, pull.number),
    );
    if (_mergedMainPull(detail) != pull) {
      throw FormatException(
        '${_location(sha, pull.number)}: PR detail conflicts with the commit association.',
      );
    }
    if (landed != null) return (pull.number, landed);
    final body = detail is Map ? detail['body'] : null;
    final section = body is String ? _readChangelog(body) : null;
    if (section == null) {
      _warn(sha, pull.number, 'associated PR has no valid Changelog section.');
      return null;
    }
    return (pull.number, section);
  }

  Future<bool> _sameRebaseBatch(String sha, _Pull candidate) async {
    final current = positions[sha]!;
    final end = positions[candidate.mergeSha];
    if (end == null || end < current) return false;
    // The final rebase-merged SHA alone cannot distinguish an envelope from
    // an unrelated squash. Require the same association on a second commit.
    final other = end == current ? current - 1 : end;
    if (other < 0 || other < positions[window.first]!) return false;
    return (await _associated(
      chain[other],
      candidate.number,
    )).contains(candidate);
  }

  Future<Set<_Pull>> _associated(
    String sha,
    int? number,
  ) => _associations.putIfAbsent(sha, () async {
    final pages = await _get('commits/$sha/pulls', sha, number, paginate: true);
    if (pages is! List || pages.isEmpty || pages.any((page) => page is! List)) {
      throw FormatException(
        '${_location(sha, number)}: malformed GitHub association pages.',
      );
    }
    return {
      for (final page in pages.cast<List>())
        for (final item in page) ?_mergedMainPull(item),
    };
  });

  Future<Object?> _get(
    String endpoint,
    String sha,
    int? number, {
    bool paginate = false,
  }) async {
    try {
      return await lookup('repos/$_repository/$endpoint', paginate: paginate);
    } on Exception {
      throw FormatException('${_location(sha, number)}: GitHub lookup failed.');
    }
  }

  void _warn(String sha, int? number, String problem) {
    warnings.add('WARNING ${_location(sha, number)}: $problem');
  }
}

String _location(String sha, int? number) =>
    number == null ? sha : '$sha (#$number)';

Future<Object?> _githubGet(String endpoint, {required bool paginate}) async {
  final result = await Process.run('gh', [
    'api',
    '--hostname',
    'github.com',
    '--method',
    'GET',
    if (paginate) ...['--paginate', '--slurp'],
    endpoint,
  ]);
  if (result.exitCode != 0) {
    throw const FormatException('GitHub request failed.');
  }
  return jsonDecode(result.stdout as String);
}

class _Changelog {
  const _Changelog(this.preamble, this.sections);

  final String preamble;
  final Map<String, String> sections;

  static _Changelog parse(String source, {bool allowUnreleased = false}) {
    final heads = _releaseHeading.allMatches(source).toList();
    if (heads.isEmpty) {
      throw const FormatException('Changelog has no release headings.');
    }
    final sections = <String, String>{};
    for (final (index, head) in heads.indexed) {
      final version = head[1]!.trim();
      if (version == 'Unreleased'
          ? !allowUnreleased
          : !_version.hasMatch(version)) {
        throw const FormatException('Unexpected changelog heading.');
      }
      if (sections.containsKey(version)) {
        throw const FormatException('Duplicate changelog heading.');
      }
      sections[version] = source.substring(
        head.start,
        index + 1 < heads.length ? heads[index + 1].start : source.length,
      );
    }
    return _Changelog(source.substring(0, heads.first.start), sections);
  }
}

String _singleMatch(String source, RegExp pattern, String label) {
  final matches = pattern.allMatches(source).toList();
  if (matches.length != 1) throw FormatException('Expected one $label.');
  return matches.single[1]!;
}

String _bridgeTag(String source) => _singleMatch(
  source,
  RegExp(
    r'^ASSETS_TAG="\$\{WEBGPU_BRIDGE_ASSETS_TAG:-(v\d+\.\d+\.\d+)\}"\r?$',
    multiLine: true,
  ),
  'default WebGPU asset pin',
);

class _Pins {
  const _Pins(this.bridge, this.baseline);

  final String bridge;
  final String baseline;

  static _Pins read(_Git git, String sha) {
    final native = git.blob(sha, _nativePins);
    final bridge = git.blob(sha, _bridgePins);
    String pin(String name, String source, String value) => _singleMatch(
      source,
      RegExp(
        "^(?:const String|const) $name =\\s*'($value)';\\r?\$",
        multiLine: true,
      ),
      name,
    );
    const tag = r'v[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9]+)?';
    final cpp = pin('llamaCppTag', native, tag);
    final litert = pin('liteRtLmReleaseTag', native, tag);
    final sd = pin('stableDiffusionReleaseTag', native, tag);
    final upstream = pin('bridgeLlamaCppTag', bridge, tag);
    final upstreamCommit = pin('bridgeLlamaCppCommit', bridge, '[a-f0-9]{40}');
    final manifest = pin(
      'webBridgeManifestSha256',
      git.blob(sha, _manifestPin),
      '[a-f0-9]{64}',
    );
    final module = _singleMatch(
      git.blob(sha, _modulePin),
      RegExp(
        r'https://cdn\.jsdelivr\.net/npm/(@litert-lm/core@\d+\.\d+\.\d+)/\+esm',
      ),
      'default Web LiteRT-LM module',
    );
    final bridgeTag = _bridgeTag(git.blob(sha, _bridgeDefault));
    if (!cpp.startsWith('$upstream-') && cpp != upstream) {
      throw const FormatException(
        'Native and Web llama.cpp upstream pins disagree.',
      );
    }
    return _Pins(
      bridgeTag,
      'Runtime baseline: native llama.cpp `$cpp` and Web use upstream '
      '`$upstream@$upstreamCommit`; native LiteRT-LM uses `$litert` and '
      'stable-diffusion uses `$sd`. Web LiteRT-LM uses `$module`. '
      'Manifest SHA-256: `$manifest`.',
    );
  }
}

class _Rendered {
  const _Rendered(this.draft, this.files);

  final String draft;
  final Map<String, String> files;
}

_Rendered _render(
  _Options options,
  _Changelog root,
  _Changelog docs,
  _Changelog archive,
  List<String> notes,
  _Pins pins,
  String oldBridge,
) {
  final version = options.version;
  final series = _version.firstMatch(version)!;
  final history = {...root.sections, ...archive.sections};
  if (history.containsKey(version) || docs.sections.containsKey(version)) {
    throw const FormatException(
      'The requested version is already in the pinned history.',
    );
  }
  if (history.length != root.sections.length + archive.sections.length ||
      docs.sections.keys.any((version) => !history.containsKey(version))) {
    throw const FormatException(
      'Root, archive and docs release headings disagree.',
    );
  }
  final previous = options.from.substring(1);
  final changedBridge = oldBridge != pins.bridge;
  final announcement = changedBridge
      ? notes.lastIndexWhere(
          (text) =>
              text.startsWith('Aligned ') &&
              _bridgeClaim.firstMatch(text)?[1] == pins.bridge,
        )
      : -1;

  String release({required bool docs}) {
    final article = docs ? '' : 'the ';
    final output = StringBuffer('## $version\n\n');
    for (final (i, note) in notes.indexed) {
      if (i == announcement) {
        output.writeln(
          '- ${note.replaceFirst(RegExp(r'Aligned (?:the )?default'), 'Aligned ${article}default')}',
        );
      } else if (_bridgeClaim.hasMatch(note)) {
        output.writeln('- WebGPU: ${_docsBridgeText(note)}');
      } else {
        output.writeln('- ${docs ? _docsBridgeText(note) : note}');
      }
    }
    if (announcement < 0) {
      output.writeln(
        changedBridge
            ? '- Aligned ${article}default WebGPU bridge assets to `${pins.bridge}`.'
            : '- Keep ${article}default WebGPU bridge assets at `${pins.bridge}` (unchanged from $previous).',
      );
    }
    return (output..writeln('\n${pins.baseline}\n')).toString();
  }

  final draft = release(docs: false);
  final docsDraft = release(docs: true);
  final retained = retainedReleaseHeadings(
    ['## $version', for (final heading in history.keys) '## $heading'],
    major: int.parse(series[1]!),
    minor: int.parse(series[2]!),
  ).skip(1).map((heading) => heading.substring(3)).toList();
  if (retained.any((version) => !docs.sections.containsKey(version))) {
    throw const FormatException(
      'Docs changelog is missing retained release history.',
    );
  }
  final drift = docsChangelogDriftProblems(
    {
      version: _sectionBody(draft),
      for (final key in retained) key: _sectionBody(history[key]!),
    },
    {
      version: _sectionBody(docsDraft),
      for (final key in retained) key: _sectionBody(docs.sections[key]!),
    },
  );
  if (drift.isNotEmpty) {
    throw const FormatException(
      'Retained root and docs changelog bodies disagree.',
    );
  }

  final rootSections = root.sections.values.toList();
  final archived = <String>[];
  var size = utf8.encode(root.preamble + draft + rootSections.join()).length;
  while (size > _sizeLimit && rootSections.isNotEmpty) {
    final oldest = rootSections.removeLast();
    if (!oldest.endsWith('\n')) {
      throw const FormatException(
        'Cannot join the oldest root section to the archive losslessly.',
      );
    }
    size -= utf8.encode(oldest).length;
    archived.add(oldest);
  }
  if (size > _sizeLimit) {
    throw const FormatException(
      'The new root changelog section exceeds the pub.dev size limit.',
    );
  }
  final keep = retained.toSet();
  return _Rendered(draft, {
    _root: root.preamble + draft + rootSections.join(),
    _docs:
        docs.preamble +
        docsDraft +
        docs.sections.entries
            .where((entry) => keep.contains(entry.key))
            .map((entry) => entry.value)
            .join(),
    _archive:
        archive.preamble +
        archived.reversed.join() +
        archive.sections.values.join(),
  });
}

String _docsBridgeText(String note) =>
    note.contains('default WebGPU bridge assets')
    ? note.replaceFirst('the default WebGPU', 'default WebGPU')
    : note;

String _sectionBody(String section) =>
    section.substring(section.indexOf('\n') + 1);

void _writeChanges(
  _Git git,
  String through,
  Map<String, String> files,
  Map<String, String> generated,
) {
  final paths = files.keys.toList();
  final trackedChanges = git.text([
    'diff',
    '--cached',
    '--name-only',
    '-z',
    '--',
    ...paths,
  ]);
  if (trackedChanges.isNotEmpty ||
      git.text(['ls-files', '--unmerged', '--', ...paths]).isNotEmpty ||
      git.text(['diff', '--summary', '--', ...paths]).isNotEmpty) {
    throw const FormatException(
      'Changelog targets contain staging changes, conflicts or mode changes.',
    );
  }
  final current = <String, String>{};
  final pinned = <String, String>{};
  for (final path in paths) {
    final file = File('${git.directory.path}/$path');
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw FormatException('$path is missing or is not a regular file.');
    }
    if (!Platform.isWindows && (file.statSync().mode & 0x49) != 0) {
      throw FormatException('$path is executable.');
    }
    current[path] = file.readAsStringSync();
    pinned[path] = git.blob(through, path);
  }
  bool matches(Map<String, String> other) =>
      paths.every((path) => current[path] == other[path]);
  if (matches(files)) return;
  if (!matches(pinned) && !matches(generated)) {
    throw const FormatException(
      'Changelog targets differ from the pinned history and generated draft.',
    );
  }
  final changed = paths.where((path) => files[path] != current[path]).toList();
  final scratch = <Directory>[];
  final staged = <String, (File, File, File)>{};
  final replaced = <String>[];
  final recoveries = <String>[];
  try {
    for (final path in changed) {
      final destination = File('${git.directory.path}/$path');
      final temp = destination.parent.createTempSync('cps-changelog-');
      scratch.add(temp);
      final next = File('${temp.path}/next')
        ..writeAsStringSync(files[path]!, flush: true);
      final backup = destination.copySync('${temp.path}/backup');
      staged[path] = (destination, next, backup);
    }
    for (final path in changed) {
      final (destination, next, _) = staged[path]!;
      if (destination.readAsStringSync() != current[path]) {
        throw FormatException('$path changed while staging the update.');
      }
      next.renameSync(destination.path);
      replaced.add(path);
    }
  } catch (_) {
    for (final path in replaced.reversed) {
      final (destination, _, backup) = staged[path]!;
      try {
        if (destination.readAsStringSync() == files[path]) {
          backup.renameSync(destination.path);
          continue;
        }
      } on FileSystemException {
        // Preserve the backup when the original cannot be restored.
      }
      recoveries.add(path);
      scratch.removeWhere((temp) => temp.path == backup.parent.path);
    }
    if (recoveries.isNotEmpty) {
      throw FormatException(
        'Could not restore ${recoveries.join(', ')}. Original bytes remain in '
        'the cps-changelog-* backup directories beside the affected files.',
      );
    }
    rethrow;
  } finally {
    for (final temp in scratch) {
      temp.deleteSync(recursive: true);
    }
  }
}
