import '../../ports/key_value_store.dart';
import '../../ports/note_store.dart';
import 'file_note_store_stub.dart'
    if (dart.library.io) 'file_note_store_io.dart'
    as impl;

/// Creates a durable file-backed [StudioNoteStore] at [directoryPath] on native
/// `dart:io` platforms (storing note JSON atomically and binary media off-heap
/// under `note_media/<id>/`), or falls back to [KeyValueNoteStore] when
/// [directoryPath] is `null` or running on Web/Wasm.
StudioNoteStore createDefaultNoteStore({
  required KeyValueStore fallbackKeyValueStore,
  String? directoryPath,
}) {
  return impl.createPlatformNoteStore(
    fallbackKeyValueStore: fallbackKeyValueStore,
    directoryPath: directoryPath,
  );
}
