/// Persistence port for the last successfully selected Coding workspace root.
///
/// Values crossing this port are filesystem roots. A host may persist them in
/// another form (for example, as an identity inside relocatable app storage)
/// as long as [readRoot] resolves that form against the current host.
abstract interface class CodingWorkspaceRootStore {
  /// Returns the saved root, or `null` when none was saved.
  ///
  /// Throws when a saved value exists but cannot be resolved; callers must not
  /// substitute another root in that case.
  Future<String?> readRoot();

  /// Saves [root] after it was successfully opened.
  Future<void> writeRoot(String root);
}
