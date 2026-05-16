@TestOn('vm')
library;

import 'dart:io';

import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('LlamaCppService can be instantiated', () {
    final service = LlamaCppService();
    expect(service, isA<LlamaCppService>());
  });

  group('loadModel preflight validation', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('llamadart-loadmodel-');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('throws when model file does not exist', () {
      final service = LlamaCppService();
      final missingPath = path.join(tempDir.path, 'missing.gguf');

      expect(
        () => service.loadModel(missingPath, const ModelParams()),
        throwsA(isA<Exception>()),
      );
    });

    test('throws when model file is empty', () {
      final service = LlamaCppService();
      final emptyFile = File(path.join(tempDir.path, 'empty.gguf'))
        ..writeAsBytesSync(const <int>[]);

      expect(
        () => service.loadModel(emptyFile.path, const ModelParams()),
        throwsA(isA<Exception>()),
      );
    });

    test('throws when model file does not look like GGUF', () {
      final service = LlamaCppService();
      final badFile = File(path.join(tempDir.path, 'bad.gguf'))
        ..writeAsBytesSync(const <int>[0x00, 0x01, 0x02, 0x03]);

      expect(
        () => service.loadModel(badFile.path, const ModelParams()),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('invalid-handle guard rails', () {
    late LlamaCppService service;

    setUp(() {
      service = LlamaCppService();
    });

    test('createContext throws for unknown model handle', () {
      expect(
        () => service.createContext(-1, const ModelParams()),
        throwsA(isA<Exception>()),
      );
    });

    test('generate stream reports error for unknown context handle', () async {
      expect(
        service
            .generate(-1, 'hello', const GenerationParams(), 0)
            .drain<void>(),
        throwsA(isA<Exception>()),
      );
    });

    test('embed and embedBatch throw for unknown context handle', () {
      expect(() => service.embed(-1, 'hello'), throwsA(isA<Exception>()));
      expect(
        () => service.embedBatch(-1, const <String>['hello']),
        throwsA(isA<Exception>()),
      );
    });

    test('stateSaveFile throws for unknown context handle', () {
      expect(
        () => service.stateSaveFile(-1, '/tmp/state.bin', const <int>[]),
        throwsA(isA<StateError>()),
      );
    });

    test('createMultimodalContext throws for unknown model handle', () {
      expect(
        () => service.createMultimodalContext(-1, 'mmproj.gguf'),
        throwsA(isA<Exception>()),
      );
    });

    test(
      'token and metadata methods return safe defaults for unknown model',
      () {
        expect(service.tokenize(-1, 'hello', true), isEmpty);
        expect(service.detokenize(-1, const <int>[1, 2, 3], false), isEmpty);
        expect(service.getMetadata(-1), isEmpty);
      },
    );

    test(
      'state/introspection methods return safe defaults before model load',
      () {
        expect(service.getContextSize(-1), 0);
        expect(service.hasMultimodalContext(-1), isFalse);
        expect(service.getResolvedGpuLayers(), isNull);
        expect(service.getActiveBackendName(), 'CPU');
        expect(service.getAvailableBackendInfo(), contains('CPU'));
      },
    );

    test('handleLora and free methods are no-op for unknown handles', () {
      service.handleLora(-1, '/tmp/a.lora', 0.5, 'set');
      service.freeModel(-1);
      service.freeContext(-1);
      service.freeMultimodalContext(-1);
    });
  });

  group('resolveGpuLayersForLoad', () {
    test('prefers CPU for Android auto mode', () {
      const params = ModelParams(
        gpuLayers: ModelParams.maxGpuLayers,
        preferredBackend: GpuBackend.auto,
      );

      expect(
        LlamaCppService.resolvePreferredBackendForLoad(params, isAndroid: true),
        GpuBackend.cpu,
      );
    });

    test('keeps auto mode on non-Android hosts', () {
      const params = ModelParams(
        gpuLayers: ModelParams.maxGpuLayers,
        preferredBackend: GpuBackend.auto,
      );

      expect(
        LlamaCppService.resolvePreferredBackendForLoad(params),
        GpuBackend.auto,
      );
    });

    test('forces CPU mode to zero gpu layers', () {
      const params = ModelParams(
        gpuLayers: ModelParams.maxGpuLayers,
        preferredBackend: GpuBackend.cpu,
      );

      expect(LlamaCppService.resolveGpuLayersForLoad(params), 0);
    });

    test('forces Android auto mode to zero gpu layers', () {
      const params = ModelParams(
        gpuLayers: ModelParams.maxGpuLayers,
        preferredBackend: GpuBackend.auto,
      );

      expect(
        LlamaCppService.resolveGpuLayersForLoad(params, isAndroid: true),
        0,
      );
    });

    test('preserves configured gpu layers for non-CPU backends', () {
      const params = ModelParams(
        gpuLayers: 42,
        preferredBackend: GpuBackend.vulkan,
      );

      expect(LlamaCppService.resolveGpuLayersForLoad(params), 42);
    });
  });

  group('resolveContextBatchSizes', () {
    test('preserves legacy defaults when batch sizes are unset', () {
      const params = ModelParams(contextSize: 2048);

      final resolved = LlamaCppService.resolveContextBatchSizes(params, 2048);

      expect(resolved.batchSize, 2048);
      expect(resolved.microBatchSize, 2048);
    });

    test('uses explicit batch and micro-batch values', () {
      const params = ModelParams(
        contextSize: 4096,
        batchSize: 512,
        microBatchSize: 128,
      );

      final resolved = LlamaCppService.resolveContextBatchSizes(params, 4096);

      expect(resolved.batchSize, 512);
      expect(resolved.microBatchSize, 128);
    });

    test('defaults micro-batch to batch when micro-batch is unset', () {
      const params = ModelParams(contextSize: 4096, batchSize: 384);

      final resolved = LlamaCppService.resolveContextBatchSizes(params, 4096);

      expect(resolved.batchSize, 384);
      expect(resolved.microBatchSize, 384);
    });

    test('clamps micro-batch to batch when only micro-batch is oversized', () {
      const params = ModelParams(contextSize: 1024, microBatchSize: 2048);

      final resolved = LlamaCppService.resolveContextBatchSizes(params, 1024);

      expect(resolved.batchSize, 1024);
      expect(resolved.microBatchSize, 1024);
    });

    test('clamps batch sizes to safe bounds', () {
      const params = ModelParams(
        contextSize: 512,
        batchSize: 2048,
        microBatchSize: 1024,
      );

      final resolved = LlamaCppService.resolveContextBatchSizes(params, 512);

      expect(resolved.batchSize, 512);
      expect(resolved.microBatchSize, 512);
    });

    test('falls back from invalid values to sane minimums', () {
      const params = ModelParams(
        contextSize: 0,
        batchSize: -10,
        microBatchSize: -20,
      );

      final resolved = LlamaCppService.resolveContextBatchSizes(params, 0);

      expect(resolved.batchSize, 1);
      expect(resolved.microBatchSize, 1);
    });
  });

  group('backend asset candidate scoring', () {
    test('accepts missing score symbol for compatibility', () {
      expect(LlamaCppService.isBackendCandidateScoreSupported(null), isTrue);
    });

    test('rejects non-positive scores', () {
      expect(LlamaCppService.isBackendCandidateScoreSupported(0), isFalse);
      expect(LlamaCppService.isBackendCandidateScoreSupported(-1), isFalse);
      expect(LlamaCppService.isBackendCandidateScoreSupported(1), isTrue);
    });

    test('skips unsupported Android CPU variants until score passes', () {
      final selected = LlamaCppService.selectFirstSupportedBackendCandidate(
        const <String>[
          'package:llamadart/ggml-cpu-android_armv9_2_2',
          'package:llamadart/ggml-cpu-android_armv8_6_1',
          'package:llamadart/ggml-cpu-android_armv8_2_2',
          'package:llamadart/ggml-cpu-android_armv8_0_1',
        ],
        scoreForCandidate: (candidate) {
          switch (candidate) {
            case 'package:llamadart/ggml-cpu-android_armv9_2_2':
            case 'package:llamadart/ggml-cpu-android_armv8_6_1':
              return 0;
            case 'package:llamadart/ggml-cpu-android_armv8_2_2':
              return 7;
            case 'package:llamadart/ggml-cpu-android_armv8_0_1':
              return 1;
          }
          return 0;
        },
      );

      expect(selected, 'package:llamadart/ggml-cpu-android_armv8_2_2');
    });

    test('keeps older backends without score symbol eligible', () {
      final selected = LlamaCppService.selectFirstSupportedBackendCandidate(
        const <String>[
          'package:llamadart/ggml-cpu-android_armv8_0_1',
          'package:llamadart/ggml-cpu',
        ],
        scoreForCandidate: (candidate) {
          if (candidate == 'package:llamadart/ggml-cpu-android_armv8_0_1') {
            return null;
          }
          return 1;
        },
      );

      expect(selected, 'package:llamadart/ggml-cpu-android_armv8_0_1');
    });

    test('returns null when every candidate is unsupported', () {
      final selected =
          LlamaCppService.selectFirstSupportedBackendCandidate(const <String>[
            'package:llamadart/ggml-cpu-android_armv9_2_2',
            'package:llamadart/ggml-cpu-android_armv8_6_1',
          ], scoreForCandidate: (_) => 0);

      expect(selected, isNull);
    });

    test('formats skipped backend asset diagnostics', () {
      expect(
        LlamaCppService.describeSkippedBackendAssetCandidate(
          'package:llamadart/ggml-cpu-android_armv8_6_1',
          0,
        ),
        'Skipped backend asset '
        '`package:llamadart/ggml-cpu-android_armv8_6_1` because '
        '`ggml_backend_score` returned 0.',
      );
    });

    test('formats loaded backend asset diagnostics with a score', () {
      expect(
        LlamaCppService.describeLoadedBackendAssetCandidate(
          'package:llamadart/ggml-cpu-android_armv8_2_2',
          7,
        ),
        'Loaded backend asset '
        '`package:llamadart/ggml-cpu-android_armv8_2_2` with '
        '`ggml_backend_score`=7.',
      );
    });

    test('formats loaded backend asset diagnostics without a score', () {
      expect(
        LlamaCppService.describeLoadedBackendAssetCandidate(
          'package:llamadart/ggml-cpu',
          null,
        ),
        'Loaded backend asset `package:llamadart/ggml-cpu` without '
        '`ggml_backend_score`.',
      );
    });
  });

  group('shouldDisableContextGpuOffload', () {
    test('disables offload for explicit CPU backend', () {
      const params = ModelParams(
        gpuLayers: ModelParams.maxGpuLayers,
        preferredBackend: GpuBackend.cpu,
      );

      expect(LlamaCppService.shouldDisableContextGpuOffload(params), isTrue);
    });

    test('disables offload when effective gpu layers are zero', () {
      const params = ModelParams(
        gpuLayers: 0,
        preferredBackend: GpuBackend.auto,
      );

      expect(LlamaCppService.shouldDisableContextGpuOffload(params), isTrue);
    });

    test('keeps offload enabled for non-CPU backend with gpu layers', () {
      const params = ModelParams(
        gpuLayers: 12,
        preferredBackend: GpuBackend.hip,
      );

      expect(LlamaCppService.shouldDisableContextGpuOffload(params), isFalse);
    });

    test('honors resolved load-time fallback to zero gpu layers', () {
      const params = ModelParams(
        gpuLayers: 32,
        preferredBackend: GpuBackend.vulkan,
      );

      expect(
        LlamaCppService.shouldDisableContextGpuOffload(
          params,
          resolvedGpuLayers: 0,
        ),
        isTrue,
      );
    });
  });

  group('shouldUseConservativeAndroidVulkanContextConfig', () {
    test('returns false off Android', () {
      const params = ModelParams(
        gpuLayers: 16,
        preferredBackend: GpuBackend.vulkan,
      );

      expect(
        LlamaCppService.shouldUseConservativeAndroidVulkanContextConfig(params),
        isFalse,
      );
    });

    test('returns true for Android Vulkan with GPU layers', () {
      const params = ModelParams(
        gpuLayers: 16,
        preferredBackend: GpuBackend.vulkan,
      );

      expect(
        LlamaCppService.shouldUseConservativeAndroidVulkanContextConfig(
          params,
          isAndroid: true,
        ),
        isTrue,
      );
    });

    test('returns false for Android CPU mode', () {
      const params = ModelParams(
        gpuLayers: 0,
        preferredBackend: GpuBackend.cpu,
      );

      expect(
        LlamaCppService.shouldUseConservativeAndroidVulkanContextConfig(
          params,
          isAndroid: true,
        ),
        isFalse,
      );
    });

    test('returns false after effective Vulkan fallback to zero layers', () {
      const params = ModelParams(
        gpuLayers: 16,
        preferredBackend: GpuBackend.vulkan,
      );

      expect(
        LlamaCppService.shouldUseConservativeAndroidVulkanContextConfig(
          params,
          resolvedGpuLayers: 0,
          isAndroid: true,
        ),
        isFalse,
      );
    });
  });

  group('shouldEnableExperimentalAndroidVulkanAcceleration', () {
    test('returns false off Android', () {
      expect(
        LlamaCppService.shouldEnableExperimentalAndroidVulkanAcceleration(
          'Qwen3.5-0.8B-Q4_K_M.gguf',
        ),
        isFalse,
      );
    });

    test('returns true for small Qwen3.5 models on Android', () {
      expect(
        LlamaCppService.shouldEnableExperimentalAndroidVulkanAcceleration(
          '/data/user/0/app_flutter/models/Qwen3.5-0.8B-Q4_K_M.gguf',
          isAndroid: true,
        ),
        isTrue,
      );
      expect(
        LlamaCppService.shouldEnableExperimentalAndroidVulkanAcceleration(
          '/data/user/0/app_flutter/models/Qwen3.5-2B-Q4_K_M.gguf',
          isAndroid: true,
        ),
        isTrue,
      );
      expect(
        LlamaCppService.shouldEnableExperimentalAndroidVulkanAcceleration(
          '/data/user/0/app_flutter/models/Qwen3.5-4B-Q4_K_M.gguf',
          isAndroid: true,
        ),
        isTrue,
      );
    });

    test('returns false for unrelated models on Android', () {
      expect(
        LlamaCppService.shouldEnableExperimentalAndroidVulkanAcceleration(
          '/data/user/0/app_flutter/models/Llama-3.2-3B.gguf',
          isAndroid: true,
        ),
        isFalse,
      );
    });
  });

  group('resolveMtmdUseGpuForLoad', () {
    test('forces CPU mode to disable projector GPU offload', () {
      const params = ModelParams(
        gpuLayers: ModelParams.maxGpuLayers,
        preferredBackend: GpuBackend.cpu,
      );

      expect(LlamaCppService.resolveMtmdUseGpuForLoad(params, 0), isFalse);
    });

    test(
      'disables projector GPU offload when effective gpu layers are zero',
      () {
        const params = ModelParams(
          gpuLayers: 0,
          preferredBackend: GpuBackend.auto,
        );

        expect(LlamaCppService.resolveMtmdUseGpuForLoad(params, 0), isFalse);
      },
    );

    test(
      'enables projector GPU offload for non-CPU backend with gpu layers',
      () {
        const params = ModelParams(
          gpuLayers: 42,
          preferredBackend: GpuBackend.vulkan,
        );

        expect(LlamaCppService.resolveMtmdUseGpuForLoad(params, 42), isTrue);
      },
    );

    test(
      'keeps projector GPU offload disabled after effective CPU fallback',
      () {
        const params = ModelParams(
          gpuLayers: 42,
          preferredBackend: GpuBackend.vulkan,
        );

        expect(LlamaCppService.resolveMtmdUseGpuForLoad(params, 0), isFalse);
      },
    );
  });

  group('parseBackendModuleDirectoryFromProcMaps', () {
    test('extracts lib directory from standard maps entry', () {
      const maps = '''
7f8a0000-7f8b0000 r-xp 00000000 103:04 12345 /data/app/~~pkg/lib/arm64/libllamadart.so
''';

      expect(
        LlamaCppService.parseBackendModuleDirectoryFromProcMaps(maps),
        '/data/app/~~pkg/lib/arm64',
      );
    });

    test('handles deleted mapping suffix', () {
      const maps = '''
7f8a0000-7f8b0000 r-xp 00000000 103:04 12345 /tmp/libllamadart.so (deleted)
''';

      expect(
        LlamaCppService.parseBackendModuleDirectoryFromProcMaps(maps),
        '/tmp',
      );
    });

    test('accepts versioned Linux libllamadart mappings', () {
      const maps = '''
7f8a0000-7f8b0000 r-xp 00000000 103:04 12345 /opt/app/lib/libllamadart.so.0
''';

      expect(
        LlamaCppService.parseBackendModuleDirectoryFromProcMaps(maps),
        '/opt/app/lib',
      );
    });

    test('returns null when libllamadart mapping is missing', () {
      const maps = '''
7f8a0000-7f8b0000 r-xp 00000000 103:04 12345 /system/lib64/libc.so
''';

      expect(
        LlamaCppService.parseBackendModuleDirectoryFromProcMaps(maps),
        isNull,
      );
    });

    test('forces CPU projector mode for Android Qwen3.5 0.8B', () {
      const params = ModelParams(
        gpuLayers: ModelParams.maxGpuLayers,
        preferredBackend: GpuBackend.vulkan,
      );

      expect(
        LlamaCppService.resolveMtmdUseGpuForLoad(
          params,
          ModelParams.maxGpuLayers,
          modelPath: '/data/user/0/app/models/Qwen3.5-0.8B-Q4_K_M.gguf',
          isAndroid: true,
        ),
        isFalse,
      );
    });

    test('keeps projector GPU path for unrelated Android models', () {
      const params = ModelParams(
        gpuLayers: ModelParams.maxGpuLayers,
        preferredBackend: GpuBackend.vulkan,
      );

      expect(
        LlamaCppService.resolveMtmdUseGpuForLoad(
          params,
          ModelParams.maxGpuLayers,
          modelPath: '/data/user/0/app/models/Llama-3.2-3B.gguf',
          isAndroid: true,
        ),
        isTrue,
      );
    });
  });

  group('resolveWindowsBackendModuleDirectory', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync(
        'llamadart-windows-modules-',
      );
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('uses explicit environment override when valid', () {
      final overrideDir = Directory(path.join(tempRoot.path, 'override'))
        ..createSync(recursive: true);
      _createWindowsBundleMarkerFiles(overrideDir.path);

      final resolved = LlamaCppService.resolveWindowsBackendModuleDirectory(
        resolvedExecutablePath: path.join(tempRoot.path, 'dart.exe'),
        currentDirectoryPath: tempRoot.path,
        environment: {'LLAMADART_NATIVE_LIB_DIR': overrideDir.path},
      );

      expect(path.normalize(resolved!), path.normalize(overrideDir.path));
    });

    test('falls back to hook cache extracted bundle directory', () {
      final extractedDir = Directory(
        path.join(
          tempRoot.path,
          '.dart_tool',
          'llamadart',
          'native_bundles',
          'b8095',
          'windows-x64',
          'extracted',
        ),
      )..createSync(recursive: true);
      _createWindowsBundleMarkerFiles(extractedDir.path);

      final resolved = LlamaCppService.resolveWindowsBackendModuleDirectory(
        resolvedExecutablePath: path.join(
          tempRoot.path,
          'dart-sdk',
          'dart.exe',
        ),
        currentDirectoryPath: tempRoot.path,
        environment: const {},
      );

      expect(path.normalize(resolved!), path.normalize(extractedDir.path));
    });

    test('prefers .dart_tool/lib when suffixed native assets are present', () {
      final dartToolLibDir = Directory(
        path.join(tempRoot.path, '.dart_tool', 'lib'),
      )..createSync(recursive: true);
      _createWindowsBundleMarkerFiles(
        dartToolLibDir.path,
        suffix: '-windows-x64',
      );

      final extractedDir = Directory(
        path.join(
          tempRoot.path,
          '.dart_tool',
          'llamadart',
          'native_bundles',
          'b8095',
          'windows-x64',
          'extracted',
        ),
      )..createSync(recursive: true);
      _createWindowsBundleMarkerFiles(extractedDir.path);

      final resolved = LlamaCppService.resolveWindowsBackendModuleDirectory(
        resolvedExecutablePath: path.join(
          tempRoot.path,
          'dart-sdk',
          'dart.exe',
        ),
        currentDirectoryPath: tempRoot.path,
        environment: const {},
      );

      expect(path.normalize(resolved!), path.normalize(dartToolLibDir.path));
    });

    test('uses current directory when executable dir is not a bundle', () {
      final currentDir = Directory(path.join(tempRoot.path, 'cwd'))
        ..createSync(recursive: true);
      _createWindowsBundleMarkerFiles(currentDir.path);

      final resolved = LlamaCppService.resolveWindowsBackendModuleDirectory(
        resolvedExecutablePath: path.join(tempRoot.path, 'dart.exe'),
        currentDirectoryPath: currentDir.path,
        environment: const {},
      );

      expect(path.normalize(resolved!), path.normalize(currentDir.path));
    });

    test(
      'falls back to executable directory when no bundle can be detected',
      () {
        final exeDir = Directory(path.join(tempRoot.path, 'bin'))
          ..createSync(recursive: true);
        final resolved = LlamaCppService.resolveWindowsBackendModuleDirectory(
          resolvedExecutablePath: path.join(exeDir.path, 'dart.exe'),
          currentDirectoryPath: tempRoot.path,
          environment: const {},
        );

        expect(path.normalize(resolved!), path.normalize(exeDir.path));
      },
    );
  });

  group('resolveLinuxPrimaryLibraryDirectory', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync(
        'llamadart-linux-primary-',
      );
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('uses explicit environment override when valid', () {
      final overrideDir = Directory(path.join(tempRoot.path, 'override'))
        ..createSync(recursive: true);
      _createLinuxBundleMarkerFiles(overrideDir.path);

      final resolved = LlamaCppService.resolveLinuxPrimaryLibraryDirectory(
        resolvedExecutablePath: path.join(tempRoot.path, 'dart'),
        currentDirectoryPath: tempRoot.path,
        environment: {'LLAMADART_NATIVE_LIB_DIR': overrideDir.path},
      );

      expect(path.normalize(resolved!), path.normalize(overrideDir.path));
    });

    test('prefers executable-adjacent lib directory for packaged bundles', () {
      final bundleDir = Directory(path.join(tempRoot.path, 'bundle'))
        ..createSync(recursive: true);
      final executableDir = Directory(path.join(bundleDir.path, 'app'))
        ..createSync(recursive: true);
      final libDir = Directory(path.join(executableDir.path, 'lib'))
        ..createSync(recursive: true);
      _createLinuxBundleMarkerFiles(libDir.path);

      final resolved = LlamaCppService.resolveLinuxPrimaryLibraryDirectory(
        resolvedExecutablePath: path.join(executableDir.path, 'my_app'),
        currentDirectoryPath: bundleDir.path,
        environment: const {},
      );

      expect(path.normalize(resolved!), path.normalize(libDir.path));
    });

    test('falls back to current working directory lib folder', () {
      final currentDir = Directory(path.join(tempRoot.path, 'cwd'))
        ..createSync(recursive: true);
      final libDir = Directory(path.join(currentDir.path, 'lib'))
        ..createSync(recursive: true);
      _createLinuxBundleMarkerFiles(libDir.path, versionedPrimary: true);

      final resolved = LlamaCppService.resolveLinuxPrimaryLibraryDirectory(
        resolvedExecutablePath: path.join(tempRoot.path, 'dart'),
        currentDirectoryPath: currentDir.path,
        environment: const {},
      );

      expect(path.normalize(resolved!), path.normalize(libDir.path));
    });
  });

  group('Linux runtime dependency helpers', () {
    late Directory tempRoot;

    setUp(() {
      tempRoot = Directory.systemTemp.createTempSync(
        'llamadart-linux-runtime-helpers-',
      );
    });

    tearDown(() {
      if (tempRoot.existsSync()) {
        tempRoot.deleteSync(recursive: true);
      }
    });

    test('copyMissingLinuxLibrary copies from the first available source', () {
      final targetDir = Directory(path.join(tempRoot.path, 'target'))
        ..createSync(recursive: true);
      final sourceA = Directory(path.join(tempRoot.path, 'source-a'))
        ..createSync(recursive: true);
      final sourceB = Directory(path.join(tempRoot.path, 'source-b'))
        ..createSync(recursive: true);
      File(path.join(sourceB.path, 'libggml.so')).writeAsStringSync('ggml');

      final diagnostics = <String>[];
      final copied = LlamaCppService.copyMissingLinuxLibrary(
        targetDirectory: targetDir.path,
        sourceDirectories: <String>[sourceA.path, sourceB.path],
        fileName: 'libggml.so',
        onDiagnostic: diagnostics.add,
      );

      expect(copied, isTrue);
      expect(
        File(path.join(targetDir.path, 'libggml.so')).readAsStringSync(),
        'ggml',
      );
      expect(diagnostics, isEmpty);
    });

    test('copyMissingLinuxLibrary reports copy failures', () {
      final targetDir = Directory(path.join(tempRoot.path, 'target'))
        ..createSync(recursive: true);
      Directory(path.join(targetDir.path, 'libggml.so')).createSync();
      final sourceDir = Directory(path.join(tempRoot.path, 'source'))
        ..createSync(recursive: true);
      File(path.join(sourceDir.path, 'libggml.so')).writeAsStringSync('ggml');

      final diagnostics = <String>[];
      final copied = LlamaCppService.copyMissingLinuxLibrary(
        targetDirectory: targetDir.path,
        sourceDirectories: <String>[sourceDir.path],
        fileName: 'libggml.so',
        onDiagnostic: diagnostics.add,
      );

      expect(copied, isFalse);
      expect(diagnostics, hasLength(1));
      expect(
        diagnostics.single,
        contains('Failed to copy Linux runtime dependency'),
      );
    });

    test('ensureLinuxSonameAlias creates fallback alias when missing', () {
      final targetDir = Directory(path.join(tempRoot.path, 'target'))
        ..createSync(recursive: true);
      final sourcePath = path.join(targetDir.path, 'libllama.so');
      File(sourcePath).writeAsStringSync('llama');

      final diagnostics = <String>[];
      final created = LlamaCppService.ensureLinuxSonameAlias(
        directory: targetDir.path,
        baseFileName: 'libllama.so',
        onDiagnostic: diagnostics.add,
      );

      expect(created, isTrue);
      expect(
        File('$sourcePath.0').existsSync() ||
            Link('$sourcePath.0').existsSync(),
        isTrue,
      );
      expect(diagnostics, isEmpty);
    });

    test('ensureLinuxSonameAlias reports alias creation failures', () {
      final targetDir = Directory(path.join(tempRoot.path, 'target'))
        ..createSync(recursive: true);
      final sourcePath = path.join(targetDir.path, 'libllama.so');
      File(sourcePath).writeAsStringSync('llama');
      Directory('$sourcePath.0').createSync();

      final diagnostics = <String>[];
      final created = LlamaCppService.ensureLinuxSonameAlias(
        directory: targetDir.path,
        baseFileName: 'libllama.so',
        onDiagnostic: diagnostics.add,
      );

      expect(created, isFalse);
      expect(diagnostics, hasLength(1));
      expect(
        diagnostics.single,
        contains('Failed to create or copy Linux SONAME alias'),
      );
    });
  });

  test('resolveBackendModuleDirectory returns null on unsupported hosts', () {
    if (Platform.isAndroid || Platform.isLinux || Platform.isWindows) {
      return;
    }

    expect(LlamaCppService.resolveBackendModuleDirectory(), isNull);
  });
}

void _createWindowsBundleMarkerFiles(
  String directoryPath, {
  String suffix = '',
}) {
  final markerFiles = <String>[
    'llama$suffix.dll',
    'ggml$suffix.dll',
    'ggml-cpu$suffix.dll',
  ];
  for (final fileName in markerFiles) {
    File(path.join(directoryPath, fileName)).writeAsStringSync('');
  }
}

void _createLinuxBundleMarkerFiles(
  String directoryPath, {
  bool versionedPrimary = false,
}) {
  final markerFiles = <String>[
    versionedPrimary ? 'libllamadart.so.0' : 'libllamadart.so',
    'libllama.so',
    'libggml.so',
  ];
  for (final fileName in markerFiles) {
    File(path.join(directoryPath, fileName)).writeAsStringSync('');
  }
}
