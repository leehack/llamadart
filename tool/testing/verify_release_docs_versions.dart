#!/usr/bin/env dart

import 'dart:io';

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

final RegExp _dependencyLine = RegExp(
  r'^\s+(llamadart(?:_[a-z0-9_]+)?):\s+\^([0-9]+\.[0-9]+\.[0-9]+(?:[-+][^\s#]+)?)',
);

void main() {
  final versions = <String, String>{
    for (final entry in _packagePubspecs.entries)
      entry.key: _readPubspecVersion(entry.value),
  };

  final errors = <String>[];
  for (final entry in _currentDocDependencies.entries) {
    _checkCurrentDoc(
      path: entry.key,
      expectedPackages: entry.value,
      versions: versions,
      errors: errors,
    );
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
    '${versions.entries.map((entry) => '${entry.key} ${entry.value}').join(', ')}.',
  );
}

String _readPubspecVersion(String path) {
  final lines = File(path).readAsLinesSync();
  for (final line in lines) {
    final match = RegExp(r'^version:\s*(\S+)\s*$').firstMatch(line);
    if (match != null) {
      return match.group(1)!;
    }
  }
  throw StateError('$path does not contain a top-level version field.');
}

void _checkCurrentDoc({
  required String path,
  required List<String> expectedPackages,
  required Map<String, String> versions,
  required List<String> errors,
}) {
  final expectedPackageSet = expectedPackages.toSet();
  final seen = <String>{};
  final lines = File(path).readAsLinesSync();

  for (var index = 0; index < lines.length; index += 1) {
    final match = _dependencyLine.firstMatch(lines[index]);
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
        '$path is missing a current dependency snippet for '
        '$package ^${versions[package]}.',
      );
    }
  }
}

String packagePubspecPath(String package) => _packagePubspecs[package]!;
