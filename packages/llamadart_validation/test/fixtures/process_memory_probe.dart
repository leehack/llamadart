import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:llamadart_validation/src/process_memory.dart';

/// Prints resident set and footprint samples as JSON, in a process of its own
/// so no other test suite moves them.
///
/// `dirty <bytes>` samples before and after dirtying that many bytes of
/// `malloc` memory. `mapped <file>` maps the file read-only and samples before
/// reading every page, after, and after evicting the pages again. Each repeats
/// [_rounds] times, so the last round runs away from VM start-up.
void main(List<String> args) {
  Map<String, int> sample() => {
    'rss': ProcessInfo.currentRss,
    'footprint': memoryFootprintBytes()!,
  };
  final samples = switch (args) {
    ['dirty', final size] => _dirty(int.parse(size), sample),
    ['mapped', final path] => _mapped(path, sample),
    _ => throw ArgumentError('Usage: dirty <bytes> | mapped <file>'),
  };
  stdout.writeln(jsonEncode(samples));
}

const _rounds = 3;

Map<String, Object> _dirty(int size, Map<String, int> Function() sample) {
  final buffers = <Pointer<Uint8>>[];
  final rounds = <List<Map<String, int>>>[];
  for (var i = 0; i < _rounds; i++) {
    final before = sample();
    final memory = malloc<Uint8>(size);
    buffers.add(memory);
    memory.asTypedList(size).fillRange(0, size, 1);
    rounds.add([before, sample()]);
  }
  buffers.forEach(malloc.free);
  return {'rounds': rounds};
}

Map<String, Object> _mapped(String path, Map<String, int> Function() sample) {
  final libc = DynamicLibrary.process();
  final open = libc
      .lookupFunction<
        Int32 Function(Pointer<Utf8>, Int32),
        int Function(Pointer<Utf8>, int)
      >('open');
  final close = libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
    'close',
  );
  final mmap = libc
      .lookupFunction<
        Pointer<Uint8> Function(
          Pointer<Void>,
          Size,
          Int32,
          Int32,
          Int32,
          Int64,
        ),
        Pointer<Uint8> Function(Pointer<Void>, int, int, int, int, int)
      >('mmap');
  final evict = libc
      .lookupFunction<
        Int32 Function(Pointer<Uint8>, Size, Int32),
        int Function(Pointer<Uint8>, int, int)
      >(Platform.isMacOS ? 'msync' : 'madvise');
  const oReadOnly = 0, protRead = 1, mapShared = 1;
  const msInvalidate = 2, madvDontNeed = 4;
  final size = File(path).lengthSync();
  final nativePath = path.toNativeUtf8();
  final fd = open(nativePath, oReadOnly);
  malloc.free(nativePath);
  if (fd < 0) throw StateError('open failed');
  final pages = mmap(nullptr, size, protRead, mapShared, fd, 0);
  close(fd);
  if (pages.address == -1) throw StateError('mmap failed');
  final bytes = pages.asTypedList(size);
  var sum = 0;
  final rounds = <List<Map<String, int>>>[];
  for (var i = 0; i < _rounds; i++) {
    final before = sample();
    sum = 0;
    for (var offset = 0; offset < size; offset += 4096) {
      sum += bytes[offset];
    }
    final touched = sample();
    if (evict(pages, size, Platform.isMacOS ? msInvalidate : madvDontNeed) !=
        0) {
      throw StateError('eviction failed');
    }
    rounds.add([before, touched, sample()]);
  }
  return {'rounds': rounds, 'sum': sum};
}
