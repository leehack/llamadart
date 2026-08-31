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
      r'^The example currently pins bridge assets to `(v\d+\.\d+\.\d+)`,',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/platforms/webgpu-bridge.md',
    RegExp(
      r'^  even though the bridge asset tag `(v\d+\.\d+\.\d+)` differs from the '
      r'native runtime tag$',
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
      r'^identified as `(v\d+\.\d+\.\d+)-local-[a-zA-Z0-9.-]+`\.$',
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
  BridgeTagPin(
    'website/docs/guides/text-to-speech.md',
    RegExp(r'^- The chat example pins `(v\d+\.\d+\.\d+)`,', multiLine: true),
  ),
];

/// Release-notes files whose current section restates the pinned tag.
///
/// The patterns are matched against [currentReleaseNotesSection] alone, so the
/// frozen sections below it keep the tags their releases shipped.
final List<BridgeTagPin> releaseNotesPins = <BridgeTagPin>[
  BridgeTagPin(
    'CHANGELOG.md',
    RegExp(
      r'^\* Aligned the default WebGPU bridge assets to `(v\d+\.\d+\.\d+)`',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/changelog/recent-releases.md',
    RegExp(
      r'^- Aligned default WebGPU bridge assets to `(v\d+\.\d+\.\d+)`',
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

/// The body of the top `## ` section of [contents] when it is the current one.
///
/// Ordinary development leaves the top section headed `## Unreleased`; a
/// release-prep change promotes that same section to `## $releaseVersion`.
/// Returns null for any other heading, so a gate reading this never mistakes a
/// frozen historical section for the current release notes.
String? currentReleaseNotesSection(String contents, String releaseVersion) {
  final match = _topReleaseNotesSection.firstMatch(contents);
  if (match == null) return null;
  final heading = match.namedGroup('heading');
  if (heading != 'Unreleased' && heading != releaseVersion) return null;
  return match.namedGroup('body');
}

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
  return <String>[
    ...problems,
    ...findCurrentReleaseNotesDrift(repoRoot, expectedTag),
  ];
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
const String bridgeLlamaCppTag = 'v0.3.0';

/// The exact upstream llama.cpp commit embedded in the pinned bridge assets.
const String bridgeLlamaCppCommit = 'c1d0e7a004015f23bc0233470b747b596f29b264';

/// The exact bridge source commit used to build the pinned bridge assets.
const String bridgeSourceCommit = '0bdc8286fd52b70da27f5b039e1b4278361da0be';

/// Canonical repository identities recorded in the approved manifest.
const String bridgeAssetsRepository = 'leehack/llama-web-bridge-assets';
const String bridgeSourceRepository = 'leehack/llama-web-bridge';
const String bridgeUpstreamRepository = 'ggml-org/llama.cpp';
const String bridgeNativeRepository = 'leehack/llamadart-native';

/// The native release tag the pinned bridge assets were qualified against.
const String bridgeNativeReleaseTag = 'v0.3.0';

/// The asset repository release that published the pinned bridge assets.
const String bridgeAssetsReleaseId = '379234159';

/// The asset repository commit the pinned bridge asset tag points at.
const String bridgeAssetsTagCommit = 'a18f1c31835ee722c7750a5c68f22c5b19e4c937';

/// SHA-256 hash of the exact approved published manifest.json.
const String bridgeManifestSha256 =
    '99fc09bb0cc23cf0eb08875a9ea973803fb1d432c5c8ca1b1211af0eb1d20b17';

/// Where the native runtime's llama.cpp build is pinned.
const String nativeLlamaCppTagPath = 'hook/build.dart';

final RegExp _nativeLlamaCppTag = RegExp(r"const _llamaCppTag = '([^']+)';");

final RegExp _stableNativeTag = RegExp(
  r'^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$',
);
final RegExp _stableWrapperTag = RegExp(
  r'^v(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)-([1-9]\d*)$',
);
final RegExp _legacyNativeTag = RegExp(r'^b(0|[1-9]\d*)$');
final RegExp _nightlyWrapperTag = RegExp(r'^b(0|[1-9]\d*)-([1-9]\d*)$');
final RegExp _legacyWrapperTag = RegExp(
  r'^b(0|[1-9]\d*)-llamadart\.([1-9]\d*)$',
);

/// Normalizes a native release tag (e.g., `v0.2.0-1` or `b10514-1`) to its
/// upstream llama.cpp release family (e.g., `v0.2.0` or `b10514`).
///
/// Returns null if the tag is malformed or not a recognized native release tag.
String? normalizeNativeLlamaCppTag(String nativeTag) {
  final stableWrapperMatch = _stableWrapperTag.firstMatch(nativeTag);
  if (stableWrapperMatch != null) {
    return 'v${stableWrapperMatch.group(1)}.${stableWrapperMatch.group(2)}.${stableWrapperMatch.group(3)}';
  }
  final stableMatch = _stableNativeTag.firstMatch(nativeTag);
  if (stableMatch != null) {
    return nativeTag;
  }
  final nightlyWrapperMatch = _nightlyWrapperTag.firstMatch(nativeTag);
  if (nightlyWrapperMatch != null) {
    return 'b${nightlyWrapperMatch.group(1)}';
  }
  final legacyWrapperMatch = _legacyWrapperTag.firstMatch(nativeTag);
  if (legacyWrapperMatch != null) {
    return 'b${legacyWrapperMatch.group(1)}';
  }
  final legacyMatch = _legacyNativeTag.firstMatch(nativeTag);
  if (legacyMatch != null) {
    return nativeTag;
  }
  return null;
}

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
      r'^- The pinned `v\d+\.\d+\.\d+` bridge assets embed llama\.cpp `(v\d+\.\d+\.\d+|b\d+)`, matching the native runtime$',
      multiLine: true,
    ),
  ),
];

/// The provenance values the docs restate for the pinned immutable release.
///
/// Each pattern matches one passage; every named group is checked against
/// [bridgeProvenanceValues]. The same seven values are written out in two docs,
/// so without this a partial bump leaves half the tree describing the previous
/// release with nothing failing.
final List<BridgeTagPin> bridgeProvenancePins = <BridgeTagPin>[
  BridgeTagPin(
    'doc/webgpu_bridge.md',
    RegExp(
      r'^\(`(?<nativeReleaseTag>[^`]+)`, both built from upstream llama\.cpp '
      r'`(?<upstreamTag>[^`@]+)@(?<upstreamCommit>[0-9a-f]{40})`\)\r?\n'
      r'even though the bridge asset tag `v\d+\.\d+\.\d+` differs from the '
      r'native runtime tag\r?\n'
      r'`v\d+\.\d+\.\d+`\. Provenance for this immutable consumer artifact: '
      r'release `(?<releaseId>\d+)`,\r?\n'
      r'tag commit `(?<tagCommit>[0-9a-f]{40})`, bridge source\r?\n'
      r'`(?<bridgeCommit>[0-9a-f]{40})`, and manifest SHA-256\r?\n'
      r'`(?<manifestSha256>[0-9a-f]{64})`\.',
      multiLine: true,
    ),
  ),
  BridgeTagPin(
    'website/docs/platforms/webgpu-bridge.md',
    RegExp(
      r'^  \(`(?<nativeReleaseTag>[^`]+)`, both built from upstream '
      r'`(?<upstreamTag>[^`@]+)@(?<upstreamCommit>[0-9a-f]{40})`\)\r?\n'
      r'  even though the bridge asset tag `v\d+\.\d+\.\d+` differs from the '
      r'native runtime tag\r?\n'
      r'  `v\d+\.\d+\.\d+`\. Pinned artifact provenance: release '
      r'`(?<releaseId>\d+)`, tag commit\r?\n'
      r'  `(?<tagCommit>[0-9a-f]{40})`, bridge source\r?\n'
      r'  `(?<bridgeCommit>[0-9a-f]{40})`, manifest SHA-256\r?\n'
      r'  `(?<manifestSha256>[0-9a-f]{64})`\.',
      multiLine: true,
    ),
  ),
];

/// The expected value behind each [bridgeProvenancePins] group name.
Map<String, String> get bridgeProvenanceValues => <String, String>{
  'nativeReleaseTag': bridgeNativeReleaseTag,
  'upstreamTag': bridgeLlamaCppTag,
  'upstreamCommit': bridgeLlamaCppCommit,
  'releaseId': bridgeAssetsReleaseId,
  'tagCommit': bridgeAssetsTagCommit,
  'bridgeCommit': bridgeSourceCommit,
  'manifestSha256': bridgeManifestSha256,
};

/// Returns one message per problem with the Web/native llama.cpp relationship.
///
/// `hook/build.dart` and the bridge manifest move in different repositories, so
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
      '$nativeLlamaCppTagPath: found ${matches.length} _llamaCppTag constants, '
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
    if (nativeTag != bridgeNativeReleaseTag) {
      problems.add(
        '$nativeLlamaCppTagPath pins $nativeTag, expected the bridge-qualified '
        'native anchor $bridgeNativeReleaseTag',
      );
    }
    if (normalizedNativeFamily != bridgeTag) {
      problems.add(
        'bridge assets embed llama.cpp $bridgeTag but $nativeLlamaCppTagPath '
        'pins $nativeTag (upstream family $normalizedNativeFamily) — Web and '
        'native must share the same upstream llama.cpp release',
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
    final found = matches.single.group(1)!;
    if (found != bridgeTag) {
      problems.add('${pin.path}: states $found, expected $bridgeTag');
    }
  }

  return problems;
}

/// Returns one message per provenance value a doc states incorrectly.
///
/// The bridge assets are consumed as an immutable artifact, so every value in
/// [bridgeProvenanceValues] identifies bytes that can be re-fetched and
/// re-hashed. Docs that restate them are pinned rather than trusted.
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

/// The transport result consumed by [verifyManifest].
class ManifestResponse {
  /// HTTP status returned by the manifest endpoint.
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
  int maximumBytes,
) async {
  final request = await client.getUrl(url);
  final response = await request.close();
  if (response.statusCode != HttpStatus.ok) {
    return ManifestResponse(response.statusCode, const <int>[]);
  }
  if (response.contentLength > maximumBytes) {
    throw HttpException(
      'manifest Content-Length ${response.contentLength} exceeds the '
      '$maximumBytes-byte limit',
      uri: url,
    );
  }

  final bytes = <int>[];
  await for (final chunk in response) {
    if (bytes.length + chunk.length > maximumBytes) {
      throw HttpException(
        'manifest body exceeds the $maximumBytes-byte limit',
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

/// Files that record past releases, where an old tag is correct. The current
/// release-notes claims in these files remain explicit [releaseNotesPins].
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

/// Runs every offline drift gate and the optional published-manifest gate.
Future<List<String>> findBridgeProblems(
  Directory repoRoot,
  String expectedTag, {
  bool verifyPublishedManifest = false,
  ManifestFetcher? manifestFetcher,
}) async => <String>[
  ...findBridgeTagDrift(repoRoot, expectedTag),
  ...findUnregisteredTagSites(repoRoot, expectedTag),
  ...findBridgeRuntimeDrift(repoRoot, bridgeLlamaCppTag),
  ...findBridgeProvenanceDrift(repoRoot),
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

Future<void> main(List<String> arguments) async {
  final verifyManifestFlag = arguments.contains('--verify-manifest');
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

  final problems = await findBridgeProblems(
    repoRoot,
    expectedTag,
    verifyPublishedManifest: verifyManifestFlag,
  );
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
    '${bridgeTagPins.length + releaseNotesPins.length} pins agree on '
    '$expectedTag.',
  );
  stdout.writeln(
    '[webgpu-bridge-tag] OK: Web and native both run upstream llama.cpp '
    '$bridgeLlamaCppTag.',
  );
  stdout.writeln(
    '[webgpu-bridge-tag] OK: ${bridgeProvenancePins.length} docs restate the '
    'release $bridgeAssetsReleaseId provenance correctly.',
  );
}
