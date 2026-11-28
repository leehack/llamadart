import 'dart:ffi';

import 'package:ffi/ffi.dart';

const int _readOnly = 0;
const int _writeOnly = 1;
const int _seekSet = 0;
const int _seekCurrent = 1;

typedef _OpenNative = Int32 Function(Pointer<Utf8>, Int32, VarArgs<()>);
typedef _Open = int Function(Pointer<Utf8>, int);

final DynamicLibrary _libc = DynamicLibrary.process();
final _Open _open = _libc.lookupFunction<_OpenNative, _Open>('open');
final int Function(int) _close = _libc
    .lookupFunction<Int32 Function(Int32), int Function(int)>('close');
final int Function(int, int, int) _lseek = _libc
    .lookupFunction<
      Int64 Function(Int32, Int64, Int32),
      int Function(int, int, int)
    >('lseek');
final int Function(Pointer<Int32>) _pipe = _libc
    .lookupFunction<
      Int32 Function(Pointer<Int32>),
      int Function(Pointer<Int32>)
    >('pipe');

/// Opens [path] read-only and returns the descriptor, which the caller closes
/// with [closeDescriptor]. Descriptors exist on POSIX hosts only.
int openReadOnlyDescriptor(String path) => _openFlags(path, _readOnly);

/// Opens [path] write-only.
int openWriteOnlyDescriptor(String path) => _openFlags(path, _writeOnly);

int _openFlags(String path, int flags) {
  final native = path.toNativeUtf8();
  try {
    final fd = _open(native, flags);
    if (fd < 0) throw StateError('open failed for a test file');
    return fd;
  } finally {
    malloc.free(native);
  }
}

/// Closes [fd]; ignores a descriptor that is already closed.
void closeDescriptor(int fd) => _close(fd);

/// The current offset of [fd].
int descriptorOffset(int fd) => _lseek(fd, 0, _seekCurrent);

/// Moves [fd] to [offset] from the start of the file.
void seekDescriptor(int fd, int offset) => _lseek(fd, offset, _seekSet);

/// Opens a pipe and returns its `(read, write)` descriptors.
(int, int) openPipeDescriptors() {
  final ends = malloc<Int32>(2);
  try {
    if (_pipe(ends) != 0) throw StateError('pipe failed');
    return (ends[0], ends[1]);
  } finally {
    malloc.free(ends);
  }
}
