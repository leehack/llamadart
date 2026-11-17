@TestOn('vm')
library;

import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:mirrors';

import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _required = [
  'api_version',
  'request_default',
  'get_info',
  'init',
  'free',
  'start',
  'step',
  'cancel',
  'reset',
  'get_output_info',
  'read_pcm',
  'last_error',
];

LibraryMirror get _library =>
    reflectClass(LlamaCppService).owner as LibraryMirror;

Symbol _symbol(String name) => MirrorSystem.getSymbol(name, _library);

Object? _load(Pointer<NativeType> Function(String) lookup) =>
    (_library.declarations[_symbol('_TtsApi')]! as ClassMirror).invoke(
      #tryLoad,
      [lookup],
    ).reflectee;

Object? _resolve(
  LlamaCppService service, {
  required Pointer<NativeType> Function(String) lookup,
  List<String> candidates = const [],
  DynamicLibrary Function(String)? open,
}) => reflect(service).invoke(_symbol('_resolveTtsApi'), const [], {
  #assetSymbol: lookup,
  #candidates: candidates,
  #open: ?open,
}).reflectee;

void main() {
  late NativeCallable<Uint32 Function()> version;

  setUp(() {
    version = NativeCallable<Uint32 Function()>.isolateLocal(
      () => 1,
      exceptionalReturn: 0,
    );
    addTearDown(version.close);
  });

  for (final missing in _required) {
    test('missing required $missing does not admit a partial TTS API', () {
      final requested = <String>[];
      final api = _load((name) {
        requested.add(name);
        if (name == 'llama_dart_tts_$missing') {
          throw ArgumentError('missing export');
        }
        // Only api_version is called; other converted addresses are unused.
        return version.nativeFunction;
      });
      expect(api, isNull);
      expect(requested, contains('llama_dart_tts_$missing'));
    });
  }

  for (final incompatible in [0, 2]) {
    test('ABI $incompatible is rejected before binding object calls', () {
      final skew = NativeCallable<Uint32 Function()>.isolateLocal(
        () => incompatible,
        exceptionalReturn: 0,
      );
      addTearDown(skew.close);
      final requested = <String>[];
      expect(
        _load((name) {
          requested.add(name);
          return skew.nativeFunction;
        }),
        isNull,
      );
      expect(requested, ['llama_dart_tts_api_version']);
    });
  }

  test('legacy ABI 1 remains supported without optional export groups', () {
    final api = _load((name) {
      if (!_required.any((suffix) => name == 'llama_dart_tts_$suffix')) {
        throw ArgumentError('optional export absent');
      }
      return version.nativeFunction;
    });
    expect(api, isNotNull);
    final mirror = reflect(api);
    expect(mirror.getField(#hasModelTypeOptIn).reflectee, isFalse);
    expect(mirror.getField(#listsVoices).reflectee, isFalse);
    expect(mirror.getField(#evalCallback).reflectee, nullptr);
    expect(mirror.getField(#setCancelFlag).reflectee, isNull);
  });

  test('the streaming export is optional', () {
    final api = _load((name) {
      if (name == 'llama_dart_tts_start_streaming') {
        throw ArgumentError('optional export absent');
      }
      return version.nativeFunction;
    });
    expect(api, isNotNull);
    expect(reflect(api).getField(#startStreaming).reflectee, isNull);
    expect(reflect(api).getField(#hasModelTypeOptIn).reflectee, isTrue);
  });

  for (final missing in [
    'supported_model_types',
    'get_info_ext',
    'init_ext',
    'start_with_voice',
  ]) {
    test('partial optional group missing $missing never advertises opt-in', () {
      final api = _load((name) {
        if (name == 'llama_dart_tts_$missing') {
          throw ArgumentError('optional export absent');
        }
        return version.nativeFunction;
      });
      expect(api, isNotNull);
      expect(reflect(api).getField(#hasModelTypeOptIn).reflectee, isFalse);
    });
  }

  test('a complete selected asset is cached without opening fallbacks', () {
    var lookups = 0;
    final service = LlamaCppService();
    Pointer<NativeType> lookup(String _) {
      lookups++;
      return version.nativeFunction;
    }

    final api = _resolve(service, lookup: lookup);
    expect(api, isNotNull);
    final firstLookups = lookups;
    expect(identical(_resolve(service, lookup: lookup), api), isTrue);
    expect(lookups, firstLookups);
  });

  test('no complete asset or fallback produces a typed unsupported error', () {
    expect(
      () => _resolve(
        LlamaCppService(),
        lookup: (_) => throw ArgumentError('missing export'),
      ),
      throwsA(isA<LlamaUnsupportedException>()),
    );
  });

  test('a rejected selected asset retains compatible file fallback', () {
    final assets = _nativeAssets();
    final mapping =
        (assets['native-assets'] as Map)[Abi.current().toString()] as Map;
    final id = Platform.isWindows
        ? 'package:llamadart/llamadart_wrapper'
        : 'package:llamadart/llamadart';
    final location = mapping[id] as List;
    expect(location.first, 'absolute');
    final api = _resolve(
      LlamaCppService(),
      lookup: (_) => throw ArgumentError('selected export absent'),
      candidates: [location[1] as String],
    );
    expect(api, isNotNull);
  });

  group('real bundled native asset without filesystem fallbacks', () {
    late Directory temp;
    late String kernel;

    setUpAll(() async {
      temp = Directory.systemTemp.createTempSync('tts-asset-discovery-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final assets = _nativeAssets();
      final mapping =
          (assets['native-assets'] as Map)[Abi.current().toString()] as Map;
      // Exercise the Windows wrapper binding on every host with the same real
      // published binary, without claiming Windows execution qualification.
      final selected =
          mapping[Platform.isWindows
              ? 'package:llamadart/llamadart_wrapper'
              : 'package:llamadart/llamadart'];
      mapping['package:llamadart/llamadart'] = selected;
      mapping['package:llamadart/llamadart_wrapper'] = selected;
      final nativeAssets = File(path.join(temp.path, 'assets.json'))
        ..writeAsStringSync(jsonEncode(assets));
      kernel = path.join(temp.path, 'checks.dill');
      final sdk = path.dirname(path.dirname(Platform.resolvedExecutable));
      final result = await Process.run(
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
          nativeAssets.path,
          '--output',
          kernel,
          'test/fixtures/tts_asset_checks.dart',
        ],
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    });

    for (final mode in ['primary', 'windows-wrapper']) {
      test(
        '$mode resolves the complete real ABI from its code asset',
        () async {
          final result = await Process.run(Platform.resolvedExecutable, [
            kernel,
            mode,
          ], workingDirectory: temp.path);
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
          expect(result.stdout, contains('ABI=1 required=12'));
          final selected =
              ((_nativeAssets()['native-assets'] as Map)[Abi.current()
                          .toString()]
                      as Map)[Platform.isWindows
                      ? 'package:llamadart/llamadart_wrapper'
                      : 'package:llamadart/llamadart']
                  as List;
          final bundleHasStreaming = latin1
              .decode(File(selected[1] as String).readAsBytesSync())
              .contains('llama_dart_tts_start_streaming');
          expect(
            result.stdout,
            contains('streaming=$bundleHasStreaming'),
            reason:
                'The bundled asset exports start_streaming: '
                '$bundleHasStreaming.',
          );
        },
      );
    }
  });
}

Map<String, dynamic> _nativeAssets() =>
    jsonDecode(
          jsonEncode(
            loadYaml(File('.dart_tool/native_assets.yaml').readAsStringSync()),
          ),
        )
        as Map<String, dynamic>;
