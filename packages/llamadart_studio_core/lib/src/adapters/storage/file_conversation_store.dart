import '../../ports/conversation_store.dart';
import '../../ports/key_value_store.dart';
import 'file_conversation_store_stub.dart'
    if (dart.library.io) 'file_conversation_store_io.dart'
    as impl;

/// Creates a durable file-backed [StudioConversationStore] at [directoryPath]
/// on native `dart:io` platforms, or falls back to [KeyValueConversationStore]
/// when `directoryPath` is `null` or running on Web/Wasm.
StudioConversationStore createDefaultConversationStore({
  required KeyValueStore fallbackKeyValueStore,
  String? directoryPath,
}) {
  return impl.createPlatformConversationStore(
    fallbackKeyValueStore: fallbackKeyValueStore,
    directoryPath: directoryPath,
  );
}
