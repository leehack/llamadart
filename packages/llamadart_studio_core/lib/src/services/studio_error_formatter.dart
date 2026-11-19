/// Formats caught runtime and exception objects into concise, user-facing Studio
/// error messages without raw Dart exception class prefixes.
String humanizeStudioError(
  Object error, {
  Iterable<String> sensitiveValues = const <String>[],
}) {
  var raw = error.toString().trim();
  const prefixes = <String>[
    'LlamaUnsupportedException: ',
    'LlamaContextException: ',
    'LlamaInferenceException: ',
    'LlamaModelException: ',
    'LlamaArgumentException: ',
    'LlamaStateException: ',
    'LlamaException: ',
    'StateError: ',
    'Bad state: ',
    'ArgumentError: ',
    'Exception: ',
  ];
  var stripped = true;
  while (stripped) {
    stripped = false;
    for (final prefix in prefixes) {
      if (raw.startsWith(prefix)) {
        raw = raw.substring(prefix.length).trim();
        stripped = true;
      }
    }
  }
  for (final secret in sensitiveValues) {
    if (secret.isNotEmpty) raw = raw.replaceAll(secret, '[redacted]');
  }
  raw = raw.replaceAllMapped(RegExp(r'https?://[^\s<>]+'), (match) {
    final uri = Uri.tryParse(match[0]!);
    if (uri == null) return '[redacted URL]';
    return uri.replace(userInfo: '', query: '', fragment: '').toString();
  });
  raw = raw.replaceAll(
    RegExp(r'Bearer\s+[^\s,;]+', caseSensitive: false),
    'Bearer [redacted]',
  );
  if (raw.contains('Web runtime could not load the model') &&
      raw.contains('Aborted()')) {
    return 'Browser model loading stopped. Try a smaller model or reduce the '
        'context and batch sizes in Expert tuning, then reload.';
  }
  if (raw.contains('MediaEngine error')) {
    return 'Audio output device unavailable. Connect or check a playback device and try again.';
  }
  return raw;
}
