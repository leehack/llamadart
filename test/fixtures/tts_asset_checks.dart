import 'dart:ffi';
import 'dart:mirrors';

import 'package:llamadart/src/backends/llama_cpp/llama_cpp_service.dart';

void main(List<String> args) {
  final mode = args.first;
  final isWindows = mode == 'windows-wrapper';
  final service = LlamaCppService(isWindows: isWindows);
  final library = reflectClass(LlamaCppService).owner as LibraryMirror;
  final api = reflect(service).invoke(
    MirrorSystem.getSymbol('_resolveTtsApi', library),
    const [],
    {#candidates: const <String>[]},
  );
  final version = (api.getField(#apiVersion).reflectee as int Function())();
  if (version != 1) throw StateError('Unexpected TTS ABI $version');
  for (final field in [
    'apiVersion',
    'requestDefault',
    'getInfo',
    'init',
    'free',
    'start',
    'step',
    'cancel',
    'reset',
    'getOutputInfo',
    'readPcm',
    'lastError',
  ]) {
    if (api.getField(Symbol(field)).reflectee is! Function) {
      throw StateError('Unresolved required TTS binding $field');
    }
  }
  final free = api.getField(#freeAddress).reflectee as Pointer<NativeType>;
  if (free == nullptr) throw StateError('Unresolved TTS release address');
  final streams = api.getField(#startStreaming).reflectee != null;
  if (streams && args.length > 1) {
    final resolvedAddress =
        (library
                    .invoke(
                      MirrorSystem.getSymbol('_ttsAssetSymbol', library),
                      const ['llama_dart_tts_start_streaming'],
                      {#isWindows: isWindows},
                    )
                    .reflectee
                as Pointer<NativeType>)
            .address;
    final expectedAddress = DynamicLibrary.open(
      args[1],
    ).lookup<NativeType>('llama_dart_tts_start_streaming').address;
    if (resolvedAddress != expectedAddress) {
      throw StateError(
        'llama_dart_tts_start_streaming bound to $resolvedAddress, '
        'expected $expectedAddress',
      );
    }
  }
  print(
    'TTS_ASSET_DISCOVERY $mode ABI=$version required=12 '
    'streaming=$streams',
  );
}
