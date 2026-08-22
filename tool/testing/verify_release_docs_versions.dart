#!/usr/bin/env dart

import 'dart:io';

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

final RegExp _dependencyLine = RegExp(
  r'^\s+(llamadart(?:_[a-z0-9_]+)?):\s+\^([0-9]+\.[0-9]+\.[0-9]+(?:[-+][^\s#]+)?)',
);
final RegExp _fenceLine = RegExp(r'^\s*```\s*([^\s`]*)?\s*$');
final RegExp _versionLine = RegExp(r'^version:\s*(\S+)\s*$');
final RegExp _nativeReleaseTag = RegExp(
  r'^(?:v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[1-9][0-9]*)?|'
  r'b[0-9]+(?:-[1-9][0-9]*|-llamadart\.[1-9][0-9]*)?)$',
);

void main() {
  final errors = <String>[];
  final versions = <String, String>{};
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
    if (!_nativeReleaseTag.hasMatch(pin)) {
      errors.add(
        '${entry.key} uses unsupported native tag $pin; expected stable '
        'vMAJOR.MINOR.PATCH, stable wrapper rebuild '
        'vMAJOR.MINOR.PATCH-N, historical/nightly bNNNN, nightly wrapper '
        'rebuild bNNNN-N, or legacy wrapper artifact bNNNN-llamadart.N.',
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
