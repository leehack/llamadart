@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('ignores SwiftPM build output in companion packages', () async {
    final repository = await Directory.systemTemp.createTemp(
      'gitignore_contract_',
    );
    addTearDown(() => repository.delete(recursive: true));
    await File('.gitignore').copy('${repository.path}/.gitignore');
    final init = await Process.run('git', [
      'init',
      '--quiet',
    ], workingDirectory: repository.path);
    expect(init.exitCode, 0, reason: '${init.stdout}\n${init.stderr}');
    // Keeps a contributor's global excludes and .git/info/exclude from
    // masking a missing rule.
    final emptyExcludes = File('${repository.path}/.git/empty_excludes')
      ..writeAsStringSync('');
    File('${repository.path}/.git/info/exclude').writeAsStringSync('');

    for (final package in <String>[
      'llamadart_litert_lm_flutter',
      'llamadart_llama_cpp_flutter',
      'llamadart_stable_diffusion_flutter',
    ]) {
      final candidate = 'packages/$package/darwin/$package/.build/manifest.db';
      final result = await Process.run('git', [
        '-c',
        'core.excludesFile=${emptyExcludes.path}',
        'check-ignore',
        '--no-index',
        '--quiet',
        candidate,
      ], workingDirectory: repository.path);
      expect(result.exitCode, 0, reason: '$candidate is not ignored');
    }
  });
}
