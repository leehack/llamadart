@TestOn('vm')
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_bindings.dart'
    as sd;
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_calls.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_runtime_io.dart';
import 'package:llamadart/src/hook/native_release_pins.dart';

// The exports image generation depends on.
const _symbols = [
  'sd_dart_progress_enable',
  'sd_dart_progress_read',
  'sd_dart_new_sd_ctx',
  'sd_dart_generate_image',
  'sd_dart_cancel_generation',
  'sd_dart_exit_free',
];

// The root package does not bundle the stable_diffusion runtime, so these
// tests resolve the functions from stand-ins. That each name resolves to the
// runtime's own export is checked against the real runtime by
// example/basic_app/test/image_exit_teardown_e2e_test.dart.
void main() {
  test('binds every sd_dart_ function through the lookup, and resolves '
      'nothing when one is missing', () {
    final requested = <String>[];
    Pointer<NativeType> exported(String name) {
      requested.add(name);
      return Pointer.fromAddress(0x1000 + requested.length);
    }

    expect(StableDiffusionCalls.tryResolve(symbol: exported), isNotNull);
    expect(requested, unorderedEquals(_symbols));
    expect(StableDiffusionCalls.wrapperSymbols, unorderedEquals(_symbols));

    for (final missing in _symbols) {
      expect(
        StableDiffusionCalls.tryResolve(
          symbol: (name) => name == missing
              ? throw ArgumentError("Couldn't resolve native function '$name'")
              : exported(name),
        ),
        isNull,
        reason: missing,
      );
    }
  });

  test('calls the function exported under the name of each of its '
      'members', () {
    final exports = _RecordingExports();
    addTearDown(exports.close);
    final calls = StableDiffusionCalls.tryResolve(symbol: exports.symbol)!;

    final members = <String, void Function()>{
      'sd_dart_progress_enable': calls.progressEnable,
      'sd_dart_new_sd_ctx': () => calls.newContext(nullptr),
      'sd_dart_generate_image': () =>
          calls.generateImage(nullptr, nullptr, nullptr, nullptr),
      'sd_dart_cancel_generation': () => calls.cancelGeneration(nullptr),
      'sd_dart_exit_free': () => calls.exitFree(nullptr),
    };
    for (final MapEntry(key: name, value: call) in members.entries) {
      exports.called.clear();
      call();
      expect(exports.called, [name]);
    }
    expect(exports.cancelMode, sd.sd_cancel_mode_t.SD_CANCEL_ALL.value);
    expect(calls.exitFreeAddress, exports.symbol('sd_dart_exit_free'));

    // sd_dart_progress_read is a leaf call, which cannot call back into
    // Dart, so memcpy stands in for it: called as
    // (destination, source, length, ignored) it copies and returns its
    // destination.
    using((arena) {
      final source = arena<Uint8>(4)..asTypedList(4).setAll(0, [9, 8, 7, 6]);
      final destination = arena<Uint8>(4);
      expect(
        calls.progressRead(destination.address, source.cast(), 4, nullptr),
        destination.address,
      );
      expect(destination.asTypedList(4), [9, 8, 7, 6]);
    });
  });

  test(
    'resolves nothing from a process without the runtime',
    () {
      expect(StableDiffusionCalls.tryResolve(), isNull);
    },
    skip: probeStableDiffusionRuntime().isAvailable
        ? 'the stable_diffusion runtime is bundled here'
        : false,
  );

  test('the unsupported error names the functions, the release that has them '
      'and the pinned release', () {
    final message = stableDiffusionWrapperUnsupported().message;

    for (final symbol in _symbols) {
      expect(message, contains(symbol));
    }
    expect(message, contains('stable-diffusion-native v0.2.0-1 or later'));
    expect(message, contains('pinned release $stableDiffusionReleaseTag'));
  });

  group('generated bindings', () {
    final bindings = File(
      'lib/src/backends/stable_diffusion/stable_diffusion_bindings.dart',
    ).readAsStringSync();

    test('leave out the functions that are not safe from an isolate', () {
      for (final name in const [
        'sd_dart_exit_teardown',
        'sd_dart_exit_call_begin',
        'sd_dart_exit_call_end',
        'sd_dart_exit_track',
        'sd_dart_exit_untrack',
      ]) {
        expect(bindings, isNot(contains(RegExp('$name\\b'))), reason: name);
      }
    });

    test('bind only sd_dart_progress_read as a leaf call', () {
      final leaves = RegExp(
        r'isLeaf: true\)\s*external \w[\w<>.]* (\w+)\(',
      ).allMatches(bindings).map((match) => match.group(1));

      expect(leaves, ['sd_dart_progress_read']);
      expect('isLeaf'.allMatches(bindings), hasLength(1));
    });
  });
}

/// A stand-in export for each `sd_dart_` function, which records its name
/// when called.
final class _RecordingExports {
  final List<String> called = <String>[];
  int? cancelMode;

  late final Map<String, NativeCallable<Function>> _functions = {
    'sd_dart_progress_enable': NativeCallable<Void Function()>.isolateLocal(
      () => _record('sd_dart_progress_enable', null),
    ),
    'sd_dart_new_sd_ctx':
        NativeCallable<
          Pointer<sd.sd_ctx_t> Function(Pointer<sd.sd_ctx_params_t>)
        >.isolateLocal(
          (Pointer<sd.sd_ctx_params_t> _) =>
              _record('sd_dart_new_sd_ctx', nullptr.cast<sd.sd_ctx_t>()),
        ),
    'sd_dart_generate_image':
        NativeCallable<
          Bool Function(
            Pointer<sd.sd_ctx_t>,
            Pointer<sd.sd_img_gen_params_t>,
            Pointer<Pointer<sd.sd_image_t>>,
            Pointer<Int>,
          )
        >.isolateLocal(
          (
            Pointer<sd.sd_ctx_t> _,
            Pointer<sd.sd_img_gen_params_t> _,
            Pointer<Pointer<sd.sd_image_t>> _,
            Pointer<Int> _,
          ) => _record('sd_dart_generate_image', false),
          exceptionalReturn: false,
        ),
    'sd_dart_cancel_generation':
        NativeCallable<
          Void Function(Pointer<sd.sd_ctx_t>, UnsignedInt)
        >.isolateLocal((Pointer<sd.sd_ctx_t> _, int mode) {
          cancelMode = mode;
          _record('sd_dart_cancel_generation', null);
        }),
    'sd_dart_exit_free':
        NativeCallable<Void Function(Pointer<Void>)>.isolateLocal(
          (Pointer<Void> _) => _record('sd_dart_exit_free', null),
        ),
  };

  T _record<T>(String name, T result) {
    called.add(name);
    return result;
  }

  Pointer<NativeType> symbol(String name) => name == 'sd_dart_progress_read'
      ? _memcpy
      : _functions[name]!.nativeFunction;

  void close() {
    for (final function in _functions.values) {
      function.close();
    }
  }
}

final Pointer<NativeType> _memcpy =
    (Platform.isWindows
            ? DynamicLibrary.open('msvcrt.dll')
            : DynamicLibrary.process())
        .lookup('memcpy');
