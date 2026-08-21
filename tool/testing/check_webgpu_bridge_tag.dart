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
  r'(?<![A-Za-z0-9_])ASSETS_TAG(?:\[\d+\])?(?::=|\+?=)',
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
  final source = file.readAsStringSync();
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
    final matches = pin.pattern.allMatches(file.readAsStringSync()).toList();
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

/// Machine-readable ways of writing a pin, whatever value it holds.
///
/// Scanning for these as well as for the current tag is what catches a newly
/// added pin that is already stale; searching only for the expected value
/// would never look at it.
final List<RegExp> bridgeTagPinShapes = <RegExp>[
  RegExp(r'llama-web-bridge-assets@v\d+\.\d+\.\d+'),
  RegExp('BridgeAssetsTag\\s*=\\s*[\'"]?v\\d+\\.\\d+\\.\\d+[\'"]?'),
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
  var at = line.indexOf(expectedTag);
  while (at >= 0) {
    final after = at + expectedTag.length;
    final isFloor = after < line.length && line[after] == '+';
    if (!isFloor && !found.any((other) => other.at == at)) {
      found.add(_PinOccurrence(at, expectedTag));
    }
    at = line.indexOf(expectedTag, at + 1);
  }
  return found;
}

void main() {
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

  stdout.writeln(
    '[webgpu-bridge-tag] OK: ${bridgeTagPins.length} pins agree on $expectedTag.',
  );
}
