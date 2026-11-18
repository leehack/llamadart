@TestOn('vm')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

const _admitted =
    'llamadart-native-build/1;llama.cpp=b1b770d90d94cad9e9ea5b993bdbc383a522fb28;';

// A null identity is the runtime without the export, or one reporting nothing.
const Map<String, String?> _refused = {
  'null': null,
  'empty': '',
  'unknown': 'unknown',
  'schema2': 'llamadart-native-build/2;llama.cpp=b1b770d9;',
  'commit unknown': 'llamadart-native-build/1;llama.cpp=unknown;',
  'dirty':
      'llamadart-native-build/1;llama.cpp=b1b770d90d94cad9e9ea5b993bdbc383a522fb28+dirty.1;',
  'duplicate':
      'llamadart-native-build/1;llama.cpp=b1b770d90d94cad9e9ea5b993bdbc383a522fb28;llama.cpp=unknown;',
  'v0.9.0':
      'llamadart-native-build/1;llama.cpp=cd959bae99ff4bed22bef2604f45241c09bbb8c8;',
  'v0.8.0':
      'llamadart-native-build/1;llama.cpp=8642541b255bfb5dc39cd351a178be09013a55d6;',
};

void main() {
  late Directory temp;
  final kernels = <String, ({String snapshot, String library})>{};

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    Map<String, String>? environment,
  }) => Process.run(executable, arguments, environment: environment);

  Future<void> check(
    String mode,
    String expected,
    String variant,
    String? identity,
  ) async {
    final kernel = kernels[variant]!;
    final result = await run(
      Platform.resolvedExecutable,
      [kernel.snapshot, mode, expected, kernel.library],
      environment: {'FIXTURE_IDENTITY': ?identity},
    );
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('runtime-admission-');
    addTearDown(() => temp.deleteSync(recursive: true));
    final sdk = path.dirname(path.dirname(Platform.resolvedExecutable));
    for (final variant in ['identity', 'noexport']) {
      final library = path.join(
        temp.path,
        '$variant.${Platform.isWindows
            ? 'dll'
            : Platform.isMacOS
            ? 'dylib'
            : 'so'}',
      );
      final compile = await run(Platform.isWindows ? 'clang' : 'cc', [
        if (Platform.isWindows) '-fuse-ld=lld',
        Platform.isMacOS ? '-dynamiclib' : '-shared',
        if (!Platform.isWindows) '-fPIC',
        '-DCONTEXT_PARAMS_SIZE=${sizeOf<llama_context_params>()}',
        '-DMODEL_PARAMS_SIZE=${sizeOf<llama_model_params>()}',
        '-DSAMPLER_CHAIN_PARAMS_SIZE=${sizeOf<llama_sampler_chain_params>()}',
        '-DMTMD_CONTEXT_PARAMS_SIZE=${sizeOf<mtmd_context_params>()}',
        '-DMTMD_HELPER_INIT_OPT_SIZE=${sizeOf<mtmd_helper_init_opt>()}',
        if (variant == 'noexport') '-DOMIT_IDENTITY',
        'test/fixtures/runtime_admission_runtime.c',
        '-o',
        library,
      ]);
      expect(compile.exitCode, 0, reason: '${compile.stderr}');
      final assets = File(path.join(temp.path, '$variant-assets.json'))
        ..writeAsStringSync(
          jsonEncode({
            'format-version': [1, 0, 0],
            'native-assets': {
              Abi.current().toString(): {
                'package:llamadart/llamadart': ['absolute', library],
                'package:llamadart/llamadart_wrapper': ['absolute', library],
              },
            },
          }),
        );
      final snapshot = path.join(temp.path, '$variant.dill');
      final kernel = await run(
        path.join(
          sdk,
          'bin',
          Platform.isWindows ? 'dartaotruntime.exe' : 'dartaotruntime',
        ),
        [
          path.join(sdk, 'bin', 'snapshots', 'gen_kernel_aot.dart.snapshot'),
          '--platform',
          path.join(sdk, 'lib', '_internal', 'vm_platform_strong.dill'),
          '--packages',
          path.absolute('.dart_tool/package_config.json'),
          '--native-assets',
          assets.path,
          '--output',
          snapshot,
          'test/fixtures/runtime_admission_checks.dart',
        ],
      );
      expect(kernel.exitCode, 0, reason: '${kernel.stdout}\n${kernel.stderr}');
      kernels[variant] = (snapshot: snapshot, library: library);
    }
  });

  const modes = ['load', 'direct', 'windows', 'dynamic', 'mtmd-default'];

  for (final entry in _refused.entries) {
    for (final mode in modes) {
      test('${entry.key} identity makes no by-value call: $mode', () {
        return check(mode, 'refused', 'identity', entry.value);
      });
    }
    test('${entry.key} identity is refused by a dynamic mtmd library', () {
      if (entry.value == null) return Future<void>.value();
      return check('mtmd', 'refused', 'identity', entry.value);
    });
  }

  for (final mode in modes) {
    test('a runtime without the identity export is refused: $mode', () {
      return check(mode, 'refused', 'noexport', null);
    });
  }

  for (final mode in [...modes, 'mtmd']) {
    test('the admitted identity proceeds: $mode', () {
      return check(mode, 'admitted', 'identity', _admitted);
    });
  }
}
