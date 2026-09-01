/// Pure classification and parsing of `llamadart-native` release tags.
library;

/// The specific grammatical form of a native release tag.
enum NativeTagForm {
  /// Unsuffixed semantic version: `vMAJOR.MINOR.PATCH`.
  stable,

  /// Semantic version with integer wrapper rebuild counter: `vMAJOR.MINOR.PATCH-N`.
  stableWrapper,

  /// Historical/nightly decimal build tag: `bNNNN`.
  nightly,

  /// Nightly decimal build tag with integer wrapper rebuild counter: `bNNNN-N`.
  nightlyWrapper,

  /// Historical consumption-only legacy wrapper artifact: `bNNNN-llamadart.N`.
  legacyWrapper,
}

/// A parsed and classified `llamadart-native` release tag.
class NativeReleaseTag {
  /// The raw tag string verbatim.
  final String rawTag;

  /// The release channel: `'stable'` or `'nightly'`.
  final String channel;

  /// The version numbers: `[major, minor, patch]` for stable, `[build]` for nightly.
  final List<int> version;

  /// The wrapper rebuild counter: `0` for unsuffixed tags, `N >= 1` for rebuilds.
  final int wrapperRevision;

  /// The canonical upstream llama.cpp tag prefix: `vMAJOR.MINOR.PATCH` or `bNNNN`.
  final String upstreamTag;

  /// The specific grammatical form of this tag.
  final NativeTagForm form;

  /// Creates a classified native release tag.
  const NativeReleaseTag({
    required this.rawTag,
    required this.channel,
    required this.version,
    required this.wrapperRevision,
    required this.upstreamTag,
    required this.form,
  });

  /// Whether this tag is a wrapper rebuild (`wrapperRevision > 0`).
  bool get isWrapper => wrapperRevision > 0;

  /// Whether this is a legacy/historical artifact (`channel == 'nightly'`).
  bool get isLegacy => channel == 'nightly';

  /// Whether this tag is eligible for automatic `latest` discovery (unsuffixed stable only).
  bool get isLatestEligible => form == NativeTagForm.stable;

  /// Whether this tag belongs to a stable upstream line (stable base or stable wrapper).
  bool get isStableUpstream => channel == 'stable';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NativeReleaseTag &&
          rawTag == other.rawTag &&
          channel == other.channel &&
          wrapperRevision == other.wrapperRevision &&
          upstreamTag == other.upstreamTag &&
          form == other.form &&
          _listEquals(version, other.version);

  @override
  int get hashCode => Object.hash(
    rawTag,
    channel,
    wrapperRevision,
    upstreamTag,
    form,
    Object.hashAll(version),
  );

  @override
  String toString() => rawTag;
}

bool _listEquals(List<int> a, List<int> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Matches strictly valid stable release tags: `vMAJOR.MINOR.PATCH`.
final RegExp stableNativeTagPattern = RegExp(
  r'^v(0|[1-9][0-9]{0,17})\.(0|[1-9][0-9]{0,17})\.(0|[1-9][0-9]{0,17})$',
);

/// Matches strictly valid stable wrapper rebuild tags: `vMAJOR.MINOR.PATCH-N`.
final RegExp stableWrapperTagPattern = RegExp(
  r'^v(0|[1-9][0-9]{0,17})\.(0|[1-9][0-9]{0,17})\.(0|[1-9][0-9]{0,17})-([1-9][0-9]{0,17})$',
);

/// Matches strictly valid nightly core tags: `bNNNN`.
final RegExp nightlyNativeTagPattern = RegExp(r'^b(0|[1-9][0-9]{0,17})$');

/// Matches strictly valid nightly wrapper rebuild tags: `bNNNN-N`.
final RegExp nightlyWrapperTagPattern = RegExp(
  r'^b(0|[1-9][0-9]{0,17})-([1-9][0-9]{0,17})$',
);

/// Matches strictly valid legacy consumption-only wrapper tags: `bNNNN-llamadart.N`.
final RegExp legacyWrapperTagPattern = RegExp(
  r'^b(0|[1-9][0-9]{0,17})-llamadart\.([1-9][0-9]{0,17})$',
);

/// Combined pattern matching any supported `llamadart-native` release tag.
final RegExp nativeReleaseTagPattern = RegExp(
  r'^(?:v(?:0|[1-9][0-9]{0,17})\.(?:0|[1-9][0-9]{0,17})\.(?:0|[1-9][0-9]{0,17})(?:-[1-9][0-9]{0,17})?|'
  r'b(?:0|[1-9][0-9]{0,17})(?:-[1-9][0-9]{0,17}|-llamadart\.[1-9][0-9]{0,17})?)$',
);

/// Parses [tag] into a [NativeReleaseTag], returning `null` if [tag] is not a
/// valid `llamadart-native` release tag.
NativeReleaseTag? tryParseNativeReleaseTag(String tag) {
  final stableMatch = stableNativeTagPattern.firstMatch(tag);
  if (stableMatch != null) {
    final major = int.parse(stableMatch.group(1)!);
    final minor = int.parse(stableMatch.group(2)!);
    final patch = int.parse(stableMatch.group(3)!);
    return NativeReleaseTag(
      rawTag: tag,
      channel: 'stable',
      version: [major, minor, patch],
      wrapperRevision: 0,
      upstreamTag: tag,
      form: NativeTagForm.stable,
    );
  }

  final stableWrapperMatch = stableWrapperTagPattern.firstMatch(tag);
  if (stableWrapperMatch != null) {
    final major = int.parse(stableWrapperMatch.group(1)!);
    final minor = int.parse(stableWrapperMatch.group(2)!);
    final patch = int.parse(stableWrapperMatch.group(3)!);
    final wrapperRevision = int.parse(stableWrapperMatch.group(4)!);
    return NativeReleaseTag(
      rawTag: tag,
      channel: 'stable',
      version: [major, minor, patch],
      wrapperRevision: wrapperRevision,
      upstreamTag: 'v$major.$minor.$patch',
      form: NativeTagForm.stableWrapper,
    );
  }

  final nightlyMatch = nightlyNativeTagPattern.firstMatch(tag);
  if (nightlyMatch != null) {
    final build = int.parse(nightlyMatch.group(1)!);
    return NativeReleaseTag(
      rawTag: tag,
      channel: 'nightly',
      version: [build],
      wrapperRevision: 0,
      upstreamTag: tag,
      form: NativeTagForm.nightly,
    );
  }

  final nightlyWrapperMatch = nightlyWrapperTagPattern.firstMatch(tag);
  if (nightlyWrapperMatch != null) {
    final build = int.parse(nightlyWrapperMatch.group(1)!);
    final wrapperRevision = int.parse(nightlyWrapperMatch.group(2)!);
    return NativeReleaseTag(
      rawTag: tag,
      channel: 'nightly',
      version: [build],
      wrapperRevision: wrapperRevision,
      upstreamTag: 'b$build',
      form: NativeTagForm.nightlyWrapper,
    );
  }

  final legacyWrapperMatch = legacyWrapperTagPattern.firstMatch(tag);
  if (legacyWrapperMatch != null) {
    final build = int.parse(legacyWrapperMatch.group(1)!);
    final wrapperRevision = int.parse(legacyWrapperMatch.group(2)!);
    return NativeReleaseTag(
      rawTag: tag,
      channel: 'nightly',
      version: [build],
      wrapperRevision: wrapperRevision,
      upstreamTag: 'b$build',
      form: NativeTagForm.legacyWrapper,
    );
  }

  return null;
}

/// Parses [tag] into a [NativeReleaseTag], throwing [FormatException] if [tag]
/// is invalid.
NativeReleaseTag parseNativeReleaseTag(String tag) {
  final parsed = tryParseNativeReleaseTag(tag);
  if (parsed == null) {
    throw FormatException(
      'Invalid llamadart-native release tag "$tag". Expected stable '
      'vMAJOR.MINOR.PATCH, stable wrapper rebuild vMAJOR.MINOR.PATCH-N, '
      'canonical historical/nightly bNNNN without leading zeros, nightly wrapper '
      'rebuild bNNNN-N, or legacy wrapper artifact bNNNN-llamadart.N; each '
      'numeric component may contain at most 18 digits.',
    );
  }
  return parsed;
}

/// Whether [tag] is a valid `llamadart-native` release tag.
bool isValidNativeReleaseTag(String tag) =>
    tryParseNativeReleaseTag(tag) != null;

/// Normalizes a native release tag (e.g. `v0.2.0-1` or `b10514-1`) to its
/// upstream llama.cpp release tag (e.g. `v0.2.0` or `b10514`).
///
/// Returns `null` if [tag] is malformed or unsupported.
String? normalizeNativeLlamaCppTag(String tag) =>
    tryParseNativeReleaseTag(tag)?.upstreamTag;
