import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Opens the Windows directory [directoryPath] the way a virus scanner or
/// indexer does, sharing delete access, and returns a function that closes
/// the handle.
///
/// While it is open, deleting the directory succeeds but leaves it pending
/// delete, still listed under its parent, until the handle closes.
void Function() openSharedWindowsDirectoryHandle(String directoryPath) {
  final kernel32 = DynamicLibrary.open('kernel32.dll');
  final createFile = kernel32
      .lookupFunction<
        IntPtr Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          IntPtr,
        ),
        int Function(Pointer<Utf16>, int, int, Pointer<Void>, int, int, int)
      >('CreateFileW');
  final closeHandle = kernel32
      .lookupFunction<Int32 Function(IntPtr), int Function(int)>('CloseHandle');
  const fileReadAttributes = 0x80;
  const shareReadWriteDelete = 0x7;
  const openExisting = 3;
  const fileFlagBackupSemantics = 0x02000000;
  const invalidHandleValue = -1;

  final pathPointer = directoryPath.toNativeUtf16();
  final int handle;
  try {
    handle = createFile(
      pathPointer,
      fileReadAttributes,
      shareReadWriteDelete,
      nullptr,
      openExisting,
      fileFlagBackupSemantics,
      0,
    );
  } finally {
    calloc.free(pathPointer);
  }
  if (handle == invalidHandleValue) {
    throw StateError('CreateFileW failed to open $directoryPath');
  }
  var closed = false;
  return () {
    if (!closed) {
      closed = true;
      closeHandle(handle);
    }
  };
}
