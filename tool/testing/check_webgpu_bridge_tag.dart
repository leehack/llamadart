// Fails when a place that pins the WebGPU bridge asset tag drifts from the
// default in scripts/fetch_webgpu_bridge_assets.sh.
//
// Only sites that pin the tag in use are listed. Capability floors
// (`v0.1.30+ bridge assets opt into ...`) and changelog entries naming past
// releases legitimately hold older values and are deliberately absent, as is
// website/versioned_docs/**, which is a frozen archive.

import 'dart:convert';
import 'dart:io';

/// The file whose default decides what a fresh vendoring run downloads.
const String bridgeTagSourcePath = 'scripts/fetch_webgpu_bridge_assets.sh';

// Any assignment to the name, wherever it sits: indented, after `export` or
// `declare`, after a `;`, appending with `+=`, or defaulting with `${x:=y}`.
// Enumerating prefixes kept missing forms, so this matches the identifier
// itself and relies on the lookbehind to exclude longer names such as
// `WEBGPU_BRIDGE_ASSETS_TAG=`.
final RegExp _anyAssignment = RegExp(
  r'(?<![A-Za-z0-9_])ASSETS_TAG(?:\[[^\]]*\])?(?::=|\+?=)',
);

final RegExp _sourceOfTruth = RegExp(
  r'^ASSETS_TAG="\$\{WEBGPU_BRIDGE_ASSETS_TAG:-(v\d+\.\d+\.\d+)\}"$',
  multiLine: true,
);

/// A place that must quote the tag from [bridgeTagSourcePath].
class BridgeTagPin {
  /// Repository-relative path.
  final String path;

  /// Matches the pin and nothing else in [path]; group 1 is the tag.
  final RegExp pattern;

  /// Creates a pin site.
  const BridgeTagPin(this.path, this.pattern);
}

/// Every site that mirrors the pinned tag.
final List<BridgeTagPin> bridgeTagPins = <BridgeTagPin>[
  BridgeTagPin(
    bridgeTagSourcePath,
    RegExp(
      r'^\s*https://cdn\.jsdelivr\.net/gh/leehack/llama-web-bridge-assets@(v\d+\.\d+\.\d+)$',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    bridgeTagSourcePath,
    RegExp(
      r'^\s*WEBGPU_BRIDGE_ASSETS_TAG=(v\d+\.\d+\.\d+) \./scripts/fetch_webgpu_bridge_assets\.sh$',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'example/chat_app/web/index.html',
    RegExp(
      r"^\s*const defaultBridgeAssetsTag = '(v\d+\.\d+\.\d+)';$",
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'README.md',
    RegExp(
      r'^\| Web llama\.cpp / GGUF \| `leehack/llama-web-bridge-assets@(v\d+\.\d+\.\d+)` \|$',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'doc/webgpu_bridge.md',
    RegExp(
      r'^Default pinned tag in the example is `(v\d+\.\d+\.\d+)`\.$',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'doc/webgpu_bridge.md',
    RegExp(
      r'^WEBGPU_BRIDGE_ASSETS_TAG=(v\d+\.\d+\.\d+) \./scripts/fetch_webgpu_bridge_assets\.sh$',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'doc/webgpu_bridge.md',
    RegExp(
      r"^\s*window\.__llamadartBridgeAssetsTag = '(v\d+\.\d+\.\d+)';$",
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/platforms/webgpu-bridge.md',
    RegExp(
      r'^The example currently pins bridge assets to `(v\d+\.\d+\.\d+)`,',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/platforms/webgpu-bridge.md',
    RegExp(r'^identified as `(v\d+\.\d+\.\d+)-local-b\d+`\.$', multiLine: true),
  ),
  BridgeTagPin(
    'website/docs/platforms/webgpu-bridge.md',
    RegExp(
      r'^WEBGPU_BRIDGE_ASSETS_TAG=(v\d+\.\d+\.\d+) \./scripts/fetch_webgpu_bridge_assets\.sh$',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/platforms/webgpu-bridge.md',
    RegExp(
      r"^\s*window\.__llamadartBridgeAssetsTag = '(v\d+\.\d+\.\d+)';$",
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/guides/text-to-speech.md',
    RegExp(r'^- The chat example pins `(v\d+\.\d+\.\d+)`,', multiLine: true),
  ),
];

/// Reads the tag every pin must quote.
///
/// Throws [FormatException] when the default is missing, so a rename of the
/// source of truth fails loudly instead of disabling the gate.
String readPinnedBridgeTag(Directory repoRoot) {
  final file = File('${repoRoot.path}/$bridgeTagSourcePath');
  if (!file.existsSync()) {
    throw FormatException('Missing $bridgeTagSourcePath');
  }
  late final String source;
  try {
    source = file.readAsStringSync();
  } on FileSystemException catch (error) {
    throw FormatException('$bridgeTagSourcePath could not be read: $error');
  } on FormatException catch (error) {
    throw FormatException('$bridgeTagSourcePath could not be decoded: $error');
  }
  // Bash takes the last assignment, so a second one would leave this gate
  // validating a tag the script never downloads.
  final assignments = _anyAssignment.allMatches(source).length;
  if (assignments != 1) {
    throw FormatException(
      'Expected exactly one ASSETS_TAG assignment in $bridgeTagSourcePath, '
      'found $assignments; the gate cannot run.',
    );
  }
  final match = _sourceOfTruth.firstMatch(source);
  if (match == null) {
    throw FormatException(
      'No ASSETS_TAG default in $bridgeTagSourcePath; the gate cannot run.',
    );
  }
  return match.group(1)!;
}

/// Returns one message per pin that drifted, or whose pattern stopped matching.
///
/// A pattern that matches nothing is a failure, not a skip: silently matching
/// zero lines would turn this gate into a no-op.
List<String> findBridgeTagDrift(Directory repoRoot, String expectedTag) {
  final problems = <String>[];
  for (final pin in bridgeTagPins) {
    final file = File('${repoRoot.path}/${pin.path}');
    if (!file.existsSync()) {
      problems.add('${pin.path}: file is missing');
      continue;
    }
    final contents = _readGateFile(file, pin.path, problems);
    if (contents == null) continue;
    final matches = pin.pattern.allMatches(contents).toList();
    if (matches.length != 1) {
      problems.add(
        '${pin.path}: ${pin.pattern.pattern} matches ${matches.length} lines, '
        'expected 1 — the pin moved, was reworded, or was duplicated, so this '
        'check no longer covers exactly one site',
      );
      continue;
    }
    final found = matches.single.group(1)!;
    if (found != expectedTag) {
      problems.add('${pin.path}: pins $found, expected $expectedTag');
    }
  }
  return problems;
}

/// The llama.cpp build embedded in the pinned bridge assets.
///
/// Taken from `llama_cpp_tag` in the `manifest.json` published under the tag
/// [bridgeTagSourcePath] pins. `--verify-manifest` re-reads the published
/// manifest and fails when this record no longer matches it.
const String bridgeLlamaCppTag = 'b10514';

/// Where the native runtime's llama.cpp build is pinned.
const String nativeLlamaCppTagPath = 'hook/build.dart';

final RegExp _nativeLlamaCppTag = RegExp(r"const _llamaCppTag = '([^']+)';");

/// Why Web deliberately runs a different llama.cpp build from native, or null
/// when the two must agree.
///
/// Set this only alongside docs that say so; clear it once the bridge assets
/// catch up. The gate fails both ways: an unrecorded divergence, and a record
/// left behind after the tags converged. Prose describing the relationship
/// lives in the [bridgeLlamaCppTagPins] sentences, which move with it.
String? get bridgeLlamaCppDivergence =>
    'Bridge assets v0.1.37 embed b10514; the native pin moved to b10545 after '
    'v0.8.20. Web trails native until the next bridge asset release.';

/// Doc sentences that state the bridge assets' llama.cpp build.
///
/// Anchored on the surrounding wording so a reworded parity claim fails here
/// instead of quietly outliving the pin it describes.
final List<BridgeTagPin> bridgeLlamaCppTagPins = <BridgeTagPin>[
  BridgeTagPin(
    'doc/webgpu_bridge.md',
    RegExp(
      r'^That release embeds llama\.cpp `(b\d+)`, which now trails the '
      r'`hook/build\.dart`$',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/platforms/webgpu-bridge.md',
    RegExp(
      r'^- `v\d+\.\d+\.\d+\+` bridge assets embed llama\.cpp `(b\d+)`, which now trails the$',
      multiLine: true,
    ),
  ),
];

/// Returns one message per problem with the Web/native llama.cpp relationship.
///
/// `hook/build.dart` and the bridge manifest move in different repositories, so
/// nothing else notices when a native pin bump silently ends Web/native parity
/// and leaves the docs claiming it.
List<String> findBridgeRuntimeDrift(
  Directory repoRoot,
  String bridgeTag,
  String? divergence,
) {
  final problems = <String>[];
  final file = File('${repoRoot.path}/$nativeLlamaCppTagPath');
  if (!file.existsSync()) {
    return <String>['$nativeLlamaCppTagPath: file is missing'];
  }
  final nativeContents = _readGateFile(file, nativeLlamaCppTagPath, problems);
  if (nativeContents == null) return problems;
  final match = _nativeLlamaCppTag.firstMatch(nativeContents);
  if (match == null) {
    return <String>[
      '$nativeLlamaCppTagPath: no _llamaCppTag constant; the gate cannot run',
    ];
  }

  final nativeTag = match.group(1)!;
  if (nativeTag == bridgeTag) {
    if (divergence != null) {
      problems.add(
        'bridgeLlamaCppDivergence records a divergence, but the bridge assets '
        'and $nativeLlamaCppTagPath both use $nativeTag — clear the record and '
        'restore the parity wording in the docs, then update the anchored '
        'bridgeLlamaCppTagPins patterns with the wording',
      );
    }
  } else if (divergence == null) {
    problems.add(
      'bridge assets embed llama.cpp $bridgeTag but $nativeLlamaCppTagPath '
      'pins $nativeTag — move the bridge asset pin, or set '
      'bridgeLlamaCppDivergence and say so in the docs',
    );
  }

  for (final pin in bridgeLlamaCppTagPins) {
    final doc = File('${repoRoot.path}/${pin.path}');
    if (!doc.existsSync()) {
      problems.add('${pin.path}: file is missing');
      continue;
    }
    final contents = _readGateFile(doc, pin.path, problems);
    if (contents == null) continue;
    final matches = pin.pattern.allMatches(contents).toList();
    if (matches.length != 1) {
      problems.add(
        '${pin.path}: ${pin.pattern.pattern} matches ${matches.length} lines, '
        'expected 1 — the sentence describing the bridge llama.cpp build was '
        'reworded or removed, so this check no longer covers it',
      );
      continue;
    }
    final found = matches.single.group(1)!;
    if (found != bridgeTag) {
      problems.add('${pin.path}: states $found, expected $bridgeTag');
    }
  }
  return problems;
}

String? _readGateFile(File file, String path, List<String> problems) {
  try {
    return file.readAsStringSync();
  } on FileSystemException catch (error) {
    problems.add('$path: could not be read: $error');
  } on FormatException catch (error) {
    problems.add('$path: could not be decoded as UTF-8 text: $error');
  }
  return null;
}

/// Re-reads the published manifest for [expectedTag] and returns one message
/// when [bridgeLlamaCppTag] no longer matches it.
///
/// Network-dependent, so it is opt-in rather than part of the default run.
Future<List<String>> verifyManifestLlamaCppTag(
  String expectedTag,
  String bridgeTag, {
  Uri? manifestUrl,
}) async {
  final url =
      manifestUrl ??
      Uri.parse(
        'https://cdn.jsdelivr.net/gh/leehack/llama-web-bridge-assets@$expectedTag'
        '/manifest.json',
      );
  final client = HttpClient();
  try {
    final response = await client
        .getUrl(url)
        .then((request) => request.close());
    if (response.statusCode != 200) {
      return <String>['$url returned HTTP ${response.statusCode}'];
    }
    final body = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      return <String>[
        '$url returned invalid manifest JSON: expected an object',
      ];
    }
    final manifestTag = decoded['llama_cpp_tag'];
    if (manifestTag is! String || manifestTag.isEmpty) {
      return <String>[
        '$url returned invalid manifest JSON: llama_cpp_tag must be a '
            'non-empty string',
      ];
    }
    if (manifestTag != bridgeTag) {
      return <String>[
        '$url reports llama_cpp_tag $manifestTag, but bridgeLlamaCppTag is '
            '$bridgeTag',
      ];
    }
    return <String>[];
  } on IOException catch (error) {
    return <String>['could not read $url: $error'];
  } on FormatException catch (error) {
    return <String>['$url returned invalid manifest JSON: $error'];
  } finally {
    client.close();
  }
}

/// Machine-readable ways of writing a pin, whatever value it holds.
///
/// Scanning for these as well as for the current tag is what catches a newly
/// added pin that is already stale; searching only for the expected value
/// would never look at it.
final List<RegExp> bridgeTagPinShapes = <RegExp>[
  RegExp(r'llama-web-bridge-assets@v\d+\.\d+\.\d+'),
  // Backticks only in the JS form; in shell they would be command substitution.
  RegExp('BridgeAssetsTag\\s*=\\s*[\'"`]?v\\d+\\.\\d+\\.\\d+[\'"`]?'),
  RegExp('WEBGPU_BRIDGE_ASSETS_TAG=[\'"]?v\\d+\\.\\d+\\.\\d+[\'"]?'),
  RegExp('ASSETS_TAG:-[\'"]?v\\d+\\.\\d+\\.\\d+[\'"]?'),
];

/// This gate's own sources, whose fixtures are deliberately not real pins.
const List<String> _selfPaths = <String>[
  'tool/testing/check_webgpu_bridge_tag.dart',
  'test/unit/tooling/check_webgpu_bridge_tag_test.dart',
];

/// Files that record past releases, where an old tag is correct.
const List<String> tagHistoryFiles = <String>[
  'CHANGELOG.md',
  'website/docs/changelog/recent-releases.md',
];

/// Frozen documentation snapshots.
const String versionedDocsPrefix = 'website/versioned_docs/';

/// Returns one message per live occurrence of [expectedTag] that no pin covers.
///
/// Without this the gate would only protect sites someone remembered to
/// register, so a newly added pin could go stale while CI stayed green.
/// Capability floors (`v0.1.37+`) and the release histories are excluded
/// because they legitimately keep their own values.
List<String> findUnregisteredTagSites(Directory repoRoot, String expectedTag) {
  final listed = Process.runSync('git', <String>[
    'ls-files',
  ], workingDirectory: repoRoot.path);
  if (listed.exitCode != 0) {
    return <String>['git ls-files failed: ${listed.stderr}'];
  }

  final registered = <String, List<RegExp>>{
    // The source of truth is checked by readPinnedBridgeTag, not by a pin.
    bridgeTagSourcePath: <RegExp>[_sourceOfTruth],
  };
  for (final pin in bridgeTagPins) {
    registered.putIfAbsent(pin.path, () => <RegExp>[]).add(pin.pattern);
  }

  final unregistered = <String>[];
  for (final path in const LineSplitter().convert(listed.stdout as String)) {
    if (path.isEmpty ||
        path.startsWith(versionedDocsPrefix) ||
        tagHistoryFiles.contains(path) ||
        _selfPaths.contains(path)) {
      continue;
    }
    final file = File('${repoRoot.path}/$path');
    if (!file.existsSync()) continue;
    final String contents;
    try {
      contents = file.readAsStringSync();
    } on FileSystemException {
      continue; // Binary asset: this SDK reports a failed decode this way.
    } on FormatException {
      continue; // Binary asset, if a future SDK reports it as a decode error.
    }
    final patterns = registered[path] ?? const <RegExp>[];
    var lineNumber = 0;
    for (final line in const LineSplitter().convert(contents)) {
      lineNumber++;
      // Cover each occurrence, not the line: a registered pin whose pattern is
      // not end-anchored would otherwise mask a second pin appended to it.
      final covered = <List<int>>[
        for (final pattern in patterns)
          for (final match in pattern.allMatches(line))
            [match.start, match.end],
      ];
      bool isCovered(int at) =>
          covered.any((span) => at >= span[0] && at < span[1]);

      for (final occurrence in _pinOccurrences(line, expectedTag)) {
        if (isCovered(occurrence.at)) continue;
        unregistered.add(
          '$path:$lineNumber: ${occurrence.what} is not covered by any '
          'registered pin — add it to bridgeTagPins, or to tagHistoryFiles if '
          'it records a past release',
        );
      }
    }
  }
  return unregistered;
}

/// One pin-like thing found on a line.
class _PinOccurrence {
  /// Offset into the line.
  final int at;

  /// How to describe it in a failure message.
  final String what;

  const _PinOccurrence(this.at, this.what);
}

/// Every pin shape, plus every mention of [expectedTag] that is not a
/// `v0.1.37+` minimum.
List<_PinOccurrence> _pinOccurrences(String line, String expectedTag) {
  final found = <_PinOccurrence>[];
  for (final shape in bridgeTagPinShapes) {
    for (final match in shape.allMatches(line)) {
      found.add(_PinOccurrence(match.start, 'a bridge asset pin'));
    }
  }
  // A whole version token: without the lookahead, a `v0.1.3` tag would match
  // inside every `v0.1.30+` floor and report it as an unregistered pin.
  final token = RegExp('${RegExp.escape(expectedTag)}(?![0-9.])');
  for (final match in token.allMatches(line)) {
    final after = match.end;
    final isFloor = after < line.length && line[after] == '+';
    if (isFloor) continue;
    if (found.any((other) => other.at == match.start)) continue;
    found.add(_PinOccurrence(match.start, expectedTag));
  }
  return found;
}

Future<void> main(List<String> arguments) async {
  final verifyManifest = arguments.contains('--verify-manifest');
  final unknown = arguments.where(
    (argument) => argument != '--verify-manifest',
  );
  if (unknown.isNotEmpty) {
    stderr.writeln(
      '[webgpu-bridge-tag] Unknown argument(s): ${unknown.join(', ')}. '
      'Usage: check_webgpu_bridge_tag.dart [--verify-manifest]',
    );
    exit(64);
  }

  final repoRoot = Directory.current;
  final String expectedTag;
  try {
    expectedTag = readPinnedBridgeTag(repoRoot);
  } on FormatException catch (error) {
    stderr.writeln('[webgpu-bridge-tag] ${error.message}');
    exit(1);
  }

  final problems = <String>[
    ...findBridgeTagDrift(repoRoot, expectedTag),
    ...findUnregisteredTagSites(repoRoot, expectedTag),
    ...findBridgeRuntimeDrift(
      repoRoot,
      bridgeLlamaCppTag,
      bridgeLlamaCppDivergence,
    ),
    if (verifyManifest)
      ...await verifyManifestLlamaCppTag(expectedTag, bridgeLlamaCppTag),
  ];
  if (problems.isNotEmpty) {
    stderr.writeln(
      '[webgpu-bridge-tag] $bridgeTagSourcePath pins $expectedTag, but:',
    );
    for (final problem in problems) {
      stderr.writeln('  - $problem');
    }
    exit(1);
  }

  final divergence = bridgeLlamaCppDivergence;
  stdout.writeln(
    '[webgpu-bridge-tag] OK: ${bridgeTagPins.length} pins agree on $expectedTag.',
  );
  if (divergence == null) {
    stdout.writeln(
      '[webgpu-bridge-tag] OK: Web and native both run llama.cpp '
      '$bridgeLlamaCppTag.',
    );
  } else {
    stdout.writeln(
      '[webgpu-bridge-tag] Recorded divergence: bridge assets embed '
      '$bridgeLlamaCppTag. $divergence',
    );
  }
}
