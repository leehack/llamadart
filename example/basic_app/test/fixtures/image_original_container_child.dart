// ignore_for_file: implementation_imports
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_calls.dart';

import 'image_original_container_model.dart';

final class _DlInfo extends Struct {
  external Pointer<Utf8> filename;
  external Pointer<Void> base;
  external Pointer<Utf8> symbol;
  external Pointer<Void> address;
}

Future<void> main(List<String> args) async {
  if (!Platform.isMacOS || args.length != 5) {
    throw ArgumentError(
      'macOS: model taesd output.ppm expected-library-sha256 expected-library-path',
    );
  }
  final [model, taesd, output, libraryHash, libraryPath] = args;
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(libraryHash) ||
      File(output).existsSync()) {
    throw ArgumentError('exact library identity and fresh output required');
  }
  final clock = Stopwatch()..start();
  Future<void> stage(String name, [int loadMs = -1]) async {
    stdout.writeln(
      'SD24_STAGE ${jsonEncode({'schema': 1, 'stage': name, 'elapsedMs': clock.elapsedMilliseconds, 'loadMs': loadMs})}',
    );
    await stdout.flush();
  }

  await stage('load_begin');
  final load = Stopwatch()..start();
  await LlamaLogging.configure(
    level: LlamaLogLevel.info,
    handler: (record) => stderr.writeln('SD24_NATIVE_LOG ${record.message}'),
  );
  final dladdr = DynamicLibrary.process()
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<_DlInfo>),
        int Function(Pointer<Void>, Pointer<_DlInfo>)
      >('dladdr');
  final info = calloc<_DlInfo>();
  try {
    final symbol = StableDiffusionCalls.symbolAddress('sd_dart_new_sd_ctx');
    if (dladdr(symbol.cast(), info) == 0 || info.ref.filename == nullptr) {
      throw StateError('default native-asset binding could not be identified');
    }
    final path = info.ref.filename.toDartString();
    if (File(path).resolveSymbolicLinksSync() !=
        File(libraryPath).resolveSymbolicLinksSync()) {
      throw StateError('mapped runtime path differs');
    }
    final actual = (await sha256.bind(File(path).openRead()).first).toString();
    stdout.writeln(
      'SD24_BINDING ${jsonEncode({'schema': 1, 'route': 'public', 'mappedLibraryPath': path, 'mappedLibrarySha256': actual})}',
    );
    await stdout.flush();
    if (actual != libraryHash) {
      throw StateError('mapped runtime identity differs');
    }
  } finally {
    calloc.free(info);
  }

  final runtime = await ImageGenerationEngine.checkRuntime();
  if (!runtime.isSupported) {
    throw StateError('${runtime.unsupportedReason}');
  }
  final engine = await loadOriginalContainer(model, taesd);
  final loadMs = load.elapsedMilliseconds;
  await stage('load_end', loadMs);
  try {
    final capabilities = await engine.capabilities;
    if (capabilities.backendName != 'CPU' ||
        capabilities.modelVersion != 'SD 2.x' ||
        engine.roles.length != 2 ||
        !engine.roles.containsKey(ImageModelRole.checkpoint) ||
        !engine.roles.containsKey(ImageModelRole.taesd)) {
      throw StateError('unexpected public backend/family/component assignment');
    }
    stdout.writeln(
      'SD24_PUBLIC ${jsonEncode({'backend': capabilities.backendName, 'family': capabilities.modelVersion, 'runtimeVersion': capabilities.runtimeVersion})}',
    );
    await stage('generation_begin', loadMs);
    final result = await engine.generateImage(
      const ImageGenerationRequest(
        prompt: 'a red fox in a green forest, watercolor painting',
        width: 128,
        height: 128,
        steps: 1,
        guidanceScale: 1,
        seed: 42,
        sampler: ImageGenerationSampler.euler,
        scheduler: ImageGenerationScheduler.discrete,
      ),
    );
    await stage('generation_end', loadMs);
    final image = result.images.single;
    if ((image.width, image.height, image.channels) != (128, 128, 3)) {
      throw StateError('unexpected public output dimensions/channels');
    }
    File(output).writeAsBytesSync([
      ...ascii.encode('P6\n128 128\n255\n'),
      ...image.pixels,
    ], flush: true);
    await stage('pixels_written', loadMs);
  } finally {
    await engine.dispose();
    await stage('disposed', loadMs);
  }
  if (loadMs >= 45000) {
    throw StateError('load crossed original 45-second bound');
  }
}
