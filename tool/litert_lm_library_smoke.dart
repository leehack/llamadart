import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:llamadart/src/backends/litert_lm/litert_lm_runtime.dart'
    as runtime;

const _liteRtLmAssetId = 'package:llamadart/litert_lm_LiteRtLm';
const _litertLmLibDirEnv = 'LLAMADART_LITERT_LM_LIB_DIR';
const _requiredSymbols = <String>[
  'litert_lm_engine_settings_create',
  'litert_lm_engine_create',
  'litert_lm_engine_delete',
  'stream_proxy_create',
  'stream_proxy_free_string',
  'stream_proxy_delete',
];

void main() {
  if (!_isSupportedHost()) {
    stderr.writeln(
      'LiteRT-LM library smoke does not support ${Abi.current()}.',
    );
    exitCode = 64;
    return;
  }

  final opened = openLiteRtLmSmokeLibrary(
    directory: Platform.environment[_litertLmLibDirEnv],
    abi: Abi.current(),
  );
  final library = opened.library;
  for (final symbol in _requiredSymbols) {
    library.lookup<NativeFunction<Void Function()>>(symbol);
  }

  print(
    'RESULT litert_lm_library ${jsonEncode({'abi': Abi.current().toString(), 'library': opened.path, 'symbols': _requiredSymbols})}',
  );
}

bool _isSupportedHost() {
  final abi = Abi.current();
  return (Platform.isLinux && (abi == Abi.linuxX64 || abi == Abi.linuxArm64)) ||
      (Platform.isWindows && abi == Abi.windowsX64);
}

/// Opens the smoke runtime with the same dependency handling as production.
({String path, DynamicLibrary library, List<DynamicLibrary> companions})
openLiteRtLmSmokeLibrary({
  required String? directory,
  required Abi abi,
  DynamicLibrary Function(String)? openLibrary,
}) {
  final open = openLibrary ?? DynamicLibrary.open;
  final envDir = directory;
  if (envDir != null && envDir.isNotEmpty) {
    final primary = _primaryLibraryFileName(abi);
    if (primary == null) {
      throw UnsupportedError('LiteRT-LM does not support $abi.');
    }

    final companionPaths = [
      for (final library in runtime.liteRtLmCompanionLibrariesForAbi(abi))
        '$envDir/$library',
    ];
    // Production discovery can skip absent optional candidates; the smoke
    // must fail if any required inventory entry is missing.
    for (final library in runtime.liteRtLmRequiredLibrariesForAbi(abi)) {
      final file = '$envDir/$library';
      if (!File(file).existsSync()) {
        throw StateError('Required LiteRT-LM smoke library is missing: $file');
      }
    }
    final companions = runtime.liteRtLmOpenCompanionLibraries(
      companionPaths,
      openLibrary: open,
    );
    final path = '$envDir/$primary';
    return (path: path, library: open(path), companions: companions);
  }

  return (
    path: _liteRtLmAssetId,
    library: open(_liteRtLmAssetId),
    companions: const <DynamicLibrary>[],
  );
}

String? _primaryLibraryFileName(Abi abi) {
  return switch (abi) {
    Abi.linuxArm64 || Abi.linuxX64 => 'libLiteRtLm.so',
    Abi.windowsX64 => 'LiteRtLm.dll',
    _ => null,
  };
}
