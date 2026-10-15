/// The Apple companion dependency `hook/build.dart` tells an app to declare.
library;

/// The first core `MAJOR.MINOR` whose Apple companions share it.
///
/// Companions paired with an earlier core are numbered `0.0.x`.
const appleCompanionLockstepStart = (major: 0, minor: 13);

final RegExp _coreVersionPattern = RegExp(
  r'^(\d+)\.(\d+)\.\d+(?:[-+][0-9A-Za-z.-]+)?$',
);

({int major, int minor})? _coreMinor(String? coreVersion) {
  final match = coreVersion == null
      ? null
      : _coreVersionPattern.firstMatch(coreVersion);
  if (match == null) return null;
  return (major: int.parse(match[1]!), minor: int.parse(match[2]!));
}

bool _isLockstep(({int major, int minor}) core) =>
    core.major > appleCompanionLockstepStart.major ||
    (core.major == appleCompanionLockstepStart.major &&
        core.minor >= appleCompanionLockstepStart.minor);

/// The pubspec constraint that resolves an Apple companion core
/// [coreVersion] pairs with, or `null` when there is none to name.
///
/// From [appleCompanionLockstepStart] on, that is the core's own minor:
/// `^0.MINOR.0`, or `'>=MAJOR.MINOR.0 <MAJOR.(MINOR+1).0'` once a caret
/// would admit later minors. An earlier core names `^`[firstPinningRelease],
/// the first `0.0.x` companion pinning its native tag, when it is known. A
/// missing [coreVersion], or one that is not a version, names nothing.
String? appleCompanionConstraint(
  String? coreVersion, {
  String? firstPinningRelease,
}) {
  final core = _coreMinor(coreVersion);
  if (core == null) return null;
  if (_isLockstep(core)) {
    return core.major == 0
        ? '^0.${core.minor}.0'
        : "'>=${core.major}.${core.minor}.0 "
              "<${core.major}.${core.minor + 1}.0'";
  }
  return firstPinningRelease == null ? null : '^$firstPinningRelease';
}

/// The sentence an incompatible Apple companion build error uses to tell the
/// app which [packageName] release to depend on, or `null` when
/// [appleCompanionConstraint] names none.
///
/// [nativePin] is the `repository@tag` the core requires; an earlier core's
/// sentence names it.
String? appleCompanionRequirement({
  required String packageName,
  required String? coreVersion,
  required String nativePin,
  String? firstPinningRelease,
}) {
  final constraint = appleCompanionConstraint(
    coreVersion,
    firstPinningRelease: firstPinningRelease,
  );
  if (constraint == null) return null;
  final core = _coreMinor(coreVersion)!;
  if (_isLockstep(core)) {
    return 'Depend on `$packageName: $constraint`, the releases paired with '
        'core ${core.major}.${core.minor}.x, in pubspec.yaml and rerun '
        'flutter pub get.';
  }
  return 'Depend on `$packageName: $constraint`, the first release pinning '
      '$nativePin, in pubspec.yaml and rerun flutter pub get; a caret '
      'constraint on an earlier 0.0.x release never resolves it.';
}
