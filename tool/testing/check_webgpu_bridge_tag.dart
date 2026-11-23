// Fails when a place that pins the WebGPU bridge asset tag drifts from the
// default in scripts/fetch_webgpu_bridge_assets.sh.
//
// Only sites that pin the tag in use are listed. Capability floors
// (`v0.1.30+ bridge assets opt into ...`) and changelog entries naming past
// releases legitimately hold older values and are deliberately absent, as is
// website/versioned_docs/**, which is a frozen archive.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:html/dom.dart' as html;
import 'package:html/parser.dart' as html_parser;
import 'package:llamadart/src/hook/native_bundle_config.dart';
import 'package:llamadart/src/web_setup/web_bridge_setup.dart';
import 'package:markdown/markdown.dart' as md;

/// The file whose default decides what a fresh vendoring run downloads.
import '../release/pr_changelog.dart';
import 'check_released_changelog_sections.dart';
import 'release_note_case_folding.dart';

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
    'packages/llamadart_studio/web/index.html',
    RegExp(
      r"^\s*const defaultBridgeAssetsTag = '(v\d+\.\d+\.\d+)';$",
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'lib/src/web_setup/web_bridge_setup.dart',
    RegExp(
      r"^const String webBridgeAssetsTag = '(v\d+\.\d+\.\d+)';$",
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
    'doc/webgpu_bridge.md',
    RegExp(
      r'^even though the bridge asset tag `(v\d+\.\d+\.\d+)` differs from the '
      r'native runtime tag$',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/platforms/webgpu-bridge.md',
    RegExp(
      r'^This llamadart version pins bridge assets `(v\d+\.\d+\.\d+)`, which',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/platforms/webgpu-bridge.md',
    RegExp(
      r'^- The pinned `(v\d+\.\d+\.\d+)` bridge assets embed llama\.cpp ',
      multiLine: true,
    ),
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
];

/// Release-notes files whose current section restates the pinned tag.
///
/// An unchanged baseline names its prior release explicitly, without repeating
/// the features that shipped with the original alignment.
///
/// The patterns are matched against [currentReleaseNotesSection] alone, so the
/// frozen sections below it keep the tags their releases shipped.
final List<BridgeTagPin> releaseNotesPins = <BridgeTagPin>[
  BridgeTagPin(
    'CHANGELOG.md',
    RegExp(
      r'^[*-] (?:Aligned the default WebGPU bridge assets to|Keep the default '
      r'WebGPU bridge assets at(?= `v\d+\.\d+\.\d+` '
      r'\(unchanged from \d+\.\d+\.\d+\)\.\r?$)) `(v\d+\.\d+\.\d+)`',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/changelog/recent-releases.md',
    RegExp(
      r'^- (?:Aligned default WebGPU bridge assets to|Keep default WebGPU '
      r'bridge assets at(?= `v\d+\.\d+\.\d+` '
      r'\(unchanged from \d+\.\d+\.\d+\)\.\r?$)) `(v\d+\.\d+\.\d+)`',
      multiLine: true,
    ),
  ),
];

/// The pubspec whose version names the section a release-prep tree promotes.
const String rootPubspecPath = 'pubspec.yaml';

final RegExp _rootPubspecVersion = RegExp(
  r'^version:\s*(\S+)\s*$',
  multiLine: true,
);

final RegExp _topReleaseNotesSection = RegExp(
  r'^## (?<heading>.*?)\s*$(?<body>(?:(?!^## ).)*)',
  multiLine: true,
  dotAll: true,
);

/// Reads the version the root package will publish.
///
/// Throws [FormatException] when it is missing or duplicated, so the gate
/// cannot fall back to accepting any release-notes heading it finds.
String readRootPackageVersion(Directory repoRoot) {
  final file = File('${repoRoot.path}/$rootPubspecPath');
  if (!file.existsSync()) {
    throw FormatException('Missing $rootPubspecPath');
  }
  final String source;
  try {
    source = file.readAsStringSync();
  } on FileSystemException catch (error) {
    throw FormatException('$rootPubspecPath could not be read: $error');
  } on FormatException catch (error) {
    throw FormatException('$rootPubspecPath could not be decoded: $error');
  }
  final matches = _rootPubspecVersion.allMatches(source).toList();
  if (matches.length != 1) {
    throw FormatException(
      'Expected exactly one version field in $rootPubspecPath, found '
      '${matches.length}; the gate cannot identify the current release-notes '
      'section.',
    );
  }
  return matches.single.group(1)!;
}

/// The current bridge-pin announcement section of [contents].
///
/// Ordinary development leaves the top section headed `## Unreleased`; a
/// release-prep change promotes that same section to `## $releaseVersion`.
/// Pin-free Unreleased notes use only the immediately following exact current
/// release. A recognizable (even malformed) pin bullet prevents fallback.
String? currentReleaseNotesSection(String contents, String releaseVersion) {
  final match = _topReleaseNotesSection.firstMatch(contents);
  if (match == null) return null;
  final heading = match.namedGroup('heading');
  if (heading != 'Unreleased' && heading != releaseVersion) return null;
  final body = match.namedGroup('body')!;
  if (heading != 'Unreleased' || _bridgePinBullet.hasMatch(body)) return body;
  final released = _topReleaseNotesSection.firstMatch(
    contents.substring(match.end),
  );
  if (released?.namedGroup('heading') != releaseVersion) return null;
  return released!.namedGroup('body');
}

// Ambiguous/reworded pin bullets must fail the exact canonical claim check,
// not silently borrow a historical value. Ordinary prose is not a pin site.
final RegExp _bridgePinBullet = RegExp(
  r'^[*-]\s+[^\n]*(?:WebGPU bridge assets|default WebGPU)[^\n]*$',
  multiLine: true,
);

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

/// Returns one message per [releaseNotesPins] site whose current section
/// drifted, lost its claim, or sits under an unrecognized heading.
List<String> findCurrentReleaseNotesDrift(
  Directory repoRoot,
  String expectedTag,
) {
  final String releaseVersion;
  try {
    releaseVersion = readRootPackageVersion(repoRoot);
  } on FormatException catch (error) {
    return <String>[error.message];
  }

  final problems = <String>[];
  for (final pin in releaseNotesPins) {
    final file = File('${repoRoot.path}/${pin.path}');
    if (!file.existsSync()) {
      problems.add('${pin.path}: file is missing');
      continue;
    }
    final contents = _readGateFile(file, pin.path, problems);
    if (contents == null) continue;
    final section = currentReleaseNotesSection(contents, releaseVersion);
    if (section == null) {
      problems.add(
        '${pin.path}: the top section is neither `## Unreleased` nor '
        '`## $releaseVersion`, so the gate cannot tell the current release '
        'notes from frozen history',
      );
      continue;
    }
    final matches = pin.pattern.allMatches(section).toList();
    if (matches.length == 1 &&
        _bridgePinBullet.allMatches(section).length != 1) {
      problems.add(
        '${pin.path}: ambiguous or malformed additional bridge pin bullet',
      );
      continue;
    }
    if (matches.length != 1) {
      problems.add(
        '${pin.path}: ${pin.pattern.pattern} matches ${matches.length} lines in '
        'the current release-notes section, expected 1 — the pin moved, was '
        'reworded, or was duplicated, so this check no longer covers exactly '
        'one site',
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

/// The llama.cpp upstream release tag embedded in the pinned bridge assets.
const String bridgeLlamaCppTag = 'v1.0.0';

/// The exact upstream llama.cpp commit embedded in the pinned bridge assets.
const String bridgeLlamaCppCommit = 'b1b770d90d94cad9e9ea5b993bdbc383a522fb28';

/// The exact bridge source commit used to build the pinned bridge assets.
const String bridgeSourceCommit = 'd7236223d2393d51dab541df6caf3ef88f06d49b';

/// Canonical repository identities recorded in the approved manifest.
const String bridgeAssetsRepository = 'leehack/llama-web-bridge-assets';
const String bridgeSourceRepository = 'leehack/llama-web-bridge';
const String bridgeUpstreamRepository = 'ggml-org/llama.cpp';
const String bridgeNativeRepository = 'leehack/llamadart-native';

/// The native release tag the pinned bridge assets were qualified against.
const String bridgeNativeReleaseTag = 'v1.0.0-4';

/// The native pin approved beside the pinned bridge assets.
const String bridgeApprovedNativePin = 'v1.0.0-4';

/// The asset repository release that published the pinned bridge assets.
const String bridgeAssetsReleaseId = '454541989';

/// The asset repository commit the pinned bridge asset tag points at.
const String bridgeAssetsTagCommit = '056f474f389feaa4e02a62a3125549cb9154fabf';

/// SHA-256 hash of the exact approved published manifest.json.
///
/// `dart run llamadart:web_setup` trusts the assets this manifest lists, so
/// the value lives with that tool and `--verify-manifest` checks it here.
const String bridgeManifestSha256 = webBridgeManifestSha256;

/// Where the native runtime's llama.cpp build is pinned.
const String nativeLlamaCppTagPath = 'lib/src/hook/native_release_pins.dart';

final RegExp _nativeLlamaCppTag = RegExp(r"const llamaCppTag = '([^']+)';");

/// Every site that names the llama.cpp build the bridge assets embed.
///
/// The doc sentences are anchored on their parity wording so a reworded claim
/// fails here instead of outliving the pin it describes. The chat bootstrap
/// constant is included because it feeds the user-visible local build id, so a
/// stale value there misreports the running build in every browser console.
final List<BridgeTagPin> bridgeLlamaCppParityPins = <BridgeTagPin>[
  BridgeTagPin(
    'example/chat_app/web/index.html',
    RegExp(
      r"^\s*const defaultBridgeLlamaCppTag = '(v\d+\.\d+\.\d+|b\d+)';$",
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'packages/llamadart_studio/web/index.html',
    RegExp(
      r"^\s*const defaultBridgeLlamaCppTag = '(v\d+\.\d+\.\d+|b\d+)';$",
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'doc/webgpu_bridge.md',
    RegExp(
      r'^That release embeds llama\.cpp `(v\d+\.\d+\.\d+|b\d+)`, matching the '
      r'`hook/build\.dart` native pin$',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/platforms/webgpu-bridge.md',
    RegExp(
      r'^- The pinned `v\d+\.\d+\.\d+` bridge assets embed llama\.cpp '
      r'`(v\d+\.\d+\.\d+|b\d+)`, matching the '
      r'native runtime `(?<nativePin>[^`]+)`\.$',
      multiLine: true,
    ),
  ),
];

/// The provenance values the docs restate for the pinned immutable release.
///
/// Each pattern matches one passage. [bridgeProvenanceValues] checks the
/// recorded values and whether native and Web share an upstream release.
final List<BridgeTagPin> bridgeProvenancePins = <BridgeTagPin>[
  BridgeTagPin(
    'doc/webgpu_bridge.md',
    RegExp(
      r'^\(`(?<nativePin>[^`]+)`, both '
      r'built from upstream llama\.cpp '
      r'`(?<upstreamTag>[^`@]+)@(?<upstreamCommit>[0-9a-f]{40})`\)\r?\n'
      r'even though the bridge asset tag `v\d+\.\d+\.\d+` differs from the '
      r'native runtime tag\r?\n'
      r'`(?<nativeRuntimeTag>[^`]+)`\. Provenance for this immutable consumer artifact: '
      r'release `(?<releaseId>\d+)`,\r?\n'
      r'tag commit `(?<tagCommit>[0-9a-f]{40})`, bridge source\r?\n'
      r'`(?<bridgeCommit>[0-9a-f]{40})`, and manifest SHA-256\r?\n'
      r'`(?<manifestSha256>[0-9a-f]{64})`\.',
      multiLine: true,
    ),
  ),
];

/// The expected value behind each [bridgeProvenancePins] group name.
Map<String, String> get bridgeProvenanceValues => <String, String>{
  'nativePin': bridgeApprovedNativePin,
  'upstreamTag': bridgeLlamaCppTag,
  'upstreamCommit': bridgeLlamaCppCommit,
  'nativeRuntimeTag': bridgeApprovedNativePin,
  'releaseId': bridgeAssetsReleaseId,
  'tagCommit': bridgeAssetsTagCommit,
  'bridgeCommit': bridgeSourceCommit,
  'manifestSha256': bridgeManifestSha256,
};

final RegExp _runtimeBaselineParagraph = RegExp(
  r'^Runtime baseline[^\n]*$',
  multiLine: true,
);

/// The runtime tags a `Runtime baseline:` paragraph states, each read from the
/// source that pins it. A missing group fails, so a reworded paragraph cannot
/// disable the check.
final _runtimeBaselineClaims = [
  (
    label: 'native llama.cpp',
    wording: 'native llama.cpp',
    source: _nativeLlamaCppTag,
  ),
  (
    label: 'native LiteRT-LM',
    wording: 'native LiteRT-LM uses',
    source: RegExp(r"const liteRtLmReleaseTag = '([^']+)';"),
  ),
  (
    label: 'stable-diffusion',
    wording: 'stable-diffusion uses',
    source: RegExp(r"const stableDiffusionReleaseTag = '([^']+)';"),
  ),
];

/// Returns one message per runtime tag in the current release notes'
/// `Runtime baseline:` paragraph that differs from the pinned runtime.
///
/// Only the top section is read: `## Unreleased` or the `## $releaseVersion`
/// that release prep promotes it to. A released section that
/// [currentReleaseNotesSection] falls back to is frozen and keeps the tags it
/// shipped with, so a mid-cycle pin bump must not fail against it. A top
/// section without the paragraph is skipped: Unreleased carries it only once
/// release prep has written it.
List<String> findRuntimeBaselineDrift(Directory repoRoot) {
  final String releaseVersion;
  try {
    releaseVersion = readRootPackageVersion(repoRoot);
  } on FormatException catch (error) {
    return <String>[error.message];
  }
  final problems = <String>[];
  final pinsFile = File('${repoRoot.path}/$nativeLlamaCppTagPath');
  if (!pinsFile.existsSync()) {
    return <String>['$nativeLlamaCppTagPath: file is missing'];
  }
  final pins = _readGateFile(pinsFile, nativeLlamaCppTagPath, problems);
  if (pins == null) return problems;
  final expected = <String, String>{};
  for (final claim in _runtimeBaselineClaims) {
    final matches = claim.source.allMatches(pins).toList();
    if (matches.length != 1) {
      problems.add(
        '$nativeLlamaCppTagPath: found ${matches.length} ${claim.label} tag '
        'constants, expected exactly 1; the runtime baseline gate cannot run',
      );
      continue;
    }
    expected[claim.label] = matches.single.group(1)!;
  }
  if (problems.isNotEmpty) return problems;

  for (final path in <String>[
    'CHANGELOG.md',
    'website/docs/changelog/recent-releases.md',
  ]) {
    final file = File('${repoRoot.path}/$path');
    if (!file.existsSync()) {
      problems.add('$path: file is missing');
      continue;
    }
    final contents = _readGateFile(file, path, problems);
    if (contents == null) continue;
    final top = _topReleaseNotesSection.firstMatch(contents);
    final heading = top?.namedGroup('heading');
    if (top == null || (heading != 'Unreleased' && heading != releaseVersion)) {
      continue;
    }
    final section = top.namedGroup('body')!;
    final paragraphs = _runtimeBaselineParagraph.allMatches(section).toList();
    if (paragraphs.isEmpty) continue;
    if (paragraphs.length != 1) {
      problems.add(
        '$path: ${paragraphs.length} Runtime baseline paragraphs in the '
        'current release-notes section, expected 1',
      );
      continue;
    }
    final paragraph = paragraphs.single.group(0)!;
    for (final claim in _runtimeBaselineClaims) {
      final found = RegExp(
        '${RegExp.escape(claim.wording)} `([^`]+)`',
      ).firstMatch(paragraph)?[1];
      if (found == null) {
        problems.add(
          '$path: the Runtime baseline paragraph no longer states the '
          '${claim.label} tag in the expected wording',
        );
      } else if (found != expected[claim.label]) {
        problems.add(
          '$path: Runtime baseline names ${claim.label} $found, but '
          '$nativeLlamaCppTagPath pins ${expected[claim.label]}',
        );
      }
    }
    final upstream = RegExp(
      r'upstream `([^@`]+)@([0-9a-f]{40})`',
    ).firstMatch(paragraph);
    if (upstream == null) {
      problems.add(
        '$path: the Runtime baseline paragraph no longer states the Web '
        'upstream llama.cpp tag@commit in the expected wording',
      );
    } else if (upstream.group(1) != bridgeLlamaCppTag ||
        upstream.group(2) != bridgeLlamaCppCommit) {
      problems.add(
        '$path: Runtime baseline names Web upstream llama.cpp '
        '${upstream.group(1)}@${upstream.group(2)}, but the pinned bridge '
        'assets embed $bridgeLlamaCppTag@$bridgeLlamaCppCommit',
      );
    }
  }
  return problems;
}

/// Returns one message per problem with the Web/native llama.cpp relationship.
///
/// `lib/src/hook/native_release_pins.dart` and the bridge manifest move in different
/// repositories, so
/// nothing else notices when a native pin bump silently ends Web/native parity
/// and leaves the docs claiming it.
/// [bridgeTag] is the llama.cpp upstream release tag embedded by the bridge
/// assets, not the bridge asset release tag itself.
List<String> findBridgeRuntimeDrift(Directory repoRoot, String bridgeTag) {
  final problems = <String>[];
  final file = File('${repoRoot.path}/$nativeLlamaCppTagPath');
  if (!file.existsSync()) {
    return <String>['$nativeLlamaCppTagPath: file is missing'];
  }
  final nativeContents = _readGateFile(file, nativeLlamaCppTagPath, problems);
  if (nativeContents == null) return problems;
  final matches = _nativeLlamaCppTag.allMatches(nativeContents).toList();
  if (matches.length != 1) {
    return <String>[
      '$nativeLlamaCppTagPath: found ${matches.length} llamaCppTag constants, '
          'expected exactly 1; the gate cannot identify the active native pin',
    ];
  }

  final normalizedBridgeTag = normalizeNativeLlamaCppTag(bridgeTag);
  if (normalizedBridgeTag != bridgeTag) {
    problems.add(
      'bridgeLlamaCppTag $bridgeTag is not a canonical upstream llama.cpp '
      'release tag',
    );
  }

  // The recorded anchor and the recorded upstream tag are bumped by hand in
  // separate constants, so a half-finished bump would otherwise pass here and
  // then be compared against the manifest in its stale form by
  // --verify-manifest, which would pass too.
  final normalizedAnchor = normalizeNativeLlamaCppTag(bridgeNativeReleaseTag);
  if (normalizedAnchor != bridgeTag) {
    problems.add(
      'bridgeNativeReleaseTag $bridgeNativeReleaseTag does not belong to the '
      'recorded upstream llama.cpp release $bridgeTag — the checked-in bridge '
      'provenance constants disagree with each other',
    );
  }

  final nativeTag = matches.single.group(1)!;
  final normalizedNativeFamily = normalizeNativeLlamaCppTag(nativeTag);
  if (normalizedNativeFamily == null) {
    problems.add(
      '$nativeLlamaCppTagPath: malformed native llama.cpp tag "$nativeTag" — '
      'expected stable vMAJOR.MINOR.PATCH(-N) or nightly bNNNN(-N|-llamadart.N)',
    );
  } else {
    if (nativeTag != bridgeApprovedNativePin) {
      problems.add(
        '$nativeLlamaCppTagPath pins $nativeTag, expected the bridge-approved '
        'native pin $bridgeApprovedNativePin',
      );
    }
    if (normalizedNativeFamily != bridgeTag) {
      problems.add(
        'bridge assets embed llama.cpp $bridgeTag but $nativeLlamaCppTagPath '
        'pins $nativeTag (upstream family $normalizedNativeFamily) — Web and '
        'native must share an upstream llama.cpp release',
      );
    }
  }

  for (final pin in bridgeLlamaCppParityPins) {
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
    final match = matches.single;
    final found = match.group(1)!;
    if (found != bridgeTag) {
      problems.add('${pin.path}: states $found, expected $bridgeTag');
    }
    if (match.groupNames.contains('nativePin')) {
      final foundNativePin = match.namedGroup('nativePin');
      if (foundNativePin != nativeTag) {
        problems.add(
          '${pin.path}: states native pin $foundNativePin, expected $nativeTag',
        );
      }
    }
  }

  return problems;
}

/// Returns one message per incorrect claim in the pinned provenance docs.
List<String> findBridgeProvenanceDrift(Directory repoRoot) {
  final problems = <String>[];
  for (final pin in bridgeProvenancePins) {
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
        '${pin.path}: the pinned release provenance passage matches '
        '${matches.length} lines, expected 1 — it was reworded, removed, or '
        'duplicated, so this check no longer covers it',
      );
      continue;
    }
    final match = matches.single;
    for (final entry in bridgeProvenanceValues.entries) {
      if (!match.groupNames.contains(entry.key)) {
        problems.add(
          '${pin.path}: the provenance passage no longer states ${entry.key}',
        );
        continue;
      }
      final found = match.namedGroup(entry.key);
      if (found != entry.value) {
        problems.add(
          '${pin.path}: states ${entry.key} $found, expected ${entry.value}',
        );
      }
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

/// Maximum accepted response size for the small release manifest.
const int maxBridgeManifestBytes = 64 * 1024;

/// The transport result consumed by [verifyManifest] and
/// [verifyPublishedRelease].
class ManifestResponse {
  /// HTTP status returned by the endpoint.
  final int statusCode;

  /// Response bytes, empty for a non-success status.
  final List<int> bytes;

  /// Creates a manifest response.
  const ManifestResponse(this.statusCode, this.bytes);
}

/// Fetches one manifest response.
typedef ManifestFetcher = Future<ManifestResponse> Function(Uri url);

const Map<String, String> _manifestProvenanceAliases = <String, String>{
  'release_tag': 'bridge_assets_tag',
  'bridge_repository': 'source_repository',
  'bridge_commit': 'source_commit',
  'upstream_tag': 'llama_cpp_tag',
  'upstream_commit': 'llama_cpp_commit',
};

Future<ManifestResponse> _fetchManifest(
  HttpClient client,
  Uri url,
  int maximumBytes, {
  String what = 'manifest',
  Map<String, String> headers = const <String, String>{},
  bool followRedirects = true,
}) async {
  final request = await client.getUrl(url);
  request.followRedirects = followRedirects;
  headers.forEach(request.headers.set);
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    return ManifestResponse(response.statusCode, const <int>[]);
  }
  if (response.contentLength > maximumBytes) {
    throw HttpException(
      '$what Content-Length ${response.contentLength} exceeds the '
      '$maximumBytes-byte limit',
      uri: url,
    );
  }

  final bytes = <int>[];
  await for (final chunk in response) {
    if (bytes.length + chunk.length > maximumBytes) {
      throw HttpException(
        '$what body exceeds the $maximumBytes-byte limit',
        uri: url,
      );
    }
    bytes.addAll(chunk);
  }
  return ManifestResponse(response.statusCode, bytes);
}

/// Verifies exact manifest bytes and their canonical schema-2 provenance.
List<String> verifyManifestBytes({
  required List<int> bytes,
  required Uri source,
  required String expectedManifestSha256,
  required Map<String, Object> expectedProvenance,
}) {
  final problems = <String>[];
  final actualHash = sha256.convert(bytes).toString();
  if (actualHash != expectedManifestSha256) {
    problems.add(
      '$source manifest SHA-256 is $actualHash, expected '
      '$expectedManifestSha256',
    );
  }

  final String body;
  try {
    body = utf8.decode(bytes);
  } on FormatException catch (error) {
    return <String>[
      ...problems,
      '$source returned invalid manifest UTF-8 bytes: $error',
    ];
  }

  final dynamic decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException catch (error) {
    return <String>[
      ...problems,
      '$source returned invalid manifest JSON: $error',
    ];
  }
  if (decoded is! Map<String, dynamic>) {
    return <String>[
      ...problems,
      '$source returned invalid manifest JSON: expected an object',
    ];
  }

  // Alias fields remain in the published manifest for old consumers. This gate
  // deliberately reads only the schema-2 canonical names so an alias cannot
  // hide a missing or conflicting provenance field.
  for (final expectation in expectedProvenance.entries) {
    final value = decoded[expectation.key];
    if (value == null || (value is String && value.isEmpty)) {
      problems.add(
        '$source returned invalid manifest JSON: ${expectation.key} is missing '
        'or empty',
      );
      continue;
    }
    if (value != expectation.value) {
      problems.add(
        '$source reports ${expectation.key} $value, expected '
        '${expectation.value}',
      );
    }
  }
  for (final alias in _manifestProvenanceAliases.entries) {
    final aliasValue = decoded[alias.value];
    if (aliasValue != null && aliasValue != decoded[alias.key]) {
      problems.add(
        '$source has conflicting provenance aliases: ${alias.key} '
        '${decoded[alias.key]} but ${alias.value} $aliasValue',
      );
    }
  }
  return problems;
}

/// Re-reads the published manifest for [expectedTag] and machine-verifies its
/// exact approved bytes and canonical schema-2 provenance fields.
///
/// Network-dependent, so it is opt-in rather than part of the default run.
Future<List<String>> verifyManifest({
  required String expectedTag,
  required String expectedLlamaCppTag,
  required String expectedLlamaCppCommit,
  required String expectedBridgeCommit,
  required String expectedNativeReleaseTag,
  required String expectedManifestSha256,
  Uri? manifestUrl,
  Duration timeout = const Duration(seconds: 15),
  int maximumBytes = maxBridgeManifestBytes,
  ManifestFetcher? fetcher,
}) async {
  final url =
      manifestUrl ??
      Uri.parse(
        'https://cdn.jsdelivr.net/gh/$bridgeAssetsRepository@$expectedTag'
        '/manifest.json',
      );
  final client = fetcher == null ? HttpClient() : null;
  try {
    final response =
        await (fetcher ?? (url) => _fetchManifest(client!, url, maximumBytes))(
          url,
        ).timeout(timeout);
    if (response.statusCode != HttpStatus.ok) {
      return <String>['$url returned HTTP ${response.statusCode}'];
    }
    if (response.bytes.length > maximumBytes) {
      return <String>[
        '$url manifest body exceeds the $maximumBytes-byte limit',
      ];
    }
    return verifyManifestBytes(
      bytes: response.bytes,
      source: url,
      expectedManifestSha256: expectedManifestSha256,
      expectedProvenance: <String, Object>{
        'schema_version': 2,
        'release_tag': expectedTag,
        'assets_repository': bridgeAssetsRepository,
        'bridge_repository': bridgeSourceRepository,
        'bridge_commit': expectedBridgeCommit,
        'upstream_repository': bridgeUpstreamRepository,
        'upstream_tag': expectedLlamaCppTag,
        'upstream_commit': expectedLlamaCppCommit,
        'native_repository': bridgeNativeRepository,
        'native_release_tag': expectedNativeReleaseTag,
      },
    );
  } on TimeoutException {
    return <String>[
      'timed out reading $url after ${timeout.inMilliseconds} ms',
    ];
  } on IOException catch (error) {
    return <String>['could not read $url: $error'];
  } finally {
    client?.close(force: true);
  }
}

/// The GitHub REST API root [verifyPublishedRelease] reads by default.
final Uri gitHubApiBase = Uri.parse('https://api.github.com');

/// Maximum accepted size of one GitHub API response.
const int maxGitHubApiResponseBytes = 1024 * 1024;

/// Fetches one GitHub REST API response.
typedef GitHubApiFetcher = Future<ManifestResponse> Function(Uri url);

/// Annotated tags may point at further tags; a longer chain is refused rather
/// than followed indefinitely.
const int maxTagPeelDepth = 8;

final RegExp _gitObjectSha = RegExp(r'^[0-9a-f]{40}$');

/// Reads the release published under [expectedTag] and the commit its tag
/// peels to, and returns one message per mismatch with the pinned values.
///
/// The manifest bytes alone do not identify the release: an unpinned or
/// mutable release could be re-tagged or re-published with the same bytes.
/// Any missing field, unexpected shape or API failure is a problem, never a
/// pass. `GH_TOKEN` (or `GITHUB_TOKEN`, matching `gh`'s precedence) in
/// [environment] authenticates the requests; it is sent only as a header and
/// redirects are not followed, so it cannot reach another host or appear in a
/// message. A token that is not a valid bearer token sends no request.
Future<List<String>> verifyPublishedRelease({
  required String expectedTag,
  required String expectedReleaseId,
  required String expectedTagCommit,
  Uri? apiBase,
  Map<String, String>? environment,
  Duration timeout = const Duration(seconds: 15),
  int maximumBytes = maxGitHubApiResponseBytes,
  GitHubApiFetcher? fetcher,
}) async {
  final base = apiBase ?? gitHubApiBase;
  Uri api(String path) =>
      base.replace(path: '/repos/$bridgeAssetsRepository/$path');

  final headers = <String, String>{
    HttpHeaders.acceptHeader: 'application/vnd.github+json',
    'X-GitHub-Api-Version': '2022-11-28',
  };
  if (fetcher == null) {
    final (name, token) = _gitHubToken(environment ?? Platform.environment);
    if (token != null) {
      // HttpHeaders quotes an invalid value in its exception, which would
      // print the token.
      if (!_bearerToken.hasMatch(token)) {
        return <String>[
          '$name is not a valid bearer token, so no GitHub API request was '
              'sent; its value is not shown',
        ];
      }
      headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
    }
  }

  final client = fetcher == null ? HttpClient() : null;
  final fetch =
      fetcher ??
      (Uri url) => _fetchManifest(
        client!,
        url,
        maximumBytes,
        what: 'GitHub API response',
        headers: headers,
        followRedirects: false,
      );

  Future<Object> readObject(Uri url) async {
    final ManifestResponse response;
    try {
      response = await fetch(url).timeout(timeout);
    } on TimeoutException {
      return 'timed out reading $url after ${timeout.inMilliseconds} ms';
    } on IOException catch (error) {
      return 'could not read $url: $error';
    }
    if (response.statusCode != HttpStatus.ok) {
      final hint = const <int>{401, 403, 429}.contains(response.statusCode)
          ? '; unauthenticated requests are rate limited, so set GH_TOKEN '
                'or GITHUB_TOKEN, or check the one that is set'
          : '';
      return '$url returned HTTP ${response.statusCode}$hint';
    }
    if (response.bytes.length > maximumBytes) {
      return '$url GitHub API response exceeds the $maximumBytes-byte limit';
    }
    try {
      final decoded = jsonDecode(utf8.decode(response.bytes));
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException catch (error) {
      return '$url returned invalid JSON: $error';
    }
    return '$url returned invalid JSON: expected an object';
  }

  try {
    final problems = <String>[];

    final releaseUrl = api('releases/tags/$expectedTag');
    final release = await readObject(releaseUrl);
    if (release is String) {
      problems.add(release);
    } else if (release is Map<String, dynamic>) {
      final tagName = release['tag_name'];
      if (tagName != expectedTag) {
        problems.add('$releaseUrl reports tag_name $tagName');
      }
      final id = release['id'];
      if (id is! int) {
        problems.add('$releaseUrl reports no numeric release id');
      } else if ('$id' != expectedReleaseId) {
        problems.add(
          'release $expectedTag has id $id, expected bridgeAssetsReleaseId '
          '$expectedReleaseId',
        );
      }
      if (release['immutable'] != true) {
        problems.add(
          'release $expectedTag reports immutable: ${release['immutable']}, '
          'expected true — a mutable release can change after it is pinned',
        );
      }
      if (release['draft'] != false) {
        problems.add(
          'release $expectedTag reports draft: ${release['draft']}, expected '
          'false',
        );
      }
    }

    final refUrl = api('git/ref/tags/$expectedTag');
    final ref = await readObject(refUrl);
    if (ref is String) return <String>[...problems, ref];
    if (ref is! Map<String, dynamic> ||
        ref['ref'] != 'refs/tags/$expectedTag') {
      return <String>[
        ...problems,
        '$refUrl does not describe refs/tags/$expectedTag',
      ];
    }

    var target = ref['object'];
    var source = refUrl;
    for (var depth = 0; ; depth++) {
      final type = target is Map<String, dynamic> ? target['type'] : null;
      final sha = target is Map<String, dynamic> ? target['sha'] : null;
      if (sha is! String || !_gitObjectSha.hasMatch(sha)) {
        problems.add('$source reports no valid object sha');
        break;
      }
      if (type == 'commit') {
        if (sha != expectedTagCommit) {
          problems.add(
            'tag $expectedTag points at commit $sha, expected '
            'bridgeAssetsTagCommit $expectedTagCommit',
          );
        }
        break;
      }
      if (type != 'tag') {
        problems.add(
          '$source points tag $expectedTag at a $type object, expected a '
          'commit or an annotated tag',
        );
        break;
      }
      if (depth == maxTagPeelDepth) {
        problems.add(
          'tag $expectedTag does not reach a commit within $maxTagPeelDepth '
          'annotated tags',
        );
        break;
      }
      source = api('git/tags/$sha');
      final tagObject = await readObject(source);
      if (tagObject is String) {
        problems.add(tagObject);
        break;
      }
      target = (tagObject as Map<String, dynamic>)['object'];
    }
    return problems;
  } finally {
    client?.close(force: true);
  }
}

/// RFC 6750 `b64token`, which every GitHub token format satisfies.
final RegExp _bearerToken = RegExp(r'^[A-Za-z0-9\-._~+/]+=*$');

(String, String?) _gitHubToken(Map<String, String> environment) {
  for (final name in const <String>['GH_TOKEN', 'GITHUB_TOKEN']) {
    final value = environment[name]?.trim() ?? '';
    if (value.isNotEmpty) return (name, value);
  }
  return ('', null);
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

/// Files that record past releases or frozen runtime emissions, where an old
/// tag is correct. Current release-notes claims remain [releaseNotesPins].
const List<String> tagHistoryFiles = <String>[
  'CHANGELOG.md',
  'doc/changelog_archive.md',
  'doc/multimodal_embeddings_web.md',
  // Register with bridgeTagPins once #2153 makes this tag canonical.
  'packages/genkit_llamadart/example/dartpad/lib/bridge_bootstrap_web.dart',
  'website/docs/changelog/recent-releases.md',
  'test/fixtures/lfm2_quoted_tool_delimiter.md',
  'test/fixtures/release_prep/pr_2114_description.md',
  'test/fixtures/release_prep/pr_2114_github_squash_body.txt',
  'packages/llamadart_validation/test/fixtures/windows_native_log/chat.events.jsonl',
  'packages/llamadart_validation/test/fixtures/windows_native_log/tiny.events.jsonl',
  'packages/llamadart_validation/test/fixtures/android_logcat/galaxys24-gemma4-litert-gpu.events.jsonl',
  'packages/llamadart_validation/test/fixtures/android_logcat/pixel9pro-gemma4-litert-gpu.events.jsonl',
];

/// Frozen documentation snapshots.
const String versionedDocsPrefix = 'website/versioned_docs/';

/// Returns one message per live occurrence of [expectedTag] that no pin covers.
///
/// Without this the gate would only protect sites someone remembered to
/// register, so a newly added pin could go stale while CI stayed green.
/// Capability floors (`v0.1.39+`) and the release histories are excluded
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
/// `v0.1.39+` minimum.
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

/// Runs every offline drift gate and the optional published release and
/// manifest gates.
Future<List<String>> findBridgeProblems(
  Directory repoRoot,
  String expectedTag, {
  bool verifyPublishedManifest = false,
  ManifestFetcher? manifestFetcher,
  GitHubApiFetcher? releaseFetcher,
  Map<String, String>? environment,
}) async => <String>[
  ...findBridgeTagDrift(repoRoot, expectedTag),
  ...findUnregisteredTagSites(repoRoot, expectedTag),
  ...findBridgeRuntimeDrift(repoRoot, bridgeLlamaCppTag),
  ...findBridgeProvenanceDrift(repoRoot),
  if (verifyPublishedManifest)
    ...await verifyPublishedRelease(
      expectedTag: expectedTag,
      expectedReleaseId: bridgeAssetsReleaseId,
      expectedTagCommit: bridgeAssetsTagCommit,
      fetcher: releaseFetcher,
      environment: environment,
    ),
  if (verifyPublishedManifest)
    ...await verifyManifest(
      expectedTag: expectedTag,
      expectedLlamaCppTag: bridgeLlamaCppTag,
      expectedLlamaCppCommit: bridgeLlamaCppCommit,
      expectedBridgeCommit: bridgeSourceCommit,
      expectedNativeReleaseTag: bridgeNativeReleaseTag,
      expectedManifestSha256: bridgeManifestSha256,
      fetcher: manifestFetcher,
    ),
];

final _unchangedFrom = RegExp(
  r'\(\s*unchanged\s+(?:from|since)\b|'
  r'\bunchanged\s+(?:from|since)\s+v?\d+\.\d+\.\d+\b',
  caseSensitive: false,
);
final _preparedBridgeWording = RegExp('WebGPU bridge assets|default WebGPU');
final _releaseWhitespace = RegExp(r'\s+');
final _blockIndent = RegExp(
  r'^[ \t]*(?:>[ \t]*|(?:[-+*]|[0-9]{1,9}[.)])[ \t]+)*',
);
final _footnoteWhitespace = RegExp(r'[ \t\r\n]+');
final _footnoteEdgeWhitespace = RegExp(r'^[ \t\r\n]+|[ \t\r\n]+$');
final _anchorProtocol = RegExp(r'^([^/:]*):');
const _anchorProtocols = {
  'http',
  'https',
  'mailto',
  'xmpp',
  'github-windows',
  'github-mac',
};

String _expandBlockTabs(String line) {
  final firstTab = line.indexOf('\t');
  if (firstTab < 0) return line;
  final end = _blockIndent.matchAsPrefix(line)!.end;
  if (firstTab >= end) return line;
  // Count container markers in the source column before the parser removes them.
  final indent = StringBuffer(line.substring(0, firstTab));
  var column = firstTab;
  for (var i = firstTab; i < end; i++) {
    if (line[i] == '\t') {
      final spaces = 4 - column % 4;
      indent.write(' ' * spaces);
      column += spaces;
    } else {
      indent.write(line[i]);
      column++;
    }
  }
  return '$indent${line.substring(end)}';
}

String _normalizeFootnoteLabel(String label) {
  final folded = foldReleaseNoteLabel(label);
  return folded
      .replaceAll(_footnoteEdgeWhitespace, '')
      .replaceAll(_footnoteWhitespace, ' ');
}

const _markdownProseTags = {
  'p',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'th',
  'td',
};
const _markdownContainers = {
  'blockquote',
  'ol',
  'ul',
  'li',
  'table',
  'thead',
  'tbody',
  'tr',
};
const _htmlContextTags = {'pre', ..._markdownContainers, 'th', 'td'};
const _markdownBlockTags = {
  ..._markdownProseTags,
  ..._markdownContainers,
  'pre',
  'hr',
  'div',
};
const _htmlBlockTags = {
  ..._markdownBlockTags,
  'address',
  'article',
  'aside',
  'caption',
  'center',
  'dd',
  'details',
  'dialog',
  'dir',
  'dl',
  'dt',
  'fieldset',
  'figcaption',
  'figure',
  'footer',
  'form',
  'header',
  'hgroup',
  'main',
  'menu',
  'nav',
  'search',
  'section',
  'summary',
  'tfoot',
};
// GFM escapes these tags before they can change HTML tokenization.
final _gfmFilteredTag = RegExp(
  r'<(?=/?(?:title|textarea|style|xmp|iframe|noembed|noframes|script|plaintext)'
  r'(?:[ \t\r\n\f/>]))',
  caseSensitive: false,
);
final _versionCodeSpan = RegExp(
  r'^v?\d+\.\d+\.\d+(?:[-+][\w.+-]+)?$',
  caseSensitive: false,
);

class _ReleaseHeading extends md.Element {
  _ReleaseHeading(List<md.Node> children) : super('h2', children);
}

class _ReleaseHeadingSyntax extends md.HeaderSyntax {
  const _ReleaseHeadingSyntax();

  static final _levelTwo = RegExp(r'^ {0,3}##[ \t]');

  @override
  bool canParse(md.BlockParser parser) =>
      super.canParse(parser) && _levelTwo.hasMatch(parser.current.content);

  @override
  md.Node parse(md.BlockParser parser) {
    final heading = super.parse(parser) as md.Element;
    return _ReleaseHeading(heading.children!);
  }
}

class _ReleaseFootnote extends md.Element {
  _ReleaseFootnote(this.label, List<md.Node> children) : super('li', children);

  final String label;
}

class _QuotedLine extends md.Line {
  _QuotedLine(super.content);
}

class _ReleaseBlockquoteSyntax extends md.BlockquoteSyntax {
  const _ReleaseBlockquoteSyntax();

  static final _codeFence = md.FencedCodeBlockSyntax().pattern;
  static final _indent = md.CodeBlockSyntax().pattern;

  @override
  md.Node parse(md.BlockParser parser) {
    final (:lines, :lazy) = _parseQuotedLines(parser);
    final children = md.BlockParser(
      lines,
      parser.document,
    ).parseLines(disabledSetextHeading: lazy, parentSyntax: this);
    return md.Element('blockquote', children);
  }

  ({List<md.Line> lines, bool lazy}) _parseQuotedLines(md.BlockParser parser) {
    final lines = <md.Line>[];
    var lazy = false;
    while (!parser.isDone) {
      final current = parser.current;
      final content = current.content;
      if (pattern.hasMatch(content)) {
        var markerEnd = content.indexOf('>') + 1;
        if (content.startsWith(' ', markerEnd) ||
            content.startsWith('\t', markerEnd)) {
          markerEnd++;
        }
        lines.add(_QuotedLine(content.substring(markerEnd)));
        lazy = false;
      } else {
        final lastLine = lines.last;
        final otherMatched = parser.blockSyntaxes.firstWhere(
          (syntax) => syntax.canParse(parser),
        );
        if (lastLine.isBlankLine ||
            _codeFence.hasMatch(lastLine.content) ||
            (otherMatched is! md.ParagraphSyntax &&
                !(otherMatched is md.CodeBlockSyntax &&
                    !_indent.hasMatch(lastLine.content)))) {
          break;
        }
        lines.add(current);
        lazy = true;
      }
      parser.advance();
    }
    return (lines: lines, lazy: lazy);
  }
}

class _ReleaseFootnoteSyntax extends md.FootnoteDefSyntax {
  const _ReleaseFootnoteSyntax();

  @override
  md.Node parse(md.BlockParser parser) {
    final current = parser.current.content;
    final match = pattern.firstMatch(current)!;
    final label = _normalizeFootnoteLabel(match[2]!);
    (parser.document as _ReleaseMarkdown).definedFootnotes.add(label);
    final firstContent = current.substring(match.end);
    parser.advance();
    final lines = [
      md.Line(firstContent),
      ..._parseFootnoteLines(
        parser,
        startAfterBlank: firstContent.trim().isEmpty,
      ),
    ];
    final children = md.BlockParser(lines, parser.document).parseLines();
    // Retain the definition's position so it can be attributed to its release.
    return _ReleaseFootnote(label, children);
  }

  List<md.Line> _parseFootnoteLines(
    md.BlockParser parser, {
    required bool startAfterBlank,
  }) {
    final lines = <md.Line>[];
    var shouldBeBlock = startAfterBlank;
    final interruptingSyntaxes = parser.blockSyntaxes.where(
      (syntax) =>
          syntax is! md.EmptyBlockSyntax && syntax.pattern.pattern.isNotEmpty,
    );
    while (!parser.isDone) {
      final current = parser.current;
      final line = current.content;
      if (line.startsWith('    ')) {
        final rest = line.substring(4);
        lines.add(md.Line(rest));
        shouldBeBlock = rest.trim().isEmpty;
      } else if (line.isEmpty && current is! _QuotedLine) {
        // GFM keeps an unindented blank only if the raw line was empty.
        lines.add(current);
        shouldBeBlock = true;
      } else if (current.isBlankLine ||
          shouldBeBlock ||
          interruptingSyntaxes.any((syntax) => syntax.pattern.hasMatch(line))) {
        break;
      } else {
        lines.add(current);
      }
      parser.advance();
    }
    return lines;
  }
}

final _footnoteEntity = RegExp(
  r'&(?:[a-zA-Z][a-zA-Z0-9]{1,31}|#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6});',
);
final _footnoteNamedEntities = md.Document(
  encodeHtml: false,
  withDefaultBlockSyntaxes: false,
  withDefaultInlineSyntaxes: false,
  inlineSyntaxes: [md.DecodeHtmlSyntax()],
);
final _backtickRun = RegExp(r'`+');
final _footnoteNonTextTag = RegExp(
  r'<[A-Za-z][A-Za-z0-9+.-]{1,31}:[^<>\x00-\x20]*>'
  '|${md.EmailAutolinkSyntax().pattern.pattern}'
  r'|<!--(?:>|->|[\s\S]*?-->)'
  '|${md.InlineHtmlSyntax().pattern.pattern}',
);

String _decodeCommonMarkEntity(String entity) {
  if (!entity.startsWith('&#')) {
    return _footnoteNamedEntities.parseInline(entity).single.textContent;
  }
  final isHex = entity[2].toLowerCase() == 'x';
  final value = int.parse(
    entity.substring(isHex ? 3 : 2, entity.length - 1),
    radix: isHex ? 16 : 10,
  );
  if (value == 0 || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) {
    return '\uFFFD';
  }
  return String.fromCharCode(value);
}

bool _isAsciiPunctuation(int code) =>
    (code >= 0x21 && code <= 0x2f) ||
    (code >= 0x3a && code <= 0x40) ||
    (code >= 0x5b && code <= 0x60) ||
    (code >= 0x7b && code <= 0x7e);

String? _extractFootnoteReferenceLabel(String raw) {
  final label = StringBuffer();
  var sawCaret = false;
  var index = 0;
  // GFM takes adjacent inline text before processing emphasis and stops at the
  // first break, code span, autolink, or raw HTML node.
  while (index < raw.length) {
    var token = raw[index];
    index++;
    if (token == '\r' || token == '\n') break;

    if (token == r'\' && index < raw.length) {
      final next = raw[index];
      if (next == '\r' || next == '\n') break;
      if (_isAsciiPunctuation(raw.codeUnitAt(index))) {
        token = next;
        index++;
      }
    } else if (token == '&') {
      final entity = _footnoteEntity.matchAsPrefix(raw, index - 1);
      if (entity != null) {
        token = _decodeCommonMarkEntity(entity[0]!);
        index = entity.end;
      }
    } else if (token == '`') {
      final run = _backtickRun.matchAsPrefix(raw, index - 1)!;
      final length = run.end - run.start;
      if (_backtickRun
          .allMatches(raw, run.end)
          .any((candidate) => candidate.end - candidate.start == length)) {
        break;
      }
      token = run[0]!;
      index = run.end;
    } else if (token == '<' &&
        _footnoteNonTextTag.matchAsPrefix(raw, index - 1) != null) {
      break;
    }

    if (!sawCaret) {
      if (!token.startsWith('^') ||
          (token.length == 1 && index == raw.length)) {
        return null;
      }
      sawCaret = true;
      token = token.substring(1);
    }
    label.write(token);
  }
  return sawCaret ? label.toString() : null;
}

class _ReleaseLinkSyntax extends md.LinkSyntax {
  @override
  Iterable<md.Node>? close(
    md.InlineParser parser,
    covariant md.SimpleDelimiter opener,
    md.Delimiter? closer, {
    String? tag,
    required List<md.Node> Function() getChildren,
  }) {
    final closePos = parser.pos;
    final link = super.close(
      parser,
      opener,
      closer,
      tag: tag,
      getChildren: getChildren,
    );
    if (link != null) return link;

    final label = _extractFootnoteReferenceLabel(
      parser.source.substring(opener.endPos, closePos),
    );
    if (label == null) return null;

    // A failed lookup may have scanned past the first closing bracket.
    parser.pos = closePos;
    getChildren();
    final document = parser.document as _ReleaseMarkdown;
    final folded = _normalizeFootnoteLabel(label);
    if (folded.isNotEmpty &&
        utf8.encode(label).length <= 999 &&
        document.definedFootnotes.contains(folded)) {
      document.referencedFootnotes.add(folded);
      return [
        md.Element('sup', [md.Element.text('a', '1')]),
      ];
    }
    final literal = const HtmlEscape(HtmlEscapeMode.element).convert(label);
    return [md.Text('[^$literal]')];
  }
}

class _ReleaseMarkdown extends md.Document {
  _ReleaseMarkdown()
    : super(
        extensionSet: md.ExtensionSet.gitHubFlavored,
        blockSyntaxes: const [
          _ReleaseHeadingSyntax(),
          _ReleaseFootnoteSyntax(),
          _ReleaseBlockquoteSyntax(),
        ],
        encodeHtml: true,
        inlineSyntaxes: [
          // markdown 7.3.1's inline HTML syntax misses these legal comments.
          md.TextSyntax(r'<!--(?:>|->|[\s\S]*?-->)', startCharacter: 0x3c),
          md.TextSyntax(r'!(?=\[\^)', startCharacter: 0x21),
          _ReleaseLinkSyntax(),
        ],
      );

  final definedFootnotes = <String>{};
  final referencedFootnotes = <String>{};
}

Iterable<_ReleaseFootnote> _footnoteDefinitions(Iterable<md.Node> nodes) sync* {
  for (final node in nodes.whereType<md.Element>()) {
    if (node is _ReleaseFootnote) yield node;
    if (node.children case final children?) {
      yield* _footnoteDefinitions(children);
    }
  }
}

List<md.Element> _renderedReleaseFootnotes(
  List<md.Node> section,
  List<md.Node> document,
  Set<String> referenceLabels,
) {
  if (referenceLabels.isEmpty) return [];
  final firstDefinitions = <String, _ReleaseFootnote>{};
  for (final definition in _footnoteDefinitions(document)) {
    firstDefinitions.putIfAbsent(definition.label, () => definition);
  }
  final owned = _footnoteDefinitions(section).toSet();
  return [
    for (final label in referenceLabels)
      if (firstDefinitions[label] case final definition?
          when owned.contains(definition))
        md.Element('li', definition.children),
  ];
}

class _ReleaseHtmlText {
  _ReleaseHtmlText({this.includeTitles = false});

  final bool includeTitles;
  String _openContext = '';

  List<String> read(String fragment) {
    final units = <String>[];
    final text = StringBuffer();

    void addUnit(String value) {
      final unit = value.replaceAll(_releaseWhitespace, ' ').trim();
      if (unit.isNotEmpty) units.add(unit);
    }

    void flush() {
      addUnit(text.toString());
      text.clear();
    }

    void visit(html.Node node, {bool literal = false}) {
      if (node is html.Text) {
        if (!literal) text.write(node.data);
      } else if (node is html.Element) {
        final tag = node.localName;
        if (tag == 'br') {
          if (!literal) text.write(' ');
          return;
        }
        if (includeTitles &&
            ((tag == 'a' && _retainsAnchor(node)) || tag == 'img')) {
          if (node.attributes['title'] case final title?) addUnit(title);
        }
        if (tag == 'img') {
          if (!literal) text.write(node.attributes['alt'] ?? '');
          return;
        }
        final code = tag == 'code' && !_versionCodeSpan.hasMatch(node.text);
        final block = !literal && (_htmlBlockTags.contains(tag) || code);
        if (block) flush();
        for (final child in node.nodes) {
          visit(child, literal: literal || tag == 'pre' || code);
        }
        if (block) flush();
      }
    }

    final parser = html_parser.HtmlParser(
      _openContext + fragment.replaceAll(_gfmFilteredTag, '&lt;'),
    );
    parser.parseFragment().nodes.forEach(visit);
    // Preserve only pre and container context across fragments. HTML end tags
    // in a container can close an inherited pre, and container end tags can
    // close a pre opened inside them.
    final openTags = parser.tree.openElements
        .map((node) => node.localName)
        .toList();
    final context = openTags.lastIndexWhere(_htmlContextTags.contains);
    _openContext = context < 0
        ? ''
        : openTags.skip(1).take(context).map((tag) => '<$tag>').join();
    flush();
    return units;
  }
}

bool _retainsAnchor(html.Element anchor) {
  final attributes = anchor.attributes;
  if (attributes.containsKey('id') || attributes.containsKey('name')) {
    return true;
  }
  final href = attributes['href'];
  if (href == null) return false;
  final protocol = _anchorProtocol.firstMatch(href)?[1];
  return protocol == null || _anchorProtocols.contains(protocol.toLowerCase());
}

bool _isMarkdownBlock(md.Node node) =>
    node is md.Element && _markdownBlockTags.contains(node.tag);

({List<md.Node> claim, Iterable<md.Node> rest}) _bridgeItemParts(
  md.Element item,
) {
  final children = item.children!;
  final first = children.firstOrNull;
  if (first is md.Element && first.tag == 'p') {
    return (claim: first.children!, rest: children.skip(1));
  }
  final claim = children.takeWhile((node) => !_isMarkdownBlock(node)).toList();
  return (claim: claim, rest: children.skip(claim.length));
}

Iterable<String> _releaseTextUnits(
  Iterable<md.Node> nodes,
  _ReleaseHtmlText htmlText, {
  md.Element? verifiedBridge,
  md.Element? verifiedBaseline,
  bool inListItem = false,
}) sync* {
  final inlineRun = <md.Node>[];
  for (final node in nodes) {
    if (node is _ReleaseFootnote) continue;
    if (inListItem && !_isMarkdownBlock(node)) {
      inlineRun.add(node);
      continue;
    }
    if (inlineRun.isNotEmpty) {
      yield* htmlText.read(md.renderToHtml(inlineRun));
      inlineRun.clear();
    }
    if (identical(node, verifiedBaseline)) continue;
    if (node is md.Text) {
      yield* htmlText.read(node.textContent);
    } else if (node is md.Element && node.tag != 'pre') {
      final children = identical(node, verifiedBridge)
          ? _bridgeItemParts(node).rest
          : node.children ?? const <md.Node>[];
      final container = _htmlContextTags.contains(node.tag);
      if (container) htmlText.read('<${node.tag}>');
      if (_markdownProseTags.contains(node.tag)) {
        yield* htmlText.read(md.renderToHtml(children.toList()));
      } else {
        yield* _releaseTextUnits(
          children,
          htmlText,
          verifiedBridge: verifiedBridge,
          verifiedBaseline: verifiedBaseline,
          inListItem: node.tag == 'li',
        );
      }
      if (container) htmlText.read('</${node.tag}>');
    }
  }
  if (inlineRun.isNotEmpty) {
    yield* htmlText.read(md.renderToHtml(inlineRun));
  }
}

String _stripVerifiedRuntimeRetentionHtml(
  String baseline,
  String previousNativePins,
  String suffix,
) {
  for (final claim in _runtimeBaselineClaims) {
    final shown = RegExp(
      '${RegExp.escape(claim.wording)} <code>([^<]+)</code>',
    ).firstMatch(baseline);
    if (shown == null || !baseline.startsWith(suffix, shown.end)) continue;
    final previous = claim.source.allMatches(previousNativePins).singleOrNull;
    if (previous?[1] == shown[1]) {
      baseline = baseline.replaceRange(
        shown.end,
        shown.end + suffix.length,
        '',
      );
    }
  }
  return baseline;
}

/// Checks the new published section against the exact candidate's runtime pins.
List<String> findPreparedReleaseNotesDrift(
  Directory root,
  String bridge,
  String previousVersion,
  String previousBridge, {
  required String previousNativePins,
}) {
  final files = [
    for (final path in releasedChangelogs) File('${root.path}/$path'),
  ];
  final problems = <String>[];
  try {
    final version = readRootPackageVersion(root);
    final modulePath = 'example/chat_app/web/index.html';
    final modules = RegExp(
      r'https://cdn\.jsdelivr\.net/npm/(@litert-lm/core@\d+\.\d+\.\d+)/\+esm',
    ).allMatches(File('${root.path}/$modulePath').readAsStringSync()).toList();
    if (modules.length != 1) {
      return ['$modulePath must pin one Web LiteRT-LM module.'];
    }
    final module = modules.single[1]!;
    final native = File(
      '${root.path}/$nativeLlamaCppTagPath',
    ).readAsStringSync();
    final pins = <String>[];
    for (final claim in _runtimeBaselineClaims) {
      final matches = claim.source.allMatches(native).toList();
      if (matches.length != 1) {
        return [
          '$nativeLlamaCppTagPath must pin exactly one ${claim.label} tag.',
        ];
      }
      pins.add(matches.single[1]!);
    }
    final [cpp, liteRt, stableDiffusion] = pins;
    final expectedBaseline = formatRuntimeBaseline(
      native: cpp,
      upstream: bridgeLlamaCppTag,
      upstreamCommit: bridgeLlamaCppCommit,
      liteRt: liteRt,
      stableDiffusion: stableDiffusion,
      module: module,
      manifest: bridgeManifestSha256,
    );
    final unchangedSuffix = ' (unchanged from $previousVersion)';
    final bridgeUnchanged = bridge == previousBridge;
    for (final (index, file) in files.indexed) {
      final path = releasedChangelogs[index];
      final source = file.readAsStringSync();
      final sections = ChangelogHistory.parse(source).sections;
      if (sections.keys.first != version) {
        problems.add('$path must begin with the exact release $version.');
        continue;
      }
      final markdown = _ReleaseMarkdown();
      final document = markdown.parseLines(
        const LineSplitter().convert(source).map(_expandBlockTabs).toList(),
      );
      bool isReleaseHeading(md.Node node) =>
          node is _ReleaseHeading && sections.containsKey(node.textContent);

      final section = document
          .skipWhile(
            (node) => !isReleaseHeading(node) || node.textContent != version,
          )
          .skip(1)
          .takeWhile((node) => !isReleaseHeading(node))
          .toList();
      final article = index == 0 ? 'the ' : '';
      final bridgeClaim = [
        for (final list in section.whereType<md.Element>())
          if (list.tag == 'ul')
            for (final item in list.children!.whereType<md.Element>())
              if (item.tag == 'li' &&
                  _preparedBridgeWording.hasMatch(
                    _ReleaseHtmlText()
                        .read(md.renderToHtml(_bridgeItemParts(item).claim))
                        .join(' '),
                  ))
                item,
      ].singleOrNull;
      final expectedBridgeHtml = md.renderToHtml(
        markdown.parseInline(
          bridgeUnchanged
              ? 'Keep ${article}default WebGPU bridge assets at `$bridge`$unchangedSuffix.'
              : 'Aligned ${article}default WebGPU bridge assets to `$bridge`',
        ),
      );
      final actualBridgeHtml = bridgeClaim == null
          ? null
          : md.renderToHtml(_bridgeItemParts(bridgeClaim).claim);
      final matchingBridge =
          actualBridgeHtml != null &&
          (bridgeUnchanged
              ? actualBridgeHtml == expectedBridgeHtml
              : RegExp(
                  '^${RegExp.escape(expectedBridgeHtml)}(?:[ .,:].*)?\$',
                  dotAll: true,
                ).hasMatch(actualBridgeHtml));
      if (!matchingBridge) {
        problems.add(
          '$path must contain exactly one matching WebGPU bridge claim for this release.',
        );
      }
      final baseline = section.whereType<md.Element>().where((node) {
        return node.tag == 'p' &&
            _ReleaseHtmlText()
                .read(md.renderToHtml(node.children!))
                .join(' ')
                .startsWith('Runtime baseline');
      }).singleOrNull;
      final matchingBaseline =
          baseline != null &&
          _stripVerifiedRuntimeRetentionHtml(
                md.renderToHtml(baseline.children!),
                previousNativePins,
                unchangedSuffix,
              ) ==
              md.renderToHtml(markdown.parseInline(expectedBaseline));
      if (!matchingBaseline) {
        problems.add(
          '$path must contain one complete Runtime baseline matching the candidate pins.',
        );
      }
      final footnotes = _renderedReleaseFootnotes(
        section,
        document,
        markdown.referencedFootnotes,
      );
      if (_releaseTextUnits(
            section,
            _ReleaseHtmlText(includeTitles: true),
            verifiedBridge: bridgeUnchanged && matchingBridge
                ? bridgeClaim
                : null,
            verifiedBaseline: matchingBaseline ? baseline : null,
          ).any(_unchangedFrom.hasMatch) ||
          _releaseTextUnits(
            footnotes,
            _ReleaseHtmlText(includeTitles: true),
          ).any(_unchangedFrom.hasMatch)) {
        problems.add(
          '$path contains an (unchanged from ...) claim that does not match the previous release.',
        );
      }
    }
  } on FormatException catch (error) {
    problems.add(error.message);
  } on FileSystemException catch (error) {
    problems.add(error.message);
  }
  return problems;
}

List<String> _verifyPreparedRelease(Directory root, String bridge, String tag) {
  if (!tag.startsWith('v') || !coreReleaseVersion.hasMatch(tag.substring(1))) {
    return ['Expected a stable previous release tag.'];
  }
  String readTagFile(String path) {
    final result = Process.runSync('git', [
      'show',
      'refs/tags/$tag:$path',
    ], workingDirectory: root.path);
    if (result.exitCode != 0) {
      throw FormatException('Cannot read $path from $tag.');
    }
    return result.stdout as String;
  }

  try {
    final previous = tag.substring(1);
    if (coreVersionFromPubspec(readTagFile(rootPubspecPath)) != previous) {
      return ['Previous tag $tag disagrees with its root pubspec.'];
    }
    final oldPin = _sourceOfTruth
        .allMatches(readTagFile(bridgeTagSourcePath))
        .toList();
    if (oldPin.length != 1) {
      return ['Previous tag $tag must identify one bridge pin.'];
    }
    return findPreparedReleaseNotesDrift(
      root,
      bridge,
      previous,
      oldPin.single[1]!,
      previousNativePins: readTagFile(nativeLlamaCppTagPath),
    );
  } on FormatException catch (error) {
    return [error.message];
  }
}

Future<void> main(List<String> arguments) async {
  final verifyManifestFlag = arguments.contains('--verify-manifest');
  final flags = arguments
      .where((argument) => argument != '--verify-manifest')
      .toList();
  final previousTag = switch (flags) {
    ['--release-prep', final tag] => tag,
    _ => null,
  };
  final unknown = previousTag == null ? flags : const <String>[];
  if (unknown.isNotEmpty) {
    stderr.writeln(
      '[webgpu-bridge-tag] Unknown argument(s): ${unknown.join(', ')}. '
      'Usage: check_webgpu_bridge_tag.dart [--verify-manifest] [--release-prep PREVIOUS_TAG]',
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

  final problems = await findBridgeProblems(
    repoRoot,
    expectedTag,
    verifyPublishedManifest: verifyManifestFlag,
  );
  if (previousTag != null) {
    problems.addAll(_verifyPreparedRelease(repoRoot, expectedTag, previousTag));
  }
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
    '[webgpu-bridge-tag] OK: '
    '${bridgeTagPins.length} live pins agree on '
    '$expectedTag.',
  );
  stdout.writeln(
    '[webgpu-bridge-tag] OK: Web runs upstream llama.cpp $bridgeLlamaCppTag '
    'beside native pin $bridgeApprovedNativePin.',
  );
  stdout.writeln(
    '[webgpu-bridge-tag] OK: ${bridgeProvenancePins.length} docs restate the '
    'release $bridgeAssetsReleaseId provenance correctly.',
  );
  if (verifyManifestFlag) {
    stdout.writeln(
      '[webgpu-bridge-tag] OK: immutable release $bridgeAssetsReleaseId '
      'publishes $expectedTag at commit $bridgeAssetsTagCommit with the '
      'approved manifest bytes.',
    );
  }
}
