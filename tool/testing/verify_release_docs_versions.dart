#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

import 'package:llamadart/src/hook/native_bundle_config.dart';

// Keep these maps in sync when adding companion packages or moving the current
// installation docs. Historical website/versioned_docs pages are intentionally
// excluded so archived release docs can keep their original package versions.
//
// During release-prep PRs, current install docs are expected to track the
// in-repository package versions being prepared. Publishing still happens only
// after merge; the release-prep PR merge is the approval boundary for the
// post-merge release automation.
const Map<String, String> _packagePubspecs = <String, String>{
  'llamadart': 'pubspec.yaml',
  'llamadart_llama_cpp_flutter':
      'packages/llamadart_llama_cpp_flutter/pubspec.yaml',
  'llamadart_litert_lm_flutter':
      'packages/llamadart_litert_lm_flutter/pubspec.yaml',
};

const Map<String, List<String>> _currentDocDependencies =
    <String, List<String>>{
      'README.md': <String>[
        'llamadart',
        'llamadart_llama_cpp_flutter',
        'llamadart_litert_lm_flutter',
      ],
      'website/docs/getting-started/installation.md': <String>[
        'llamadart',
        'llamadart_llama_cpp_flutter',
        'llamadart_litert_lm_flutter',
      ],
      'packages/llamadart_llama_cpp_flutter/README.md': <String>[
        'llamadart',
        'llamadart_llama_cpp_flutter',
      ],
      'packages/llamadart_litert_lm_flutter/README.md': <String>[
        'llamadart',
        'llamadart_litert_lm_flutter',
      ],
    };

final Map<String, RegExp> _currentNativePins = <String, RegExp>{
  'hook/build.dart': RegExp(r"const _llamaCppTag = '([^']+)';"),
  'packages/llamadart_llama_cpp_flutter/darwin/'
      'llamadart_llama_cpp_flutter/Package.swift': RegExp(
    r'let llamaCppTag = "([^"]+)"',
  ),
  'packages/llamadart_llama_cpp_flutter/README.md': RegExp(
    r'The Apple SwiftPM manifest pins\s+`leehack/llamadart-native@([^`]+)`\.',
  ),
  'README.md': RegExp(
    r'\| Native llama\.cpp / GGUF \| `leehack/llamadart-native@([^`]+)` \|',
  ),
  'website/docs/getting-started/installation.md': RegExp(
    r'llamadart_native_tag:\s*([^\s#]+)',
  ),
  'website/docs/platforms/support-matrix.md': RegExp(
    r'The native-assets hook currently pins `llamadart-native` tag\s+`([^`]+)`',
  ),
};

/// Current docs whose prose calls a specific native tag the default runtime.
///
/// Release notes and `website/versioned_docs` pages are excluded because they
/// describe the pin that was current when they were written. The WebGPU pages
/// are excluded too: bridge assets deliberately trail the native pin, and
/// `tool/testing/check_webgpu_bridge_tag.dart` owns that divergence.
/// `README.md` and `website/docs/getting-started/installation.md` are excluded
/// as well, but their coverage differs by site. [_currentNativePins] checks
/// `README.md`'s pin table row and `installation.md`'s `llamadart_native_tag:`
/// override, so scanning those here would duplicate that contract.
/// `installation.md`'s prose `leehack/llamadart-native@<tag>` claim is not in
/// [_currentNativePins]; `tool/native/sync_native_release_pins.py` rewrites
/// every `leehack/llamadart-native@<tag>` occurrence in these docs and owns
/// keeping it current.
const List<String> defaultRuntimeClaimDocs = <String>[
  'website/docs/platforms/support-matrix.md',
  'website/docs/guides/performance-tuning.md',
];

final RegExp _defaultRuntimeClaim = RegExp(
  r'(?:default|package-pinned)\s+`([^`]+)`\s+runtime',
);

/// Matches the `owner/repo@` prefix docs may put in front of a native tag.
final RegExp _qualifiedTagPrefix = RegExp(r'^[\w.-]+/[\w.-]+@');

/// Returns one message per sentence in [contents] calling a tag other than
/// [expectedPin] the default native runtime.
///
/// [_currentNativePins] only covers sites that declare the pin; prose asserting
/// which runtime ships drifts silently when the pin moves, leaving the docs
/// recommending a runtime nobody ships. Pin-agnostic wording names no tag and
/// is always accepted. A claim may name the tag bare or as
/// `owner/repo@<tag>`; both compare by tag.
List<String> findStaleDefaultRuntimeClaims(
  String path,
  String contents,
  String expectedPin,
) {
  final problems = <String>[];
  for (final match in _defaultRuntimeClaim.allMatches(contents)) {
    final claimed = match.group(1)!.replaceFirst(_qualifiedTagPrefix, '');
    if (claimed == expectedPin) {
      continue;
    }
    final line = contents.substring(0, match.start).split('\n').length;
    problems.add(
      '$path:$line calls $claimed the default native runtime, but '
      'hook/build.dart pins $expectedPin.',
    );
  }
  return problems;
}

/// A companion package whose Apple SwiftPM pin must already be recorded in the
/// CHANGELOG section its `pubspec.yaml` version will publish.
///
/// `hook/build.dart` and `Package.swift` agreeing is not enough: a companion
/// publishes the tag its own released section documents, and
/// `release_on_prep_merge.yml` silently skips a companion whose version is
/// already on pub.dev. Without this check a moved pin can sit in `Unreleased`
/// forever while the release ships the previous tag.
class CompanionSwiftPin {
  /// Package name, as in `pubspec.yaml`.
  final String package;

  /// Repository-relative package directory.
  final String root;

  /// Matches the tag in the package's `Package.swift`; group 1 is the tag.
  final RegExp swiftTag;

  /// Native repository the CHANGELOG names, as `owner/repo`.
  final String nativeRepo;

  /// Creates a companion pin site.
  const CompanionSwiftPin({
    required this.package,
    required this.root,
    required this.swiftTag,
    required this.nativeRepo,
  });

  /// Path of the package's SwiftPM manifest.
  String get swiftPackagePath => '$root/darwin/$package/Package.swift';

  /// Path of the package's CHANGELOG.
  String get changelogPath => '$root/CHANGELOG.md';

  /// Path of the package's pubspec.
  String get pubspecPath => '$root/pubspec.yaml';

  /// Matches the tag a CHANGELOG entry records; group 1 is the tag.
  RegExp get changelogTag => RegExp('`${RegExp.escape(nativeRepo)}@([^`]+)`');
}

/// Every companion package that pins a native runtime through SwiftPM.
final List<CompanionSwiftPin> companionSwiftPins = <CompanionSwiftPin>[
  CompanionSwiftPin(
    package: 'llamadart_llama_cpp_flutter',
    root: 'packages/llamadart_llama_cpp_flutter',
    swiftTag: RegExp(r'let llamaCppTag = "([^"]+)"'),
    nativeRepo: 'leehack/llamadart-native',
  ),
  CompanionSwiftPin(
    package: 'llamadart_litert_lm_flutter',
    root: 'packages/llamadart_litert_lm_flutter',
    swiftTag: RegExp(r'let liteRtLmTag = "([^"]+)"'),
    nativeRepo: 'leehack/litert-lm-native',
  ),
];

/// A companion whose SwiftPM pin is recorded only under `## Unreleased`.
///
/// Native-sync PRs deliberately leave this state behind; a release-prep PR must
/// resolve it. See `website/docs/maintainers/release-workflow.md`.
class PendingCompanionBump {
  /// Package name.
  final String package;

  /// Version currently in `pubspec.yaml`.
  final String version;

  /// Tag `Package.swift` pins.
  final String swiftPin;

  /// Tag the `## $version` section records.
  final String releasedPin;

  /// Creates a pending bump record.
  const PendingCompanionBump({
    required this.package,
    required this.version,
    required this.swiftPin,
    required this.releasedPin,
  });

  @override
  String toString() =>
      '$package $version publishes $releasedPin, but Package.swift pins '
      '$swiftPin; bump the version and rename `## Unreleased` to the new '
      'version before releasing.';
}

/// Checks that every companion's SwiftPM pin is documented in the CHANGELOG
/// section its `pubspec.yaml` version will publish.
///
/// Appends hard failures to [errors] and returns the companions whose pin is
/// still sitting in `## Unreleased`. Callers decide whether a pending bump is
/// tolerable: it is during native sync, and never during release prep.
List<PendingCompanionBump> checkCompanionSwiftPins(
  Directory repoRoot,
  List<String> errors,
) {
  final pending = <PendingCompanionBump>[];
  for (final companion in companionSwiftPins) {
    final swiftPin = _matchInFile(
      repoRoot,
      companion.swiftPackagePath,
      companion.swiftTag,
      'SwiftPM native tag',
      errors,
    );
    final version = _matchInFile(
      repoRoot,
      companion.pubspecPath,
      RegExp(r'^version:\s*(\S+)\s*$', multiLine: true),
      'version field',
      errors,
    );
    if (swiftPin == null || version == null) {
      continue;
    }

    final sections = _changelogSections(
      repoRoot,
      companion.changelogPath,
      errors,
    );
    if (sections == null) {
      continue;
    }

    final released = sections[version];
    if (released == null) {
      errors.add(
        '${companion.changelogPath} has no `## $version` section for the '
        'version in ${companion.pubspecPath}.',
      );
      continue;
    }

    final releasedPin = companion.changelogTag.firstMatch(released)?.group(1);
    if (releasedPin == null) {
      errors.add(
        '${companion.changelogPath} section `## $version` does not record a '
        '`${companion.nativeRepo}@<tag>` pin.',
      );
      continue;
    }
    if (releasedPin == swiftPin) {
      continue;
    }

    final unreleasedPin = companion.changelogTag
        .firstMatch(sections['Unreleased'] ?? '')
        ?.group(1);
    if (unreleasedPin != swiftPin) {
      errors.add(
        '${companion.swiftPackagePath} pins $swiftPin, but '
        '${companion.changelogPath} section `## $version` records '
        '$releasedPin and no `## Unreleased` entry records $swiftPin.',
      );
      continue;
    }

    pending.add(
      PendingCompanionBump(
        package: companion.package,
        version: version,
        swiftPin: swiftPin,
        releasedPin: releasedPin,
      ),
    );
  }
  return pending;
}

/// Returns section bodies keyed by heading text, or null when unreadable.
Map<String, String>? _changelogSections(
  Directory repoRoot,
  String path,
  List<String> errors,
) {
  final file = File('${repoRoot.path}/$path');
  if (!file.existsSync()) {
    errors.add('$path does not exist.');
    return null;
  }
  final sections = <String, String>{};
  var hasDuplicateHeading = false;
  String? heading;
  final body = StringBuffer();
  void flush() {
    final current = heading;
    if (current != null) {
      if (sections.containsKey(current)) {
        errors.add('$path contains duplicate `## $current` sections.');
        hasDuplicateHeading = true;
      } else {
        sections[current] = body.toString();
      }
    }
    body.clear();
  }

  late final List<String> lines;
  try {
    lines = file.readAsLinesSync();
  } on FileSystemException catch (error) {
    errors.add('$path could not be read: $error');
    return null;
  } on FormatException catch (error) {
    errors.add('$path could not be decoded as UTF-8 text: $error');
    return null;
  }

  for (final line in lines) {
    final match = RegExp(r'^##\s+(.*\S)\s*$').firstMatch(line);
    if (match != null) {
      flush();
      heading = match.group(1)!;
      continue;
    }
    body.writeln(line);
  }
  flush();
  return hasDuplicateHeading ? null : sections;
}

/// Returns group 1 of [pattern] in [path], recording an error when absent.
String? _matchInFile(
  Directory repoRoot,
  String path,
  RegExp pattern,
  String what,
  List<String> errors,
) {
  final file = File('${repoRoot.path}/$path');
  if (!file.existsSync()) {
    errors.add('$path does not exist.');
    return null;
  }
  late final String contents;
  try {
    contents = file.readAsStringSync();
  } on FileSystemException catch (error) {
    errors.add('$path could not be read: $error');
    return null;
  } on FormatException catch (error) {
    errors.add('$path could not be decoded as UTF-8 text: $error');
    return null;
  }
  final match = pattern.firstMatch(contents);
  if (match == null) {
    errors.add('$path does not contain its $what.');
    return null;
  }
  return match.group(1)!;
}

final RegExp _dependencyLine = RegExp(
  r'^\s+(llamadart(?:_[a-z0-9_]+)?):\s+\^([0-9]+\.[0-9]+\.[0-9]+(?:[-+][^\s#]+)?)',
);
final RegExp _fenceLine = RegExp(r'^\s*```\s*([^\s`]*)?\s*$');
final RegExp _versionLine = RegExp(r'^version:\s*(\S+)\s*$');
void main(List<String> arguments) {
  final releasePrep = arguments.contains('--release-prep');
  final unknown = arguments.where((argument) => argument != '--release-prep');
  if (unknown.isNotEmpty) {
    stderr.writeln(
      'Unknown argument(s): ${unknown.join(', ')}. '
      'Usage: verify_release_docs_versions.dart [--release-prep]',
    );
    exitCode = 64;
    return;
  }

  final errors = <String>[];
  final versions = <String, String>{};
  var pending = const <PendingCompanionBump>[];
  String? nativePin;
  for (final entry in _packagePubspecs.entries) {
    final version = _readPubspecVersion(entry.value, errors);
    if (version != null) {
      versions[entry.key] = version;
    }
  }

  if (errors.isEmpty) {
    for (final entry in _currentDocDependencies.entries) {
      _checkCurrentDoc(
        path: entry.key,
        expectedPackages: entry.value,
        versions: versions,
        errors: errors,
      );
    }
    nativePin = _checkCurrentNativePins(errors);
    if (nativePin != null) {
      for (final path in defaultRuntimeClaimDocs) {
        final lines = _readLines(path, errors);
        if (lines != null) {
          errors.addAll(
            findStaleDefaultRuntimeClaims(path, lines.join('\n'), nativePin),
          );
        }
      }
    }
    checkNativeTagGrammarDocContracts(Directory.current, errors);
    pending = checkCompanionSwiftPins(Directory.current, errors);
    if (releasePrep) {
      errors.addAll(pending.map((bump) => bump.toString()));
    }
  }

  if (errors.isNotEmpty) {
    stderr.writeln('Release docs version verification failed:');
    for (final error in errors) {
      stderr.writeln('- $error');
    }
    exitCode = 1;
    return;
  }

  stdout.writeln(
    'Release docs versions verified: '
    '${versions.entries.map((entry) => '${entry.key} ${entry.value}').join(', ')}; '
    'llamadart-native $nativePin.',
  );
  for (final bump in pending) {
    stdout.writeln('Pending companion bump: $bump');
  }
}

String? _checkCurrentNativePins(List<String> errors) {
  final pins = <String, String>{};
  for (final entry in _currentNativePins.entries) {
    final file = File(entry.key);
    if (!file.existsSync()) {
      errors.add('${entry.key} does not exist.');
      continue;
    }

    String text;
    try {
      text = file.readAsStringSync();
    } on FileSystemException catch (error) {
      errors.add('Could not read ${entry.key}: ${error.message}.');
      continue;
    }

    final match = entry.value.firstMatch(text);
    if (match == null) {
      errors.add('${entry.key} does not contain its current native pin.');
      continue;
    }
    final pin = match.group(1)!;
    if (!isValidNativeReleaseTag(pin)) {
      errors.add(
        '${entry.key} uses unsupported native tag $pin; expected stable '
        'vMAJOR.MINOR.PATCH, stable wrapper rebuild '
        'vMAJOR.MINOR.PATCH-N, canonical historical/nightly bNNNN without '
        'leading zeros, nightly wrapper '
        'rebuild bNNNN-N, or legacy wrapper artifact bNNNN-llamadart.N; '
        'numeric components may contain at most 18 digits.',
      );
      continue;
    }
    pins[entry.key] = pin;
  }

  if (pins.isEmpty) {
    return null;
  }
  final expectedPin = pins['hook/build.dart'] ?? pins.values.first;
  for (final entry in pins.entries) {
    if (entry.value != expectedPin) {
      errors.add(
        '${entry.key} pins native tag ${entry.value}, but hook/build.dart '
        'pins $expectedPin.',
      );
    }
  }
  return expectedPin;
}

String? _readPubspecVersion(String path, List<String> errors) {
  final lines = _readLines(path, errors);
  if (lines == null) {
    return null;
  }

  for (final line in lines) {
    final match = _versionLine.firstMatch(line);
    if (match != null) {
      return match.group(1)!;
    }
  }

  errors.add('$path does not contain a top-level version field.');
  return null;
}

void _checkCurrentDoc({
  required String path,
  required List<String> expectedPackages,
  required Map<String, String> versions,
  required List<String> errors,
}) {
  final expectedPackageSet = expectedPackages.toSet();
  final seen = <String>{};
  final lines = _readLines(path, errors);
  if (lines == null) {
    return;
  }

  var inFence = false;
  var inYamlFence = false;
  for (var index = 0; index < lines.length; index += 1) {
    final line = lines[index];
    final fenceMatch = _fenceLine.firstMatch(line);
    if (fenceMatch != null) {
      if (inFence) {
        inFence = false;
        inYamlFence = false;
      } else {
        final language = fenceMatch.group(1)?.toLowerCase();
        inFence = true;
        inYamlFence = language == 'yaml' || language == 'yml';
      }
      continue;
    }

    if (!inYamlFence) {
      continue;
    }

    final match = _dependencyLine.firstMatch(line);
    if (match == null) {
      continue;
    }

    final package = match.group(1)!;
    if (!expectedPackageSet.contains(package)) {
      continue;
    }

    seen.add(package);
    final documentedVersion = match.group(2)!;
    final expectedVersion = versions[package]!;
    if (documentedVersion != expectedVersion) {
      errors.add(
        '$path:${index + 1} documents $package ^$documentedVersion, '
        'but ${packagePubspecPath(package)} is $expectedVersion.',
      );
    }
  }

  for (final package in expectedPackages) {
    if (!seen.contains(package)) {
      errors.add(
        '$path is missing a current YAML dependency snippet for '
        '$package ^${versions[package]}.',
      );
    }
  }
}

List<String>? _readLines(String path, List<String> errors) {
  final file = File(path);
  if (!file.existsSync()) {
    errors.add('$path does not exist.');
    return null;
  }

  try {
    return file.readAsLinesSync();
  } on FileSystemException catch (error) {
    errors.add('Could not read $path: ${error.message}.');
    return null;
  }
}

String packagePubspecPath(String package) => _packagePubspecs[package]!;

void checkNativeTagGrammarDocContracts(
  Directory repoRoot,
  List<String> errors,
) {
  const fixturePath = 'tool/native/fixtures/native_release_tag_grammar.json';
  final fixtureFile = File('${repoRoot.path}/$fixturePath');
  if (!fixtureFile.existsSync()) {
    errors.add('$fixturePath does not exist.');
    return;
  }

  late final Object? decoded;
  try {
    decoded = jsonDecode(fixtureFile.readAsStringSync());
  } on FileSystemException catch (error) {
    errors.add('Could not read $fixturePath: ${error.message}.');
    return;
  } on FormatException catch (error) {
    errors.add('$fixturePath is not valid JSON: ${error.message}.');
    return;
  }
  if (decoded is! Map<String, dynamic>) {
    errors.add('$fixturePath must contain a JSON object.');
    return;
  }
  final contract = decoded['documentation_contract'];
  if (contract is! Map<String, dynamic>) {
    errors.add('$fixturePath has no documentation_contract object.');
    return;
  }
  final workflow = contract['workflow'];
  if (workflow is! Map<String, dynamic> ||
      workflow['path'] is! String ||
      workflow['input'] is! String ||
      workflow['required_text'] is! String) {
    errors.add('$fixturePath has an invalid workflow documentation contract.');
    return;
  }
  final workflowPath = workflow['path'] as String;
  final workflowInput = workflow['input'] as String;
  final expectedDescription = workflow['required_text'] as String;
  final workflowLines = _readLinesFromRoot(repoRoot, workflowPath, errors);
  if (workflowLines != null) {
    final inputLine = '      $workflowInput:';
    final inputStart = workflowLines.indexOf(inputLine);
    final nextInput = inputStart < 0
        ? -1
        : workflowLines.indexWhere(
            (line) => RegExp(r'^      [a-zA-Z0-9_]+:$').hasMatch(line),
            inputStart + 1,
          );
    final inputEnd = nextInput < 0 ? workflowLines.length : nextInput;
    final inputBlock = inputStart < 0
        ? const <String>[]
        : workflowLines.sublist(inputStart + 1, inputEnd);
    if (!inputBlock.contains('        $expectedDescription')) {
      errors.add(
        '$workflowPath $workflowInput input description does not match the '
        'canonical native tag grammar contract.',
      );
    }
  }

  final docs = contract['docs'];
  if (docs is! Map<String, dynamic>) {
    errors.add('$fixturePath has no documentation_contract.docs object.');
    return;
  }
  for (final entry in docs.entries) {
    final rawRequirements = entry.value;
    if (rawRequirements is! List<dynamic> ||
        rawRequirements.any((value) => value is! String)) {
      errors.add('$fixturePath has invalid doc requirements for ${entry.key}.');
      continue;
    }
    final lines = _readLinesFromRoot(repoRoot, entry.key, errors);
    if (lines == null) continue;
    final normalized = lines.join(' ').replaceAll(RegExp(r'\s+'), ' ');
    for (final requirement in rawRequirements.cast<String>()) {
      final normalizedRequirement = requirement.replaceAll(RegExp(r'\s+'), ' ');
      if (!normalized.contains(normalizedRequirement)) {
        errors.add(
          '${entry.key} is missing native release tag contract requirement: '
          '"$requirement".',
        );
      }
    }
  }
}

List<String>? _readLinesFromRoot(
  Directory repoRoot,
  String relativePath,
  List<String> errors,
) {
  final file = File('${repoRoot.path}/$relativePath');
  if (!file.existsSync()) {
    errors.add('$relativePath does not exist.');
    return null;
  }

  try {
    return file.readAsLinesSync();
  } on FileSystemException catch (error) {
    errors.add('Could not read $relativePath: ${error.message}.');
    return null;
  } on FormatException catch (error) {
    errors.add('$relativePath is not valid UTF-8 text: ${error.message}.');
    return null;
  }
}
