/// Formats caught runtime and exception objects into concise, user-facing Studio
/// error messages without raw Dart exception class prefixes.
String humanizeStudioError(Object error) {
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
  return raw;
}
