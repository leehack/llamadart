@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  late Directory repository;

  setUpAll(() async {
    repository = await Directory.systemTemp.createTemp('pubignore_contract_');
    await File('.pubignore').copy('${repository.path}/.gitignore');

    final result = await Process.run('git', [
      'init',
      '--quiet',
    ], workingDirectory: repository.path);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
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
    ]) {
      expect(
        await _isIgnored(repository, candidate),
        isFalse,
        reason: candidate,
      );
    }
  });
}

Future<bool> _isIgnored(Directory repository, String candidate) async {
  final result = await Process.run('git', [
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
