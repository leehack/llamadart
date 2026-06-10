@TestOn('vm')
library;

import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:test/test.dart';
import 'package:llamadart/src/backends/llama_cpp/bindings.dart';

const _llamadartWrapperAssetId = 'package:llamadart/llamadart_wrapper';

const _mtpSymbols = [
  'llama_dart_mtp_init',
  'llama_dart_mtp_init_with_draft_model',
  'llama_dart_mtp_free',
  'llama_dart_mtp_get_draft_context',
  'llama_dart_mtp_begin',
  'llama_dart_mtp_process_batch',
  'llama_dart_mtp_draft',
  'llama_dart_mtp_accept',
  'llama_dart_sampler_sample_and_accept_n',
];

@ffi.Native<ffi.Void Function(ffi.Pointer<llama_dart_mtp>)>(
  assetId: _llamadartWrapperAssetId,
  symbol: 'llama_dart_mtp_free',
)
external void _windowsMtpFree(ffi.Pointer<llama_dart_mtp> mtp);

File _windowsMtpWrapperLibraryFile() {
  final dartToolLibPath = [
    Directory.current.path,
    '.dart_tool',
    'lib',
  ].join(Platform.pathSeparator);
  final dartToolLibDir = Directory(dartToolLibPath);
  final candidates = <String>[
    ?_nativeAssetFilePath(_llamadartWrapperAssetId),
    ..._matchingWindowsLibraryPaths(
      dartToolLibDir,
      RegExp(r'^llamadart(?:[-_][^.\\/]+)*\.dll$'),
    ),
    [dartToolLibPath, 'llamadart_wrapper.dll'].join(Platform.pathSeparator),
    [dartToolLibPath, 'llamadart.dll'].join(Platform.pathSeparator),
    'llamadart_wrapper.dll',
    'llamadart.dll',
  ];

  final tried = <String>{};
  for (final candidate in candidates) {
    if (!tried.add(candidate)) {
      continue;
    }

    final file = File(candidate);
    if (file.existsSync()) {
      return file;
    }
  }

  throw StateError(
    'Unable to find Windows llama.cpp MTP wrapper library. '
    'Tried: ${tried.join(', ')}.',
  );
}

bool _fileContainsAscii(File file, String text) {
  final bytes = file.readAsBytesSync();
  final pattern = ascii.encode(text);
  if (pattern.isEmpty || bytes.length < pattern.length) {
    return false;
  }

  for (var i = 0; i <= bytes.length - pattern.length; i++) {
    var matched = true;
    for (var j = 0; j < pattern.length; j++) {
      if (bytes[i + j] != pattern[j]) {
        matched = false;
        break;
      }
    }
    if (matched) {
      return true;
    }
  }
  return false;
}

String? _nativeAssetFilePath(String assetId) {
  final configFile = File('.dart_tool/native_assets.yaml');
  if (!configFile.existsSync()) {
    return null;
  }

  final source = configFile
      .readAsLinesSync()
      .where((line) => !line.trimLeft().startsWith('#'))
      .join('\n');
  final Object? decoded;
  try {
    decoded = jsonDecode(source);
  } on FormatException {
    return null;
  }
  if (decoded is! Map<String, Object?>) {
    return null;
  }

  final nativeAssets = decoded['native-assets'];
  if (nativeAssets is! Map) {
    return null;
  }

  for (final platformAssets in nativeAssets.values) {
    if (platformAssets is! Map) {
      continue;
    }
    final entry = platformAssets[assetId];
    if (entry is List && entry.length >= 2 && entry[0] == 'absolute') {
      final filePath = entry[1];
      if (filePath is String && filePath.isNotEmpty) {
        return filePath;
      }
    }
  }

  return null;
}

List<String> _matchingWindowsLibraryPaths(Directory directory, RegExp regex) {
  try {
    return directory
        .listSync()
        .whereType<File>()
        .map((file) => file.path)
        .where((filePath) {
          final separatorIndex = filePath.lastIndexOf(Platform.pathSeparator);
          final name = separatorIndex == -1
              ? filePath
              : filePath.substring(separatorIndex + 1);
          return regex.hasMatch(name);
        })
        .toList(growable: false);
  } catch (_) {
    return const <String>[];
  }
}

void main() {
  group('Native Symbol Availability', () {
    test('Verify MTP symbols are declared in generated bindings', () {
      final bindingsSource = File(
        'lib/src/backends/llama_cpp/bindings.dart',
      ).readAsStringSync();

      for (final symbol in _mtpSymbols) {
        expect(
          bindingsSource,
          matches(RegExp(r'external\s+[\s\S]*?\b' + RegExp.escape(symbol))),
          reason: symbol,
        );
      }
    });

    test('Verify MTP wrapper symbols are resolvable', () {
      if (Platform.isWindows) {
        expect(() => llama_context_default_params(), returnsNormally);
        expect(
          () => _windowsMtpFree(ffi.nullptr.cast<llama_dart_mtp>()),
          returnsNormally,
        );
        final wrapper = _windowsMtpWrapperLibraryFile();
        for (final symbol in _mtpSymbols) {
          expect(_fileContainsAscii(wrapper, symbol), isTrue, reason: symbol);
        }
        return;
      }

      final nullMtp = ffi.nullptr.cast<llama_dart_mtp>();
      final nullModel = ffi.nullptr.cast<llama_model>();
      final nullContext = ffi.nullptr.cast<llama_context>();
      final nullSampler = ffi.nullptr.cast<llama_sampler>();
      final nullTokenArray = ffi.nullptr.cast<ffi.Int32>();
      final ctxParams = llama_context_default_params();

      expect(
        llama_dart_mtp_init(
          nullModel,
          nullContext,
          ctxParams,
          1,
          0,
          0.0,
          true,
        ).address,
        0,
      );
      expect(
        llama_dart_mtp_init_with_draft_model(
          nullModel,
          nullContext,
          ctxParams,
          1,
          0,
          0.0,
          true,
        ).address,
        0,
      );
      expect(() => llama_dart_mtp_free(nullMtp), returnsNormally);
      expect(llama_dart_mtp_get_draft_context(nullMtp).address, 0);
      expect(llama_dart_mtp_begin(nullMtp, 0, nullTokenArray, 0), isFalse);
      expect(
        llama_dart_mtp_draft(
          nullMtp,
          0,
          0,
          0,
          nullTokenArray,
          0,
          1,
          nullTokenArray,
          0,
        ),
        -1,
      );
      expect(() => llama_dart_mtp_accept(nullMtp, 0, 0), returnsNormally);
      expect(
        llama_dart_sampler_sample_and_accept_n(
          nullSampler,
          nullContext,
          nullTokenArray,
          0,
          nullTokenArray,
          0,
          nullTokenArray,
          0,
        ),
        -1,
      );

      final batch = llama_batch_init(1, 0, 1);
      try {
        expect(llama_dart_mtp_process_batch(nullMtp, batch), isFalse);
      } finally {
        llama_batch_free(batch);
      }
    });

    test('Verify multimodal symbols are resolvable', () {
      // Some bundles export mtmd via the primary llama asset while others ship
      // it as a dedicated mtmd shared library loaded via runtime fallback.
      // So direct primary-asset lookup may legitimately fail.
      if (Platform.isWindows || Platform.isLinux || Platform.isAndroid) {
        expect(
          () => mtmd_context_params_default(),
          anyOf(returnsNormally, throwsA(isA<ArgumentError>())),
        );
        return;
      }

      expect(() => mtmd_context_params_default(), returnsNormally);
    });

    test('Verify core llama symbols are resolvable', () {
      expect(() => llama_backend_init(), returnsNormally);
      expect(() => llama_time_us(), returnsNormally);
      expect(() => llama_max_devices(), returnsNormally);
      expect(() => llama_supports_mmap(), returnsNormally);
      expect(() => llama_supports_mlock(), returnsNormally);
      expect(() => llama_supports_gpu_offload(), returnsNormally);
      expect(() => llama_supports_rpc(), returnsNormally);
      expect(() => llama_model_default_params(), returnsNormally);
      expect(() => llama_context_default_params(), returnsNormally);
      expect(() => llama_sampler_chain_default_params(), returnsNormally);
      expect(() => llama_model_quantize_default_params(), returnsNormally);
      expect(
        () => llama_numa_init(ggml_numa_strategy.GGML_NUMA_STRATEGY_DISABLED),
        returnsNormally,
      );
    });
  });
}
