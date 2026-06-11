@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('LiteRtLmRuntimeMetrics serializes runtime counters', () {
    const metrics = LiteRtLmRuntimeMetrics(
      inputTokens: 12,
      outputTokens: 34,
      timeToFirstTokenSeconds: 0.5,
      initSeconds: 1.25,
      prefillTokensPerSecond: 20.0,
      decodeTokensPerSecond: 30.0,
      wallMilliseconds: 4567,
    );

    expect(metrics.toJson(), {
      'inputTokens': 12,
      'outputTokens': 34,
      'timeToFirstTokenSeconds': 0.5,
      'initSeconds': 1.25,
      'prefillTokensPerSecond': 20.0,
      'decodeTokensPerSecond': 30.0,
      'wallMilliseconds': 4567,
    });
  });

  test('LiteRtLmRuntimeResult keeps generated text with metrics', () {
    const metrics = LiteRtLmRuntimeMetrics(
      inputTokens: 1,
      outputTokens: 2,
      timeToFirstTokenSeconds: null,
      initSeconds: null,
      prefillTokensPerSecond: null,
      decodeTokensPerSecond: null,
      wallMilliseconds: 3,
    );

    const result = LiteRtLmRuntimeResult(text: 'hello', metrics: metrics);

    expect(result.text, 'hello');
    expect(result.metrics, same(metrics));
  });

  test('macOS LiteRT-LM cache lookup follows the current runtime ABI', () {
    expect(
      liteRtLmMacOsCacheDirectoryCandidatesForAbi(Abi.macosArm64),
      const <String>['macos_arm64', 'macos/arm64'],
    );
    expect(
      liteRtLmMacOsCacheDirectoryCandidatesForAbi(Abi.macosX64),
      const <String>['macos_x64', 'macos/x64'],
    );
    expect(liteRtLmMacOsCacheDirectoryCandidatesForAbi(Abi.linuxX64), isEmpty);
  });

  test('LiteRT-LM cache lookup follows desktop runtime ABIs', () {
    expect(
      liteRtLmCacheDirectoryCandidatesForAbi(Abi.macosArm64),
      const <String>['macos_arm64', 'macos/arm64'],
    );
    expect(liteRtLmCacheDirectoryCandidatesForAbi(Abi.linuxX64), const <String>[
      'linux/x64',
      'linux_x64',
    ]);
    expect(
      liteRtLmCacheDirectoryCandidatesForAbi(Abi.linuxArm64),
      const <String>['linux/arm64', 'linux_arm64'],
    );
    expect(
      liteRtLmCacheDirectoryCandidatesForAbi(Abi.windowsX64),
      const <String>['windows/x64', 'windows_x64'],
    );
    expect(liteRtLmCacheDirectoryCandidatesForAbi(Abi.androidArm64), isEmpty);
  });

  test('LiteRT-LM package config lookup finds the llamadart package root', () {
    final root = Directory.systemTemp.createTempSync('litert_lm_pkg_config_');
    addTearDown(() => root.deleteSync(recursive: true));

    final appRoot = Directory('${root.path}/app')..createSync();
    final packageRoot = Directory('${root.path}/llamadart')..createSync();
    final dotDartTool = Directory('${appRoot.path}/.dart_tool')
      ..createSync(recursive: true);
    final packageConfig = File('${dotDartTool.path}/package_config.json')
      ..writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "llamadart",
      "rootUri": "${packageRoot.uri}",
      "packageUri": "lib/",
      "languageVersion": "3.10"
    }
  ]
}
''');

    expect(liteRtLmPackageRootsFromPackageConfig(packageConfig), [
      path.normalize(packageRoot.absolute.path),
    ]);
  });

  test('LiteRT-LM iOS fallback identifiers include process and frameworks', () {
    // The process candidate supports the Flutter SPM bridge. The remaining
    // entries preserve the native-asset/framework fallbacks used by bundled
    // builds.
    expect(liteRtLmIosLibraryCandidatesForAbi(Abi.iosArm64), const <String>[
      '<process>',
      'package:llamadart/litert_lm_LiteRtLm',
      'LiteRtLm',
      'CLiteRTLM',
    ]);
    expect(liteRtLmIosLibraryCandidatesForAbi(Abi.iosX64), const <String>[
      '<process>',
      'package:llamadart/litert_lm_LiteRtLm',
      'LiteRtLm',
      'CLiteRTLM',
    ]);
    expect(liteRtLmIosLibraryCandidatesForAbi(Abi.macosArm64), isEmpty);
  });

  test('LiteRT-LM iOS lookup prefers process then framework paths', () {
    // With the app Frameworks dir known, process lookup is still tried first
    // for SPM, then absolute upstream/wrapper framework paths.
    expect(
      liteRtLmIosLibraryCandidates(
        Abi.iosArm64,
        frameworksDirPath: '/App.app/Frameworks',
      ),
      const <String>[
        '<process>',
        '/App.app/Frameworks/CLiteRTLM.framework/CLiteRTLM',
        '/App.app/Frameworks/LiteRtLm.framework/LiteRtLm',
        'package:llamadart/litert_lm_LiteRtLm',
        'LiteRtLm',
        'CLiteRTLM',
      ],
    );
    // Without a Frameworks dir, only process and fallback identifiers remain.
    expect(liteRtLmIosLibraryCandidates(Abi.iosArm64), const <String>[
      '<process>',
      'package:llamadart/litert_lm_LiteRtLm',
      'LiteRtLm',
      'CLiteRTLM',
    ]);
    // Non-iOS ABIs have no iOS candidates regardless of a frameworks dir.
    expect(
      liteRtLmIosLibraryCandidates(
        Abi.macosArm64,
        frameworksDirPath: '/App.app/Frameworks',
      ),
      isEmpty,
    );
    expect(
      liteRtLmIosFrameworkBinaryPath('/App.app/Frameworks', 'LiteRtLm'),
      '/App.app/Frameworks/LiteRtLm.framework/LiteRtLm',
    );
  });

  test('macOS LiteRT-LM cache validation follows runtime ABI files', () {
    expect(liteRtLmMacOsRequiredLibrariesForAbi(Abi.macosArm64), const <String>[
      'libLiteRtLm.dylib',
      'libCLiteRTLM_mac.dylib',
    ]);
    expect(liteRtLmMacOsRequiredLibrariesForAbi(Abi.macosX64), const <String>[
      'libLiteRtLm.dylib',
      'libCLiteRTLM_mac.dylib',
    ]);
    expect(liteRtLmMacOsRequiredLibrariesForAbi(Abi.linuxX64), isEmpty);
  });

  test('LiteRT-LM cache validation follows desktop runtime ABI files', () {
    expect(liteRtLmRequiredLibrariesForAbi(Abi.linuxX64), const <String>[
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
    ]);
    expect(liteRtLmRequiredLibrariesForAbi(Abi.windowsX64), const <String>[
      'LiteRtLm.dll',
      'libGemmaModelConstraintProvider.dll',
      'libLiteRt.dll',
      'libLiteRtTopKWebGpuSampler.dll',
      'libLiteRtWebGpuAccelerator.dll',
    ]);
    expect(liteRtLmRequiredLibrariesForAbi(Abi.androidArm64), isEmpty);
  });

  test('macOS LiteRT-LM app framework validation follows runtime ABI', () {
    expect(
      liteRtLmMacOsRequiredFrameworksForAbi(Abi.macosArm64),
      const <String>[
        'GemmaModelConstraintProvider.framework/Versions/A/'
            'GemmaModelConstraintProvider',
        'LiteRt.framework/Versions/A/LiteRt',
        'LiteRtLm.framework/Versions/A/LiteRtLm',
        'LiteRtMetalAccelerator.framework/Versions/A/'
            'LiteRtMetalAccelerator',
        'LiteRtTopKMetalSampler.framework/Versions/A/'
            'LiteRtTopKMetalSampler',
        'LiteRtTopKWebGpuSampler.framework/Versions/A/'
            'LiteRtTopKWebGpuSampler',
        'LiteRtWebGpuAccelerator.framework/Versions/A/'
            'LiteRtWebGpuAccelerator',
      ],
    );
    expect(liteRtLmMacOsRequiredFrameworksForAbi(Abi.macosX64), const <String>[
      'LiteRtLm.framework/Versions/A/LiteRtLm',
    ]);
    expect(liteRtLmMacOsRequiredFrameworksForAbi(Abi.linuxX64), isEmpty);
  });

  test('macOS LiteRT-LM cache validation rejects partial caches', () {
    final root = Directory.systemTemp.createTempSync('litert_lm_cache_test_');
    addTearDown(() => root.deleteSync(recursive: true));

    final arm64Dir = Directory('${root.path}/arm64')..createSync();
    File('${arm64Dir.path}/libLiteRtLm.dylib').createSync();

    expect(
      liteRtLmIsMacOsCacheDirectoryForAbi(arm64Dir, Abi.macosArm64),
      isFalse,
    );

    for (final library in liteRtLmMacOsRequiredLibrariesForAbi(
      Abi.macosArm64,
    )) {
      File('${arm64Dir.path}/$library').createSync();
    }

    expect(
      liteRtLmIsMacOsCacheDirectoryForAbi(arm64Dir, Abi.macosArm64),
      isTrue,
    );

    final x64Dir = Directory('${root.path}/x64')..createSync();

    expect(liteRtLmIsMacOsCacheDirectoryForAbi(x64Dir, Abi.macosX64), isFalse);

    File('${x64Dir.path}/libLiteRtLm.dylib').createSync();

    expect(liteRtLmIsMacOsCacheDirectoryForAbi(x64Dir, Abi.macosX64), isFalse);

    File('${x64Dir.path}/libCLiteRTLM_mac.dylib').createSync();

    expect(liteRtLmIsMacOsCacheDirectoryForAbi(x64Dir, Abi.macosX64), isTrue);
    expect(liteRtLmIsMacOsCacheDirectoryForAbi(x64Dir, Abi.linuxX64), isFalse);
  });

  test('LiteRT-LM cache validation rejects partial desktop caches', () {
    final root = Directory.systemTemp.createTempSync('litert_lm_cache_test_');
    addTearDown(() => root.deleteSync(recursive: true));

    final linuxDir = Directory('${root.path}/linux')..createSync();
    File('${linuxDir.path}/libLiteRtLm.so').createSync();

    expect(liteRtLmIsCacheDirectoryForAbi(linuxDir, Abi.linuxX64), isFalse);

    for (final library in liteRtLmRequiredLibrariesForAbi(Abi.linuxX64)) {
      File('${linuxDir.path}/$library').createSync();
    }

    expect(liteRtLmIsCacheDirectoryForAbi(linuxDir, Abi.linuxX64), isTrue);

    final windowsDir = Directory('${root.path}/windows')..createSync();
    File('${windowsDir.path}/LiteRtLm.dll').createSync();

    expect(liteRtLmIsCacheDirectoryForAbi(windowsDir, Abi.windowsX64), isFalse);

    for (final library in liteRtLmRequiredLibrariesForAbi(Abi.windowsX64)) {
      File('${windowsDir.path}/$library').createSync();
    }

    expect(liteRtLmIsCacheDirectoryForAbi(windowsDir, Abi.windowsX64), isTrue);
    expect(liteRtLmIsCacheDirectoryForAbi(windowsDir, Abi.linuxX64), isFalse);
  });

  test('engine create failure diagnostics include fallback guidance', () {
    expect(
      liteRtLmEngineCreateFailureMessage(
        backend: 'npu',
        modelPath: '/models/gemma-4-E2B-it.litertlm',
      ),
      allOf(
        contains('backend "npu"'),
        contains('gemma-4-E2B-it.litertlm'),
        contains('Android NPU delegate'),
        contains('backend "gpu"'),
        contains('backend "cpu"'),
      ),
    );
    expect(
      liteRtLmEngineCreateFailureMessage(
        backend: 'gpu',
        modelPath: '/models/gemma-4-E2B-it.litertlm',
      ),
      allOf(contains('GPU delegate'), contains('backend "cpu"')),
    );
  });

  test(
    'LiteRtLmRuntimeClient validates counts before native initialization',
    () {
      final client = LiteRtLmRuntimeClient();

      expect(
        client.initialize(modelPath: 'model.litertlm', maxTokens: 0),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'maxTokens',
          ),
        ),
      );
      expect(
        client.initialize(modelPath: 'model.litertlm', outputTokens: 0),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'outputTokens',
          ),
        ),
      );
      expect(
        client.initialize(modelPath: 'model.litertlm', prefillTokens: -1),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'prefillTokens',
          ),
        ),
      );
      expect(
        client.initialize(modelPath: 'model.litertlm', maxNumImages: 0),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'maxNumImages',
          ),
        ),
      );
      expect(
        client.initialize(modelPath: 'model.litertlm', prefillChunkSize: 0),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'prefillChunkSize',
          ),
        ),
      );
      expect(
        client.initialize(modelPath: 'model.litertlm', dispatchLibDir: '  '),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'dispatchLibDir',
          ),
        ),
      );
    },
  );

  test(
    'LiteRtLmRuntimeClient validates backend before native initialization',
    () {
      final client = LiteRtLmRuntimeClient();

      expect(
        client.initialize(modelPath: 'model.litertlm', backend: ' dsp '),
        throwsA(
          isA<ArgumentError>().having((error) => error.name, 'name', 'backend'),
        ),
      );
      expect(
        client.initialize(modelPath: 'model.litertlm', visionBackend: ' dsp '),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'visionBackend',
          ),
        ),
      );
      expect(
        client.initialize(modelPath: 'model.litertlm', audioBackend: ' dsp '),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.name,
            'name',
            'audioBackend',
          ),
        ),
      );
    },
  );

  test('LiteRtLmRuntimeClient validates send optional args', () {
    final client = LiteRtLmRuntimeClient();

    expect(
      () => client.generateMessageJson(
        '{"role":"user","content":[{"type":"text","text":"hi"}]}',
        visualTokenBudget: 0,
      ),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'visualTokenBudget',
        ),
      ),
    );
  });

  test('LiteRtLmRuntimeClient validates benchmark loop counts', () {
    final client = LiteRtLmRuntimeClient();

    expect(
      client.run(prompt: 'hello', warmupRuns: -1),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'warmupRuns',
        ),
      ),
    );
    expect(
      client.run(prompt: 'hello', measuredRuns: 0),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'measuredRuns',
        ),
      ),
    );
  });
}
