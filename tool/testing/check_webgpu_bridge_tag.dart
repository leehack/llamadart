// Fails when a place that pins the WebGPU bridge asset tag drifts from the
// default in scripts/fetch_webgpu_bridge_assets.sh.
//
// Only sites that pin the tag in use are listed. Capability floors
// (`v0.1.30+ bridge assets opt into ...`) and changelog entries naming past
// releases legitimately hold older values and are deliberately absent, as is
// website/versioned_docs/**, which is a frozen archive.

import 'dart:io';

/// The file whose default decides what a fresh vendoring run downloads.
const String bridgeTagSourcePath = 'scripts/fetch_webgpu_bridge_assets.sh';

// Bash allows leading whitespace, an `export`/`readonly` prefix, and `+=`
// appends, so a narrower pattern would let a later override slip past the
// guard below.
final RegExp _anyAssignment = RegExp(
  r'^[ \t]*(?:export[ \t]+|readonly[ \t]+)?ASSETS_TAG\+?=',
  multiLine: true,
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

void main() {
  final repoRoot = Directory.current;
  final String expectedTag;
  try {
    expectedTag = readPinnedBridgeTag(repoRoot);
  } on FormatException catch (error) {
    stderr.writeln('[webgpu-bridge-tag] ${error.message}');
    exit(1);
  }

  final problems = findBridgeTagDrift(repoRoot, expectedTag);
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
