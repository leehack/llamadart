import 'dart:ffi';

/// Returns the names in [names] that the process cannot load.
///
/// Windows reports a missing import only as error 126, without naming it, so
/// native runtimes probe their known imports by name to say which one is
/// absent.
List<String> findMissingWindowsLibraries(List<String> names) => [
  for (final name in names)
    if (!_canLoadLibrary(name)) name,
];

/// Advice for a [library] whose Visual C++ runtime imports in [missing] could
/// not be loaded, for the redistributable built for [architecture] (`x64` or
/// `ARM64`).
String visualCppRuntimeAdvice({
  required String architecture,
  required List<String> missing,
  required String library,
}) =>
    'It requires the Microsoft Visual C++ 2015-2022 Redistributable '
    '($architecture), and ${missing.join(', ')} could not be loaded; install '
    'vc_redist.${architecture.toLowerCase()}.exe or ship those DLLs next to '
    '$library.';

/// Whether a `DynamicLibrary.open` failure [detail] is Windows error 126
/// (`ERROR_MOD_NOT_FOUND`), the library or one of its imports missing.
///
/// The Dart VM appends ` (error code: 126)` to the system message, or reports
/// only `error code 126` when Windows has no English message for it.
bool isWindowsModuleNotFoundError(String detail) =>
    _windowsModuleNotFound.hasMatch(detail);

final _windowsModuleNotFound = RegExp(r'error code:? 126\b');

bool _canLoadLibrary(String name) {
  try {
    DynamicLibrary.open(name);
    return true;
  } on ArgumentError {
    return false;
  }
}
