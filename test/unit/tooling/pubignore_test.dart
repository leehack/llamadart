@TestOn('vm')
library;

import 'dart:io';

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
      ]) {
        expect(
          await _isIgnored(repository, candidate),
          isTrue,
          reason: candidate,
        );
      }
    },
  );

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
