import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

import 'passive_modules.dart' as windows;

final class DlInfo extends Struct {
  external Pointer<Utf8> filename;
  external Pointer<Void> imageBase;
  external Pointer<Utf8> symbolName;
  external Pointer<Void> symbolAddress;
}

@Native<Size Function()>(
  assetId: 'package:llamadart/ggml',
  symbol: 'ggml_backend_reg_count',
)
external int hookRegistryCount();

bool nativeName(String path) => RegExp(
  r'^(?:lib)?(?:llama(?:dart)?|ggml|mtmd)(?:[-_.].*)?\.(?:dll|dylib)$',
  caseSensitive: false,
).hasMatch(path.replaceAll(r'\', '/').split('/').last);

Map<String, Object?> owner(Pointer<Void> address) {
  if (address.address == 0) throw StateError('null symbol address');
  final process = DynamicLibrary.process();
  if (Platform.isWindows) {
    final lookup = process
        .lookupFunction<
          Int32 Function(Uint32, Pointer<Void>, Pointer<Pointer<Void>>),
          int Function(int, Pointer<Void>, Pointer<Pointer<Void>>)
        >('GetModuleHandleExW');
    final filename = process
        .lookupFunction<
          Uint32 Function(Pointer<Void>, Pointer<Utf16>, Uint32),
          int Function(Pointer<Void>, Pointer<Utf16>, int)
        >('GetModuleFileNameW');
    final handle = calloc<Pointer<Void>>();
    final name = calloc<Uint16>(32768).cast<Utf16>();
    try {
      if (lookup(6, address, handle) == 0)
        throw StateError('symbol owner absent');
      final length = filename(handle.value, name, 32768);
      if (length == 0 || length >= 32768) throw StateError('owner path absent');
      return {
        'address': address.address,
        'ownerBase': handle.value.address,
        'ownerPath': name.toDartString(length: length),
      };
    } finally {
      calloc.free(handle);
      calloc.free(name);
    }
  }
  final lookup = process
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<DlInfo>),
        int Function(Pointer<Void>, Pointer<DlInfo>)
      >('dladdr');
  final info = calloc<DlInfo>();
  try {
    if (lookup(address, info) == 0 || info.ref.filename == nullptr) {
      throw StateError('dladdr owner absent');
    }
    return {
      'address': address.address,
      'ownerBase': info.ref.imageBase.address,
      'ownerPath': File(info.ref.filename.toDartString()).absolute.path,
    };
  } finally {
    calloc.free(info);
  }
}

// Only mapped indirect pointer sections are read. Disk offsets and symbol
// indices are bounded first; the image slide comes from dyld for that image.
List<Map<String, Object?>> macImports(Uint8List bytes, int slide) {
  final data = ByteData.sublistView(bytes);
  void bounded(int offset, int count) {
    if (offset < 0 || count < 0 || offset + count > bytes.length) {
      throw StateError('Mach-O import table outside file');
    }
  }

  int u32(int offset) {
    bounded(offset, 4);
    return data.getUint32(offset, Endian.little);
  }

  int u64(int offset) {
    bounded(offset, 8);
    return data.getUint64(offset, Endian.little);
  }

  if (u32(0) != 0xfeedfacf || u32(4) != 0x0100000c || u32(12) != 6) {
    throw StateError('observer requires thin arm64 MH_DYLIB');
  }
  final end = 32 + u32(20);
  bounded(32, u32(20));
  var cursor = 32;
  int? symbols, symbolCount, strings, stringBytes, indirect, indirectCount;
  final slots = <(int, int, int)>[];
  for (var index = 0; index < u32(16); index++) {
    if (cursor + 8 > end) throw StateError('truncated load command');
    final command = u32(cursor), size = u32(cursor + 4);
    if (size < 8 || size % 8 != 0 || cursor + size > end) {
      throw StateError('invalid load command');
    }
    if (command == 2) {
      if (size != 24 || symbols != null)
        throw StateError('invalid symbol command');
      symbols = u32(cursor + 8);
      symbolCount = u32(cursor + 12);
      strings = u32(cursor + 16);
      stringBytes = u32(cursor + 20);
    } else if (command == 0xb) {
      if (size != 80 || indirect != null)
        throw StateError('invalid indirect command');
      indirect = u32(cursor + 56);
      indirectCount = u32(cursor + 60);
    } else if (command == 0x19) {
      if (size < 72 || size != 72 + u32(cursor + 64) * 80) {
        throw StateError('invalid section command');
      }
      final vm = u64(cursor + 24), vmBytes = u64(cursor + 32);
      for (var section = cursor + 72; section < cursor + size; section += 80) {
        final type = u32(section + 64) & 0xff;
        if (type != 6 && type != 7) continue;
        final address = u64(section + 32), length = u64(section + 40);
        if (address < vm ||
            address + length > vm + vmBytes ||
            length % 8 != 0) {
          throw StateError('invalid mapped pointer section');
        }
        slots.add((address + slide, length ~/ 8, u32(section + 68)));
      }
    }
    cursor += size;
  }
  if (cursor != end ||
      symbols == null ||
      symbolCount == null ||
      strings == null ||
      stringBytes == null ||
      indirect == null ||
      indirectCount == null) {
    throw StateError('incomplete indirect symbol map');
  }
  bounded(symbols, symbolCount * 16);
  bounded(strings, stringBytes);
  bounded(indirect, indirectCount * 4);
  final result = <Map<String, Object?>>[];
  for (final slot in slots) {
    if (slot.$3 + slot.$2 > indirectCount)
      throw StateError('indirect index overflow');
    for (var index = 0; index < slot.$2; index++) {
      final symbol = u32(indirect + 4 * (slot.$3 + index));
      if ((symbol & 0xc0000000) != 0) continue;
      if (symbol >= symbolCount) throw StateError('symbol index overflow');
      final string = u32(symbols + symbol * 16);
      if (string >= stringBytes) throw StateError('symbol name overflow');
      var stop = strings + string;
      while (stop < strings + stringBytes && bytes[stop] != 0) {
        stop++;
      }
      if (stop == strings + stringBytes)
        throw StateError('unterminated symbol');
      final name = utf8.decode(bytes.sublist(strings + string, stop));
      if (!const [
        '_ggml_backend_reg_count',
        '_llama_model_load_from_file',
        '_llama_dart_model_load_from_file',
      ].contains(name))
        continue;
      final address = Pointer<Pointer<Void>>.fromAddress(slot.$1 + index * 8)
          .value;
      result.add({'symbol': name.substring(1), ...owner(address)});
    }
  }
  return result;
}

Future<List<Map<String, Object?>>> macSnapshot(String checkpoint) async {
  final process = DynamicLibrary.process();
  final count = process.lookupFunction<Uint32 Function(), int Function()>(
    '_dyld_image_count',
  );
  final name = process
      .lookupFunction<
        Pointer<Utf8> Function(Uint32),
        Pointer<Utf8> Function(int)
      >('_dyld_get_image_name');
  final slide = process
      .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
        '_dyld_get_image_vmaddr_slide',
      );
  final images = <(String, int)>[];
  final length = count();
  for (var index = 0; index < length; index++) {
    final pointer = name(index);
    if (pointer == nullptr) throw StateError('incomplete dyld map');
    final path = File(pointer.toDartString()).absolute.path;
    if (nativeName(path)) images.add((path, slide(index)));
  }
  final observations = <Map<String, Object?>>[];
  for (final image in images) {
    final bytes = File(image.$1).readAsBytesSync();
    // Opening only a path in the already-recorded resident map cannot select
    // a missing runtime. Address ownership remains independently checked.
    final library = DynamicLibrary.open(image.$1);
    final exports = <Map<String, Object?>>[];
    for (final symbol in [
      'ggml_backend_reg_count',
      'llama_model_load_from_file',
      'llama_dart_model_load_from_file',
    ]) {
      if (library.providesSymbol(symbol)) {
        final actual = owner(library.lookup<Void>(symbol));
        if (actual['ownerPath'] == image.$1) {
          exports.add({'symbol': symbol, ...actual});
        }
      }
    }
    final row = <String, Object?>{
      'checkpoint': checkpoint,
      'modulePath': image.$1,
      'sha256': sha256.convert(bytes).toString(),
      'bytes': bytes.length,
      'exports': exports,
      'imports': macImports(bytes, image.$2),
    };
    observations.add(row);
    stdout.writeln('PASSIVE_MODULE ${jsonEncode(row)}');
  }
  await stdout.flush();
  return observations;
}

Future<Map<String, Object?>> observe() async {
  final before = Platform.isWindows
      ? await windows.snapshot('after-public-model-outcome')
      : await macSnapshot('after-public-model-outcome');
  final wrappers = before
      .where(
        (row) => RegExp(
          r'[/\\](?:lib)?llamadart(?:-windows-x64)?\.(?:dll|dylib)$',
          caseSensitive: false,
        ).hasMatch(row['modulePath']! as String),
      )
      .toList();
  if (wrappers.length != 1)
    throw StateError('unique resident wrapper required');
  final wrapper = wrappers.single;
  final library = DynamicLibrary.open(wrapper['modulePath']! as String);
  const nextn = 'llama_dart_speculative_need_embd_nextn';
  if (!library.providesSymbol(nextn)) throw StateError('retained nextn absent');
  final pointer = library.lookup<NativeFunction<Bool Function(Pointer<Void>)>>(
    nextn,
  );
  final nextnOwner = owner(pointer.cast());
  final query = <String, Object?>{
    'wrapperPath': wrapper['modulePath'],
    'wrapperSha256': wrapper['sha256'],
    'hasNextn': true,
    'hasLegacyQuery': library.providesSymbol(
      'llama_dart_speculative_need_embd',
    ),
    'nextnNullFalse': !pointer.asFunction<bool Function(Pointer<Void>)>()(
      nullptr,
    ),
    'nextnOwnerPath': nextnOwner['ownerPath'],
    'nextnOwnerSha256': sha256
        .convert(File(nextnOwner['ownerPath']! as String).readAsBytesSync())
        .toString(),
    'probeAfterPublicOutcome': true,
  };
  if (Platform.isWindows) {
    await windows.registryIdentity(before, 'success');
  } else {
    final address = Native.addressOf<NativeFunction<Size Function()>>(
      hookRegistryCount,
    );
    final providers = <Map<String, Object?>>[];
    final primary = <Map<String, Object?>>[];
    for (final row in before) {
      for (final exported in row['exports']! as List<Map<String, Object?>>) {
        if (exported['symbol'] == 'ggml_backend_reg_count')
          providers.add(exported);
      }
      if ((row['modulePath']! as String).endsWith('/libllama.dylib')) {
        primary.addAll(
          (row['imports']! as List<Map<String, Object?>>).where(
            (item) => item['symbol'] == 'ggml_backend_reg_count',
          ),
        );
      }
    }
    final matched = providers
        .where((row) => row['address'] == address.address)
        .toList();
    final bases = providers.map((row) => row['ownerBase']).toSet();
    stdout.writeln(
      'REGISTRY_IDENTITY ${jsonEncode({'observerAfterFirstPassiveSnapshot': true, 'codeAssetResolutionAndGetterPotentiallyLoadingOrInitializing': true, 'codeAssetId': 'package:llamadart/ggml', 'codeAssetAddress': address.address, 'codeAssetProvider': matched, 'primaryRegistryImports': primary, 'distinctRegistryProviderBasesBefore': bases.length, 'primaryMatchesCodeAsset': matched.length == 1 && primary.length == 1 && primary.single['address'] == address.address, 'noUnintendedDuplicateRegistry': bases.length == 1, 'registryCountAfterOutcome': hookRegistryCount()})}',
    );
    await macSnapshot('after-registry-observation');
  }
  return query;
}
