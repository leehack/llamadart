import '../../ports/coding_workspace_root_store.dart';
import '../../ports/key_value_store.dart';

/// Default [CodingWorkspaceRootStore] that stores the absolute root string
/// under `studio.coding.workspace_root.v1` in a [KeyValueStore].
class KeyValueCodingWorkspaceRootStore implements CodingWorkspaceRootStore {
  /// Creates a [KeyValueCodingWorkspaceRootStore].
  KeyValueCodingWorkspaceRootStore(this._kv);

  /// Key holding the absolute root string.
  static const String storageKey = 'studio.coding.workspace_root.v1';

  final KeyValueStore _kv;

  @override
  Future<String?> readRoot() => _kv.readString(storageKey);

  @override
  Future<void> writeRoot(String root) => _kv.writeString(storageKey, root);
}
