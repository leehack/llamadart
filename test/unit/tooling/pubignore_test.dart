@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory repository;

  setUpAll(() async {
    repository = await Directory.systemTemp.createTemp('pubignore_contract_');
    await File(
      '.pubignore',
    ).copy('${repository.path}${Platform.pathSeparator}.gitignore');

    final result = await Process.run('git', [
      'init',
      '--quiet',
    ], workingDirectory: repository.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    await File(
      '${repository.path}${Platform.pathSeparator}.git'
      '${Platform.pathSeparator}empty_excludes',
    ).writeAsString('');
    // check-ignore also reads .git/info/exclude, which init.templateDir can
    // populate on a contributor's machine.
    await File(
      '${repository.path}${Platform.pathSeparator}.git'
      '${Platform.pathSeparator}info'
      '${Platform.pathSeparator}exclude',
    ).writeAsString('');
  });

  tearDownAll(() async {
    await repository.delete(recursive: true);
  });

  test('anchors repository-only documentation exclusions at the root', () async {
    for (final candidate in <String>[
      'doc/testing_matrix.md',
      'docs/scratch.md',
      'website/docs/index.md',
    ]) {
      expect(
        await _isIgnored(repository, candidate),
        isTrue,
        reason: candidate,
      );
    }

    for (final candidate in <String>[
      'tool/docs/build_site.sh',
      'example/llamadart_server/lib/src/features/openai_api/presentation/docs/docs.dart',
      'nested/doc/public_api.md',
      'skills/llamadart-getting-started/SKILL.md',
    ]) {
      expect(
        await _isIgnored(repository, candidate),
        isFalse,
        reason: candidate,
      );
    }
  });

  test(
    'core archive excludes the independent adapter and its dependency state',
    () async {
      for (final candidate in <String>[
        'packages/genkit_llamadart/pubspec.yaml',
        'packages/genkit_llamadart/lib/genkit_llamadart.dart',
        'packages/genkit_llamadart/skills/genkit-llamadart-getting-started/SKILL.md',
        'packages/genkit_llamadart/pubspec_overrides.yaml',
        'packages/llamadart_model_store/pubspec.yaml',
        'packages/llamadart_model_store/lib/llamadart_model_store.dart',
        'packages/llamadart_studio_core/pubspec.yaml',
        'packages/llamadart_studio/pubspec.yaml',
      ]) {
        expect(
          await _isIgnored(repository, candidate),
          isTrue,
          reason: candidate,
        );
      }
    },
  );

  test('core archive rejects checkout-only files', () async {
    const shipped = <String>[
      'pubspec.yaml',
      'lib/llamadart.dart',
      'hook/build.dart',
      'example/basic_app/pubspec.yaml',
      'example/basic_app/bin/llamadart_litert_embedding_example.dart',
      'example/basic_app/assets/demo.wav',
    ];
    Future<List<Object?>> errors(List<String> files) async {
      final result = await Process.run(
        Platform.isWindows ? 'python' : 'python3',
        [
          '-c',
          'import json,runpy,sys; '
              'm=runpy.run_path("tool/release/check_core_archive.py"); '
              'print(json.dumps(m["archive_errors"](json.loads(sys.argv[1]))))',
          jsonEncode(files),
        ],
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return jsonDecode(result.stdout as String) as List<Object?>;
    }

    expect(await errors(shipped), isEmpty);
    for (final package in [
      'packages/genkit_llamadart/pubspec.yaml',
      'packages/llamadart_model_store/pubspec.yaml',
      'packages/llamadart_validation/pubspec.yaml',
      'packages/llamadart_studio_core/pubspec.yaml',
      'packages/llamadart_studio/pubspec.yaml',
    ]) {
      expect(await errors([...shipped, package]), isNotEmpty, reason: package);
    }
    for (final audio in [
      'test/fixtures/librispeech_dev_clean/1272-128104-0000.wav',
      'test/e2e/backends/fixtures/clip.FLAC',
    ]) {
      expect(await errors([...shipped, audio]), [
        'checkout-only test audio included: $audio',
      ]);
    }
    expect(
      await _isIgnored(repository, 'test/fixtures/librispeech_dev_clean/'),
      isTrue,
      reason: 'LibriSpeech fixture directory',
    );
  });

  test('leaves companion checkout overrides out of the core archive', () async {
    expect(
      await _isIgnored(
        repository,
        'packages/llamadart_llama_cpp_flutter/pubspec_overrides.yaml',
      ),
      isTrue,
    );
    expect(
      await _isIgnored(
        repository,
        'packages/llamadart_llama_cpp_flutter/pubspec.yaml',
      ),
      isFalse,
    );
  });

  test(
    'shipped package Markdown links do not target .pubignore-excluded paths',
    () async {
      final shippedMarkdown = await _shippedMarkdownFiles(repository);
      expect(
        shippedMarkdown,
        containsAll(<String>[
          'README.md',
          'skills/llamadart-flutter-app/SKILL.md',
          'example/basic_app/README.md',
        ]),
      );

      final violations = <String>[];
      for (final filePath in shippedMarkdown) {
        final markdown = File(filePath).readAsStringSync();
        violations.addAll(
          await _excludedRelativeMarkdownLinks(repository, filePath, markdown),
        );
      }

      expect(
        violations,
        isEmpty,
        reason:
            'Relative links in shipped Markdown fail in installed pub '
            'packages when .pubignore excludes their targets.',
      );
    },
  );

  test('shipped Markdown link check rejects excluded relative targets', () async {
    expect(
      await _excludedRelativeMarkdownLinks(
        repository,
        'README.md',
        '[Android Vulkan](website/docs/platforms/known-platform-issues.md#android)\n'
            '[shutdown contract](doc/llama_cpp_exit_teardown.md#creation-time-owner-preparation)',
      ),
      <String>[
        'README.md -> website/docs/platforms/known-platform-issues.md#android '
            '(resolved: website/docs/platforms/known-platform-issues.md)',
        'README.md -> doc/llama_cpp_exit_teardown.md#creation-time-owner-preparation '
            '(resolved: doc/llama_cpp_exit_teardown.md)',
      ],
    );
    expect(
      await _excludedRelativeMarkdownLinks(
        repository,
        'skills/llamadart-flutter-app/SKILL.md',
        '[the platform limits](../../website/docs/platforms/known-platform-issues.md#android)',
      ),
      <String>[
        'skills/llamadart-flutter-app/SKILL.md -> '
            '../../website/docs/platforms/known-platform-issues.md#android '
            '(resolved: website/docs/platforms/known-platform-issues.md)',
      ],
    );
    expect(
      await _excludedRelativeMarkdownLinks(
        repository,
        'example/basic_app/README.md',
        '[schema subset](../../website/docs/guides/tool-calling.md#import-a-json-schema)\n'
            '[maintainer recipe](../../doc/image_weight_formats.md)',
      ),
      <String>[
        'example/basic_app/README.md -> '
            '../../website/docs/guides/tool-calling.md#import-a-json-schema '
            '(resolved: website/docs/guides/tool-calling.md)',
        'example/basic_app/README.md -> ../../doc/image_weight_formats.md '
            '(resolved: doc/image_weight_formats.md)',
      ],
    );
  });
}

final RegExp _markdownLinkPattern = RegExp(r'!?\[[^\]]*\]\(([^)\r\n]+)\)');
final RegExp _uriSchemePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:');
final RegExp _fencedCodeBlockPattern = RegExp(
  r'(^|\n)(`{3,}|~{3,})[^\n]*\n[\s\S]*?\n\2(?=\n|$)',
);
final RegExp _inlineCodePattern = RegExp(r'`[^`\n]*`');

Future<List<String>> _shippedMarkdownFiles(Directory repository) async {
  final candidates = <String>['README.md'];
  for (final rootName in const <String>['skills', 'example']) {
    final root = Directory(rootName);
    if (!root.existsSync()) {
      continue;
    }
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final relativePath = p.posix.normalize(entity.path.replaceAll(r'\', '/'));
      if (!relativePath.endsWith('.md')) {
        continue;
      }
      if (relativePath.contains('/.dart_tool/') ||
          relativePath.contains('/build/') ||
          relativePath.contains('/.pub/')) {
        continue;
      }
      if (!await _isIgnored(repository, relativePath)) {
        candidates.add(relativePath);
      }
    }
  }
  candidates.sort();
  return candidates;
}

Future<List<String>> _excludedRelativeMarkdownLinks(
  Directory repository,
  String sourcePath,
  String markdown,
) async {
  final normalizedSource = sourcePath.replaceAll(r'\', '/');
  final sourceDir = p.posix.dirname(normalizedSource);
  final prose = markdown
      .replaceAll('\r\n', '\n')
      .replaceAll(_fencedCodeBlockPattern, '\n')
      .replaceAll(_inlineCodePattern, '');

  final violations = <String>[];
  for (final match in _markdownLinkPattern.allMatches(prose)) {
    final rawDestination = match.group(1)!.trim();
    final targetPath = _extractRelativeLinkPath(rawDestination);
    if (targetPath == null) {
      continue;
    }

    final resolved = p.posix.isAbsolute(targetPath)
        ? targetPath
        : p.posix.normalize(
            sourceDir == '.' ? targetPath : p.posix.join(sourceDir, targetPath),
          );
    final escapesRoot =
        p.posix.isAbsolute(resolved) ||
        resolved == '..' ||
        resolved.startsWith('../');
    if (escapesRoot || await _isIgnoredTarget(repository, resolved)) {
      violations.add(
        '$normalizedSource -> $rawDestination (resolved: $resolved)',
      );
    }
  }
  return violations;
}

String? _extractRelativeLinkPath(String rawDestination) {
  if (rawDestination.isEmpty) {
    return null;
  }
  var destination = rawDestination;
  if (destination.startsWith('<')) {
    final closeIndex = destination.indexOf('>');
    if (closeIndex > 1) {
      destination = destination.substring(1, closeIndex);
    }
  } else {
    destination = destination.split(RegExp(r'\s+')).first;
  }
  if (destination.isEmpty ||
      destination.startsWith('#') ||
      _uriSchemePattern.hasMatch(destination)) {
    return null;
  }
  final withoutFragment = destination.split('#').first;
  final withoutQuery = withoutFragment.split('?').first;
  if (withoutQuery.isEmpty) {
    return null;
  }
  return withoutQuery;
}

Future<bool> _isIgnoredTarget(Directory repository, String candidate) async {
  if (await _isIgnored(repository, candidate)) {
    return true;
  }
  if (!candidate.endsWith('/') && Directory(candidate).existsSync()) {
    return _isIgnored(repository, '$candidate/');
  }
  return false;
}

Future<bool> _isIgnored(Directory repository, String candidate) async {
  final emptyExcludes =
      '${repository.path}${Platform.pathSeparator}.git'
      '${Platform.pathSeparator}empty_excludes';
  final result = await Process.run('git', [
    '-c',
    'core.excludesFile=$emptyExcludes',
    'check-ignore',
    '--no-index',
    '--quiet',
    candidate,
  ], workingDirectory: repository.path);
  if (result.exitCode == 0) {
    return true;
  }
  if (result.exitCode == 1) {
    return false;
  }
  fail(
    'git check-ignore failed for $candidate: '
    '${result.stdout}\n${result.stderr}',
  );
}
