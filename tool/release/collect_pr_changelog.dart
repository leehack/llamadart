import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/src/hook/native_release_tag.dart';

import '../testing/check_released_changelog_sections.dart';
import '../testing/verify_release_docs_versions.dart';
import 'pr_changelog.dart';

const _repository = 'leehack/llamadart';
const _cutoverPath = 'tool/release/changelog_pr_cutover.json';
const _resolutionsDir = 'tool/release/pr_resolutions';
const _nativePins = 'lib/src/hook/native_release_pins.dart';
const _bridgePins = 'tool/testing/check_webgpu_bridge_tag.dart';
const _manifestPin = 'lib/src/web_setup/web_bridge_setup.dart';
const _bridgeDefault = 'scripts/fetch_webgpu_bridge_assets.sh';
const _modulePin = 'example/chat_app/web/index.html';
const _root = 'CHANGELOG.md';
const _docs = 'website/docs/changelog/recent-releases.md';
const _archive = 'doc/changelog_archive.md';
const _sizeLimit = 256 * 1024;

final _sha = RegExp(r'^[a-f0-9]{40}$');
final _sha256 = RegExp(r'^[a-f0-9]{64}$');
final _prNumber = RegExp(r'\(#([1-9][0-9]*)\)$');
final _reverts = RegExp(
  r'^(?:This reverts commit ([a-f0-9]{40})\.|Reverts-Commit: ([a-f0-9]{40}))$',
);
final _githubRevert = RegExp(
  r'^Reverts ([A-Za-z0-9-]+/[A-Za-z0-9_.-]+#[1-9][0-9]*)$',
);
final _trailingAttribution = RegExp(
  r'(?:(\n---------)\n[ \t]*\n|\n)'
  r'(?:(?:Signed-off-by|Co-authored-by):[^\n]*(?:\n[ \t]+[^\n]+)*\n*)+$',
  caseSensitive: false,
);
final _coauthor = RegExp(
  r'^Co-authored-by:',
  caseSensitive: false,
  multiLine: true,
);

bool _isGithubCoauthorBlock(RegExpMatch attribution) =>
    attribution[1] != null && _coauthor.hasMatch(attribution[0]!);

final _trailerContinuation = RegExp(r'^[ \t\r\v\f]');
final _docsCut = RegExp(r'^docs: cut version (\S+)$');
final _bridgeClaim = RegExp(
  r'^(?:Aligned (?:the )?default WebGPU bridge assets to|'
  r'Keep (?:the )?default WebGPU bridge assets at) `(v\d+\.\d+\.\d+)`',
);

Future<void> main(List<String> args) async {
  try {
    stdout.write(await runPrChangelogCollector(args));
  } on _IncompleteInput catch (error) {
    stdout.writeln(error.message);
    exitCode = 1;
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
  if (args.length == 2 &&
      args.first == '--section-sha256' &&
      !args.last.startsWith('--')) {
    final section = parsePrChangelog(File(args.last).readAsStringSync());
    return '${_sectionDigest(section)}\n';
  }
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
        activationCommit.trailerState == _TrailerState.unaligned ||
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
    final collector = _Collector(
      git,
      chain,
      window,
      activation,
      through,
      options.version,
      lookup ?? recoveryGithubGet,
    );
    final entries = await collector.collect();
    final seedRows = [
      for (final text in legacy)
        {
          'sha': cutover,
          'source': 'legacy-seed',
          'target': 'core',
          'text': text,
        },
    ];
    final entryRows = entries.map((entry) => entry.toJson()).toList();
    final ledger = [
      'From: ${options.from}@$start',
      'Through: $through',
      ...seedRows.map(jsonEncode),
      ...entryRows.map(jsonEncode),
      for (final diagnostic in collector.diagnostics) diagnostic.toString(),
    ].join('\n');
    if (entries.any((entry) => entry.disposition == 'unresolved')) {
      throw _IncompleteInput(
        '$ledger\n\nINCOMPLETE: resolve all changelog inputs before releasing.',
      );
    }

    final receipt = _inputReceipt(
      options: options,
      start: start,
      through: through,
      cutoverTag: tag,
      cutover: cutover,
      activation: activation,
      rows: [
        ...seedRows,
        ...entryRows,
        for (final diagnostic in collector.diagnostics)
          if (diagnostic.reviewCode != null) diagnostic.toJson(),
      ],
    );
    final root = ChangelogHistory.parse(git.blob(through, _root));
    final docs = ChangelogHistory.parse(git.blob(through, _docs));
    final archive = ChangelogHistory.parse(git.blob(through, _archive));
    if (root.sections.keys.first != options.from.substring(1)) {
      throw const FormatException(
        '--from does not match the latest pinned changelog heading.',
      );
    }
    final sources = [
      for (final note in legacy) (sha: cutover, text: note),
      for (final entry in entries)
        if (entry.disposition == 'included')
          for (final bullet in entry.section!.bullets)
            if (bullet.target == 'core') (sha: entry.sha, text: bullet.text),
    ];
    final canonical = sources.map((note) => note.text).toList();
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

    final reviewShas = {
      for (final diagnostic in collector.diagnostics) ...diagnostic.reviewShas,
    };
    if (options.verify case final path?) {
      final candidate = options.candidate == null
          ? null
          : git.resolve(options.candidate!);
      final body = git.receiptBody(File(path).readAsStringSync(), candidate);
      _verifyReceipt(parseReleaseNotesInput(body), receipt);
      final diffs = <String>[];
      if (candidate != null) {
        for (final changelog in [_root, _docs]) {
          final actual = ChangelogHistory.parse(git.blob(candidate, changelog));
          if (actual.sections.keys.first != options.version) {
            throw FormatException(
              '$changelog: expected candidate release ${options.version}.',
            );
          }
          final section = actual.sections[options.version]!;
          final expected = generated.sections[changelog]!;
          if (section == expected) continue;
          diffs.add(_sectionDiff(changelog, expected, section));
          _requireMissingNotes(
            reviewShas,
            sources,
            generated.bullets[changelog]!,
            section,
          );
        }
      }
      final report = [ledger, ...diffs].join('\n\n');
      _verifyReview(
        body,
        reviewShas,
        report,
        optional: options.candidate == null
            ? sources.map((source) => source.sha)
            : const [],
      );
      return '$report\n\nRelease notes input verified.\n';
    }

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
      for (final changelog in [_root, _docs]) {
        if (result.sections[changelog] == generated.sections[changelog]) {
          continue;
        }
        _requireMissingNotes(
          reviewShas,
          sources,
          generated.bullets[changelog]!,
          result.sections[changelog]!,
        );
      }
      _verifyReview(
        options.review == null ? '' : File(options.review!).readAsStringSync(),
        reviewShas,
        '$ledger\n\n${_receiptBlock(receipt)}',
      );
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
    return '$ledger\n\n${_receiptBlock(receipt)}\n${result.draft}';
  }
  throw const FormatException(
    'Invalid cutover marker. Expected a full commit SHA and core release tag.',
  );
}

class _IncompleteInput extends FormatException {
  const _IncompleteInput(super.message);
}

class _Options {
  const _Options(
    this.version,
    this.from,
    this.through,
    this.write,
    this.curated,
    this.verify,
    this.candidate,
    this.review,
  );

  final String version;
  final String from;
  final String through;
  final bool write;
  final String? curated;
  final String? verify;
  final String? candidate;
  final String? review;

  static _Options parse(List<String> args) {
    const usage =
        'Usage: collect_pr_changelog.dart --version V --from vPREVIOUS '
        '--through BASE [--curated FILE] [--write [--review FILE]]\n'
        '   or: collect_pr_changelog.dart --version V --from vPREVIOUS '
        '--through BASE --verify-input FILE [--candidate SHA]\n'
        '   or: collect_pr_changelog.dart --section-sha256 FILE';
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
            '--verify-input',
            '--candidate',
            '--review',
          }.contains(flag) &&
          !values.containsKey(flag) &&
          i + 1 < args.length &&
          !args[i + 1].startsWith('--')) {
        values[flag] = args[++i];
      } else {
        throw const FormatException(usage);
      }
    }
    final curated = values['--curated'];
    final verify = values['--verify-input'];
    final candidate = values['--candidate'];
    final review = values['--review'];
    if (values
        case {
          '--version': final String version,
          '--from': final String from,
          '--through': final String through,
        }
        when coreReleaseVersion.hasMatch(version) &&
            (verify == null || (!write && curated == null)) &&
            (candidate == null ||
                (verify != null && _sha.hasMatch(candidate))) &&
            (review == null || write)) {
      return _Options(
        version,
        from,
        through,
        write,
        curated,
        verify,
        candidate,
        review,
      );
    }
    throw const FormatException(usage);
  }
}

ReleaseNotesInput _inputReceipt({
  required _Options options,
  required String start,
  required String through,
  required String cutoverTag,
  required String cutover,
  required String activation,
  required List<Map<String, Object?>> rows,
}) {
  final header = {
    'version': options.version,
    'previousTag': options.from,
    'previousSha': start,
    'through': through,
    'cutoverTag': cutoverTag,
    'cutoverSha': cutover,
    'activationSha': activation,
  };
  final canonical = StringBuffer();
  for (final row in [header, ...rows]) {
    canonical.writeln(jsonEncode(row));
  }
  return (
    previousTag: options.from,
    previousSha: start,
    through: through,
    inputSha256: sha256.convert(utf8.encode(canonical.toString())).toString(),
  );
}

String _receiptBlock(ReleaseNotesInput receipt) =>
    '## Release notes input\n\n'
    'Previous-tag: ${receipt.previousTag}@${receipt.previousSha}\n'
    'Through: ${receipt.through}\n'
    'Input-SHA256: ${receipt.inputSha256}\n';

void _verifyReceipt(ReleaseNotesInput received, ReleaseNotesInput expected) {
  if (received.previousTag != expected.previousTag ||
      received.previousSha != expected.previousSha) {
    throw const FormatException(
      'Release notes input: Previous-tag does not match.',
    );
  }
  if (received.through != expected.through) {
    throw const FormatException('Release notes input: Through does not match.');
  }
  if (received.inputSha256 != expected.inputSha256) {
    throw const FormatException(
      'Release notes input: Input-SHA256 does not match.',
    );
  }
}

void _verifyReview(
  String body,
  Set<String> required,
  String context, {
  Iterable<String> optional = const [],
}) {
  final Map<String, String> dispositions;
  try {
    dispositions = parseReleaseNotesReview(body);
  } on FormatException catch (error) {
    throw FormatException('$context\n\n${error.message}');
  }
  final missing = required.difference(dispositions.keys.toSet());
  final unrelated = dispositions.keys.toSet().difference({
    ...required,
    ...optional,
  });
  if (missing.isNotEmpty || unrelated.isNotEmpty) {
    throw FormatException(
      [
        context,
        '',
        if (missing.isNotEmpty)
          'Release notes review: missing dispositions for ${missing.join(', ')}.',
        if (unrelated.isNotEmpty)
          'Release notes review: unrelated dispositions for ${unrelated.join(', ')}.',
      ].join('\n'),
    );
  }
}

enum _TrailerState { clean, mixed, unaligned }

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

  ({String mode, String type})? treeEntry(String sha, String path) {
    final row = text(['ls-tree', '-z', sha, '--', path]);
    if (row.isEmpty) return null;
    final fields = row.split('\t');
    final header = fields.first.split(' ');
    if (fields.length != 2 ||
        fields.last != '$path\x00' ||
        header.length != 3) {
      throw FormatException('$sha: invalid Git tree entry for $path.');
    }
    return (mode: header[0], type: header[1]);
  }

  String receiptBody(String input, String? candidate) {
    if (candidate == null) return input;
    final raw = text(['show', '-s', '--format=%B', candidate]);
    if (raw.trimRight() != input.trimRight()) return input;

    // Git can classify the receipt fields themselves as trailers.
    final message = raw.replaceAll('\r\n', '\n').trimRight();
    final attribution = _trailingAttribution.firstMatch(message);
    return landedPrBody(
      attribution == null
          ? message
          : message.substring(
              0,
              attribution.start +
                  (_isGithubCoauthorBlock(attribution)
                      ? 0
                      : attribution[1]?.length ?? 0),
            ),
    );
  }

  ({
    String subject,
    String body,
    String trailers,
    _TrailerState trailerState,
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
    final (message, trailerState) = fields[3].isEmpty
        ? (fields[2], _TrailerState.clean)
        : _stripTrailers(fields[2], fields[4], fields[5]);
    final raw = fields[2].trimRight();
    final attribution = _trailingAttribution.firstMatch(raw);
    final body = attribution != null && _isGithubCoauthorBlock(attribution)
        ? raw.substring(0, attribution.start)
        : message;
    return (
      subject: fields[0],
      body: landedPrBody(body),
      trailers: fields[3],
      trailerState: trailerState,
      parents: fields[1].isEmpty ? 0 : fields[1].split(' ').length,
    );
  }

  (String, _TrailerState) _stripTrailers(
    String message,
    String block,
    String records,
  ) {
    final unaligned = (message, _TrailerState.unaligned);

    final start = message.lastIndexOf('\n$block') + 1;
    if (block.isEmpty ||
        start == 0 ||
        message.substring(start + block.length).trim().isNotEmpty ||
        block.contains('\x1e') ||
        block.contains('\x1f')) {
      return unaligned;
    }
    final raw = block.replaceFirst(RegExp(r'\n$'), '').split('\n');
    final retained = <String>[];
    var index = 0;
    for (final record in records.split('\x1e')) {
      if (index >= raw.length) return unaligned;
      final line = raw[index++];
      if (record.contains('\x1f')) {
        if (_trailerContinuation.hasMatch(line)) return unaligned;
        while (index < raw.length &&
            _trailerContinuation.hasMatch(raw[index])) {
          index++;
        }
      } else {
        if (line.trimRight() != record.trimRight()) return unaligned;
        retained.add(line);
      }
    }
    if (index != raw.length) return unaligned;
    return (
      message.substring(0, start) + retained.join('\n'),
      retained.isEmpty ? _TrailerState.clean : _TrailerState.mixed,
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
  if (!tag.startsWith('v') || !coreReleaseVersion.hasMatch(tag.substring(1))) {
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

(PrChangelog?, String?) _readLandedChangelog(String body) {
  try {
    return (parseLandedPrChangelog(body), null);
  } on AmbiguousLandedChangelog catch (error) {
    return (null, error.message);
  } on FormatException {
    return (null, null);
  }
}

List<String> _legacySeed(_Git git, String sha) => legacySeedNotes(
  ChangelogHistory.parse(git.blob(sha, _root), allowUnreleased: true),
  ChangelogHistory.parse(git.blob(sha, _docs), allowUnreleased: true),
);

class _Entry {
  _Entry(
    this.sha,
    this.pr,
    this.source,
    this.disposition, {
    this.section,
    this.targets = const [],
    this.failure,
    this.recovery,
    this.resolution,
  });

  final String sha;
  final int? pr;
  final String source;
  String disposition;
  final PrChangelog? section;
  final List<String> targets;
  final String? failure;
  final String? recovery;
  final String? resolution;
  late final String? sectionSha256 = switch (section) {
    final section? => _sectionDigest(section),
    null => null,
  };

  Map<String, Object?> toJson() {
    final section = this.section;
    return {
      'sha': sha,
      'pr': pr,
      'source': source,
      'disposition': disposition,
      if (failure != null) 'reason': failure,
      if (recovery != null) 'recovery': recovery,
      if (resolution != null) 'resolution': resolution,
      if (section != null) ...{
        'sectionSha256': sectionSha256,
        if (section.reason != null) 'reason': section.reason,
        if (section.bullets.isNotEmpty) 'bullets': _bulletRows(section),
      },
      if (targets.isNotEmpty) 'reverts': targets,
    };
  }
}

List<Map<String, String>> _bulletRows(PrChangelog section) => [
  for (final bullet in section.bullets)
    {'target': bullet.target, 'text': bullet.text},
];

String _sectionDigest(PrChangelog section) => sha256
    .convert(
      utf8.encode(
        jsonEncode({'reason': section.reason, 'bullets': _bulletRows(section)}),
      ),
    )
    .toString();

class _Diagnostic {
  const _Diagnostic(
    this.sha,
    this.pr,
    this.problem, {
    this.reviewCode,
    this.reviewShas = const [],
    this.reference,
  });

  final String sha;
  final int? pr;
  final String problem;
  final String? reviewCode;
  final List<String> reviewShas;
  final String? reference;

  Map<String, Object?> toJson() => {
    'sha': sha,
    'pr': pr,
    'reviewCode': reviewCode,
    'reviewShas': reviewShas,
    if (reference != null) 'reference': reference,
  };

  @override
  String toString() => 'WARNING ${_location(sha, pr)}: $problem';
}

typedef _Pull = ({int number, String mergeSha});
typedef _PrResolution = ({String path, int pr, String sectionSha256});

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
  _Collector(
    this.git,
    this.chain,
    this.window,
    this.activation,
    this.through,
    this.version,
    this.lookup,
  ) : positions = Map.fromEntries(
        chain.indexed.map((entry) => MapEntry(entry.$2, entry.$1)),
      );

  final _Git git;
  final List<String> chain;
  final List<String> window;
  final String activation;
  final String through;
  final String version;
  final GithubLookup lookup;
  final Map<String, int> positions;
  final diagnostics = <_Diagnostic>[];
  final _associations = <String, Future<Set<_Pull>>>{};
  final _details = <int, Future<Object?>>{};

  Future<List<_Entry>> collect() async {
    final Map<String, RecoveredPrep> recovered;
    try {
      recovered = {
        for (final row in await verifyPrepRecoveryIntroductions(
          git.directory,
          window,
          lookup,
        ))
          row.prep: row,
      };
    } on FormatException catch (error) {
      throw _IncompleteInput('INCOMPLETE: ${error.message}');
    } on StateError catch (error) {
      throw _IncompleteInput('INCOMPLETE: ${error.message}');
    } on Exception {
      throw _IncompleteInput(
        'INCOMPLETE: could not verify unpublished prep recovery.',
      );
    }
    final rows = <_Entry>[];
    final seen = <int, _Entry>{};
    for (final sha in window) {
      if (recovered[sha] case final row?) {
        rows.add(
          _Entry(
            sha,
            row.pr,
            'recovery',
            'recovered-prep',
            recovery: row.recovery,
          ),
        );
        continue;
      }
      final commit = git.commit(sha);
      final number = int.tryParse(
        _prNumber.firstMatch(commit.subject)?[1] ?? '',
      );
      if (commit.trailerState == _TrailerState.unaligned) {
        rows.add(
          _unresolved(
            sha,
            number,
            'git',
            'Cannot safely separate Git trailers.',
          ),
        );
        continue;
      }
      if (commit.trailerState == _TrailerState.mixed) {
        _warn(sha, number, 'kept non-trailer lines in the Git trailer block.');
      }
      if (commit.parents != 1) {
        rows.add(
          _unresolved(sha, number, 'git', 'unsupported main commit shape.'),
        );
        continue;
      }
      final (landed, ambiguity) = _readLandedChangelog(commit.body);
      if (ambiguity != null) _warn(sha, number, ambiguity);
      if (landed != null && number != null) {
        rows.add(_row(sha, number, 'git', landed, commit.trailers, seen));
        continue;
      }
      if (number == null &&
          landed == null &&
          _generatedDocs(sha, commit.subject)) {
        rows.add(_Entry(sha, null, 'git', 'generated-docs'));
        continue;
      }
      final resolution = number == null ? _readPrResolution(sha) : null;
      if (landed != null && resolution != null) {
        rows.add(
          _unresolved(
            sha,
            resolution.pr,
            'git',
            'PR resolution cannot replace a landed Changelog.',
          ),
        );
        continue;
      }
      final associatedNumber = number ?? resolution?.pr;
      if (associatedNumber == null) {
        rows.add(
          _unresolved(
            sha,
            null,
            'git',
            'missing final PR number in commit subject.',
          ),
        );
        continue;
      }
      try {
        final (section, reason) = await _fallback(
          sha,
          associatedNumber,
          resolution: resolution,
        );
        rows.add(
          section != null
              ? _row(
                  sha,
                  associatedNumber,
                  'api',
                  section,
                  '',
                  seen,
                  resolution: resolution?.path,
                )
              : _unresolved(sha, associatedNumber, 'api', reason!),
        );
      } on FormatException catch (error) {
        if (ambiguity == null) rethrow;
        throw FormatException('${error.message} $ambiguity');
      }
    }
    _reviewGitHubReverts(rows);
    _applyReverts(rows);
    return rows;
  }

  _Entry _row(
    String sha,
    int number,
    String source,
    PrChangelog section,
    String trailers,
    Map<int, _Entry> seen, {
    String? resolution,
  }) {
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
    final row = _Entry(
      sha,
      number,
      source,
      disposition,
      section: section,
      targets: targets,
      resolution: resolution,
    );
    if (first == null) {
      seen[number] = row;
    } else if (first.sectionSha256 != row.sectionSha256) {
      _warn(
        sha,
        number,
        'Changelog section differs from ${first.sha}. Kept the first section.',
        reviewCode: 'divergent-duplicate',
        reviewShas: [first.sha, sha],
      );
    }
    return row;
  }

  void _reviewGitHubReverts(List<_Entry> rows) {
    for (final row in rows) {
      for (final line in row.section?.outsideLines ?? const <String>[]) {
        final reference = _githubRevert.firstMatch(line)?[1];
        if (reference == null) continue;
        final number = reference.toLowerCase().startsWith('$_repository#')
            ? int.tryParse(reference.split('#').last)
            : null;
        final targets = [
          for (final target in rows)
            if (target.sha != row.sha &&
                target.pr == number &&
                target.section != null)
              target.sha,
        ];
        _warn(
          row.sha,
          row.pr,
          'GitHub revert of $reference needs review.'
          '${targets.isEmpty ? '' : ' Target commits: ${targets.join(', ')}.'}',
          reviewCode: 'github-revert',
          reviewShas: [row.sha, ...targets],
          reference: reference,
        );
      }
    }
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
        if (row.section!.bullets.isNotEmpty ||
            (target.targets.isNotEmpty && target.section!.bullets.isNotEmpty)) {
          _warn(
            row.sha,
            row.pr,
            'exact revert of ${target.sha} suppressed authored reversal notes.',
            reviewCode: 'authored-exact-revert',
            reviewShas: [target.sha, row.sha],
          );
        }
      } else {
        keepForReview.addAll([row.sha, ...row.targets]);
        final targetLabel = target?.pr == null
            ? ''
            : ' (target #${target!.pr})';
        _warn(
          row.sha,
          row.pr,
          'revert of ${row.targets.join(', ')}$targetLabel needs review. Kept its notes.',
          reviewCode: 'unconfirmed-revert',
          reviewShas: [
            row.sha,
            for (final target in row.targets)
              if (target != row.sha && bySha[target]?.section != null) target,
          ],
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

  _PrResolution? _readPrResolution(String sha) {
    final path = '$_resolutionsDir/$sha.json';
    final entry = git.treeEntry(through, path);
    if (entry == null) return null;
    if (entry.mode != '100644' || entry.type != 'blob') {
      throw FormatException(
        '$sha: PR resolution must be a regular non-executable file.',
      );
    }
    final source = git.blob(through, path);
    final Object? record;
    try {
      record = jsonDecode(source);
    } on FormatException {
      throw FormatException('$sha: invalid PR resolution JSON in $path.');
    }
    if (record
        case {
          'version': final String recordVersion,
          'sha': final String recordSha,
          'pr': final int pr,
          'sectionSha256': final String digest,
        }
        when coreReleaseVersion.hasMatch(recordVersion) &&
            recordSha == sha &&
            pr > 0 &&
            _sha256.hasMatch(digest)) {
      final canonical = jsonEncode({
        'version': recordVersion,
        'sha': recordSha,
        'pr': pr,
        'sectionSha256': digest,
      });
      if (source == '$canonical\n') {
        if (recordVersion != version) {
          throw FormatException(
            '$sha: PR resolution version $recordVersion does not match $version.',
          );
        }
        return (path: path, pr: pr, sectionSha256: digest);
      }
    }
    throw FormatException(
      '$sha: invalid canonical PR resolution record in $path.',
    );
  }

  Future<(PrChangelog?, String?)> _fallback(
    String sha,
    int number, {
    _PrResolution? resolution,
  }) async {
    final candidates = await _associated(sha, number);
    final numbered = candidates.where((pull) => pull.number == number).toList();
    if (numbered.length > 1) {
      throw FormatException(
        '${_location(sha, number)}: PR association has conflicting merge commits.',
      );
    }
    final exact = candidates.where((pull) => pull.mergeSha == sha).toList();
    final pull = exact.where((pull) => pull.number == number).firstOrNull;
    const unmatched = 'no matching merged main PR association.';
    if (pull == null) {
      if (numbered.isNotEmpty &&
          !await _sharedAssociation(sha, numbered.single)) {
        throw FormatException(
          '${_location(sha, number)}: PR association has the wrong merge commit.',
        );
      }
      return (null, unmatched);
    }

    final matches = [
      ...exact,
      for (final candidate in candidates)
        if (candidate.mergeSha != sha &&
            await _sharedAssociation(sha, candidate))
          candidate,
    ];
    if (matches.length > 1) {
      final numbers = matches.map((pull) => pull.number).toList()..sort();
      throw FormatException(
        '${_location(sha, number)}: ambiguous merged main PR associations '
        '(${numbers.map((number) => '#$number').join(', ')}).',
      );
    }
    if (await _sharedAssociation(sha, pull)) {
      return (
        null,
        'shared batch association requires a landed Changelog section.',
      );
    }

    final detail = await _details.putIfAbsent(
      pull.number,
      () => _get('pulls/${pull.number}', sha, pull.number),
    );
    if (_mergedMainPull(detail) != pull) {
      throw FormatException(
        '${_location(sha, pull.number)}: PR detail conflicts with the commit association.',
      );
    }
    if (resolution != null &&
        (detail is! Map ||
            detail['commits'] is! int ||
            detail['commits'] != 1)) {
      throw FormatException(
        '${_location(sha, pull.number)}: resolved PR must contain exactly one commit.',
      );
    }
    final body = detail is Map ? detail['body'] : null;
    final section = body is String ? _readChangelog(body) : null;
    if (section == null) {
      return (null, 'associated PR has no valid Changelog section.');
    }
    if (resolution != null &&
        _sectionDigest(section) != resolution.sectionSha256) {
      throw FormatException(
        '${_location(sha, pull.number)}: associated PR Changelog digest conflicts with the reviewed resolution.',
      );
    }
    return (section, null);
  }

  Future<bool> _sharedAssociation(String sha, _Pull candidate) async {
    final current = positions[sha]!;
    final end = positions[candidate.mergeSha];
    if (end == null || end < current) return false;
    final other = end == current ? current - 1 : end;
    if (other < positions[window.first]! || chain[other] == activation) {
      return false;
    }
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

  _Entry _unresolved(String sha, int? number, String source, String reason) {
    _warn(sha, number, reason);
    return _Entry(sha, number, source, 'unresolved', failure: reason);
  }

  void _warn(
    String sha,
    int? number,
    String problem, {
    String? reviewCode,
    List<String> reviewShas = const [],
    String? reference,
  }) {
    diagnostics.add(
      _Diagnostic(
        sha,
        number,
        problem,
        reviewCode: reviewCode,
        reviewShas: reviewShas,
        reference: reference,
      ),
    );
  }
}

String _location(String sha, int? number) =>
    number == null ? sha : '$sha (#$number)';

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
    final cpp = pin('llamaCppTag', native, r"[^']+");
    final litert = pin('liteRtLmReleaseTag', native, tag);
    final sd = pin('stableDiffusionReleaseTag', native, tag);
    final upstream = pin('bridgeLlamaCppTag', bridge, r"[^']+");
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
    if (normalizeNativeLlamaCppTag(cpp) != upstream ||
        normalizeNativeLlamaCppTag(upstream) != upstream) {
      throw const FormatException(
        'Native and Web llama.cpp upstream pins disagree.',
      );
    }
    return _Pins(
      bridgeTag,
      formatRuntimeBaseline(
        native: cpp,
        upstream: upstream,
        upstreamCommit: upstreamCommit,
        liteRt: litert,
        stableDiffusion: sd,
        module: module,
        manifest: manifest,
      ),
    );
  }
}

class _Rendered {
  const _Rendered(this.files, this.sections, this.bullets);

  final Map<String, String> files;
  final Map<String, String> sections;
  final Map<String, List<String>> bullets;

  String get draft => sections[_root]!;
}

_Rendered _render(
  _Options options,
  ChangelogHistory root,
  ChangelogHistory docs,
  ChangelogHistory archive,
  List<String> notes,
  _Pins pins,
  String oldBridge,
) {
  final version = options.version;
  final series = coreReleaseVersion.firstMatch(version)!;
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

  List<String> authoredBullets({required bool docs}) => [
    for (final (i, note) in notes.indexed)
      if (i == announcement)
        '- ${note.replaceFirst(RegExp(r'Aligned (?:the )?default'), docs ? 'Aligned default' : 'Aligned the default')}'
      else if (_bridgeClaim.hasMatch(note))
        '- WebGPU: ${_docsBridgeText(note)}'
      else
        '- ${docs ? _docsBridgeText(note) : note}',
  ];

  String release(List<String> bullets, {required bool docs}) {
    final article = docs ? '' : 'the ';
    final output = StringBuffer('## $version\n\n');
    for (final bullet in bullets) {
      output.writeln(bullet);
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

  final rootBullets = authoredBullets(docs: false);
  final docsBullets = authoredBullets(docs: true);
  final draft = release(rootBullets, docs: false);
  final docsDraft = release(docsBullets, docs: true);
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
  final oldBoundary = root.sections.keys.last;
  String boundary() => rootSections.isEmpty
      ? version
      : root.sections.keys.elementAt(rootSections.length - 1);
  String rootPreamble() =>
      archiveBoundary(root.preamble, oldBoundary, boundary());
  final draftSize = utf8.encode(draft).length;
  var historySize = utf8.encode(rootSections.join()).length;
  int size() => utf8.encode(rootPreamble()).length + draftSize + historySize;
  while (size() > _sizeLimit && rootSections.isNotEmpty) {
    final oldest = rootSections.removeLast();
    if (!oldest.endsWith('\n')) {
      throw const FormatException(
        'Cannot join the oldest root section to the archive losslessly.',
      );
    }
    historySize -= utf8.encode(oldest).length;
    archived.add(oldest);
  }
  if (size() > _sizeLimit) {
    throw const FormatException(
      'The new root changelog section exceeds the pub.dev size limit.',
    );
  }
  final archivePreamble = archiveBoundary(
    archive.preamble,
    oldBoundary,
    boundary(),
  );
  final keep = retained.toSet();
  return _Rendered(
    {
      _root: rootPreamble() + draft + rootSections.join(),
      _docs:
          docs.preamble +
          docsDraft +
          docs.sections.entries
              .where((entry) => keep.contains(entry.key))
              .map((entry) => entry.value)
              .join(),
      _archive:
          archivePreamble +
          archived.reversed.join() +
          archive.sections.values.join(),
    },
    {_root: draft, _docs: docsDraft},
    {_root: rootBullets, _docs: docsBullets},
  );
}

String _docsBridgeText(String note) =>
    note.contains('default WebGPU bridge assets')
    ? note.replaceFirst('the default WebGPU', 'default WebGPU')
    : note;

String _sectionBody(String section) =>
    section.substring(section.indexOf('\n') + 1);

String _sectionDiff(String path, String expected, String actual) {
  final before = const LineSplitter().convert(expected);
  final after = const LineSplitter().convert(actual);
  return [
    '--- generated/$path',
    '+++ candidate/$path',
    '@@ -1,${before.length} +1,${after.length} @@',
    for (final line in before) '-$line',
    for (final line in after) '+$line',
  ].join('\n');
}

void _requireMissingNotes(
  Set<String> required,
  List<({String sha, String text})> sources,
  List<String> generated,
  String candidate,
) {
  final lineEndings = RegExp(r'\r\n?');
  final normalized = candidate.replaceAll(lineEndings, '\n');
  final baseline = normalized.lastIndexOf('\n\nRuntime baseline: ');
  final notes = baseline < 0 ? normalized : normalized.substring(0, baseline);
  final lines = const LineSplitter().convert(notes);
  final visible = visibleReleaseBulletLines(notes);
  final listMarker = RegExp(r'^[-*+] ');
  final markers = [
    for (final (index, line) in lines.indexed)
      if (listMarker.hasMatch(line)) index,
  ];
  final available = <String, int>{};
  for (final (index, start) in markers.indexed) {
    if (!visible.contains(start)) continue;
    final end = index + 1 < markers.length ? markers[index + 1] : lines.length;
    final bullet = lines
        .getRange(start, end)
        .join('\n')
        .replaceFirst(RegExp(r'(?:\n[ \t]*)+$'), '');
    available.update(bullet, (count) => count + 1, ifAbsent: () => 1);
  }
  final expected = <String, List<String>>{};
  for (final (index, bullet) in generated.indexed) {
    final normalizedBullet = bullet.replaceAll(lineEndings, '\n');
    (expected[normalizedBullet] ??= []).add(sources[index].sha);
  }
  for (final entry in expected.entries) {
    if ((available[entry.key] ?? 0) < entry.value.length) {
      // Identical prose does not identify which of its sources was omitted.
      required.addAll(entry.value);
    }
  }
}

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
