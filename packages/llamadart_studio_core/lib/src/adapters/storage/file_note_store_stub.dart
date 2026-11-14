import '../../ports/key_value_store.dart';
import '../../ports/note_store.dart';
import 'key_value_note_store.dart';

/// Web/Wasm fallback returning a [KeyValueNoteStore].
StudioNoteStore createPlatformNoteStore({
  required KeyValueStore fallbackKeyValueStore,
  String? directoryPath,
}) {
  return KeyValueNoteStore(fallbackKeyValueStore);
}
