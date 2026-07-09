/// Returns whether [value] contains URL parts that should not be persisted as
/// browser cache keys.
///
/// The browser model cache stores request URLs in CacheStorage. Plain catalog
/// flags such as Hugging Face's `?download=true` are safe to persist, but
/// user info, fragments, and credential-like query keys can leak signed or
/// session-specific material into durable browser storage.
bool hasPersistentCacheSensitiveUrlParts(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return false;
  }
  if (uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
    return true;
  }

  const benignQueryKeys = {'download'};
  return uri.queryParameters.keys.any((key) {
    final lower = key.toLowerCase();
    if (benignQueryKeys.contains(lower)) {
      return false;
    }
    return lower.contains('token') ||
        lower.contains('sig') ||
        lower.contains('signature') ||
        lower.contains('expires') ||
        lower.contains('credential') ||
        lower.contains('key') ||
        lower.contains('secret') ||
        lower.contains('auth') ||
        lower.contains('session') ||
        lower.startsWith('x-amz');
  });
}
