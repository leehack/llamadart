import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Why a suite or helper may name Markdown without a Markdown-only change
/// needing to run it, with the evidence that was checked.
///
/// [evidence] maps each file to the sorted tokens discovery finds in it, joined
/// by ` | `, so a changed read fails until someone re-checks it. A non-null
/// [gate] names a tag the suite must declare to be excluded from the job.
typedef Exemption = ({
  String reason,
  Map<String, String> evidence,
  String? gate,
});

final RegExp _commentLine = RegExp(r'^\s*(?://|#).*$', multiLine: true);
final RegExp _directive = RegExp(
  r'''^\s*(?:import|export|part)\s+((?:[^;'"]|'[^']*'|"[^"]*")*);''',
  multiLine: true,
);
final RegExp _quoted = RegExp(r'''['"]([^'"\n]+)['"]''');
final RegExp _scriptPath = RegExp(
  r'((?:[\w.-]+/)*[\w.-]+\.(?:dart|py|sh|ps1))',
);
final RegExp _bareScript = RegExp(r'^[\w.*-]+\.(?:dart|py|sh|ps1)$');
final RegExp _pyImport = RegExp(
  r'^\s*(?:from\s+([\w.]+)\s+import\s+([\w., ]+)|import\s+([\w., ]+))',
  multiLine: true,
);
final RegExp _literalRun = RegExp(r'''(?:['"][^'"\n]*['"]\s*[,+]?\s*){2,}''');
final RegExp _joinGap = RegExp(r'''['"]\s*,\s*['"]''');
final RegExp _concatGap = RegExp(r'''['"]\s*\+?\s*['"]''');

/// Names of tracked Markdown or of a directory that holds it.
final Map<String, RegExp> _nameTokens = {
  '.md': RegExp(r'\.md\b'),
  for (final word in ['README', 'CHANGELOG', 'AGENTS', 'CONTRIBUTING', 'SKILL'])
    word: RegExp(word),
  for (final dir in ['doc', 'website', 'skills'])
    '$dir/': RegExp('[\'"/]$dir/|[\'"]$dir[\'"]'),
  'Directory(.)': RegExp(r'''Directory\(['"]\.['"]\)'''),
  'ls-files': RegExp('ls-files'),
};

/// Directory traversal; counted only beside a [_repositoryRoot] in the file.
final Map<String, RegExp> _walkTokens = {
  'listSync': RegExp(r'\.listSync\('),
  'list': RegExp(r'\.list\('),
  'Glob': RegExp(r'\bGlob\('),
  'os.walk': RegExp(r'os\.walk'),
  'glob': RegExp(r'\.r?glob\(|glob\.i?glob'),
  'listdir': RegExp(r'os\.listdir|os\.scandir|\.iterdir\('),
  'copytree': RegExp(r'shutil\.copytree'),
  'find': RegExp(r'\bfind\s+[."$\w/-]'),
  'grep -r': RegExp(r'\bgrep\s+-\w*[rR]|\brg\s'),
  'Get-ChildItem': RegExp('Get-ChildItem'),
  'cp -r': RegExp(r'\bcp\s+-\w*[rRa]|\brsync\s|\btar\s'),
};

/// Git commands that enumerate or read tracked content; counted only in a file
/// that mentions git.
final Map<String, RegExp> _gitTokens = {
  for (final command in [
    'ls-tree',
    'cat-file',
    'grep',
    'archive',
    'show',
    'diff',
    'worktree',
    'clone',
    'checkout',
  ])
    'git $command': RegExp('\\bgit\\s+$command\\b|[\'"]$command[\'"]'),
};
final RegExp _mentionsGit = RegExp(r'\bgit\b');

/// A walk root that is the working directory, the script's directory or a
/// relative literal, each of which lies inside the checkout in a root test.
/// Walks of a temp directory do not match.
final RegExp _repositoryRoot = RegExp(
  r'''Directory\.current|Directory\(\s*['"](?![/$])'''
  r'''|Directory\(\s*p(?:ath)?\.join\(\s*['"](?![/$])|\bp(?:ath)?\.current\b'''
  r'''|Platform\.script|os\.getcwd|Path\.cwd\(|__file__|Path\(\s*['"]\.'''
  r'''|\$\(pwd\)|\$PWD|--show-toplevel|BASH_SOURCE|dirname\s+"?\$0'''
  r'''|\$PSScriptRoot''',
);

class _FileInfo {
  final Set<String> tokens = {};
  final Set<String> edges = {};
}

/// What one suite reaches: files, and per file the tokens that read Markdown.
class Reach {
  final Map<String, Set<String>> evidence = {};
  final Set<String> files = {};

  /// Evidence as `{path: 'a | b'}`, the form exemptions record.
  Map<String, String> get recorded => {
    for (final entry in evidence.entries)
      entry.key: (entry.value.toList()..sort()).join(' | '),
  };
}

/// Static discovery of the files a test suite can reach and which of them name
/// Markdown or enumerate the checkout.
///
/// Limits, kept in `doc/ci_selection.md`: it reads source text, so it cannot
/// see a path built at runtime, an environment-selected script, a read through
/// a temp tree repointed at the checkout, or a callee dispatched by name.
class MarkdownReaders {
  MarkdownReaders({
    required this.files,
    this.root = '.',
    this.packageRoots = const {},
  }) {
    for (final file in files) {
      (_byBasename[p.posix.basename(file)] ??= []).add(file);
      (_byDir[p.posix.dirname(file)] ??= []).add(file);
      var dir = p.posix.dirname(file);
      while (dir != '.' && _dirs.add(dir)) {
        dir = p.posix.dirname(dir);
      }
    }
  }

  /// Repository-relative POSIX paths of every file discovery may follow.
  final Set<String> files;
  final String root;

  /// Workspace packages: name -> its `lib` directory.
  final Map<String, String> packageRoots;
  final Map<String, List<String>> _byBasename = {};
  final Map<String, List<String>> _byDir = {};
  final Set<String> _dirs = {};
  final Map<String, _FileInfo> _cache = {};
  final Map<String, List<String>> _scriptCache = {};

  List<String> _resolveScript(String token, String from) {
    return _scriptCache['$from\n$token'] ??= () {
      final found = <String>{};
      final parts = token.split('/');
      for (var i = 0; i < parts.length; i++) {
        final tail = parts.sublist(i).join('/');
        if (files.contains(tail)) found.add(tail);
        final rel = p.posix.normalize(
          p.posix.join(p.posix.dirname(from), tail),
        );
        if (files.contains(rel)) found.add(rel);
        if (parts.length - i >= 2) {
          for (final f in _byBasename[parts.last] ?? const <String>[]) {
            if (f.endsWith('/$tail')) found.add(f);
          }
        }
      }
      return found.toList();
    }();
  }

  _FileInfo _analyze(String path) {
    final cached = _cache[path];
    if (cached != null) return cached;
    final info = _cache[path] = _FileInfo();
    String code;
    try {
      code = File(
        p.join(root, path),
      ).readAsStringSync().replaceAll(_commentLine, '');
    } on FileSystemException {
      info.tokens.add('unreadable');
      return info;
    }
    final constructed = StringBuffer();
    for (final run in _literalRun.allMatches(code)) {
      final text = run.group(0)!;
      constructed
        ..writeln(text.replaceAll(_joinGap, '/'))
        ..writeln(text.replaceAll(_concatGap, ''));
    }
    final text = '$code\n$constructed';

    for (final entry in _nameTokens.entries) {
      if (entry.value.hasMatch(text)) info.tokens.add(entry.key);
    }
    if (_repositoryRoot.hasMatch(code)) {
      for (final entry in _walkTokens.entries) {
        if (entry.value.hasMatch(code)) info.tokens.add(entry.key);
      }
    }
    if (_mentionsGit.hasMatch(code)) {
      for (final entry in _gitTokens.entries) {
        if (entry.value.hasMatch(code)) info.tokens.add(entry.key);
      }
    }

    if (path.endsWith('.dart')) _addDartEdges(path, code, info);
    if (path.endsWith('.py')) _addPythonEdges(path, code, info);
    for (final match in _scriptPath.allMatches(text)) {
      info.edges.addAll(_resolveScript(match.group(1)!, path));
    }
    _addDirectoryAndNameEdges(code, info);
    info.edges.removeWhere((e) => e.endsWith('_test.dart') || e == path);
    return info;
  }

  void _addDartEdges(String path, String code, _FileInfo info) {
    for (final match in _directive.allMatches(code)) {
      for (final quoted in _quoted.allMatches(match.group(1)!)) {
        final uri = quoted.group(1)!;
        if (uri.startsWith('dart:')) continue;
        String local;
        if (uri.startsWith('package:')) {
          final slash = uri.indexOf('/');
          if (slash < 0) continue;
          final lib = packageRoots[uri.substring(8, slash)];
          if (lib == null) continue;
          local = p.posix.join(lib, uri.substring(slash + 1));
        } else if (uri.endsWith('.dart')) {
          local = p.posix.normalize(p.posix.join(p.posix.dirname(path), uri));
        } else {
          continue;
        }
        if (files.contains(local)) {
          info.edges.add(local);
        } else {
          info.tokens.add('unresolved $uri');
        }
      }
    }
  }

  void _addPythonEdges(String path, String code, _FileInfo info) {
    for (final match in _pyImport.allMatches(code)) {
      final names = <String>[];
      if (match.group(1) != null) {
        final base = match.group(1)!;
        names.add(base);
        for (final name in match.group(2)!.split(',')) {
          names.add('$base.${name.trim().split(' ').first}');
        }
      } else {
        for (final name in match.group(3)!.split(',')) {
          names.add(name.trim().split(' ').first);
        }
      }
      for (final name in names) {
        final rel = name.replaceAll(RegExp(r'^\.+'), '').replaceAll('.', '/');
        if (rel.isEmpty) continue;
        for (final candidate in ['$rel.py', '$rel/__init__.py']) {
          final sibling = p.posix.normalize(
            p.posix.join(p.posix.dirname(path), candidate),
          );
          if (files.contains(sibling)) info.edges.add(sibling);
          for (final f
              in _byBasename[p.posix.basename(candidate)] ?? const <String>[]) {
            if (f == candidate || f.endsWith('/$candidate')) info.edges.add(f);
          }
        }
      }
    }
  }

  /// A directory literal and a script name or glob given apart, as in
  /// `unittest discover -s test/ci -p test_x.py`.
  void _addDirectoryAndNameEdges(String code, _FileInfo info) {
    final literals = _quoted.allMatches(code).map((m) => m.group(1)!).toSet();
    final names = [
      for (final literal in literals)
        if (_bareScript.hasMatch(literal)) literal,
    ];
    if (names.isEmpty && literals.contains('discover')) names.add('test*.py');
    for (final dir in literals.where(_dirs.contains)) {
      for (final name in names) {
        final pattern = RegExp(
          '^${RegExp.escape(name).replaceAll(r'\*', '.*')}\$',
        );
        for (final f in _byDir[dir] ?? const <String>[]) {
          if (pattern.hasMatch(p.posix.basename(f))) info.edges.add(f);
        }
      }
    }
  }

  /// Tokens of [path] alone, empty for a file outside [files].
  Set<String> tokensOf(String path) =>
      files.contains(path) ? _analyze(path).tokens : const {};

  /// Everything [suite] can reach. Tokens of a path in [helpers] are not
  /// evidence, but its own imports and scripts are still followed.
  Reach reach(String suite, {Set<String> helpers = const {}}) {
    final result = Reach();
    final queue = [suite];
    while (queue.isNotEmpty) {
      final path = queue.removeLast();
      if (result.files.contains(path) || !files.contains(path)) continue;
      result.files.add(path);
      final info = _analyze(path);
      if (info.tokens.isNotEmpty && !helpers.contains(path)) {
        result.evidence[path] = info.tokens;
      }
      queue.addAll(info.edges.where((e) => !result.files.contains(e)));
    }
    return result;
  }
}

/// Tracked and untracked, not-ignored files under [root], as POSIX paths.
Set<String> repositoryFiles({String root = '.'}) {
  final listing = Process.runSync('git', [
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
  ], workingDirectory: root);
  if (listing.exitCode != 0) throw StateError('${listing.stderr}');
  return const LineSplitter()
      .convert(listing.stdout as String)
      .where((f) => File(p.join(root, f)).existsSync())
      .toSet();
}

/// Package name -> `lib` directory for every `pubspec.yaml` in [files]; the
/// shallowest pubspec wins a name.
Map<String, String> workspacePackageRoots(
  Set<String> files, {
  String root = '.',
}) {
  final pubspecs =
      files.where((f) => p.posix.basename(f) == 'pubspec.yaml').toList()
        ..sort((a, b) => a.split('/').length - b.split('/').length);
  final roots = <String, String>{};
  for (final pubspec in pubspecs) {
    final name = RegExp(
      r'^name:\s*([\w.]+)',
      multiLine: true,
    ).firstMatch(File(p.join(root, pubspec)).readAsStringSync())?.group(1);
    if (name == null) continue;
    final dir = p.posix.dirname(pubspec);
    roots.putIfAbsent(name, () => p.posix.normalize(p.posix.join(dir, 'lib')));
  }
  return roots;
}

final RegExp _tagsAnnotation = RegExp(r'@Tags\(\s*\[([^\]]*)\]');

bool _declaresTag(String root, String suite, String tag) {
  final source = File(p.join(root, suite)).readAsStringSync();
  final tags = _tagsAnnotation.firstMatch(source)?.group(1) ?? '';
  return RegExp('[\'"]${RegExp.escape(tag)}[\'"]').hasMatch(tags);
}

String _describe(Map<String, String> evidence) => evidence.isEmpty
    ? '(none)'
    : [for (final e in evidence.entries) '${e.key}: ${e.value}'].join('; ');

bool _sameEvidence(Map<String, String> a, Map<String, String> b) =>
    a.length == b.length &&
    a.entries.every((e) => b.containsKey(e.key) && b[e.key] == e.value);

/// Every way the reader inventory and its exemptions disagree with the tree.
///
/// A root suite that reaches Markdown evidence must be in [inventory] or
/// exempt. An exemption must still match the evidence it recorded, and a
/// helper's recorded tokens stand in for that helper in every suite.
List<String> readerProblems({
  required MarkdownReaders readers,
  required Set<String> inventory,
  required Map<String, Exemption> suiteExemptions,
  required Map<String, Exemption> helperExemptions,
}) {
  final problems = <String>[];
  final suites =
      readers.files
          .where((f) => f.startsWith('test/') && f.endsWith('_test.dart'))
          .toList()
        ..sort();

  final validHelpers = <String>{};
  for (final entry in helperExemptions.entries) {
    final path = entry.key;
    final exemption = entry.value;
    if (exemption.reason.trim().isEmpty) {
      problems.add('helper $path: exemption has no reason');
    }
    if (!readers.files.contains(path)) {
      problems.add('helper $path: no such file; remove or rename the entry');
      continue;
    }
    final current = {
      path: (readers.tokensOf(path).toList()..sort()).join(' | '),
    };
    if (readers.tokensOf(path).isEmpty) {
      problems.add('helper $path: names no Markdown; remove the exemption');
    } else if (!_sameEvidence(exemption.evidence, current)) {
      problems.add(
        'helper $path: evidence changed from ${_describe(exemption.evidence)} '
        'to ${_describe(current)}; re-check it and update the exemption',
      );
    }
    validHelpers.add(path);
  }

  final reachedHelpers = <String>{};
  for (final suite in suites) {
    final reach = readers.reach(suite, helpers: validHelpers);
    reachedHelpers.addAll(reach.files.where(validHelpers.contains));
    final actual = reach.recorded;
    final exemption = suiteExemptions[suite];
    if (inventory.contains(suite)) {
      if (exemption != null) {
        problems.add('$suite: listed in the inventory and exempt');
      }
    } else if (exemption != null) {
      if (!_sameEvidence(exemption.evidence, actual)) {
        problems.add(
          '$suite: evidence changed from ${_describe(exemption.evidence)} '
          'to ${_describe(actual)}; re-check it and update the exemption, or '
          'list the suite in the inventory',
        );
      }
    } else if (actual.isNotEmpty) {
      problems.add(
        '$suite: reaches ${_describe(actual)}; list it in the inventory or '
        'exempt it with the evidence',
      );
    }
  }

  for (final entry in suiteExemptions.entries) {
    final suite = entry.key;
    final exemption = entry.value;
    if (!suites.contains(suite)) {
      problems.add('$suite: exempt but not a root test suite');
      continue;
    }
    if (exemption.reason.trim().isEmpty) {
      problems.add('$suite: exemption has no reason');
    }
    if (exemption.evidence.isEmpty) {
      problems.add('$suite: exemption records no evidence; remove it');
    }
    final gate = exemption.gate;
    if (gate != null && !_declaresTag(readers.root, suite, gate)) {
      problems.add('$suite: exempt behind the $gate tag, which it lacks');
    }
  }

  for (final helper in validHelpers.difference(reachedHelpers)) {
    problems.add('helper $helper: no suite reaches it; remove the exemption');
  }
  return problems;
}
