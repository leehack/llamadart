@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:mirrors';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';
import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/models/config/gpu_backend.dart';
import 'package:llamadart/src/core/models/config/gpu_device_info.dart';
import 'package:llamadart/src/core/models/inference/generation_params.dart';
import 'package:llamadart/src/core/models/inference/model_params.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  test('preserved template tokens remain excluded from native text stops', () {
    final stops = _invokePrivateForTesting<List<String>>(
      LlamaCppService(),
      '_effectiveStopSequences',
      [
        ['<tool_call>', 'cedar17', '<tool_call>suffix'],
        ['<tool_call>'],
      ],
    );
    expect(stops, ['cedar17', '<tool_call>suffix']);
  });

  group('reasoning-budget resolver diagnostics', () {
    Object? resolve(
      LlamaCppService service,
      List<String> candidates, {
      DynamicLibrary Function(String)? open,
    }) => _invokePrivateForTesting<Object?>(
      service,
      '_resolveReasoningBudgetApi',
      const [],
      {#candidates: candidates, #open: open},
    );

    String failure(void Function() action) {
      try {
        action();
      } on LlamaUnsupportedException catch (error) {
        return error.message;
      }
      fail('Expected the production resolver to reject an unavailable helper');
    }

    test('a real library without the export reports lookup, not open', () {
      final systemLibrary = Platform.isWindows
          ? 'kernel32.dll'
          : Platform.isMacOS
          ? '/usr/lib/libSystem.B.dylib'
          : 'libc.so.6';
      final service = LlamaCppService();
      final message = failure(() => resolve(service, [systemLibrary]));
      expect(message, contains('lookup: required export unavailable'));
      expect(message, isNot(contains('open:')));
      expect(message, contains('llama_dart_sampler_init_reasoning_budget'));
      expect(message, isNot(contains(systemLibrary)));
      // A cached failure must preserve the explanation without re-opening.
      expect(
        failure(
          () => resolve(service, [], open: (_) => throw StateError('retry')),
        ),
        message,
      );
    });

    test('an actual missing library reports an opening failure', () {
      final directory = Directory.systemTemp.createTempSync('budget-loader-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final candidate = path.join(directory.path, 'secret-token', 'absent.dll');
      final message = failure(() => resolve(LlamaCppService(), [candidate]));
      expect(message, contains('open:'));
      expect(message, isNot(contains('lookup:')));
      expect(message, isNot(contains(directory.path)));
      expect(message, isNot(contains('secret-token')));
    });

    test(
      'retains safe Windows causes and bounds repeated sensitive errors',
      () {
        for (final code in [5, 126, 127, 193, 1114]) {
          final message = failure(
            () => resolve(
              LlamaCppService(),
              List.filled(
                1000,
                'https://user:password@host/wrapper?token=secret',
              ),
              open: (_) => throw ArgumentError(
                'Failed to load C:\\private\\secret\\wrapper.dll\n'
                'https://user:password@host/?token=secret (error code: $code)',
              ),
            ),
          );
          expect(message, contains('Windows error $code'));
          expect(message, contains('1000 attempts'));
          expect(message.length, lessThan(700));
          for (final secret in [
            'private',
            'secret',
            'password',
            'https:',
            '\n',
          ]) {
            expect(message, isNot(contains(secret)));
          }
        }
      },
    );

    test('continues after opening failure and caches the real wrapper API', () {
      final service = LlamaCppService();
      final wrapper = path.absolute(
        '.dart_tool',
        'lib',
        Platform.isWindows
            ? 'llamadart.dll'
            : Platform.isMacOS
            ? 'libllamadart.dylib'
            : 'libllamadart.so',
      );
      final api = resolve(service, ['$wrapper.absent', wrapper]);
      expect(api, isNotNull);
      expect(
        resolve(service, [], open: (_) => throw StateError('retry')),
        same(api),
      );
      final message = _invokePrivateForTesting<String>(
        service,
        '_reasoningBudgetUnavailableMessage',
        const [],
      );
      expect(message, contains('loaderDiagnostics=[]'));
    });
  });

  group('wrapper sibling dependency loading', () {
    final absolute = path.join(Directory.systemTemp.path, 'llamadart.dll');
    final handle = Pointer<Void>.fromAddress(123);

    test('holds the preload until the wrapper acquires its reference', () {
      final events = <String>[];
      final library = DynamicLibrary.process();
      final result = LlamaCppService.openWrapperLibraryWithDependencies(
        absolute,
        isWindows: true,
        preload: (candidate) {
          expect(candidate, absolute);
          events.add('preload');
          return handle;
        },
        open: (candidate) {
          expect(events, ['preload']);
          events.add('open');
          return library;
        },
        release: (actual, candidate) {
          expect(actual, handle);
          events.add('release');
        },
        exists: (_) => true,
      );
      expect(result, same(library));
      expect(events, ['preload', 'open', 'release']);
    });

    test('releases the preload and preserves the original opening error', () {
      final failure = StateError('missing transitive import');
      var released = false;
      expect(
        () => LlamaCppService.openWrapperLibraryWithDependencies(
          absolute,
          isWindows: true,
          preload: (_) => handle,
          open: (_) => throw failure,
          release: (_, _) => released = true,
          exists: (_) => true,
        ),
        throwsA(same(failure)),
      );
      expect(released, isTrue);
    });

    for (final candidate in [
      'llamadart.dll',
      'package:llamadart/llamadart_wrapper',
    ]) {
      test('does not alter search semantics for $candidate', () {
        LlamaCppService.openWrapperLibraryWithDependencies(
          candidate,
          isWindows: true,
          preload: (_) => throw StateError('unexpected preload'),
          open: (_) => DynamicLibrary.process(),
          release: (_, _) => fail('unexpected release'),
        );
      });
    }

    test('does not preload a missing absolute candidate', () {
      final failure = StateError('not found');
      final checked = <String>[];
      expect(
        () => LlamaCppService.openWrapperLibraryWithDependencies(
          absolute,
          isWindows: true,
          preload: (_) => throw StateError('unexpected preload'),
          open: (_) => throw failure,
          release: (_, _) => fail('unexpected release'),
          exists: (candidate) {
            checked.add(candidate);
            return false;
          },
        ),
        throwsA(same(failure)),
      );
      expect(checked, [absolute]);
    });

    test('checks the file system by default', () {
      final directory = Directory.systemTemp.createTempSync('llamadart_wrap_');
      addTearDown(() => directory.deleteSync(recursive: true));
      final present = path.join(directory.path, 'llamadart.dll');
      File(present).writeAsBytesSync(const []);
      final preloaded = <String>[];
      for (final candidate in [
        present,
        path.join(directory.path, 'missing.dll'),
      ]) {
        LlamaCppService.openWrapperLibraryWithDependencies(
          candidate,
          isWindows: true,
          preload: (candidate) {
            preloaded.add(candidate);
            return nullptr;
          },
          open: (_) => DynamicLibrary.process(),
          release: (_, _) => fail('unexpected release'),
        );
      }
      expect(preloaded, [present]);
    });

    test('does not preload on non-Windows or release a failed preload', () {
      for (final isWindows in [false, true]) {
        LlamaCppService.openWrapperLibraryWithDependencies(
          absolute,
          isWindows: isWindows,
          preload: (_) => nullptr,
          open: (_) => DynamicLibrary.process(),
          release: (_, _) => fail('unexpected release'),
          exists: (_) => true,
        );
      }
    });
  });

  test('LlamaCppService can be instantiated', () {
    final service = LlamaCppService();
    expect(service, isA<LlamaCppService>());
  });

  group('aLoRA eager-activation guard', () {
    final adapter = Pointer<llama_adapter_lora>.fromAddress(1);

    test('preserves an ordinary LoRA adapter', () {
      var freed = 0;

      LlamaCppService.debugValidateLoraForEagerActivationForTesting(
        adapter,
        'ordinary.gguf',
        invocationTokenCount: (_) => 0,
        invocationTokenData: (_) => nullptr,
        freeAdapter: (_) => freed++,
      );

      expect(freed, 0);
    });

    test('rejects and frees an aLoRA adapter', () {
      var freed = 0;

      expect(
        () => LlamaCppService.debugValidateLoraForEagerActivationForTesting(
          adapter,
          'activated.gguf',
          invocationTokenCount: (_) => 3,
          invocationTokenData: (_) => Pointer<llama_token>.fromAddress(2),
          freeAdapter: (_) => freed++,
        ),
        throwsA(
          isA<LlamaUnsupportedException>()
              .having(
                (error) => error.message,
                'message',
                contains('activated.gguf is an aLoRA adapter'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('3 invocation token(s)'),
              ),
        ),
      );
      expect(freed, 1);
    });

    test('fails closed and frees on missing metadata symbol', () {
      var freed = 0;

      expect(
        () => LlamaCppService.debugValidateLoraForEagerActivationForTesting(
          adapter,
          'unknown.gguf',
          invocationTokenCount: (_) => throw ArgumentError(
            'Could not resolve '
            'llama_adapter_get_alora_n_invocation_tokens',
          ),
          invocationTokenData: (_) => nullptr,
          freeAdapter: (_) => freed++,
        ),
        throwsA(
          isA<LlamaUnsupportedException>()
              .having(
                (error) => error.message,
                'message',
                contains('Cannot safely load the LoRA adapter'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('llama_adapter_get_alora_n_invocation_tokens'),
              )
              .having(
                (error) => error.message,
                'message',
                contains("matches this package's bindings"),
              ),
        ),
      );
      expect(freed, 1);
    });

    test('fails closed and frees on a partial metadata ABI', () {
      var freed = 0;

      expect(
        () => LlamaCppService.debugValidateLoraForEagerActivationForTesting(
          adapter,
          'partial-abi.gguf',
          invocationTokenCount: (_) => 0,
          invocationTokenData: (_) => throw ArgumentError(
            'Could not resolve llama_adapter_get_alora_invocation_tokens',
          ),
          freeAdapter: (_) => freed++,
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('llama_adapter_get_alora_invocation_tokens'),
          ),
        ),
      );
      expect(freed, 1);
    });

    test('fails closed and frees on inconsistent aLoRA metadata', () {
      var freed = 0;

      expect(
        () => LlamaCppService.debugValidateLoraForEagerActivationForTesting(
          adapter,
          'inconsistent-metadata.gguf',
          invocationTokenCount: (_) => 1,
          invocationTokenData: (_) => nullptr,
          freeAdapter: (_) => freed++,
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('Cannot safely load the LoRA adapter'),
          ),
        ),
      );
      expect(freed, 1);
    });

    test('keeps version-skew failure typed if cleanup also fails', () {
      expect(
        () => LlamaCppService.debugValidateLoraForEagerActivationForTesting(
          adapter,
          'severely-skewed.gguf',
          invocationTokenCount: (_) => throw ArgumentError('missing getter'),
          invocationTokenData: (_) => nullptr,
          freeAdapter: (_) => throw ArgumentError('missing free'),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    });
  });

  group('getVramInfo', () {
    test('returns a non-negative (total, free) record without throwing', () {
      // Shape invariant: callers destructure these two fields. A
      // rename or struct change in `LlamaCppService.getVramInfo`
      // would break every backend that forwards the worker
      // SystemInfoResponse fields. Hosts with GPU runtimes available
      // may return real memory here; hosts without them return (0, 0).
      final service = LlamaCppService();
      final info = service.getVramInfo();
      expect(info.total, isA<int>());
      expect(info.free, isA<int>());
      expect(info.total, greaterThanOrEqualTo(0));
      expect(info.free, greaterThanOrEqualTo(0));
    });
  });

  group('listGpuDevices', () {
    test('returns a List<GpuDeviceInfo> without throwing', () {
      // Hosts with a GPU runtime return real devices; CI hosts without one
      // return an empty list. Either way the call must not throw and every
      // element must satisfy the field contract callers rely on. A rename or
      // struct change in `LlamaCppService.listGpuDevices` breaks this.
      final service = LlamaCppService();
      final devices = service.listGpuDevices();
      expect(devices, isA<List<GpuDeviceInfo>>());
      for (final device in devices) {
        expect(device.type, isNot(GpuDeviceType.cpu));
        expect(device.mainGpu, greaterThanOrEqualTo(0));
        expect(device.memoryFreeBytes, greaterThanOrEqualTo(0));
        expect(device.memoryTotalBytes, greaterThanOrEqualTo(0));
      }
    });

    test('does not throw when probing an unavailable backend', () {
      // probeBackends opt-in must stay safe: requesting a backend whose module
      // or symbols are absent (as on CI hosts) returns a list rather than
      // throwing.
      final service = LlamaCppService();
      final devices = service.listGpuDevices(
        probeBackends: const [GpuBackend.vulkan, GpuBackend.cuda],
      );
      expect(devices, isA<List<GpuDeviceInfo>>());
    });
  });

  group('gpuBackendFromRegName', () {
    test('maps ggml registry names (incl. Metal MTL) to GpuBackend', () {
      expect(
        LlamaCppService.gpuBackendFromRegName('Vulkan'),
        GpuBackend.vulkan,
      );
      expect(LlamaCppService.gpuBackendFromRegName('CUDA'), GpuBackend.cuda);
      expect(LlamaCppService.gpuBackendFromRegName('Metal'), GpuBackend.metal);
      // Regression: macOS reports the registry name as "MTL", which previously
      // fell through to GpuBackend.auto.
      expect(LlamaCppService.gpuBackendFromRegName('MTL'), GpuBackend.metal);
      expect(LlamaCppService.gpuBackendFromRegName('ROCm'), GpuBackend.hip);
      expect(LlamaCppService.gpuBackendFromRegName('HIP'), GpuBackend.hip);
      expect(
        LlamaCppService.gpuBackendFromRegName('OpenCL'),
        GpuBackend.opencl,
      );
      expect(LlamaCppService.gpuBackendFromRegName('BLAS'), GpuBackend.blas);
      expect(LlamaCppService.gpuBackendFromRegName('CPU'), GpuBackend.cpu);
      expect(
        LlamaCppService.gpuBackendFromRegName('SomethingElse'),
        GpuBackend.auto,
      );
    });
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

  group('speculative validation', () {
    late LlamaCppService service;
    late Directory tempDir;

    setUp(() {
      service = LlamaCppService();
      tempDir = Directory.systemTemp.createTempSync('llamadart-spec-');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('de-duplicates mixed strategies before native mapping', () {
      final typeNames = service.debugResolveSpeculativeTypeNamesForTesting(
        const GenerationParams(
          speculativeDecodingConfig: SpeculativeDecodingConfig.mixed(
            strategies: [
              SpeculativeDecodingStrategy.ngramMod,
              SpeculativeDecodingStrategy.ngramMod,
              SpeculativeDecodingStrategy.mtp,
              SpeculativeDecodingStrategy.mtp,
            ],
            draftTokenMax: 4,
          ),
        ),
      );

      expect(typeNames, 'ngram-mod,draft-mtp');
    });

    test('maps DSpark exactly as an external non-MTP draft context', () {
      final resolved = service.debugResolveSpeculativeNativeParamsForTesting(
        const GenerationParams(
          speculativeDecodingConfig: SpeculativeDecodingConfig.draftDspark(
            draftModelPath: 'dspark.gguf',
            draftTokenMax: 7,
          ),
        ),
      );

      expect(resolved['typeNames'], 'draft-dspark');
      expect(resolved['draftTokenMax'], 7);
      expect(resolved['hasDraftContextStrategy'], isTrue);
      expect(resolved['requiresExternalDraftModel'], isTrue);
      expect(resolved['usesMtp'], isFalse);
      expect(resolved['suppressDraftProcessLogits'], isTrue);
    });

    test('mixes DSpark with draftless n-gram strategies in order', () {
      final typeNames = service.debugResolveSpeculativeTypeNamesForTesting(
        const GenerationParams(
          speculativeDecodingConfig: SpeculativeDecodingConfig.mixed(
            strategies: [
              SpeculativeDecodingStrategy.ngramMod,
              SpeculativeDecodingStrategy.draftDspark,
            ],
            draftModelPath: 'dspark.gguf',
          ),
        ),
      );

      expect(typeNames, 'ngram-mod,draft-dspark');
    });

    test('rejects speculative decoding with a thinking budget', () {
      expect(
        () => service.debugResolveSpeculativeTypeNamesForTesting(
          const GenerationParams(
            thinkingBudget: ThinkingBudget(maxTokens: 64),
            speculativeDecodingConfig: SpeculativeDecodingConfig.ngramMod(),
          ),
        ),
        throwsA(isA<LlamaUnsupportedException>()),
      );
    });

    test('uses ngram size M as native draft cap for map strategies', () {
      final configs = <String, SpeculativeDecodingConfig>{
        'ngram-simple': const SpeculativeDecodingConfig.ngramSimple(
          draftTokenMax: 8,
        ),
        'ngram-map-k': const SpeculativeDecodingConfig.ngramMapK(
          draftTokenMax: 8,
        ),
        'ngram-map-k4v': const SpeculativeDecodingConfig.ngramMapK4v(
          draftTokenMax: 8,
        ),
      };

      for (final entry in configs.entries) {
        final defaults = service.debugResolveSpeculativeNativeParamsForTesting(
          GenerationParams(speculativeDecodingConfig: entry.value),
        );

        expect(defaults['typeNames'], entry.key);
        expect(defaults['draftTokenMax'], 48);
        expect(defaults['ngramSizeM'], isNull);
      }

      final explicitConfigs = <String, SpeculativeDecodingConfig>{
        'ngram-simple': const SpeculativeDecodingConfig.ngramSimple(
          draftTokenMax: 8,
          ngramSizeM: 16,
        ),
        'ngram-map-k': const SpeculativeDecodingConfig.ngramMapK(
          draftTokenMax: 8,
          ngramSizeM: 16,
        ),
        'ngram-map-k4v': const SpeculativeDecodingConfig.ngramMapK4v(
          draftTokenMax: 8,
          ngramSizeM: 16,
        ),
      };

      for (final entry in explicitConfigs.entries) {
        final explicit = service.debugResolveSpeculativeNativeParamsForTesting(
          GenerationParams(speculativeDecodingConfig: entry.value),
        );

        expect(explicit['typeNames'], entry.key);
        expect(explicit['draftTokenMax'], 16);
        expect(explicit['ngramSizeM'], 16);
      }
    });

    test('uses upstream ngram size M default when draft cap is omitted', () {
      final resolved = service.debugResolveSpeculativeNativeParamsForTesting(
        const GenerationParams(
          speculativeDecodingConfig: SpeculativeDecodingConfig.ngramMapK(),
        ),
      );

      expect(resolved['draftTokenMax'], 48);
      expect(resolved['ngramSizeM'], isNull);
    });

    test('rejects mixed configs with more than one draft strategy', () {
      expect(
        () => service.debugResolveSpeculativeTypeNamesForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.mixed(
              strategies: [
                SpeculativeDecodingStrategy.mtp,
                SpeculativeDecodingStrategy.draftSimple,
              ],
              draftModelPath: 'draft.gguf',
            ),
          ),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('at most one draft-model strategy'),
          ),
        ),
      );
    });

    test('rejects DSpark mixed with another draft-context strategy', () {
      expect(
        () => service.debugResolveSpeculativeTypeNamesForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.mixed(
              strategies: [
                SpeculativeDecodingStrategy.draftDspark,
                SpeculativeDecodingStrategy.mtp,
              ],
              draftModelPath: 'dspark.gguf',
            ),
          ),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('at most one draft-model strategy'),
          ),
        ),
      );
    });

    test('requires draftModelPath for external draft strategies', () {
      expect(
        () => service.debugResolveSpeculativeTypeNamesForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.mixed(
              strategies: [SpeculativeDecodingStrategy.draftEagle3],
            ),
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('requires draftModelPath'),
          ),
        ),
      );
    });

    test('requires a non-empty draftModelPath for DSpark', () {
      expect(
        () => service.debugResolveSpeculativeTypeNamesForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.mixed(
              strategies: [SpeculativeDecodingStrategy.draftDspark],
            ),
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('requires draftModelPath'),
          ),
        ),
      );
      expect(
        () => service.debugResolveSpeculativeTypeNamesForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.draftDspark(
              draftModelPath: ' ',
            ),
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('must be null or a non-empty path'),
          ),
        ),
      );
    });

    test('suppresses process logits only for external draft strategies', () {
      expect(
        service.debugSuppressesDraftProcessLogitsForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.draftSimple(
              draftModelPath: 'draft.gguf',
            ),
          ),
        ),
        isTrue,
      );
      expect(
        service.debugSuppressesDraftProcessLogitsForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.draftDspark(
              draftModelPath: 'draft.gguf',
            ),
          ),
        ),
        isTrue,
      );
      expect(
        service.debugSuppressesDraftProcessLogitsForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.draftEagle3(
              draftModelPath: 'draft.gguf',
            ),
          ),
        ),
        isTrue,
      );
      expect(
        service.debugSuppressesDraftProcessLogitsForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.mtp(),
          ),
        ),
        isFalse,
      );
      expect(
        service.debugSuppressesDraftProcessLogitsForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.ngramSimple(),
          ),
        ),
        isFalse,
      );
    });

    test('requires loadMtp for bundled MTP tensors', () {
      const generationParams = GenerationParams(
        speculativeDecodingConfig: SpeculativeDecodingConfig.mtp(),
      );

      expect(
        () => service.debugValidateMtpModelLoadForTesting(
          generationParams,
          const ModelParams(),
        ),
        throwsA(
          isA<LlamaUnsupportedException>().having(
            (error) => error.message,
            'message',
            contains('ModelParams(loadMtp: true)'),
          ),
        ),
      );
      expect(
        () => service.debugValidateMtpModelLoadForTesting(
          generationParams,
          const ModelParams(loadMtp: true),
        ),
        returnsNormally,
      );
    });

    test('external MTP draft does not require target bundled tensors', () {
      expect(
        () => service.debugValidateMtpModelLoadForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.mtp(
              draftModelPath: 'draft.gguf',
            ),
          ),
          const ModelParams(),
        ),
        returnsNormally,
      );
    });

    test('DSpark never requires target bundled MTP tensors', () {
      expect(
        () => service.debugValidateMtpModelLoadForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.draftDspark(
              draftModelPath: 'draft.gguf',
            ),
          ),
          const ModelParams(),
        ),
        returnsNormally,
      );
    });

    test('reports DSpark native version skew as a typed failure', () {
      expect(
        () => service.debugThrowSpeculativeInitFailureForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.draftDspark(
              draftModelPath: 'draft.gguf',
            ),
          ),
        ),
        throwsA(
          isA<LlamaUnsupportedException>()
              .having(
                (error) => error.message,
                'message',
                contains('draft-dspark'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('llamadart-native@b10356'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('draft-context support'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('draftTokenMax'),
              ),
        ),
      );
    });

    test('temporarily zeros and restores suppressed batch logits', () {
      final logits = malloc<Int8>(3);
      addTearDown(() => malloc.free(logits));
      logits[0] = 1;
      logits[1] = 0;
      logits[2] = 1;

      final seenLogits = <int>[];
      final result = LlamaCppService.debugWithSuppressedBatchLogitsForTesting(
        logits,
        3,
        true,
        () {
          seenLogits.addAll([logits[0], logits[1], logits[2]]);
          logits[1] = 7;
          return 'processed';
        },
      );

      expect(result, 'processed');
      expect(seenLogits, [0, 0, 0]);
      expect([logits[0], logits[1], logits[2]], [1, 0, 1]);
    });

    test('leaves batch logits untouched when suppression is disabled', () {
      final logits = malloc<Int8>(2);
      addTearDown(() => malloc.free(logits));
      logits[0] = 1;
      logits[1] = 0;

      final seenLogits = <int>[];
      LlamaCppService.debugWithSuppressedBatchLogitsForTesting(
        logits,
        2,
        false,
        () {
          seenLogits.addAll([logits[0], logits[1]]);
        },
      );

      expect(seenLogits, [1, 0]);
      expect([logits[0], logits[1]], [1, 0]);
    });

    test('rejects invalid ngram-cache paths', () {
      expect(
        () => service.debugResolveSpeculativeTypeNamesForTesting(
          const GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.ngramCache(
              ngramCacheStaticPath: ' ',
            ),
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('must be null or a non-empty path'),
          ),
        ),
      );

      final missingPath = path.join(tempDir.path, 'missing.ngram');
      expect(
        () => service.debugResolveSpeculativeTypeNamesForTesting(
          GenerationParams(
            speculativeDecodingConfig: SpeculativeDecodingConfig.ngramCache(
              ngramCacheStaticPath: missingPath,
            ),
          ),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (error) => error.message,
            'message',
            contains('must exist before enabling llama.cpp ngram-cache'),
          ),
        ),
      );
    });
  });

  test('maps presence penalty to the native penalty sampler', () {
    final service = LlamaCppService();

    expect(
      service.debugResolvePenaltySamplerParamsForTesting(
        const GenerationParams(penalty: 1.0, presencePenalty: 1.5),
      ),
      <String, Object>{
        'lastN': 64,
        'repeat': 1.0,
        'frequency': 0.0,
        'presence': 1.5,
      },
    );
  });

  group('thinking-budget validation', () {
    test(
      'rejects a token budget that exceeds the native signed 32-bit limit',
      () {
        final service = LlamaCppService();

        expect(
          () => service.debugValidateThinkingBudgetForTesting(
            const GenerationParams(
              thinkingBudget: ThinkingBudget(maxTokens: 2147483648),
            ),
          ),
          throwsA(
            isA<RangeError>().having(
              (error) => error.toString(),
              'message',
              contains('signed 32-bit'),
            ),
          ),
        );
      },
    );
  });

  group('startup diagnostics', () {
    test('an empty buffer leaves the message unchanged', () {
      expect(formatStartupDiagnostics(const <String>[]), isEmpty);
    });

    test('entries are joined into a labelled suffix', () {
      expect(
        formatStartupDiagnostics(const <String>['first failed', 'then this']),
        ', startupDiagnostics=[first failed; then this]',
      );
    });

    test('truncation keeps the root cause and final outcome', () {
      final entries = <String>[
        'root cause',
        'a' * 100,
        '${startupTeardownDiagnosticPrefix}noise',
        'final outcome',
      ];

      expect(
        formatStartupDiagnostics(entries, maxLength: 40),
        ', startupDiagnostics=[root cause; ...; final outcome]',
      );
      expect(
        formatStartupDiagnostics(entries, maxLength: 60),
        ', startupDiagnostics=['
        'root cause; ...; ${startupTeardownDiagnosticPrefix}noise; '
        'final outcome]',
      );
    });

    test('truncation is bounded for every content limit', () {
      final entries = <String>[
        '${startupTeardownDiagnosticPrefix}early noise',
        'root cause ${'a' * 40}',
        'middle probe',
        'final outcome',
        '${startupTeardownDiagnosticPrefix}late noise',
      ];
      final untruncated = entries.join('; ');

      for (var maxLength = 1; maxLength <= untruncated.length; maxLength++) {
        final formatted = formatStartupDiagnostics(
          entries,
          maxLength: maxLength,
        );
        final content = formatted.substring(
          ', startupDiagnostics=['.length,
          formatted.length - 1,
        );
        final reason = 'maxLength=$maxLength';
        expect(content.length, lessThanOrEqualTo(maxLength), reason: reason);
        if (maxLength == untruncated.length) {
          expect(content, untruncated);
        } else if (maxLength >= 7) {
          expect(content, contains('root'), reason: reason);
          expect(content, contains('...'), reason: reason);
        }
      }
    });

    test('an oversized entry keeps its head within half the limit', () {
      final formatted = formatStartupDiagnostics(<String>[
        'oldest:${'a' * 100}',
        'newest failure',
      ], maxLength: 40);

      expect(
        formatted,
        ', startupDiagnostics=[oldest:${'a' * 10}...; newest failure]',
      );
    });

    test('two oversized causal entries both keep their heads', () {
      final buffer = StartupDiagnosticBuffer()
        ..record('ROOT:${'r' * 5000}')
        ..record('noise', category: StartupDiagnosticCategory.teardown)
        ..record('FINAL:${'f' * 5000}');

      final formatted = formatStartupDiagnostics(buffer.entries);

      expect(formatted, startsWith(', startupDiagnostics=[ROOT:rrr'));
      expect(formatted, contains('rrr...; ...; FINAL:fff'));
      expect(formatted, endsWith('fff...]'));
      expect(formatted, hasLength(', startupDiagnostics=[]'.length + 4096));
    });

    test('cuts never split a surrogate pair', () {
      final buffer = StartupDiagnosticBuffer()
        ..record('${'a' * 2044}${'\u{1F600}' * 10}');

      expect(buffer.entries.single, '${'a' * 2044}...');
      expect(
        formatStartupDiagnostics(<String>[
          'a\u{1F600}${'b' * 20}',
          'c',
        ], maxLength: 10),
        ', startupDiagnostics=[a...; c]',
      );
    });

    group('buffer retention', () {
      test('drops repeats and keeps the first position', () {
        final buffer = StartupDiagnosticBuffer()
          ..record('first')
          ..record('second')
          ..record('first')
          ..record('')
          ..record('second', category: StartupDiagnosticCategory.teardown);

        expect(buffer.entries, <String>[
          'first',
          'second',
          '${startupTeardownDiagnosticPrefix}second',
        ]);
      });

      test('teardown overflow never evicts the discovery failure', () {
        final buffer = StartupDiagnosticBuffer();
        const discovery =
            'Failed to preload Windows backend dependency '
            r'`C:\app\cudart64_12.dll` for `cuda`: error code 126';
        buffer.record(discovery);
        for (var i = 0; i < 100; i++) {
          buffer.record(
            'Failed to release temporary Windows backend module preload for '
            '`C:\\app\\ggml-cuda-$i.dll` (`cuda`).',
            category: StartupDiagnosticCategory.teardown,
          );
        }
        const outcome = 'Backend asset `package:llamadart/cuda` failed';
        buffer.record(outcome);

        final entries = buffer.entries;
        expect(entries, hasLength(StartupDiagnosticBuffer.maxEntries));
        expect(entries.first, discovery);
        expect(entries.last, outcome);
        expect(entries[1], contains('ggml-cuda-70.dll'));
        expect(entries[entries.length - 2], contains('ggml-cuda-99.dll'));

        final formatted = formatStartupDiagnostics(entries, maxLength: 512);
        expect(formatted, contains(discovery));
        expect(formatted, contains(outcome));
        expect(
          formatted.length,
          lessThanOrEqualTo(', startupDiagnostics=[]'.length + 512),
        );
      });

      test('causal overflow evicts teardown, then the unpinned middle', () {
        final buffer = StartupDiagnosticBuffer();
        for (var i = 0; i < 4; i++) {
          buffer.record(
            'noise $i',
            category: StartupDiagnosticCategory.teardown,
          );
        }
        for (var i = 0; i < 40; i++) {
          buffer.record('probe $i');
        }
        buffer.record(
          'late noise',
          category: StartupDiagnosticCategory.teardown,
        );

        expect(buffer.entries, <String>[
          for (var i = 0; i < StartupDiagnosticBuffer.pinnedCausalEntries; i++)
            'probe $i',
          for (var i = 24; i < 40; i++) 'probe $i',
        ]);
      });

      test('a failed Windows module release records as teardown', () {
        final service = LlamaCppService();
        for (final error in <Object?>[null, 'error code 5']) {
          _invokePrivateForTesting<void>(
            service,
            '_recordWindowsBackendModuleReleaseFailure',
            <Object?>[r'C:\app\ggml-cuda.dll', 'cuda', error],
          );
        }

        expect(service.getStartupDiagnostics(), <String>[
          '${startupTeardownDiagnosticPrefix}Failed to release temporary '
              r'Windows backend module preload for `C:\app\ggml-cuda.dll` '
              '(`cuda`).',
          '${startupTeardownDiagnosticPrefix}Failed to release temporary '
              r'Windows backend module preload for `C:\app\ggml-cuda.dll` '
              '(`cuda`): error code 5',
        ]);
      });

      test('stores sanitized entries and bounds each one', () {
        final buffer = StartupDiagnosticBuffer()
          ..record(
            'failed at https://user:pass@example.com/lib.so'
            '?X-Amz-Signature=secret&access_token=bearer-secret#secret',
          )
          ..record('control\u0000split\nline')
          ..record(
            'https://user:pass@example.com/${'a' * 5000}?token=secret',
            category: StartupDiagnosticCategory.teardown,
          );

        final entries = buffer.entries;
        expect(entries[0], 'failed at https://example.com/lib.so');
        expect(entries[1], 'control split line');
        expect(entries[2], startsWith(startupTeardownDiagnosticPrefix));
        expect(entries[2], endsWith('...'));
        expect(entries[2], hasLength(StartupDiagnosticBuffer.maxEntryLength));
        for (final entry in entries) {
          expect(entry, isNot(contains('pass')));
          expect(entry, isNot(contains('secret')));
          expect(entry, isNot(contains('X-Amz')));
        }
        expect(
          formatStartupDiagnostics(entries),
          ', startupDiagnostics=[${entries.join('; ')}]',
        );
      });
    });

    test('a zero content limit omits the diagnostic suffix', () {
      expect(
        formatStartupDiagnostics(const <String>['failure'], maxLength: 0),
        isEmpty,
      );
    });

    test('diagnostics are single-line and redact credentialed URLs', () {
      expect(
        formatStartupDiagnostics(const <String>[
          'failed at HTTPS:\n//user\u0085:pass@example.com/lib.so'
              '?token=secret#part',
          'next\u0000line\u0085more\u2028last\u2029line',
        ]),
        ', startupDiagnostics=['
        '<redacted-startup-diagnostic>; next line more last line]',
      );
      expect(
        formatStartupDiagnostics(const <String>[
          'failed at https://user:pass@[2001:db8::1]/lib.so?token=secret',
        ]),
        ', startupDiagnostics=[failed at https://[2001:db8::1]/lib.so]',
      );
      expect(
        formatStartupDiagnostics(const <String>[
          'https://safe.example/a,HTTPS://user:pass@evil.example/b'
              '?token=secret',
        ]),
        ', startupDiagnostics=['
        'https://safe.example/a,https://evil.example/b]',
      );
      expect(
        formatStartupDiagnostics(const <String>['https://example.com\nfailed']),
        ', startupDiagnostics=[https://example.com failed]',
      );
      expect(
        formatStartupDiagnostics(const <String>[
          'https://example.com\nfailed@evil.example',
          'https://example.com/path?\ntoken=secret',
        ]),
        ', startupDiagnostics=['
        '<redacted-startup-diagnostic>; '
        '<redacted-startup-diagnostic>]',
      );
    });

    test('diagnostics redact bearer tokens outside URLs', () {
      expect(
        formatStartupDiagnostics(const <String>[
          'Authorization: Bearer eyJhbGciOi.secret rejected',
          'header BEARER abc-123',
          'bearer\ttok3n',
          'Bearer "x y" z',
          "Bearer 'x y' z",
          'Bearer',
        ]),
        ', startupDiagnostics=['
        'Authorization: Bearer <redacted-secret> rejected; '
        'header BEARER <redacted-secret>; '
        'bearer <redacted-secret>; '
        'Bearer <redacted-secret> z; '
        'Bearer <redacted-secret> z; '
        'Bearer]',
      );
      expect(
        formatStartupDiagnostics(const <String>['forbearer of news']),
        ', startupDiagnostics=[forbearer of news]',
      );
    });

    test('diagnostics redact key=value secrets outside URLs', () {
      expect(
        formatStartupDiagnostics(const <String>[
          'token=abc123 failed',
          'token=t key=k secret=s password=p api_key=a apikey=b',
          'KEY=k1,secret=s1;password=p1 api_key=a1 apikey=a2',
          'access_token=abc x-api-key=def client.secret=ghi',
          'Authorization=Bearer abc def',
          'token=Bearer abc def',
          '(token=paren)',
          'token=',
        ]),
        ', startupDiagnostics=['
        'token=<redacted-secret> failed; '
        'token=<redacted-secret> key=<redacted-secret> '
        'secret=<redacted-secret> password=<redacted-secret> '
        'api_key=<redacted-secret> apikey=<redacted-secret>; '
        'KEY=<redacted-secret> api_key=<redacted-secret> '
        'apikey=<redacted-secret>; '
        'access_token=<redacted-secret> x-api-key=<redacted-secret> '
        'client.secret=<redacted-secret>; '
        'Authorization=Bearer <redacted-secret> def; '
        'token=<redacted-secret> def; '
        '(token=<redacted-secret>; '
        'token=]',
      );
      expect(
        formatStartupDiagnostics(const <String>[
          'secret="s p a c e" tail',
          "secret='s p a c e' tail",
          'token="abc",secret="def"',
          'token=Bearer "a b" tail',
          'token="unterminated tail',
        ]),
        ', startupDiagnostics=['
        'secret=<redacted-secret> tail; '
        'secret=<redacted-secret> tail; '
        'token=<redacted-secret>,secret=<redacted-secret>; '
        'token=<redacted-secret> tail; '
        'token=<redacted-secret> tail]',
      );
    });

    test('diagnostics keep identifiers that only contain a secret keyword', () {
      const safe = <String>[
        'keyboard=us monkey=1 tokenizer=bpe passwordless=true secrets=0',
        'cacheKey=abc n_tokens=42 key: value token: 7 key = v',
        'https://example.com/key=in-path?x=1',
      ];
      expect(
        formatStartupDiagnostics(safe),
        ', startupDiagnostics=['
        'keyboard=us monkey=1 tokenizer=bpe passwordless=true secrets=0; '
        'cacheKey=abc n_tokens=42 key: value token: 7 key = v; '
        'https://example.com/key=in-path]',
      );
    });

    test('secret redaction leaves URL redaction unchanged', () {
      expect(
        formatStartupDiagnostics(const <String>[
          'token=https://user:pass@host/x?token=secret',
          'Bearer https://user:pass@host/y#f rest',
          'key=abchttps://user:pass@host/z key=def',
          'HTTPS://host/path,token=in-path',
          'https://user:pass@example.com/lib.so'
              '?X-Amz-Signature=secret&access_token=bearer-secret#secret',
          'token=https://[bad',
          'Bearer https://[bad rest',
          'http://[bad token=abc',
        ]),
        ', startupDiagnostics=['
        'token=https://host/x; '
        'Bearer https://host/y rest; '
        'key=<redacted-secret>https://host/z key=<redacted-secret>; '
        'https://host/path,token=in-path; '
        'https://example.com/lib.so; '
        'token=<redacted-url>; '
        'Bearer <redacted-url> rest; '
        '<redacted-url> token=<redacted-secret>]',
      );
      expect(
        formatStartupDiagnostics(const <String>[
          'token=abc https://example.com/path?\nkey=secret',
        ]),
        ', startupDiagnostics=[<redacted-startup-diagnostic>]',
      );
    });

    test('the buffer stores secret-redacted entries', () {
      final buffer = StartupDiagnosticBuffer()
        ..record('loader said Bearer abc')
        ..record(
          'loader said api_key=xyz',
          category: StartupDiagnosticCategory.teardown,
        );
      expect(buffer.entries, <String>[
        'loader said Bearer <redacted-secret>',
        '${startupTeardownDiagnosticPrefix}loader said api_key=<redacted-secret>',
      ]);
    });

    test('the model-load message carries the diagnostics', () {
      final message = describeModelLoadFailure(
        sizeBytes: 4700000000,
        backendDiagnostics: '{moduleDir=/x}',
        startupDiagnostics: const <String>['libggml.so failed to load'],
      );

      expect(
        message,
        'Failed to load model (size=4700000000 bytes, '
        'diagnostics={moduleDir=/x}), '
        'startupDiagnostics=[libggml.so failed to load]',
      );
    });

    test('the draft-model message carries the diagnostics', () {
      final message = describeDraftModelLoadFailure(
        label: 'speculative draft model',
        path: '/draft.gguf',
        sizeBytes: 120,
        backendDiagnostics: '{moduleDir=/x}',
        startupDiagnostics: const <String>['libggml.so failed to load'],
      );

      expect(
        message,
        'Failed to load speculative draft model (size=120 bytes, '
        'path=/draft.gguf, diagnostics={moduleDir=/x}), '
        'startupDiagnostics=[libggml.so failed to load]',
      );
    });

    test('both messages are unchanged when nothing was recorded', () {
      expect(
        describeModelLoadFailure(
          sizeBytes: 1,
          backendDiagnostics: '{}',
          startupDiagnostics: const <String>[],
        ),
        'Failed to load model (size=1 bytes, diagnostics={})',
      );
      expect(
        describeDraftModelLoadFailure(
          label: 'draft',
          path: '/d.gguf',
          sizeBytes: 1,
          backendDiagnostics: '{}',
          startupDiagnostics: const <String>[],
        ),
        'Failed to load draft (size=1 bytes, path=/d.gguf, diagnostics={})',
      );
    });

    test('a fresh service has nothing recorded', () {
      expect(LlamaCppService().getStartupDiagnostics(), isEmpty);
    });

    group('native null-return branches', () {
      late Directory tempDir;
      late String corruptGgufPath;

      setUp(() {
        tempDir = Directory.systemTemp.createTempSync(
          'llamadart-load-failure-',
        );
        corruptGgufPath = path.join(tempDir.path, 'corrupt.gguf');
        File(
          corruptGgufPath,
        ).writeAsBytesSync(const <int>[0x47, 0x47, 0x55, 0x46]);
      });

      tearDown(() {
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      test('main-model failure uses the service diagnostics buffer', () {
        final service = _warmedLoadFailureService(corruptGgufPath);
        _recordStartupDiagnosticForTesting(
          service,
          'failed at '
          'https://safe.example/a,'
          'HTTPS:\n//user\n:pass@example.com/libggml.so'
          '?token=secret#fragment',
        );
        _recordStartupDiagnosticForTesting(
          service,
          'next\u0000line\u0085more\u2028last\u2029line',
        );

        expect(
          () => service.loadModel(corruptGgufPath, const ModelParams()),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('Failed to load model (size=4 bytes,'),
                contains(
                  'startupDiagnostics=[<redacted-startup-diagnostic>; '
                  'next line more last line]',
                ),
                isNot(contains('user:pass')),
                isNot(contains('token=secret')),
                isNot(contains('\n')),
                isNot(contains('\u0000')),
              ),
            ),
          ),
        );
      });

      test('main-model failure omits the suffix for an empty buffer', () {
        final service = _warmedLoadFailureService(corruptGgufPath);

        expect(
          () => service.loadModel(corruptGgufPath, const ModelParams()),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              isNot(contains('startupDiagnostics=')),
            ),
          ),
        );
      });

      test('draft-model failure uses its label and bounded root cause', () {
        final service = _warmedLoadFailureService(corruptGgufPath);
        _recordStartupDiagnosticForTesting(service, 'oldest:${'a' * 5000}');
        for (var i = 0; i < 40; i++) {
          _recordStartupDiagnosticForTesting(
            service,
            'FreeLibrary failed for module $i ${'b' * 100}',
            category: StartupDiagnosticCategory.teardown,
          );
        }
        _recordStartupDiagnosticForTesting(service, 'newest failure');

        expect(
          () => _loadDraftModelForTesting(
            service,
            corruptGgufPath,
            'speculative draft model',
          ),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains(
                  'Failed to load speculative draft model '
                  '(size=4 bytes, path=$corruptGgufPath,',
                ),
                contains('startupDiagnostics=[oldest:aaa'),
                contains(
                  'aaa...; ${startupTeardownDiagnosticPrefix}FreeLibrary',
                ),
                endsWith('; ...; newest failure]'),
                predicate<String>((message) {
                  final marker = 'startupDiagnostics=[';
                  final start = message.indexOf(marker);
                  final content = message.substring(
                    start + marker.length,
                    message.length - 1,
                  );
                  return content.length <= 4096 && content.length > 3900;
                }, 'caps rendered diagnostic content at 4096 characters'),
              ),
            ),
          ),
        );
      });

      test('draft-model failure omits the suffix for an empty buffer', () {
        final service = _warmedLoadFailureService(corruptGgufPath);

        expect(
          () => _loadDraftModelForTesting(service, corruptGgufPath, 'draft'),
          throwsA(
            isA<Exception>().having(
              (error) => error.toString(),
              'message',
              allOf(
                contains('Failed to load draft (size=4 bytes,'),
                isNot(contains('startupDiagnostics=')),
              ),
            ),
          ),
        );
      });
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

    test(
      'generate reports unknown context before speculative decoding',
      () async {
        expect(
          service
              .generate(
                -1,
                'hello',
                const GenerationParams(speculativeDecoding: true),
                0,
              )
              .drain<void>(),
          throwsA(isA<Exception>()),
        );
      },
    );

    test(
      'generate reports unknown context before speculative config',
      () async {
        expect(
          service
              .generate(
                -1,
                'hello',
                const GenerationParams(
                  speculativeDecodingConfig: SpeculativeDecodingConfig.mtp(),
                ),
                0,
              )
              .drain<void>(),
          throwsA(isA<Exception>()),
        );
      },
    );

    test('embed and embedBatch throw for unknown context handle', () {
      expect(() => service.embed(-1, 'hello'), throwsA(isA<Exception>()));
      expect(
        () => service.embedBatch(-1, const <String>['hello']),
        throwsA(isA<Exception>()),
      );
    });

    test('state file methods throw for unknown context handle', () {
      expect(
        () => service.stateSaveFile(-1, '/tmp/state.bin', const <int>[]),
        throwsA(isA<LlamaStateException>()),
      );
      expect(
        () => service.stateLoadFile(-1, '/tmp/state.bin', 16),
        throwsA(isA<LlamaStateException>()),
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
    test('uses llama.cpp defaults when generative batch sizes are unset', () {
      const params = ModelParams(contextSize: 16384);

      final resolved = LlamaCppService.resolveContextBatchSizes(params, 16384);

      expect(resolved.batchSize, 2048);
      expect(resolved.microBatchSize, 512);
    });

    test('clamps automatic defaults to small contexts', () {
      const params = ModelParams(contextSize: 256);

      final resolved = LlamaCppService.resolveContextBatchSizes(params, 256);

      expect(resolved.batchSize, 256);
      expect(resolved.microBatchSize, 256);
    });

    test('preserves full-context defaults for encoder-only models', () {
      const params = ModelParams(contextSize: 4096);

      final resolved = LlamaCppService.resolveContextBatchSizes(
        params,
        4096,
        useFullContextDefaults: true,
      );

      expect(resolved.batchSize, 4096);
      expect(resolved.microBatchSize, 4096);
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

    test('clamps automatic micro-batch to a smaller explicit batch', () {
      const params = ModelParams(contextSize: 4096, batchSize: 384);

      final resolved = LlamaCppService.resolveContextBatchSizes(params, 4096);

      expect(resolved.batchSize, 384);
      expect(resolved.microBatchSize, 384);
    });

    test('caps an unset micro-batch at the llama.cpp default', () {
      const params = ModelParams(contextSize: 4096, batchSize: 1024);

      final resolved = LlamaCppService.resolveContextBatchSizes(params, 4096);

      expect(resolved.batchSize, 1024);
      expect(resolved.microBatchSize, 512);
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

  group('backend probe failure aggregation', () {
    test('groups candidates by reason and keeps no directory', () {
      final failures = BackendProbeFailures();
      expect(failures.isEmpty, isTrue);
      expect(failures.describe(), 'no candidates');

      failures
        ..add('/Users/secret/bundle/libggml-cpu.so', 'not found')
        ..add('package:llamadart/cpu', 'not found')
        ..add(
          'package:llamadart/ggml-cpu',
          '`ggml_backend_init` returned null',
        );

      expect(failures.isEmpty, isFalse);
      expect(
        failures.describe(),
        'not found (libggml-cpu.so, package:llamadart/cpu); '
        '`ggml_backend_init` returned null (package:llamadart/ggml-cpu)',
      );
    });

    test('deduplicates the same failure across directories', () {
      final failures = BackendProbeFailures()
        ..add('libggml-cpu.so', '`ggml_backend_load` returned null')
        ..add('/a/libggml-cpu.so', '`ggml_backend_load` returned null')
        ..add('/b/libggml-cpu.so', '`ggml_backend_load` returned null')
        ..add('/b/libggml-cpu.so', '`ggml_backend_load` returned null');

      expect(
        failures.describe(),
        '`ggml_backend_load` returned null (libggml-cpu.so)',
      );
    });

    test('classifies loader errors without quoting them', () {
      const candidate = '/Users/secret/bundle/libggml-vulkan.so';
      const cases = <String, String>{
        "Invalid argument(s): Failed to load dynamic library '$candidate': "
                'dlopen($candidate, 0x0001): tried: '
                "'$candidate' (no such file), '/Users/secret/x' (no such file)":
            'not found',
        "Failed to load dynamic library '$candidate': $candidate: cannot "
                'open shared object file: No such file or directory':
            'not found',
        "Failed to load dynamic library '$candidate': libvulkan.so.1: cannot "
                'open shared object file: No such file or directory':
            'dependency not loaded `libvulkan.so.1`',
        'The specified module could not be found. (error code: 126)':
            'not found',
        "Failed to load dynamic library '$candidate': $candidate: undefined "
                'symbol: ggml_backend_dev_get_props':
            'unresolved symbol `ggml_backend_dev_get_props`',
        'dlopen($candidate, 0x0001): symbol not found in flat namespace '
                "'_ggml_backend_load'":
            'unresolved symbol `ggml_backend_load`',
        'dlopen($candidate): Symbol not found: _ggml_backend_reg_count\n'
                '  Referenced from: $candidate':
            'unresolved symbol `ggml_backend_reg_count`',
        'The specified procedure could not be found. (error code: 127)':
            'unresolved symbol',
        'dlopen($candidate): Library not loaded: @rpath/libggml-base.dylib\n'
                '  Referenced from: $candidate\n  Reason: image not found':
            'dependency not loaded `libggml-base.dylib`',
        '$candidate: wrong ELF class: ELFCLASS32': 'incompatible binary',
        'dlopen($candidate): mach-o file, but is an incompatible architecture '
                '(have x86_64, need arm64)':
            'incompatible binary',
        '%1 is not a valid Win32 application. (error code: 193)':
            'incompatible binary',
        'dlopen failed: cannot locate symbol "ggml_backend_dev_get_props" '
                'referenced by "$candidate"...':
            'unresolved symbol `ggml_backend_dev_get_props`',
        'dlopen failed: library "libvulkan.so" not found: needed by '
                '$candidate in namespace classloader-namespace':
            'dependency not loaded `libvulkan.so`',
        'dlopen failed: library "libggml-vulkan.so" not found': 'not found',
        'dlopen failed: "$candidate" has unexpected e_machine: 62 '
                '(EM_X86_64)':
            'incompatible binary',
        'dlopen failed: "$candidate" has bad ELF magic: 0a0a0a0a':
            'incompatible binary',
        'dlopen failed: library "$candidate" ("$candidate") needed or '
                'dlopened by "/system/lib64/libnativeloader.so" is not '
                'accessible for the namespace "classloader-namespace"':
            'blocked by namespace',
        'Authorization: Bearer secret-token https://user:pass@example.com/'
                'lib.so?token=secret':
            'open failed',
      };

      cases.forEach((text, expected) {
        final reason = describeLibraryProbeError(
          ArgumentError(text),
          candidate,
        );
        expect(reason, expected, reason: text);
        expect(reason, isNot(contains('/Users/secret')), reason: text);
        expect(reason, isNot(contains('secret')), reason: text);
      });
    });

    test('summaries are sanitized by the startup diagnostic buffer', () {
      final failures = BackendProbeFailures()
        ..add('lib ggml\ncpu.so', 'not found')
        ..add(
          'https://user:pass@example.com/lib.so?token=secret',
          describeLibraryProbeError(
            ArgumentError(
              'Bearer secret https://user:pass@example.com/x?token=secret',
            ),
            'https://user:pass@example.com/lib.so?token=secret',
          ),
        );
      final buffer = StartupDiagnosticBuffer()
        ..record(
          'Backend module `cpu` not loaded from any candidate: '
          '${failures.describe()}.',
        );

      expect(buffer.entries, <String>[
        'Backend module `cpu` not loaded from any candidate: '
            'not found (lib ggml cpu.so); open failed (lib.so).',
      ]);
      expect(buffer.entries.single, isNot(contains('pass')));
      expect(buffer.entries.single, isNot(contains('Bearer')));
      expect(buffer.entries.single, isNot(contains('secret')));
    });

    test('candidate identity drops directories, queries and fragments', () {
      expect(
        probeCandidateIdentity('package:llamadart/cpu'),
        'package:llamadart/cpu',
      );
      expect(
        probeCandidateIdentity('/Users/secret/libggml-cpu.so?token=secret#f'),
        'libggml-cpu.so',
      );
      expect(
        probeCandidateIdentity('package:llamadart/cpu?token=secret'),
        'package:llamadart/cpu',
      );
    });

    test('an empty module directory names the expected module file', () {
      final tempDir = Directory.systemTemp.createTempSync('empty_module_dir_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      const backend = 'nonexistent-probe';
      final expectedFile = Platform.isWindows
          ? 'ggml-$backend.dll'
          : Platform.isMacOS
          ? 'libggml-$backend.dylib'
          : 'libggml-$backend.so';

      final service = LlamaCppService();
      _writePrivateForTesting(service, '_backendModuleDirectory', tempDir.path);
      final loaded = _invokePrivateForTesting<bool>(
        service,
        '_tryLoadBackendModule',
        <Object?>[backend],
      );

      expect(loaded, isFalse);
      final entry = service.getStartupDiagnostics().single;
      expect(
        entry,
        startsWith(
          'Backend module `$backend` not loaded from any candidate: '
          'file missing ($expectedFile); ',
        ),
      );
      expect(entry, contains('(package:llamadart/$backend'));
      expect(entry, isNot(contains(tempDir.path)));
    });

    test('a backend family with no usable candidate records one summary', () {
      final service = LlamaCppService();
      const backend = 'nonexistent-probe';

      final loaded = _invokePrivateForTesting<bool>(
        service,
        '_tryLoadBackendModule',
        <Object?>[backend],
      );

      expect(loaded, isFalse);
      final entries = service.getStartupDiagnostics();
      expect(entries, hasLength(1));
      final loaderUnavailable = _readPrivateForTesting<bool>(
        service,
        '_backendLoadSymbolUnavailable',
      );
      if (loaderUnavailable) {
        expect(
          entries.single,
          startsWith('`ggml_backend_load` is unavailable: the primary FFI '),
        );
      } else {
        expect(
          entries.single,
          startsWith(
            'Backend module `$backend` not loaded from any candidate: ',
          ),
        );
        expect(entries.single, contains('(package:llamadart/$backend'));
      }
      expect(
        entries.single,
        isNot(contains(path.dirname(Platform.resolvedExecutable))),
      );
      expect(entries.single, isNot(contains(Directory.current.path)));

      final retried = _invokePrivateForTesting<bool>(
        service,
        '_tryLoadBackendModule',
        <Object?>[backend],
      );
      expect(retried, isFalse);
      expect(service.getStartupDiagnostics(), entries);
    });

    test('ggml candidate failures are recorded only for a missing symbol', () {
      final service = LlamaCppService();
      _invokePrivateForTesting<void>(
        service,
        '_resolveGgmlFallbackFunctions',
        const <Object?>[],
      );
      expect(service.getStartupDiagnostics(), isEmpty);

      for (var i = 0; i < 2; i++) {
        _invokePrivateForTesting<void>(
          service,
          '_recordMissingGgmlSymbol',
          const <Object?>['`ggml_backend_load`'],
        );
      }

      final entries = service.getStartupDiagnostics();
      expect(entries, hasLength(1));
      expect(
        entries.single,
        startsWith(
          '`ggml_backend_load` is unavailable: the primary FFI asset does '
          'not export it and ',
        ),
      );
      expect(entries.single, contains('package:llamadart/ggml'));
      expect(entries.single, endsWith('.'));
      expect(
        entries.single,
        isNot(contains(path.dirname(Platform.resolvedExecutable))),
      );
      expect(entries.single, isNot(contains(Directory.current.path)));
    });

    test('a missing ggml symbol reports the candidates that opened', () {
      final service = LlamaCppService();
      _writePrivateForTesting(
        service,
        '_ggmlRuntimeProbeOutcome',
        'the opened ggml runtime candidates (libggml.so) do not export it; '
            'other candidates: not found (package:llamadart/ggml)',
      );
      _invokePrivateForTesting<void>(
        service,
        '_recordMissingGgmlSymbol',
        const <Object?>['`ggml_backend_load_all`'],
      );

      expect(service.getStartupDiagnostics(), <String>[
        '`ggml_backend_load_all` is unavailable: the primary FFI asset does '
            'not export it and the opened ggml runtime candidates (libggml.so) '
            'do not export it; other candidates: not found '
            '(package:llamadart/ggml).',
      ]);
    });

    test('a registry symbol missing everywhere flags the map only', () {
      final service = LlamaCppService();
      final value = _invokePrivateForTesting<Object?>(
        service,
        '_ggmlRegistryFallbackOr',
        <Object?>[-1, () => throw ArgumentError('primary'), () => null],
      );

      expect(value, -1);
      expect(
        _readPrivateForTesting<bool>(
          service,
          '_backendRegistrySymbolUnavailable',
        ),
        isTrue,
      );
      expect(service.getStartupDiagnostics(), isEmpty);
    });

    test('a ggml candidate that resolves the symbols records nothing', () {
      final source = _locateGgmlRuntimeLibraryForTesting();
      if (source == null) {
        markTestSkipped('no built library exports ggml_backend_load');
        return;
      }
      final tempDir = Directory.systemTemp.createTempSync('ggml_probe_');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final ggmlFileName = Platform.isWindows
          ? 'ggml.dll'
          : Platform.isMacOS
          ? 'libggml.dylib'
          : 'libggml.so';
      final String moduleDir;
      if (path.basename(source) == ggmlFileName) {
        moduleDir = path.dirname(source);
      } else {
        if (Platform.isWindows) {
          markTestSkipped('a mapped DLL copy cannot be deleted on teardown');
          return;
        }
        final copy = path.join(tempDir.path, ggmlFileName);
        File(source).copySync(copy);
        if (!_exportsGgmlBackendLoad(copy)) {
          markTestSkipped('a copy of $source does not load standalone');
          return;
        }
        moduleDir = tempDir.path;
      }

      final service = LlamaCppService();
      _writePrivateForTesting(service, '_backendModuleDirectory', moduleDir);
      _invokePrivateForTesting<void>(
        service,
        '_resolveGgmlFallbackFunctions',
        const <Object?>[],
      );

      expect(
        _readPrivateForTesting<Object?>(service, '_ggmlBackendLoadFallback'),
        isNotNull,
      );
      final regCount = _readPrivateForTesting<Function?>(
        service,
        '_ggmlBackendRegCountFallback',
      );
      expect(regCount, isNotNull);
      final value = _invokePrivateForTesting<Object?>(
        service,
        '_ggmlRegistryFallbackOr',
        <Object?>[
          -1,
          () => throw ArgumentError('primary'),
          () => Function.apply(regCount!, const <Object?>[]),
        ],
      );

      expect(
        value,
        isA<int>().having((count) => count, 'count', isNonNegative),
      );
      expect(
        _readPrivateForTesting<bool>(
          service,
          '_backendRegistrySymbolUnavailable',
        ),
        isFalse,
      );
      expect(service.getStartupDiagnostics(), isEmpty);
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

  group('shouldKeepAndroidVulkanKqvOffloadEnabled', () {
    test('keeps KQV offload enabled for Qwen3.5 architecture metadata', () {
      expect(
        LlamaCppService.shouldKeepAndroidVulkanKqvOffloadEnabled('qwen35'),
        isTrue,
      );
      expect(
        LlamaCppService.shouldKeepAndroidVulkanKqvOffloadEnabled('Qwen3.5'),
        isTrue,
      );
    });

    test('keeps conservative KQV policy for other architectures', () {
      expect(
        LlamaCppService.shouldKeepAndroidVulkanKqvOffloadEnabled('llama'),
        isFalse,
      );
      expect(
        LlamaCppService.shouldKeepAndroidVulkanKqvOffloadEnabled(null),
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

    test(
      'prefers standard CLI sibling lib over unrelated working directory',
      () {
        final lib = Directory(
          path.join(tempRoot.path, 'portable bundle', 'lib'),
        )..createSync(recursive: true);
        final cwd = Directory(path.join(tempRoot.path, 'unrelated'))
          ..createSync();
        _createWindowsBundleMarkerFiles(lib.path);
        _createWindowsBundleMarkerFiles(cwd.path);
        final resolved = LlamaCppService.resolveWindowsBackendModuleDirectory(
          resolvedExecutablePath: path.join(lib.parent.path, 'bin', 'app.exe'),
          currentDirectoryPath: cwd.path,
          environment: const {},
        );
        expect(path.normalize(resolved!), path.normalize(lib.path));
      },
    );

    test(
      'CLI layout preserves override and executable-adjacent precedence',
      () {
        final root = Directory(path.join(tempRoot.path, 'portable'))
          ..createSync();
        final bin = Directory(path.join(root.path, 'bin'))..createSync();
        final lib = Directory(path.join(root.path, 'lib'))..createSync();
        final override = Directory(path.join(tempRoot.path, 'override'))
          ..createSync();
        for (final dir in [bin, lib, override]) {
          _createWindowsBundleMarkerFiles(dir.path);
        }
        for (final useOverride in [false, true]) {
          final resolved = LlamaCppService.resolveWindowsBackendModuleDirectory(
            resolvedExecutablePath: path.join(bin.path, 'app.exe'),
            currentDirectoryPath: tempRoot.path,
            environment: useOverride
                ? {'LLAMADART_NATIVE_LIB_DIR': override.path}
                : const {},
          );
          expect(
            path.normalize(resolved!),
            path.normalize(useOverride ? override.path : bin.path),
          );
        }
      },
    );

    test(
      'incomplete CLI sibling lib preserves valid working directory fallback',
      () {
        final lib = Directory(path.join(tempRoot.path, 'portable', 'lib'))
          ..createSync(recursive: true);
        File(path.join(lib.path, 'llama.dll')).writeAsStringSync('fixture');
        final cwd = Directory(path.join(tempRoot.path, 'working'))
          ..createSync();
        _createWindowsBundleMarkerFiles(cwd.path);
        final resolved = LlamaCppService.resolveWindowsBackendModuleDirectory(
          resolvedExecutablePath: path.join(lib.parent.path, 'bin', 'app.exe'),
          currentDirectoryPath: cwd.path,
          environment: const {},
        );
        expect(path.normalize(resolved!), path.normalize(cwd.path));
      },
    );

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

    test('uses altered search path for absolute Windows backend modules', () {
      expect(
        LlamaCppService.windowsBackendModuleLoadFlags(
          path.join(tempRoot.path, 'ggml-cuda.dll'),
        ),
        0x00000008,
      );
      expect(
        LlamaCppService.windowsBackendModuleLoadFlags('ggml-cuda.dll'),
        isZero,
      );
    });

    test('orders CUDA redistributable DLLs for best-effort preloading', () {
      final dependencyPaths = LlamaCppService.windowsBackendDependencyPaths(
        tempRoot.path,
        'cuda',
        fileNames: const <String>[
          'ggml-cuda.dll',
          'cublasLt64_12.dll',
          'notes.txt',
          'cudart64_12.dll',
          'cublas64_12.dll',
        ],
      );

      expect(dependencyPaths, <String>[
        path.join(tempRoot.path, 'cudart64_12.dll'),
        path.join(tempRoot.path, 'cublas64_12.dll'),
        path.join(tempRoot.path, 'cublasLt64_12.dll'),
      ]);
      expect(
        LlamaCppService.windowsBackendDependencyPaths(
          tempRoot.path,
          'vulkan',
          fileNames: const <String>['cudart64_12.dll'],
        ),
        isEmpty,
      );
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

    test('finds custom GitHub hook cache namespace', () {
      final extractedDir = Directory(
        path.join(
          tempRoot.path,
          '.dart_tool',
          'llamadart',
          'native_bundles',
          'github',
          'example',
          'native-fork',
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

    test('finds local archive hook cache namespace', () {
      final extractedDir = Directory(
        path.join(
          tempRoot.path,
          '.dart_tool',
          'llamadart',
          'native_bundles',
          'local',
          '0123456789abcdef',
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

  test('Apple wrapper lookup includes embedded framework binary names', () {
    if (!Platform.isMacOS) {
      return;
    }

    final candidates = LlamaCppService()
        .debugLlamadartWrapperLibraryCandidatesForTesting();
    expect(
      candidates,
      contains(endsWith(path.join('llamadart.framework', 'llamadart'))),
    );
    expect(
      candidates,
      contains(endsWith(path.join('llama.framework', 'llama'))),
    );
  });
}

LlamaCppService _warmedLoadFailureService(String corruptGgufPath) {
  final service = LlamaCppService();
  try {
    service.loadModel(corruptGgufPath, const ModelParams());
  } on Exception {
    // The first controlled failure initializes platform backend discovery.
  }
  _startupDiagnosticsForTesting(service).clear();
  return service;
}

void _recordStartupDiagnosticForTesting(
  LlamaCppService service,
  String diagnostic, {
  StartupDiagnosticCategory category = StartupDiagnosticCategory.causal,
}) {
  _invokePrivateForTesting<void>(
    service,
    '_recordStartupDiagnostic',
    <Object?>[diagnostic],
    category == StartupDiagnosticCategory.causal
        ? const <Symbol, Object?>{}
        : <Symbol, Object?>{#category: category},
  );
}

void _loadDraftModelForTesting(
  LlamaCppService service,
  String path,
  String label,
) {
  _invokePrivateForTesting<Object?>(
    service,
    '_loadSpeculativeDraftModel',
    <Object?>[-1, path, label],
    <Symbol, Object?>{#loadMtp: false},
  );
}

StartupDiagnosticBuffer _startupDiagnosticsForTesting(LlamaCppService service) {
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  return reflect(
        service,
      ).getField(MirrorSystem.getSymbol('_startupDiagnostics', owner)).reflectee
      as StartupDiagnosticBuffer;
}

T _invokePrivateForTesting<T>(
  LlamaCppService service,
  String member,
  List<Object?> positionalArguments, [
  Map<Symbol, Object?> namedArguments = const <Symbol, Object?>{},
]) {
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  return reflect(service)
          .invoke(
            MirrorSystem.getSymbol(member, owner),
            positionalArguments,
            namedArguments,
          )
          .reflectee
      as T;
}

T _readPrivateForTesting<T>(LlamaCppService service, String field) {
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  return reflect(
        service,
      ).getField(MirrorSystem.getSymbol(field, owner)).reflectee
      as T;
}

void _writePrivateForTesting(
  LlamaCppService service,
  String field,
  Object? value,
) {
  final owner = reflectClass(LlamaCppService).owner as LibraryMirror;
  reflect(service).setField(MirrorSystem.getSymbol(field, owner), value);
}

bool _exportsGgmlBackendLoad(String libraryPath) {
  try {
    return DynamicLibrary.open(libraryPath).providesSymbol('ggml_backend_load');
  } catch (_) {
    return false;
  }
}

String? _locateGgmlRuntimeLibraryForTesting() {
  final pattern = RegExp(
    r'^(lib)?(ggml|ggml-base|llama|llamadart)\.(dylib|so|dll)$',
  );
  final roots = <Directory>[
    Directory(path.join(Directory.current.path, '.dart_tool', 'lib')),
    Directory(
      path.join(
        Directory.current.path,
        '.dart_tool',
        'llamadart',
        'native_bundles',
      ),
    ),
  ];
  for (final root in roots) {
    if (!root.existsSync()) {
      continue;
    }
    final files =
        root
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => pattern.hasMatch(path.basename(file.path)))
            .map((file) => file.path)
            .toList()
          ..sort();
    for (final file in files) {
      if (_exportsGgmlBackendLoad(file)) {
        return file;
      }
    }
  }
  return null;
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
