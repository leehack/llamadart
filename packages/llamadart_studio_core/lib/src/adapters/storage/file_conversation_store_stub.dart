import '../../ports/conversation_store.dart';
import '../../ports/key_value_store.dart';
import 'key_value_conversation_store.dart';

/// Web/Wasm fallback returning a [KeyValueConversationStore].
StudioConversationStore createPlatformConversationStore({
  required KeyValueStore fallbackKeyValueStore,
  String? directoryPath,
}) {
  return KeyValueConversationStore(fallbackKeyValueStore);
}
