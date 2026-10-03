@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

final String _toolPath = path.absolute(
  'tool/testing/check_platform_boundaries.dart',
);
final String _packageConfigPath = path.absolute(
  '.dart_tool/package_config.json',
);

Directory _fakeRepo({Map<String, String> overrides = const {}}) {
  final root = Directory.systemTemp.createTempSync('platform_boundaries');
  addTearDown(() => root.deleteSync(recursive: true));
  final files = <String, String>{
    'lib/src/core/engine.dart': "import 'dart:async';\n",
    'lib/llamadart.dart': "export 'src/core/engine.dart';\n",
    'lib/backend.dart': "export 'src/core/engine.dart';\n",
    'lib/llama_cpp_bindings.dart': "export 'src/core/engine.dart';\n",
    'lib/src/backends/web/web_backend.dart': "import 'dart:async';\n",
    'lib/src/backends/webgpu/webgpu_backend.dart': "import 'dart:async';\n",
    ...overrides,
  };
  for (final entry in files.entries) {
    File(path.join(root.path, entry.key))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
  return root;
}

Future<ProcessResult> _runBoundaries(Directory root) {
  return Process.run(Platform.resolvedExecutable, <String>[
    '--disable-dart-dev',
    '--packages=$_packageConfigPath',
    _toolPath,
  ], workingDirectory: root.path);
}

void main() {
  test('passes a tree whose entrypoints stay platform-neutral', () async {
    final result = await _runBoundaries(_fakeRepo());

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('[platform-boundary] OK'));
  });

  test('rejects dart:io and dart:ffi in the backend and bindings '
      'entrypoints', () async {
    final result = await _runBoundaries(
      _fakeRepo(
        overrides: <String, String>{
          'lib/backend.dart': "export 'dart:io';\n",
          'lib/llama_cpp_bindings.dart': "export 'dart:ffi';\n",
        },
      ),
    );

    expect(result.exitCode, 1);
    expect(
      result.stderr,
      allOf(
        contains(
          '${path.join('lib', 'backend.dart')}:1 '
          '[backend-entrypoint] export dart:io',
        ),
        contains(
          '${path.join('lib', 'llama_cpp_bindings.dart')}:1 '
          '[bindings-entrypoint] export dart:ffi',
        ),
      ),
    );
  });

  test('reports a missing entrypoint as a scope error', () async {
    final root = _fakeRepo();
    File(path.join(root.path, 'lib/llama_cpp_bindings.dart')).deleteSync();

    final result = await _runBoundaries(root);

    expect(result.exitCode, 1);
    expect(
      result.stderr,
      contains(
        "Scope 'bindings-entrypoint' target not found: "
        'lib/llama_cpp_bindings.dart',
      ),
    );
  });
}
