@TestOn('vm')
library;

import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  group('macos_litert_lm_prepare_app.sh', () {
    test(
      'rejects incomplete explicit arm64 runtime directories',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'litert_prepare_partial_',
        );
        addTearDown(() => root.delete(recursive: true));

        final libDir = Directory(path.join(root.path, 'litert'))..createSync();
        await File(path.join(libDir.path, 'libLiteRtLm.dylib')).create();

        final appDir = Directory(path.join(root.path, 'Test.app'));
        final result = await _runPrepareApp(appDir, libDir, arch: 'arm64');

        expect(result.exitCode, 2);
        expect(result.stderr, contains('library directory is incomplete'));
        expect(
          result.stderr,
          contains('libGemmaModelConstraintProvider.dylib'),
        );
        expect(
          Directory(
            path.join(appDir.path, 'Contents', 'Frameworks'),
          ).existsSync(),
          isFalse,
        );
      },
      skip: Platform.isWindows ? 'requires bash and POSIX symlinks' : false,
    );

    test(
      'installs the full arm64 companion library set',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'litert_prepare_full_',
        );
        addTearDown(() => root.delete(recursive: true));

        final libDir = Directory(path.join(root.path, 'litert'))..createSync();
        for (final library in _arm64Libraries) {
          await File(path.join(libDir.path, library)).create();
        }

        final appDir = Directory(path.join(root.path, 'Test.app'));
        final result = await _runPrepareApp(appDir, libDir, arch: 'arm64');

        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(result.stdout, contains('Prepared LiteRT-LM macOS'));

        final frameworksDir = path.join(appDir.path, 'Contents', 'Frameworks');
        final runtimeDir = path.join(frameworksDir, 'LiteRtLmRuntime');
        for (final library in _arm64Libraries) {
          final libraryPath = path.join(runtimeDir, library);
          expect(File(libraryPath).existsSync(), isTrue, reason: library);
        }
        for (final framework in _oldFrameworks) {
          expect(
            Directory(
              path.join(frameworksDir, '$framework.framework'),
            ).existsSync(),
            isFalse,
            reason: framework,
          );
        }
      },
      skip: Platform.isWindows ? 'requires bash and POSIX symlinks' : false,
    );

    test(
      'installs the x64 runtime library set',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'litert_prepare_x64_',
        );
        addTearDown(() => root.delete(recursive: true));

        final libDir = Directory(path.join(root.path, 'litert'))..createSync();
        for (final library in _x64Libraries) {
          await File(path.join(libDir.path, library)).create();
        }

        final appDir = Directory(path.join(root.path, 'Test.app'));
        final result = await _runPrepareApp(appDir, libDir, arch: 'x64');

        expect(result.exitCode, 0, reason: result.stderr.toString());

        final frameworksDir = path.join(appDir.path, 'Contents', 'Frameworks');
        final runtimeDir = path.join(frameworksDir, 'LiteRtLmRuntime');
        for (final library in _x64Libraries) {
          final libraryPath = path.join(runtimeDir, library);
          expect(File(libraryPath).existsSync(), isTrue, reason: library);
        }
        expect(
          File(
            path.join(
              frameworksDir,
              'LiteRtLmRuntime',
              'libLiteRtMetalAccelerator.dylib',
            ),
          ).existsSync(),
          isFalse,
        );
        for (final framework in _oldFrameworks) {
          expect(
            Directory(
              path.join(frameworksDir, '$framework.framework'),
            ).existsSync(),
            isFalse,
            reason: framework,
          );
        }
      },
      skip: Platform.isWindows ? 'requires bash and POSIX symlinks' : false,
    );
  });
}

Future<ProcessResult> _runPrepareApp(
  Directory appDir,
  Directory libDir, {
  required String arch,
}) {
  return Process.run(
    'bash',
    ['tool/macos_litert_lm_prepare_app.sh', appDir.path],
    environment: {
      'LLAMADART_LITERT_LM_ARCH': arch,
      'LLAMADART_LITERT_LM_LIB_DIR': libDir.path,
    },
  );
}

const List<String> _arm64Libraries = [
  'libGemmaModelConstraintProvider.dylib',
  'libLiteRt.dylib',
  'libLiteRtLm.dylib',
  'libLiteRtMetalAccelerator.dylib',
  'libLiteRtTopKMetalSampler.dylib',
  'libLiteRtTopKWebGpuSampler.dylib',
  'libLiteRtWebGpuAccelerator.dylib',
];

const List<String> _oldFrameworks = [
  'GemmaModelConstraintProvider',
  'LiteRt',
  'LiteRtLm',
  'LiteRtMetalAccelerator',
  'LiteRtTopKMetalSampler',
  'LiteRtTopKWebGpuSampler',
  'LiteRtWebGpuAccelerator',
];

const List<String> _x64Libraries = ['libLiteRtLm.dylib'];
