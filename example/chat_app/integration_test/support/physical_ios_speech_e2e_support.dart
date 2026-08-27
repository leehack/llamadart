import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_chat_example/services/audio_recording_service.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

/// Compile-time define names for physical iOS speech integration testing.
abstract final class PhysicalIosSpeechEnvKeys {
  static const qwen3AsrModelPath = 'IOS_SPEECH_QWEN3_ASR_MODEL_PATH';
  static const qwen3AsrModelSha256 = 'IOS_SPEECH_QWEN3_ASR_MODEL_SHA256';
  static const qwen3AsrMmprojPath = 'IOS_SPEECH_QWEN3_ASR_MMPROJ_PATH';
  static const qwen3AsrMmprojSha256 = 'IOS_SPEECH_QWEN3_ASR_MMPROJ_SHA256';
  static const asrAudioPath = 'IOS_SPEECH_ASR_AUDIO_PATH';
  static const asrAudioSha256 = 'IOS_SPEECH_ASR_AUDIO_SHA256';
  static const asrExpectedTranscript = 'IOS_SPEECH_ASR_EXPECTED_TRANSCRIPT';

  static const micDurationSeconds = 'IOS_SPEECH_MIC_DURATION_SECONDS';
  static const micExpectedTranscript = 'IOS_SPEECH_MIC_EXPECTED_TRANSCRIPT';

  static const liteRtAsrModelPath = 'IOS_SPEECH_LITERT_ASR_MODEL_PATH';
  static const liteRtAsrModelSha256 = 'IOS_SPEECH_LITERT_ASR_MODEL_SHA256';
  static const liteRtAsrTokenizerPath = 'IOS_SPEECH_LITERT_ASR_TOKENIZER_PATH';
  static const liteRtAsrTokenizerSha256 =
      'IOS_SPEECH_LITERT_ASR_TOKENIZER_SHA256';
  static const liteRtAsrPreset = 'IOS_SPEECH_LITERT_ASR_PRESET';
  static const liteRtAsrAudioPath = 'IOS_SPEECH_LITERT_ASR_AUDIO_PATH';
  static const liteRtAsrAudioSha256 = 'IOS_SPEECH_LITERT_ASR_AUDIO_SHA256';
  static const liteRtAsrExpectedTranscript =
      'IOS_SPEECH_LITERT_ASR_EXPECTED_TRANSCRIPT';

  static const qwen3TtsModelPath = 'IOS_SPEECH_QWEN3_TTS_MODEL_PATH';
  static const qwen3TtsModelSha256 = 'IOS_SPEECH_QWEN3_TTS_MODEL_SHA256';
  static const qwen3TtsMmprojPath = 'IOS_SPEECH_QWEN3_TTS_MMPROJ_PATH';
  static const qwen3TtsMmprojSha256 = 'IOS_SPEECH_QWEN3_TTS_MMPROJ_SHA256';
  static const ttsText = 'IOS_SPEECH_TTS_TEXT';
  static const ttsOutputPath = 'IOS_SPEECH_TTS_OUTPUT_PATH';
  static const ttsExpectedTranscript = 'IOS_SPEECH_TTS_EXPECTED_TRANSCRIPT';

  static const liteRtLmModelPath = 'IOS_SPEECH_LITERT_LM_MODEL_PATH';
  static const liteRtLmModelSha256 = 'IOS_SPEECH_LITERT_LM_MODEL_SHA256';

  /// Optional selector used to execute one matrix row without changing the
  /// immutable artifact configuration.
  static const rowSelection = 'IOS_SPEECH_ROW';
}

/// Every define this harness requires, in declaration order.
const List<String> physicalIosSpeechDefineKeys = <String>[
  PhysicalIosSpeechEnvKeys.qwen3AsrModelPath,
  PhysicalIosSpeechEnvKeys.qwen3AsrModelSha256,
  PhysicalIosSpeechEnvKeys.qwen3AsrMmprojPath,
  PhysicalIosSpeechEnvKeys.qwen3AsrMmprojSha256,
  PhysicalIosSpeechEnvKeys.asrAudioPath,
  PhysicalIosSpeechEnvKeys.asrAudioSha256,
  PhysicalIosSpeechEnvKeys.asrExpectedTranscript,
  PhysicalIosSpeechEnvKeys.micDurationSeconds,
  PhysicalIosSpeechEnvKeys.micExpectedTranscript,
  PhysicalIosSpeechEnvKeys.liteRtAsrModelPath,
  PhysicalIosSpeechEnvKeys.liteRtAsrModelSha256,
  PhysicalIosSpeechEnvKeys.liteRtAsrTokenizerPath,
  PhysicalIosSpeechEnvKeys.liteRtAsrTokenizerSha256,
  PhysicalIosSpeechEnvKeys.liteRtAsrPreset,
  PhysicalIosSpeechEnvKeys.liteRtAsrAudioPath,
  PhysicalIosSpeechEnvKeys.liteRtAsrAudioSha256,
  PhysicalIosSpeechEnvKeys.liteRtAsrExpectedTranscript,
  PhysicalIosSpeechEnvKeys.qwen3TtsModelPath,
  PhysicalIosSpeechEnvKeys.qwen3TtsModelSha256,
  PhysicalIosSpeechEnvKeys.qwen3TtsMmprojPath,
  PhysicalIosSpeechEnvKeys.qwen3TtsMmprojSha256,
  PhysicalIosSpeechEnvKeys.ttsText,
  PhysicalIosSpeechEnvKeys.ttsOutputPath,
  PhysicalIosSpeechEnvKeys.ttsExpectedTranscript,
  PhysicalIosSpeechEnvKeys.liteRtLmModelPath,
  PhysicalIosSpeechEnvKeys.liteRtLmModelSha256,
];

/// Values supplied through `--dart-define` at compile time.
///
/// Every lookup uses a string literal because `String.fromEnvironment` is only
/// resolved by the compiler in a constant context; a dynamic key silently
/// yields the default and would let the harness run unconfigured.
const Map<String, String> physicalIosSpeechCompileTimeDefines =
    <String, String>{
      'IOS_SPEECH_QWEN3_ASR_MODEL_PATH': String.fromEnvironment(
        'IOS_SPEECH_QWEN3_ASR_MODEL_PATH',
      ),
      'IOS_SPEECH_QWEN3_ASR_MODEL_SHA256': String.fromEnvironment(
        'IOS_SPEECH_QWEN3_ASR_MODEL_SHA256',
      ),
      'IOS_SPEECH_QWEN3_ASR_MMPROJ_PATH': String.fromEnvironment(
        'IOS_SPEECH_QWEN3_ASR_MMPROJ_PATH',
      ),
      'IOS_SPEECH_QWEN3_ASR_MMPROJ_SHA256': String.fromEnvironment(
        'IOS_SPEECH_QWEN3_ASR_MMPROJ_SHA256',
      ),
      'IOS_SPEECH_ASR_AUDIO_PATH': String.fromEnvironment(
        'IOS_SPEECH_ASR_AUDIO_PATH',
      ),
      'IOS_SPEECH_ASR_AUDIO_SHA256': String.fromEnvironment(
        'IOS_SPEECH_ASR_AUDIO_SHA256',
      ),
      'IOS_SPEECH_ASR_EXPECTED_TRANSCRIPT': String.fromEnvironment(
        'IOS_SPEECH_ASR_EXPECTED_TRANSCRIPT',
      ),
      'IOS_SPEECH_MIC_DURATION_SECONDS': String.fromEnvironment(
        'IOS_SPEECH_MIC_DURATION_SECONDS',
      ),
      'IOS_SPEECH_MIC_EXPECTED_TRANSCRIPT': String.fromEnvironment(
        'IOS_SPEECH_MIC_EXPECTED_TRANSCRIPT',
      ),
      'IOS_SPEECH_LITERT_ASR_MODEL_PATH': String.fromEnvironment(
        'IOS_SPEECH_LITERT_ASR_MODEL_PATH',
      ),
      'IOS_SPEECH_LITERT_ASR_MODEL_SHA256': String.fromEnvironment(
        'IOS_SPEECH_LITERT_ASR_MODEL_SHA256',
      ),
      'IOS_SPEECH_LITERT_ASR_TOKENIZER_PATH': String.fromEnvironment(
        'IOS_SPEECH_LITERT_ASR_TOKENIZER_PATH',
      ),
      'IOS_SPEECH_LITERT_ASR_TOKENIZER_SHA256': String.fromEnvironment(
        'IOS_SPEECH_LITERT_ASR_TOKENIZER_SHA256',
      ),
      'IOS_SPEECH_LITERT_ASR_PRESET': String.fromEnvironment(
        'IOS_SPEECH_LITERT_ASR_PRESET',
      ),
      'IOS_SPEECH_LITERT_ASR_AUDIO_PATH': String.fromEnvironment(
        'IOS_SPEECH_LITERT_ASR_AUDIO_PATH',
      ),
      'IOS_SPEECH_LITERT_ASR_AUDIO_SHA256': String.fromEnvironment(
        'IOS_SPEECH_LITERT_ASR_AUDIO_SHA256',
      ),
      'IOS_SPEECH_LITERT_ASR_EXPECTED_TRANSCRIPT': String.fromEnvironment(
        'IOS_SPEECH_LITERT_ASR_EXPECTED_TRANSCRIPT',
      ),
      'IOS_SPEECH_QWEN3_TTS_MODEL_PATH': String.fromEnvironment(
        'IOS_SPEECH_QWEN3_TTS_MODEL_PATH',
      ),
      'IOS_SPEECH_QWEN3_TTS_MODEL_SHA256': String.fromEnvironment(
        'IOS_SPEECH_QWEN3_TTS_MODEL_SHA256',
      ),
      'IOS_SPEECH_QWEN3_TTS_MMPROJ_PATH': String.fromEnvironment(
        'IOS_SPEECH_QWEN3_TTS_MMPROJ_PATH',
      ),
      'IOS_SPEECH_QWEN3_TTS_MMPROJ_SHA256': String.fromEnvironment(
        'IOS_SPEECH_QWEN3_TTS_MMPROJ_SHA256',
      ),
      'IOS_SPEECH_TTS_TEXT': String.fromEnvironment('IOS_SPEECH_TTS_TEXT'),
      'IOS_SPEECH_TTS_OUTPUT_PATH': String.fromEnvironment(
        'IOS_SPEECH_TTS_OUTPUT_PATH',
      ),
      'IOS_SPEECH_TTS_EXPECTED_TRANSCRIPT': String.fromEnvironment(
        'IOS_SPEECH_TTS_EXPECTED_TRANSCRIPT',
      ),
      'IOS_SPEECH_LITERT_LM_MODEL_PATH': String.fromEnvironment(
        'IOS_SPEECH_LITERT_LM_MODEL_PATH',
      ),
      'IOS_SPEECH_LITERT_LM_MODEL_SHA256': String.fromEnvironment(
        'IOS_SPEECH_LITERT_LM_MODEL_SHA256',
      ),
    };

final _hexDigestPattern = RegExp(r'^[0-9a-f]{64}$');
final _positiveIntegerPattern = RegExp(r'^[0-9]+$');
final _whitespaceRun = RegExp(r'\s+');
final _controlCharacters = RegExp(r'[\x00-\x1f\x7f]');
const List<String> _physicalIosApplicationRoots = <String>[
  '/private/var/containers/Bundle/Application/',
  '/var/containers/Bundle/Application/',
];

const int _maximumMicrophoneDurationSeconds = 30;

/// Marker for a path expressed relative to the on-device app cache directory.
///
/// Installing onto a physical device rotates the app data-container UUID, so an
/// absolute container path captured before the install no longer resolves.
/// Defines written as `@appcache/<relative>` are bound to the real directory at
/// runtime through `getApplicationCacheDirectory` instead.
const String appCachePathPrefix = '@appcache/';

/// Matches the marker in any casing so a near-miss fails loudly instead of
/// being reinterpreted as a relative path.
final _appCacheMarkerProbe = RegExp(r'^@appcache(?=/|$)', caseSensitive: false);
final _rejectedPathCharacters = RegExp(r'[\\:?#]');

/// Whether [value] is an app-cache-relative path reference.
bool isAppCachePathReference(String value) =>
    value.startsWith(appCachePathPrefix);

void _requireSafePathSegments(String segments, String key, String value) {
  for (final segment in segments.split('/')) {
    if (segment.isEmpty) {
      throw ArgumentError.value(
        value,
        key,
        'Path contains an empty segment. Leading, trailing, and duplicated '
        '"/" separators are not allowed.',
      );
    }
    if (segment == '.' || segment == '..') {
      throw ArgumentError.value(
        value,
        key,
        'Path contains a "." or ".." traversal segment.',
      );
    }
    if (segment.startsWith('~')) {
      throw ArgumentError.value(
        value,
        key,
        'Path contains a "~" home-expansion segment.',
      );
    }
    if (_rejectedPathCharacters.hasMatch(segment)) {
      throw ArgumentError.value(
        value,
        key,
        r'Path contains "\", ":", "?", or "#". Backslash separators, '
        'drive-qualified values, URL queries, and URL fragments are not '
        'allowed.',
      );
    }
    if (_controlCharacters.hasMatch(segment) || segment.trim() != segment) {
      throw ArgumentError.value(
        value,
        key,
        'Path segments must not contain control characters or leading and '
        'trailing whitespace.',
      );
    }
  }
}

/// Validates one configured path spec and returns it unchanged.
///
/// Accepts either a safe absolute on-device path or an [appCachePathPrefix]
/// reference. Traversal, dot, empty or duplicated separators, backslashes,
/// URL-like values, the bare filesystem root, tilde expansion, and a
/// differently cased marker are all rejected.
String requireSafeSpeechPathSpec(String value, String key) {
  if (_appCacheMarkerProbe.hasMatch(value)) {
    if (!isAppCachePathReference(value)) {
      throw ArgumentError.value(
        value,
        key,
        'The app-cache marker must be spelled exactly "$appCachePathPrefix". '
        'Case variants are rejected because the on-device container may fold '
        'case.',
      );
    }
    final relative = value.substring(appCachePathPrefix.length);
    if (relative.isEmpty) {
      throw ArgumentError.value(
        value,
        key,
        'An $appCachePathPrefix reference must name a file below the app cache '
        'directory.',
      );
    }
    _requireSafePathSegments(relative, key, value);
    return value;
  }

  final uri = Uri.tryParse(value);
  if (!value.startsWith('/') || (uri?.hasScheme ?? false)) {
    throw ArgumentError.value(
      value,
      key,
      'Expected an absolute local on-device path or an $appCachePathPrefix '
      'reference. URLs and relative paths are not allowed.',
    );
  }
  final absoluteSegments = value.substring(1);
  if (absoluteSegments.isEmpty) {
    throw ArgumentError.value(
      value,
      key,
      'The filesystem root is not a usable artifact path.',
    );
  }
  _requireSafePathSegments(absoluteSegments, key, value);
  return value;
}

String _requireUsableCacheDirectory(String rawDirectory) {
  const key = 'applicationCacheDirectory';
  if (rawDirectory.trim().isEmpty) {
    throw ArgumentError.value(
      rawDirectory,
      key,
      'The platform reported an empty application cache directory.',
    );
  }
  if (rawDirectory.trim() != rawDirectory) {
    throw ArgumentError.value(
      rawDirectory,
      key,
      'The application cache directory must not have surrounding whitespace.',
    );
  }
  final directory = rawDirectory;
  final normalized = directory.length > 1 && directory.endsWith('/')
      ? directory.substring(0, directory.length - 1)
      : directory;
  requireSafeSpeechPathSpec(normalized, key);
  if (isAppCachePathReference(normalized)) {
    throw ArgumentError.value(
      rawDirectory,
      key,
      'The application cache directory must itself be an absolute path.',
    );
  }
  return normalized;
}

bool _isAsrAudioAliasPair(String firstLabel, String secondLabel) =>
    (firstLabel == 'asrAudio' && secondLabel == 'liteRtAsrAudio') ||
    (firstLabel == 'liteRtAsrAudio' && secondLabel == 'asrAudio');

bool _isCanonicalDigest(String digest) =>
    digest.length == 64 && _hexDigestPattern.hasMatch(digest);

bool _hasEqualCanonicalDigest(String firstDigest, String secondDigest) =>
    _isCanonicalDigest(firstDigest) &&
    _isCanonicalDigest(secondDigest) &&
    firstDigest == secondDigest;

String _requireCanonicalDigest(String? digest, String key) {
  if (digest == null || !_isCanonicalDigest(digest)) {
    throw ArgumentError.value(
      digest,
      key,
      'Expected a canonical lowercase 64-hex SHA-256 digest.',
    );
  }
  return digest;
}

/// Rejects duplicate immutable inputs and a TTS output that aliases an input.
///
/// Permits aliasing only between `asrAudio` and `liteRtAsrAudio` when their
/// expected SHA-256 digests are identical. Comparison folds case because the
/// on-device container may treat two differently cased names as one file.
/// Filesystem-level canonical and inode checks run later, after every path
/// exists on the installed app container.
void _requireUnambiguousSpeechPaths(
  String outputPath,
  Map<String, String> inputPaths, {
  required Map<String, String> inputDigests,
}) {
  final canonicalDigests = <String, String>{
    for (final label in inputPaths.keys)
      label: _requireCanonicalDigest(inputDigests[label], '$label.sha256'),
  };
  final labelsByFoldedPath = <String, String>{};
  for (final entry in inputPaths.entries) {
    final folded = entry.value.toLowerCase();
    final previousLabel = labelsByFoldedPath[folded];
    if (previousLabel != null) {
      if (!_isAsrAudioAliasPair(entry.key, previousLabel)) {
        throw ArgumentError.value(
          entry.value,
          entry.key,
          'Immutable input path collides with $previousLabel, ignoring case.',
        );
      }
      if (!_hasEqualCanonicalDigest(
        canonicalDigests[entry.key]!,
        canonicalDigests[previousLabel]!,
      )) {
        throw ArgumentError.value(
          entry.value,
          entry.key,
          'Shared ASR fixture paths require one identical canonical '
          'lowercase SHA-256 digest.',
        );
      }
    }
    labelsByFoldedPath[folded] = entry.key;
  }

  final foldedOutput = outputPath.toLowerCase();
  if (labelsByFoldedPath.containsKey(foldedOutput)) {
    throw ArgumentError.value(
      outputPath,
      PhysicalIosSpeechEnvKeys.ttsOutputPath,
      'The disposable TTS output path must not equal any immutable input '
      'artifact path, ignoring case.',
    );
  }
}

/// One checksum-pinned immutable input file.
class PhysicalIosSpeechArtifact {
  /// Stable identifier used in diagnostics and result digests.
  final String label;

  /// Configured path spec.
  ///
  /// This may still be an [appCachePathPrefix] reference until the config is
  /// resolved. Callers must use [PhysicalIosSpeechConfig.requireResolvedPaths]
  /// before any filesystem access.
  final String path;

  /// Expected canonical lowercase SHA-256 digest.
  final String sha256;

  const PhysicalIosSpeechArtifact({
    required this.label,
    required this.path,
    required this.sha256,
  });
}

/// Sanitized failure for one immutable artifact verification.
class PhysicalIosSpeechArtifactFailure implements Exception {
  /// Stable artifact label. The filesystem path is deliberately excluded.
  final String label;

  /// Fingerprinted underlying failure suitable for logs.
  final String diagnostic;

  PhysicalIosSpeechArtifactFailure(this.label, Object error)
    : diagnostic = safeSpeechErrorDiagnostic(error);

  @override
  String toString() => 'artifact:$label:$diagnostic';
}

/// Strict, immutable configuration for the physical iOS speech integration test.
class PhysicalIosSpeechConfig {
  final String qwen3AsrModelPath;
  final String qwen3AsrModelSha256;
  final String qwen3AsrMmprojPath;
  final String qwen3AsrMmprojSha256;
  final String asrAudioPath;
  final String asrAudioSha256;
  final String asrExpectedTranscript;

  final int micDurationSeconds;
  final String micExpectedTranscript;

  final String liteRtAsrModelPath;
  final String liteRtAsrModelSha256;
  final String liteRtAsrTokenizerPath;
  final String liteRtAsrTokenizerSha256;
  final LiteRtLmAsrModelPreset liteRtAsrPreset;
  final String liteRtAsrAudioPath;
  final String liteRtAsrAudioSha256;
  final String liteRtAsrExpectedTranscript;

  final String qwen3TtsModelPath;
  final String qwen3TtsModelSha256;
  final String qwen3TtsMmprojPath;
  final String qwen3TtsMmprojSha256;
  final String ttsText;
  final String ttsOutputPath;
  final String ttsExpectedTranscript;

  final String liteRtLmModelPath;
  final String liteRtLmModelSha256;

  /// Canonical cache root used to resolve [appCachePathPrefix] references.
  ///
  /// This stays null for an all-absolute configuration. Once set, every
  /// resolved cache-relative path is required to remain below this directory
  /// after symbolic-link resolution.
  final String? resolvedAppCacheDirectoryPath;

  const PhysicalIosSpeechConfig({
    required this.qwen3AsrModelPath,
    required this.qwen3AsrModelSha256,
    required this.qwen3AsrMmprojPath,
    required this.qwen3AsrMmprojSha256,
    required this.asrAudioPath,
    required this.asrAudioSha256,
    required this.asrExpectedTranscript,
    required this.micDurationSeconds,
    required this.micExpectedTranscript,
    required this.liteRtAsrModelPath,
    required this.liteRtAsrModelSha256,
    required this.liteRtAsrTokenizerPath,
    required this.liteRtAsrTokenizerSha256,
    required this.liteRtAsrPreset,
    required this.liteRtAsrAudioPath,
    required this.liteRtAsrAudioSha256,
    required this.liteRtAsrExpectedTranscript,
    required this.qwen3TtsModelPath,
    required this.qwen3TtsModelSha256,
    required this.qwen3TtsMmprojPath,
    required this.qwen3TtsMmprojSha256,
    required this.ttsText,
    required this.ttsOutputPath,
    required this.ttsExpectedTranscript,
    required this.liteRtLmModelPath,
    required this.liteRtLmModelSha256,
    this.resolvedAppCacheDirectoryPath,
  });

  /// Loads configuration from `--dart-define` values only.
  ///
  /// The process environment is deliberately never consulted: on device it is
  /// not the channel the harness is configured through, and reading it would
  /// let an unrelated variable satisfy a required pin.
  factory PhysicalIosSpeechConfig.fromEnvironment() =>
      PhysicalIosSpeechConfig.fromMap(physicalIosSpeechCompileTimeDefines);

  /// Parses and validates all parameters from [map].
  factory PhysicalIosSpeechConfig.fromMap(Map<String, String> map) {
    String require(String key) {
      final trimmed = (map[key] ?? '').trim();
      if (trimmed.isEmpty) {
        throw ArgumentError.value(
          map[key],
          key,
          'Required dart define $key is missing or empty. Pass '
          '--dart-define=$key=<value>.',
        );
      }
      return trimmed;
    }

    String requireDigest(String key) => _requireCanonicalDigest(map[key], key);

    String requirePathSpec(String key) {
      final raw = map[key] ?? '';
      if (raw.trim().isEmpty) {
        return requireSafeSpeechPathSpec(require(key), key);
      }
      return requireSafeSpeechPathSpec(raw, key);
    }

    final micDurationStr = require(PhysicalIosSpeechEnvKeys.micDurationSeconds);
    final micDuration = _positiveIntegerPattern.hasMatch(micDurationStr)
        ? int.tryParse(micDurationStr)
        : null;
    if (micDuration == null ||
        micDuration <= 0 ||
        micDuration > _maximumMicrophoneDurationSeconds) {
      throw ArgumentError.value(
        micDurationStr,
        PhysicalIosSpeechEnvKeys.micDurationSeconds,
        'Expected a whole number from 1 through '
        '$_maximumMicrophoneDurationSeconds seconds for microphone '
        'capture.',
      );
    }

    final qwen3AsrModelPath = requirePathSpec(
      PhysicalIosSpeechEnvKeys.qwen3AsrModelPath,
    );
    final qwen3AsrMmprojPath = requirePathSpec(
      PhysicalIosSpeechEnvKeys.qwen3AsrMmprojPath,
    );
    final asrAudioPath = requirePathSpec(PhysicalIosSpeechEnvKeys.asrAudioPath);
    final liteRtAsrModelPath = requirePathSpec(
      PhysicalIosSpeechEnvKeys.liteRtAsrModelPath,
    );
    final liteRtAsrTokenizerPath = requirePathSpec(
      PhysicalIosSpeechEnvKeys.liteRtAsrTokenizerPath,
    );
    final liteRtAsrAudioPath = requirePathSpec(
      PhysicalIosSpeechEnvKeys.liteRtAsrAudioPath,
    );
    final qwen3TtsModelPath = requirePathSpec(
      PhysicalIosSpeechEnvKeys.qwen3TtsModelPath,
    );
    final qwen3TtsMmprojPath = requirePathSpec(
      PhysicalIosSpeechEnvKeys.qwen3TtsMmprojPath,
    );
    final ttsOutputPath = requirePathSpec(
      PhysicalIosSpeechEnvKeys.ttsOutputPath,
    );
    final liteRtLmModelPath = requirePathSpec(
      PhysicalIosSpeechEnvKeys.liteRtLmModelPath,
    );
    final qwen3AsrModelSha256 = requireDigest(
      PhysicalIosSpeechEnvKeys.qwen3AsrModelSha256,
    );
    final qwen3AsrMmprojSha256 = requireDigest(
      PhysicalIosSpeechEnvKeys.qwen3AsrMmprojSha256,
    );
    final asrAudioSha256 = requireDigest(
      PhysicalIosSpeechEnvKeys.asrAudioSha256,
    );
    final liteRtAsrModelSha256 = requireDigest(
      PhysicalIosSpeechEnvKeys.liteRtAsrModelSha256,
    );
    final liteRtAsrTokenizerSha256 = requireDigest(
      PhysicalIosSpeechEnvKeys.liteRtAsrTokenizerSha256,
    );
    final liteRtAsrAudioSha256 = requireDigest(
      PhysicalIosSpeechEnvKeys.liteRtAsrAudioSha256,
    );
    final qwen3TtsModelSha256 = requireDigest(
      PhysicalIosSpeechEnvKeys.qwen3TtsModelSha256,
    );
    final qwen3TtsMmprojSha256 = requireDigest(
      PhysicalIosSpeechEnvKeys.qwen3TtsMmprojSha256,
    );
    final liteRtLmModelSha256 = requireDigest(
      PhysicalIosSpeechEnvKeys.liteRtLmModelSha256,
    );

    // Collisions are re-checked after resolution, because an absolute path and
    // an `@appcache/` reference can only be compared once both are bound.
    _requireUnambiguousSpeechPaths(
      ttsOutputPath,
      <String, String>{
        'qwen3AsrModel': qwen3AsrModelPath,
        'qwen3AsrMmproj': qwen3AsrMmprojPath,
        'asrAudio': asrAudioPath,
        'liteRtAsrModel': liteRtAsrModelPath,
        'liteRtAsrTokenizer': liteRtAsrTokenizerPath,
        'liteRtAsrAudio': liteRtAsrAudioPath,
        'qwen3TtsModel': qwen3TtsModelPath,
        'qwen3TtsMmproj': qwen3TtsMmprojPath,
        'liteRtLmModel': liteRtLmModelPath,
      },
      inputDigests: <String, String>{
        'qwen3AsrModel': qwen3AsrModelSha256,
        'qwen3AsrMmproj': qwen3AsrMmprojSha256,
        'asrAudio': asrAudioSha256,
        'liteRtAsrModel': liteRtAsrModelSha256,
        'liteRtAsrTokenizer': liteRtAsrTokenizerSha256,
        'liteRtAsrAudio': liteRtAsrAudioSha256,
        'qwen3TtsModel': qwen3TtsModelSha256,
        'qwen3TtsMmproj': qwen3TtsMmprojSha256,
        'liteRtLmModel': liteRtLmModelSha256,
      },
    );

    return PhysicalIosSpeechConfig(
      qwen3AsrModelPath: qwen3AsrModelPath,
      qwen3AsrModelSha256: qwen3AsrModelSha256,
      qwen3AsrMmprojPath: qwen3AsrMmprojPath,
      qwen3AsrMmprojSha256: qwen3AsrMmprojSha256,
      asrAudioPath: asrAudioPath,
      asrAudioSha256: asrAudioSha256,
      asrExpectedTranscript: require(
        PhysicalIosSpeechEnvKeys.asrExpectedTranscript,
      ),
      micDurationSeconds: micDuration,
      micExpectedTranscript: require(
        PhysicalIosSpeechEnvKeys.micExpectedTranscript,
      ),
      liteRtAsrModelPath: liteRtAsrModelPath,
      liteRtAsrModelSha256: liteRtAsrModelSha256,
      liteRtAsrTokenizerPath: liteRtAsrTokenizerPath,
      liteRtAsrTokenizerSha256: liteRtAsrTokenizerSha256,
      liteRtAsrPreset: _parsePreset(
        require(PhysicalIosSpeechEnvKeys.liteRtAsrPreset),
      ),
      liteRtAsrAudioPath: liteRtAsrAudioPath,
      liteRtAsrAudioSha256: liteRtAsrAudioSha256,
      liteRtAsrExpectedTranscript: require(
        PhysicalIosSpeechEnvKeys.liteRtAsrExpectedTranscript,
      ),
      qwen3TtsModelPath: qwen3TtsModelPath,
      qwen3TtsModelSha256: qwen3TtsModelSha256,
      qwen3TtsMmprojPath: qwen3TtsMmprojPath,
      qwen3TtsMmprojSha256: qwen3TtsMmprojSha256,
      ttsText: require(PhysicalIosSpeechEnvKeys.ttsText),
      ttsOutputPath: ttsOutputPath,
      ttsExpectedTranscript: require(
        PhysicalIosSpeechEnvKeys.ttsExpectedTranscript,
      ),
      liteRtLmModelPath: liteRtLmModelPath,
      liteRtLmModelSha256: liteRtLmModelSha256,
    );
  }

  static LiteRtLmAsrModelPreset _parsePreset(String name) {
    final normalized = name.trim().toLowerCase().replaceAll('_', '-');
    switch (normalized) {
      case 'moonshine-tiny':
        return LiteRtLmAsrModelPreset.moonshineTiny;
      case 'parakeet-tdt':
      case 'parakeet-tdt-0.6b-v3':
      case 'parakeet-tdt-0-6b-v3':
      case 'parakeettdt0-6bv3':
        return LiteRtLmAsrModelPreset.parakeetTdt0_6bV3;
      case 'parakeet-ctc':
      case 'parakeet-ctc-0.6b':
      case 'parakeet-ctc-0-6b':
      case 'parakeetctc0-6b':
        return LiteRtLmAsrModelPreset.parakeetCtc0_6b;
      case 'whisper-tiny':
        return LiteRtLmAsrModelPreset.whisperTiny;
      case 'qwen3-asr-0.6b':
      case 'qwen3-asr-0-6b':
      case 'qwen3asr0-6b':
        return LiteRtLmAsrModelPreset.qwen3Asr0_6b;
      default:
        throw ArgumentError.value(
          name,
          PhysicalIosSpeechEnvKeys.liteRtAsrPreset,
          'Unknown LiteRT-LM ASR preset. Supported: moonshine-tiny, '
          'parakeet-tdt, parakeet-ctc, whisper-tiny, qwen3-asr-0.6b.',
        );
    }
  }

  /// Whether any configured path still needs app-cache resolution.
  bool get usesAppCachePaths =>
      _configuredPaths.any(isAppCachePathReference) ||
      isAppCachePathReference(ttsOutputPath);

  List<String> get _configuredPaths => <String>[
    qwen3AsrModelPath,
    qwen3AsrMmprojPath,
    asrAudioPath,
    liteRtAsrModelPath,
    liteRtAsrTokenizerPath,
    liteRtAsrAudioPath,
    qwen3TtsModelPath,
    qwen3TtsMmprojPath,
    liteRtLmModelPath,
  ];

  /// Binds every [appCachePathPrefix] reference to [cacheDirectoryPath].
  ///
  /// Safe absolute paths are returned unchanged. Every path is re-validated
  /// here so a directly constructed config cannot smuggle an unsafe path past
  /// [PhysicalIosSpeechConfig.fromMap].
  PhysicalIosSpeechConfig resolveAppCachePaths(String cacheDirectoryPath) {
    final base = _requireUsableCacheDirectory(cacheDirectoryPath);

    String resolve(String value, String key) {
      final spec = requireSafeSpeechPathSpec(value, key);
      if (!isAppCachePathReference(spec)) {
        return spec;
      }
      return '$base/${spec.substring(appCachePathPrefix.length)}';
    }

    final resolvedQwen3AsrModelPath = resolve(
      qwen3AsrModelPath,
      PhysicalIosSpeechEnvKeys.qwen3AsrModelPath,
    );
    final resolvedQwen3AsrMmprojPath = resolve(
      qwen3AsrMmprojPath,
      PhysicalIosSpeechEnvKeys.qwen3AsrMmprojPath,
    );
    final resolvedAsrAudioPath = resolve(
      asrAudioPath,
      PhysicalIosSpeechEnvKeys.asrAudioPath,
    );
    final resolvedLiteRtAsrModelPath = resolve(
      liteRtAsrModelPath,
      PhysicalIosSpeechEnvKeys.liteRtAsrModelPath,
    );
    final resolvedLiteRtAsrTokenizerPath = resolve(
      liteRtAsrTokenizerPath,
      PhysicalIosSpeechEnvKeys.liteRtAsrTokenizerPath,
    );
    final resolvedLiteRtAsrAudioPath = resolve(
      liteRtAsrAudioPath,
      PhysicalIosSpeechEnvKeys.liteRtAsrAudioPath,
    );
    final resolvedQwen3TtsModelPath = resolve(
      qwen3TtsModelPath,
      PhysicalIosSpeechEnvKeys.qwen3TtsModelPath,
    );
    final resolvedQwen3TtsMmprojPath = resolve(
      qwen3TtsMmprojPath,
      PhysicalIosSpeechEnvKeys.qwen3TtsMmprojPath,
    );
    final resolvedLiteRtLmModelPath = resolve(
      liteRtLmModelPath,
      PhysicalIosSpeechEnvKeys.liteRtLmModelPath,
    );
    final resolvedTtsOutputPath = resolve(
      ttsOutputPath,
      PhysicalIosSpeechEnvKeys.ttsOutputPath,
    );
    _requireUnambiguousSpeechPaths(
      resolvedTtsOutputPath,
      <String, String>{
        'qwen3AsrModel': resolvedQwen3AsrModelPath,
        'qwen3AsrMmproj': resolvedQwen3AsrMmprojPath,
        'asrAudio': resolvedAsrAudioPath,
        'liteRtAsrModel': resolvedLiteRtAsrModelPath,
        'liteRtAsrTokenizer': resolvedLiteRtAsrTokenizerPath,
        'liteRtAsrAudio': resolvedLiteRtAsrAudioPath,
        'qwen3TtsModel': resolvedQwen3TtsModelPath,
        'qwen3TtsMmproj': resolvedQwen3TtsMmprojPath,
        'liteRtLmModel': resolvedLiteRtLmModelPath,
      },
      inputDigests: <String, String>{
        'qwen3AsrModel': qwen3AsrModelSha256,
        'qwen3AsrMmproj': qwen3AsrMmprojSha256,
        'asrAudio': asrAudioSha256,
        'liteRtAsrModel': liteRtAsrModelSha256,
        'liteRtAsrTokenizer': liteRtAsrTokenizerSha256,
        'liteRtAsrAudio': liteRtAsrAudioSha256,
        'qwen3TtsModel': qwen3TtsModelSha256,
        'qwen3TtsMmproj': qwen3TtsMmprojSha256,
        'liteRtLmModel': liteRtLmModelSha256,
      },
    );

    return PhysicalIosSpeechConfig(
      qwen3AsrModelPath: resolvedQwen3AsrModelPath,
      qwen3AsrModelSha256: qwen3AsrModelSha256,
      qwen3AsrMmprojPath: resolvedQwen3AsrMmprojPath,
      qwen3AsrMmprojSha256: qwen3AsrMmprojSha256,
      asrAudioPath: resolvedAsrAudioPath,
      asrAudioSha256: asrAudioSha256,
      asrExpectedTranscript: asrExpectedTranscript,
      micDurationSeconds: micDurationSeconds,
      micExpectedTranscript: micExpectedTranscript,
      liteRtAsrModelPath: resolvedLiteRtAsrModelPath,
      liteRtAsrModelSha256: liteRtAsrModelSha256,
      liteRtAsrTokenizerPath: resolvedLiteRtAsrTokenizerPath,
      liteRtAsrTokenizerSha256: liteRtAsrTokenizerSha256,
      liteRtAsrPreset: liteRtAsrPreset,
      liteRtAsrAudioPath: resolvedLiteRtAsrAudioPath,
      liteRtAsrAudioSha256: liteRtAsrAudioSha256,
      liteRtAsrExpectedTranscript: liteRtAsrExpectedTranscript,
      qwen3TtsModelPath: resolvedQwen3TtsModelPath,
      qwen3TtsModelSha256: qwen3TtsModelSha256,
      qwen3TtsMmprojPath: resolvedQwen3TtsMmprojPath,
      qwen3TtsMmprojSha256: qwen3TtsMmprojSha256,
      ttsText: ttsText,
      ttsOutputPath: resolvedTtsOutputPath,
      ttsExpectedTranscript: ttsExpectedTranscript,
      liteRtLmModelPath: resolvedLiteRtLmModelPath,
      liteRtLmModelSha256: liteRtLmModelSha256,
      resolvedAppCacheDirectoryPath: base,
    );
  }

  /// Fails closed unless every digest and path is canonical and unambiguous.
  void requireResolvedPaths() {
    final configuredArtifacts = artifacts;
    final unresolved = <String>[
      for (final artifact in configuredArtifacts)
        if (isAppCachePathReference(
          requireSafeSpeechPathSpec(artifact.path, artifact.label),
        ))
          artifact.label,
      if (isAppCachePathReference(
        requireSafeSpeechPathSpec(
          ttsOutputPath,
          PhysicalIosSpeechEnvKeys.ttsOutputPath,
        ),
      ))
        'ttsOutput',
    ]..sort();
    if (unresolved.isNotEmpty) {
      throw StateError(
        'Path access was attempted before $appCachePathPrefix references were '
        'resolved: ${unresolved.join(', ')}.',
      );
    }
    _requireUnambiguousSpeechPaths(
      ttsOutputPath,
      <String, String>{
        for (final artifact in configuredArtifacts)
          artifact.label: artifact.path,
      },
      inputDigests: <String, String>{
        for (final artifact in configuredArtifacts)
          artifact.label: artifact.sha256,
      },
    );
  }

  /// Every checksum-pinned immutable artifact, in verification order.
  List<PhysicalIosSpeechArtifact> get artifacts => <PhysicalIosSpeechArtifact>[
    PhysicalIosSpeechArtifact(
      label: 'qwen3AsrModel',
      path: qwen3AsrModelPath,
      sha256: qwen3AsrModelSha256,
    ),
    PhysicalIosSpeechArtifact(
      label: 'qwen3AsrMmproj',
      path: qwen3AsrMmprojPath,
      sha256: qwen3AsrMmprojSha256,
    ),
    PhysicalIosSpeechArtifact(
      label: 'asrAudio',
      path: asrAudioPath,
      sha256: asrAudioSha256,
    ),
    PhysicalIosSpeechArtifact(
      label: 'liteRtAsrModel',
      path: liteRtAsrModelPath,
      sha256: liteRtAsrModelSha256,
    ),
    PhysicalIosSpeechArtifact(
      label: 'liteRtAsrTokenizer',
      path: liteRtAsrTokenizerPath,
      sha256: liteRtAsrTokenizerSha256,
    ),
    PhysicalIosSpeechArtifact(
      label: 'liteRtAsrAudio',
      path: liteRtAsrAudioPath,
      sha256: liteRtAsrAudioSha256,
    ),
    PhysicalIosSpeechArtifact(
      label: 'qwen3TtsModel',
      path: qwen3TtsModelPath,
      sha256: qwen3TtsModelSha256,
    ),
    PhysicalIosSpeechArtifact(
      label: 'qwen3TtsMmproj',
      path: qwen3TtsMmprojPath,
      sha256: qwen3TtsMmprojSha256,
    ),
    PhysicalIosSpeechArtifact(
      label: 'liteRtLmModel',
      path: liteRtLmModelPath,
      sha256: liteRtLmModelSha256,
    ),
  ];

  /// Verifies existence and streamed SHA-256 for all immutable artifacts.
  ///
  /// Artifacts are hashed strictly one at a time: several of these files are
  /// multi-gigabyte, and hashing them concurrently saturates device I/O.
  Future<void> validateArtifacts({
    Future<void> Function(PhysicalIosSpeechArtifact artifact)? verify,
  }) async {
    requireResolvedPaths();
    final check =
        verify ??
        (PhysicalIosSpeechArtifact artifact) =>
            validateFileChecksum(artifact.path, artifact.sha256);
    for (final artifact in artifacts) {
      await check(artifact);
    }
  }

  /// Verifies every artifact sequentially and collects sanitized failures.
  ///
  /// Unlike [validateArtifacts], this does not stop after the first bad pin.
  /// The physical-device harness uses the resulting ledger so one bad input
  /// marks only its dependent rows and all four rows are still reported.
  Future<Map<String, PhysicalIosSpeechArtifactFailure>>
  validateArtifactsCollectingFailures({
    Future<void> Function(PhysicalIosSpeechArtifact artifact)? verify,
    Duration? timeoutPerArtifact,
  }) async {
    requireResolvedPaths();
    final check =
        verify ??
        (PhysicalIosSpeechArtifact artifact) => validateFileChecksum(
          artifact.path,
          artifact.sha256,
          timeout: timeoutPerArtifact,
        );
    final failures = <String, PhysicalIosSpeechArtifactFailure>{};
    for (final artifact in artifacts) {
      try {
        await check(artifact);
      } catch (error) {
        failures[artifact.label] = PhysicalIosSpeechArtifactFailure(
          artifact.label,
          error,
        );
      }
    }
    return Map<String, PhysicalIosSpeechArtifactFailure>.unmodifiable(failures);
  }
}

/// Resolves [appCachePathPrefix] references against the real app cache
/// directory, so paths survive the data-container UUID a device install mints.
///
/// [cacheDirectory] exists so host tests can bind a temporary directory; the
/// device harness always uses `getApplicationCacheDirectory`. The lookup is
/// skipped entirely when no define uses the marker, keeping an all-absolute
/// configuration independent of the plugin.
Future<PhysicalIosSpeechConfig> resolvePhysicalIosSpeechCachePaths(
  PhysicalIosSpeechConfig config, {
  Future<Directory> Function()? cacheDirectory,
}) async {
  if (!config.usesAppCachePaths) {
    config.requireResolvedPaths();
    return config;
  }
  final directory = await (cacheDirectory ?? getApplicationCacheDirectory)();
  final resolved = config.resolveAppCachePaths(directory.path);
  resolved.requireResolvedPaths();
  return resolved;
}

bool _isWithinDirectory(String root, String candidate) {
  final normalizedRoot = path.normalize(root);
  final normalizedCandidate = path.normalize(candidate);
  return path.equals(normalizedRoot, normalizedCandidate) ||
      path.isWithin(normalizedRoot, normalizedCandidate);
}

Future<FileSystemEntityType> _safeEntityType(
  String entityPath,
  String label,
) async {
  try {
    return await FileSystemEntity.type(entityPath, followLinks: false);
  } on FileSystemException {
    throw FileSystemException('Unable to inspect $label safely.');
  }
}

Future<String> _safeResolveDirectory(String directoryPath, String label) async {
  if (await _safeEntityType(directoryPath, label) !=
      FileSystemEntityType.directory) {
    throw FileSystemException('$label is not an existing directory.');
  }
  try {
    return path.normalize(
      await Directory(directoryPath).resolveSymbolicLinks(),
    );
  } on FileSystemException {
    throw FileSystemException('Unable to canonicalize $label safely.');
  }
}

Future<void> _requireNoLinksBelowRoot({
  required String root,
  required String candidate,
  required String label,
  required bool allowMissing,
}) async {
  if (!_isWithinDirectory(root, candidate) || path.equals(root, candidate)) {
    throw StateError('$label escaped the runtime application cache.');
  }
  var current = path.normalize(root);
  final relative = path.relative(path.normalize(candidate), from: current);
  for (final segment in path.split(relative)) {
    current = path.join(current, segment);
    final type = await _safeEntityType(current, label);
    if (type == FileSystemEntityType.link) {
      throw StateError('$label contains a symbolic-link component.');
    }
    if (type == FileSystemEntityType.notFound) {
      if (allowMissing) {
        return;
      }
      throw FileSystemException('$label does not exist.');
    }
  }
}

Future<String?> _canonicalizeInputArtifact(
  PhysicalIosSpeechArtifact artifact, {
  required String? configuredCacheRoot,
  required String? canonicalCacheRoot,
}) async {
  var candidate = path.normalize(artifact.path);
  if (configuredCacheRoot != null &&
      canonicalCacheRoot != null &&
      _isWithinDirectory(configuredCacheRoot, candidate)) {
    final relative = path.relative(candidate, from: configuredCacheRoot);
    candidate = path.join(canonicalCacheRoot, relative);
    await _requireNoLinksBelowRoot(
      root: canonicalCacheRoot,
      candidate: candidate,
      label: artifact.label,
      allowMissing: true,
    );
  }

  final type = await _safeEntityType(candidate, artifact.label);
  if (type == FileSystemEntityType.notFound) {
    // Preserve the path so checksum validation can classify this failure only
    // against rows that depend on the missing artifact.
    return null;
  }
  if (type == FileSystemEntityType.link) {
    throw StateError('${artifact.label} must not be a symbolic link.');
  }
  if (type != FileSystemEntityType.file) {
    return null;
  }
  try {
    final canonical = path.normalize(
      await File(candidate).resolveSymbolicLinks(),
    );
    if (canonicalCacheRoot != null &&
        _isWithinDirectory(canonicalCacheRoot, candidate) &&
        !_isWithinDirectory(canonicalCacheRoot, canonical)) {
      throw StateError(
        '${artifact.label} escaped the runtime application cache.',
      );
    }
    return canonical;
  } on FileSystemException {
    throw FileSystemException(
      'Unable to canonicalize ${artifact.label} safely.',
    );
  }
}

Future<String> _canonicalizePlannedOutputPath(
  String outputPath, {
  required String? configuredCacheRoot,
  required String? canonicalCacheRoot,
}) async {
  final normalizedOutput = path.normalize(outputPath);
  if (configuredCacheRoot != null &&
      canonicalCacheRoot != null &&
      _isWithinDirectory(configuredCacheRoot, normalizedOutput)) {
    final relative = path.relative(normalizedOutput, from: configuredCacheRoot);
    final canonicalOutput = path.join(canonicalCacheRoot, relative);
    await _requireNoLinksBelowRoot(
      root: canonicalCacheRoot,
      candidate: canonicalOutput,
      label: 'ttsOutput',
      allowMissing: true,
    );
    return canonicalOutput;
  }

  var existingAncestor = path.dirname(normalizedOutput);
  final missingSegments = <String>[];
  while (true) {
    final type = await _safeEntityType(existingAncestor, 'ttsOutputParent');
    if (type == FileSystemEntityType.directory ||
        type == FileSystemEntityType.link) {
      break;
    }
    if (type != FileSystemEntityType.notFound) {
      throw StateError('The TTS output parent is not a directory.');
    }
    final parent = path.dirname(existingAncestor);
    if (path.equals(parent, existingAncestor)) {
      throw StateError('The TTS output path has no usable parent directory.');
    }
    missingSegments.add(path.basename(existingAncestor));
    existingAncestor = parent;
  }
  var canonicalParent = path.normalize(
    await Directory(existingAncestor).resolveSymbolicLinks(),
  );
  for (final segment in missingSegments.reversed) {
    canonicalParent = path.join(canonicalParent, segment);
  }
  return path.join(canonicalParent, path.basename(normalizedOutput));
}

PhysicalIosSpeechConfig _copyConfigWithCanonicalPaths(
  PhysicalIosSpeechConfig source,
  Map<String, String> canonicalInputs,
  String canonicalOutput,
  String? canonicalCacheRoot,
) {
  return PhysicalIosSpeechConfig(
    qwen3AsrModelPath:
        canonicalInputs['qwen3AsrModel'] ?? source.qwen3AsrModelPath,
    qwen3AsrModelSha256: source.qwen3AsrModelSha256,
    qwen3AsrMmprojPath:
        canonicalInputs['qwen3AsrMmproj'] ?? source.qwen3AsrMmprojPath,
    qwen3AsrMmprojSha256: source.qwen3AsrMmprojSha256,
    asrAudioPath: canonicalInputs['asrAudio'] ?? source.asrAudioPath,
    asrAudioSha256: source.asrAudioSha256,
    asrExpectedTranscript: source.asrExpectedTranscript,
    micDurationSeconds: source.micDurationSeconds,
    micExpectedTranscript: source.micExpectedTranscript,
    liteRtAsrModelPath:
        canonicalInputs['liteRtAsrModel'] ?? source.liteRtAsrModelPath,
    liteRtAsrModelSha256: source.liteRtAsrModelSha256,
    liteRtAsrTokenizerPath:
        canonicalInputs['liteRtAsrTokenizer'] ?? source.liteRtAsrTokenizerPath,
    liteRtAsrTokenizerSha256: source.liteRtAsrTokenizerSha256,
    liteRtAsrPreset: source.liteRtAsrPreset,
    liteRtAsrAudioPath:
        canonicalInputs['liteRtAsrAudio'] ?? source.liteRtAsrAudioPath,
    liteRtAsrAudioSha256: source.liteRtAsrAudioSha256,
    liteRtAsrExpectedTranscript: source.liteRtAsrExpectedTranscript,
    qwen3TtsModelPath:
        canonicalInputs['qwen3TtsModel'] ?? source.qwen3TtsModelPath,
    qwen3TtsModelSha256: source.qwen3TtsModelSha256,
    qwen3TtsMmprojPath:
        canonicalInputs['qwen3TtsMmproj'] ?? source.qwen3TtsMmprojPath,
    qwen3TtsMmprojSha256: source.qwen3TtsMmprojSha256,
    ttsText: source.ttsText,
    ttsOutputPath: canonicalOutput,
    ttsExpectedTranscript: source.ttsExpectedTranscript,
    liteRtLmModelPath:
        canonicalInputs['liteRtLmModel'] ?? source.liteRtLmModelPath,
    liteRtLmModelSha256: source.liteRtLmModelSha256,
    resolvedAppCacheDirectoryPath: canonicalCacheRoot,
  );
}

/// Canonicalizes runtime paths and rejects symlink or inode aliases.
///
/// This runs only after app launch and [resolvePhysicalIosSpeechCachePaths], so
/// an install-time data-container rotation cannot leave stale absolute cache
/// paths in the runtime APIs. Missing inputs stay available for the later
/// row-specific checksum ledger; unsafe symlinks and canonical collisions fail
/// the whole preflight because the configured artifact identities are
/// ambiguous.
Future<PhysicalIosSpeechConfig> canonicalizePhysicalIosSpeechFilesystemLayout(
  PhysicalIosSpeechConfig config,
) async {
  config.requireResolvedPaths();
  final configuredCacheRoot = config.resolvedAppCacheDirectoryPath;
  final canonicalCacheRoot = configuredCacheRoot == null
      ? null
      : await _safeResolveDirectory(
          configuredCacheRoot,
          'applicationCacheDirectory',
        );

  final canonicalInputs = <String, String>{};
  final canonicalArtifacts = <PhysicalIosSpeechArtifact>[];
  for (final artifact in config.artifacts) {
    final canonical = await _canonicalizeInputArtifact(
      artifact,
      configuredCacheRoot: configuredCacheRoot,
      canonicalCacheRoot: canonicalCacheRoot,
    );
    if (canonical == null) {
      continue;
    }
    canonicalInputs[artifact.label] = canonical;
    canonicalArtifacts.add(
      PhysicalIosSpeechArtifact(
        label: artifact.label,
        path: canonical,
        sha256: artifact.sha256,
      ),
    );
  }

  for (var i = 0; i < canonicalArtifacts.length; i++) {
    for (var j = i + 1; j < canonicalArtifacts.length; j++) {
      final left = canonicalArtifacts[i];
      final right = canonicalArtifacts[j];
      final collidesByName =
          left.path.toLowerCase() == right.path.toLowerCase();
      bool collidesByIdentity;
      try {
        collidesByIdentity = await FileSystemEntity.identical(
          left.path,
          right.path,
        );
      } on FileSystemException {
        throw const FileSystemException(
          'Unable to compare immutable artifact identities safely.',
        );
      }
      if (collidesByName || collidesByIdentity) {
        final isPermittedAsrAlias =
            _isAsrAudioAliasPair(left.label, right.label) &&
            _hasEqualCanonicalDigest(left.sha256, right.sha256);
        if (!isPermittedAsrAlias) {
          throw StateError(
            'Immutable artifact identities collide: ${left.label}, '
            '${right.label}.',
          );
        }
      }
    }
  }

  final canonicalOutput = await _canonicalizePlannedOutputPath(
    config.ttsOutputPath,
    configuredCacheRoot: configuredCacheRoot,
    canonicalCacheRoot: canonicalCacheRoot,
  );
  final outputType = await _safeEntityType(canonicalOutput, 'ttsOutput');
  if (outputType != FileSystemEntityType.notFound) {
    throw StateError(
      'The configured TTS output already exists; refusing to overwrite or '
      'delete it.',
    );
  }
  if (canonicalArtifacts.any(
    (artifact) => artifact.path.toLowerCase() == canonicalOutput.toLowerCase(),
  )) {
    throw StateError('The TTS output aliases an immutable input artifact.');
  }

  return _copyConfigWithCanonicalPaths(
    config,
    canonicalInputs,
    canonicalOutput,
    canonicalCacheRoot,
  );
}

Future<void> _createOutputParentSafely(
  String outputPath,
  String? canonicalCacheRoot,
) async {
  final parent = path.dirname(outputPath);
  if (canonicalCacheRoot != null &&
      _isWithinDirectory(canonicalCacheRoot, outputPath)) {
    var current = canonicalCacheRoot;
    final relative = path.relative(parent, from: canonicalCacheRoot);
    for (final segment in path.split(relative)) {
      if (segment == '.') {
        continue;
      }
      current = path.join(current, segment);
      final type = await _safeEntityType(current, 'ttsOutputParent');
      if (type == FileSystemEntityType.link) {
        throw StateError('The TTS output parent contains a symbolic link.');
      }
      if (type == FileSystemEntityType.notFound) {
        try {
          await Directory(current).create();
        } on FileSystemException {
          throw const FileSystemException(
            'Unable to create the TTS output parent safely.',
          );
        }
      } else if (type != FileSystemEntityType.directory) {
        throw StateError('The TTS output parent is not a directory.');
      }
    }
    return;
  }

  try {
    await Directory(parent).create(recursive: true);
  } on FileSystemException {
    throw const FileSystemException(
      'Unable to create the TTS output parent safely.',
    );
  }
  final canonicalParent = await _safeResolveDirectory(
    parent,
    'ttsOutputParent',
  );
  if (!path.equals(canonicalParent, parent)) {
    throw StateError('The TTS output parent changed after canonicalization.');
  }
}

/// Creates and writes the disposable WAV without following an existing link.
Future<File> writePhysicalIosSpeechOutputExclusive(
  PhysicalIosSpeechConfig config,
  Uint8List bytes,
) async {
  config.requireResolvedPaths();
  final outputPath = path.normalize(config.ttsOutputPath);
  await _createOutputParentSafely(
    outputPath,
    config.resolvedAppCacheDirectoryPath,
  );
  if (await _safeEntityType(outputPath, 'ttsOutput') !=
      FileSystemEntityType.notFound) {
    throw StateError(
      'The configured TTS output already exists; refusing to overwrite or '
      'delete it.',
    );
  }

  final output = File(outputPath);
  var created = false;
  RandomAccessFile? handle;
  Object? firstError;
  StackTrace? firstStackTrace;
  try {
    await output.create(exclusive: true);
    created = true;
    if (await _safeEntityType(outputPath, 'ttsOutput') !=
        FileSystemEntityType.file) {
      throw StateError('The newly created TTS output is not a regular file.');
    }
    final canonical = path.normalize(await output.resolveSymbolicLinks());
    if (!path.equals(canonical, outputPath)) {
      throw StateError('The TTS output changed after exclusive creation.');
    }
    handle = await output.open(mode: FileMode.writeOnly);
    await handle.writeFrom(bytes);
    await handle.flush();
  } catch (error, stackTrace) {
    firstError = error;
    firstStackTrace = stackTrace;
  }
  try {
    await handle?.close();
  } catch (error, stackTrace) {
    firstError ??= error;
    firstStackTrace ??= stackTrace;
  }
  if (firstError != null) {
    if (created &&
        await _safeEntityType(outputPath, 'ttsOutput') ==
            FileSystemEntityType.file) {
      try {
        final canonical = path.normalize(await output.resolveSymbolicLinks());
        if (path.equals(canonical, outputPath)) {
          await output.delete();
        }
      } on FileSystemException {
        // Preserve the write failure. A later run will fail closed on the
        // pre-existing output instead of overwriting it.
      }
    }
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
  return output;
}

/// Deletes only the exact canonical regular file created by this harness.
Future<void> deletePhysicalIosSpeechOutput(
  PhysicalIosSpeechConfig config,
) async {
  final outputPath = path.normalize(config.ttsOutputPath);
  if (await _safeEntityType(outputPath, 'ttsOutput') !=
      FileSystemEntityType.file) {
    throw StateError('Refusing to delete a non-regular TTS output.');
  }
  final canonical = path.normalize(
    await File(outputPath).resolveSymbolicLinks(),
  );
  if (!path.equals(canonical, outputPath)) {
    throw StateError('Refusing to delete a replaced TTS output.');
  }
  try {
    await File(outputPath).delete();
  } on FileSystemException {
    throw const FileSystemException('Unable to delete the TTS output safely.');
  }
}

/// Fails one row when any of its immutable input labels failed preflight.
void requireValidSpeechArtifacts(
  Map<String, PhysicalIosSpeechArtifactFailure> failures,
  Set<String> requiredLabels,
) {
  final failedLabels =
      requiredLabels.where(failures.containsKey).toList(growable: false)
        ..sort();
  if (failedLabels.isEmpty) {
    return;
  }
  throw StateError(
    'Immutable artifact validation failed for labels: '
    '${failedLabels.join(', ')}.',
  );
}

/// Computes SHA-256 sequentially from a cancellable file stream.
Future<String> computeFileSha256(String path, {Duration? timeout}) async {
  final file = File(path);
  final stopwatch = Stopwatch()..start();

  Future<T> withinDeadline<T>(Future<T> Function() operation) {
    final bound = timeout;
    if (bound == null) {
      return operation();
    }
    final remaining = bound - stopwatch.elapsed;
    if (remaining <= Duration.zero) {
      return Future<T>.error(
        TimeoutException('Artifact SHA-256 verification timed out.', bound),
      );
    }
    return operation().timeout(
      remaining,
      onTimeout: () => throw TimeoutException(
        'Artifact SHA-256 verification timed out.',
        bound,
      ),
    );
  }

  final digestSink = _SpeechDigestSink();
  var digestSinkClosed = false;
  final inputSink = sha256.startChunkedConversion(digestSink);
  StreamSubscription<List<int>>? subscription;
  Timer? deadlineTimer;
  Object? firstError;
  StackTrace? firstStackTrace;

  void closeDigestSink() {
    if (!digestSinkClosed) {
      inputSink.close();
      digestSinkClosed = true;
    }
  }

  try {
    final initialType = await withinDeadline(
      () => FileSystemEntity.type(path, followLinks: false),
    );
    if (initialType != FileSystemEntityType.file) {
      throw const FileSystemException('Artifact path is not a regular file.');
    }
    final initialCanonicalPath = await withinDeadline(
      file.resolveSymbolicLinks,
    );
    final initialStat = await withinDeadline(file.stat);
    final streamDone = Completer<void>();

    void completeStreamError(Object error, StackTrace stackTrace) {
      if (!streamDone.isCompleted) {
        streamDone.completeError(error, stackTrace);
      }
    }

    subscription = file.openRead().listen(
      (chunk) {
        try {
          inputSink.add(chunk);
        } catch (error, stackTrace) {
          completeStreamError(error, stackTrace);
          unawaited(subscription?.cancel());
        }
      },
      onError: completeStreamError,
      onDone: () {
        if (streamDone.isCompleted) {
          return;
        }
        try {
          closeDigestSink();
          streamDone.complete();
        } catch (error, stackTrace) {
          completeStreamError(error, stackTrace);
        }
      },
      cancelOnError: true,
    );
    final bound = timeout;
    if (bound != null) {
      final remaining = bound - stopwatch.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException(
          'Artifact SHA-256 verification timed out.',
          bound,
        );
      }
      deadlineTimer = Timer(remaining, () {
        completeStreamError(
          TimeoutException('Artifact SHA-256 verification timed out.', bound),
          StackTrace.current,
        );
        unawaited(subscription?.cancel());
      });
    }
    await streamDone.future;

    final finalType = await withinDeadline(
      () => FileSystemEntity.type(path, followLinks: false),
    );
    final finalCanonicalPath = await withinDeadline(file.resolveSymbolicLinks);
    final finalStat = await withinDeadline(file.stat);
    if (finalType != FileSystemEntityType.file ||
        finalCanonicalPath != initialCanonicalPath ||
        finalStat.type != initialStat.type ||
        finalStat.size != initialStat.size ||
        finalStat.modified != initialStat.modified ||
        finalStat.changed != initialStat.changed) {
      throw StateError(
        'Artifact identity changed during SHA-256 verification.',
      );
    }
  } catch (error, stackTrace) {
    firstError = error;
    firstStackTrace = stackTrace;
  }

  deadlineTimer?.cancel();
  try {
    await subscription?.cancel().timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException(
        'Artifact SHA-256 stream cleanup timed out.',
        const Duration(seconds: 5),
      ),
    );
  } catch (error, stackTrace) {
    firstError ??= error;
    firstStackTrace ??= stackTrace;
  }
  try {
    closeDigestSink();
  } catch (error, stackTrace) {
    firstError ??= error;
    firstStackTrace ??= stackTrace;
  }

  final error = firstError;
  if (error != null) {
    if (error is FileSystemException) {
      throw const FileSystemException(
        'Artifact file cannot be read for SHA-256 verification.',
      );
    }
    Error.throwWithStackTrace(error, firstStackTrace!);
  }
  return digestSink.digest.toString().toLowerCase();
}

class _SpeechDigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get digest =>
      _digest ?? (throw StateError('SHA-256 conversion did not complete.'));

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}

/// Verifies that [path] exists and its SHA-256 matches [expectedSha256].
Future<void> validateFileChecksum(
  String path,
  String expectedSha256, {
  Duration? timeout,
}) async {
  final actual = await computeFileSha256(path, timeout: timeout);
  if (actual != expectedSha256.toLowerCase()) {
    throw StateError('Checksum mismatch for immutable artifact.');
  }
}

/// Normalizes transcript text by trimming, lowercasing, and collapsing runs of
/// whitespace. No other transformation is applied.
String normalizeSpeechTranscript(String raw) =>
    raw.trim().toLowerCase().replaceAll(_whitespaceRun, ' ');

/// A short content-addressed fingerprint of a transcript.
///
/// Diagnostics reference transcripts by fingerprint so a failing device run
/// never prints captured speech into logs or result records.
String transcriptFingerprint(String raw) => sha256
    .convert(utf8.encode(normalizeSpeechTranscript(raw)))
    .toString()
    .substring(0, 12);

/// Asserts exact normalized transcript equality without echoing either value.
void expectExactNormalizedTranscript({
  required String actual,
  required String expected,
  required String label,
}) {
  final normalizedActual = normalizeSpeechTranscript(actual);
  final normalizedExpected = normalizeSpeechTranscript(expected);
  if (normalizedActual == normalizedExpected) {
    return;
  }
  throw StateError(
    'Transcript mismatch at $label: '
    'actualSha=${transcriptFingerprint(actual)} '
    'actualChars=${normalizedActual.length} '
    'expectedSha=${transcriptFingerprint(expected)} '
    'expectedChars=${normalizedExpected.length}',
  );
}

/// Reduces free-form error text to a single safe, bounded log field.
String sanitizeSpeechDiagnostic(String raw, {int maxLength = 240}) {
  final collapsed = raw
      .replaceAll(_controlCharacters, ' ')
      .replaceAll(_whitespaceRun, ' ')
      .trim();
  if (collapsed.isEmpty) {
    return '<empty>';
  }
  if (collapsed.length <= maxLength) {
    return collapsed;
  }
  return '${collapsed.substring(0, math.max(0, maxLength - 3))}...';
}

/// Produces a bounded error code without echoing paths, URLs, prompts, or
/// transcripts from an exception message.
String safeSpeechErrorDiagnostic(Object error) {
  if (error is AudioRecordingException) {
    return '${error.runtimeType}:${error.failure.name}';
  }
  final type = error.runtimeType.toString().replaceAll(
    RegExp(r'[^A-Za-z0-9_]'),
    '_',
  );
  final fingerprint = sha256
      .convert(utf8.encode(error.toString()))
      .toString()
      .substring(0, 12);
  return '$type#$fingerprint';
}

/// Awaits [future] with an actionable timeout naming [what].
Future<T> awaitBounded<T>(Future<T> future, Duration timeout, String what) {
  return future.timeout(
    timeout,
    onTimeout: () => throw TimeoutException(
      '$what did not settle within ${timeout.inMilliseconds} ms. Re-run on the '
      'physical device with the pinned artifacts, or raise the bound if the '
      'model legitimately needs longer.',
      timeout,
    ),
  );
}

/// Subscribes immediately and marks stream errors handled while preserving
/// them for the caller that later awaits the returned future.
Future<List<T>> collectSpeechEvents<T>(Stream<T> events) {
  final collected = events.toList();
  unawaited(collected.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  return collected;
}

/// Always runs [cleanup] and preserves a failure from [body] over cleanup.
Future<void> runWithSpeechCleanup({
  required Future<void> Function() body,
  required Future<void> Function() cleanup,
}) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  try {
    await body();
  } catch (error, stackTrace) {
    firstError = error;
    firstStackTrace = stackTrace;
  }
  try {
    await cleanup();
  } catch (error, stackTrace) {
    firstError ??= error;
    firstStackTrace ??= stackTrace;
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}

/// Proves [done] has not already settled before active cancellation is issued.
Future<void> requireStillActiveBeforeCancellation<T>(
  Future<T> done,
  Duration observationWindow,
  String label,
) async {
  var settled = false;
  unawaited(
    done.then<void>(
      (_) => settled = true,
      onError: (Object _, StackTrace _) => settled = true,
    ),
  );
  await Future<void>.delayed(observationWindow);
  if (settled) {
    throw StateError(
      '$label settled before the active-cancellation observation point.',
    );
  }
}

/// Whether [path] has the public executable-path shape of a physical iOS app.
///
/// Simulator executables live on the macOS host. Physical app executables live
/// below the iOS bundle-installation root. This is deliberately a lexical,
/// fail-closed check over [Platform.resolvedExecutable], with no private FFI or
/// device identifier in diagnostics.
bool isPhysicalIosApplicationExecutablePath(String path) {
  final root = _physicalIosApplicationRoots.where(path.startsWith).firstOrNull;
  if (root == null) {
    return false;
  }
  final segments = path.substring(root.length).split('/');
  return segments.length >= 3 &&
      segments.every(
        (segment) =>
            segment.isNotEmpty &&
            segment != '.' &&
            segment != '..' &&
            !_rejectedPathCharacters.hasMatch(segment) &&
            !_controlCharacters.hasMatch(segment) &&
            segment.trim() == segment,
      ) &&
      segments[1].length > '.app'.length &&
      segments[1].endsWith('.app');
}

/// Backend family expected by one physical speech row.
enum SpeechE2EBackendKind { llamaCppCpu, liteRtLmAsrCpu, liteRtLm }

/// Validates backend identity and returns a stable, sanitized report label.
String requireSpeechBackendIdentity(
  String actual,
  SpeechE2EBackendKind expected,
) {
  final normalized = actual.trim().toLowerCase();
  final matches = switch (expected) {
    SpeechE2EBackendKind.llamaCppCpu => actual == 'CPU',
    SpeechE2EBackendKind.liteRtLmAsrCpu =>
      normalized.contains('litert-lm') &&
          normalized.contains('asr') &&
          normalized.contains('cpu'),
    SpeechE2EBackendKind.liteRtLm =>
      normalized.contains('litert-lm') && !normalized.contains('asr'),
  };
  if (!matches) {
    throw StateError(
      'Runtime backend identity did not match ${expected.name}: '
      'actualSha=${transcriptFingerprint(actual)}.',
    );
  }
  return switch (expected) {
    SpeechE2EBackendKind.llamaCppCpu => 'llama.cpp CPU',
    SpeechE2EBackendKind.liteRtLmAsrCpu => 'LiteRT-LM ASR CPU',
    SpeechE2EBackendKind.liteRtLm => 'LiteRT-LM',
  };
}

/// Splits [samples] into bounded chunks so no single push carries the whole
/// fixture into the native session queue.
Iterable<Float32List> chunkPcmSamples(
  Float32List samples,
  int chunkSize,
) sync* {
  if (chunkSize <= 0) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'Must be positive.');
  }
  if (samples.isEmpty) {
    throw ArgumentError.value(
      samples.length,
      'samples',
      'Refusing to stream an empty PCM buffer.',
    );
  }
  for (var offset = 0; offset < samples.length; offset += chunkSize) {
    final end = math.min(offset + chunkSize, samples.length);
    yield Float32List.sublistView(samples, offset, end);
  }
}

/// Extracted PCM16 signal metrics from a WAV file.
class WavPcm16Info {
  final int sampleRate;
  final int channels;
  final int sampleFrames;
  final int peakAmplitude;
  final double rmsAmplitude;
  final double durationSeconds;
  final int dataOffset;
  final int dataLength;

  const WavPcm16Info({
    required this.sampleRate,
    required this.channels,
    required this.sampleFrames,
    required this.peakAmplitude,
    required this.rmsAmplitude,
    required this.durationSeconds,
    required this.dataOffset,
    required this.dataLength,
  });
}

/// Creates a standard PCM16 WAV byte buffer.
Uint8List createPcm16WavBytes({
  required List<int> samples,
  required int sampleRate,
  required int channels,
}) {
  const bytesPerSample = 2;
  if (sampleRate <= 0) {
    throw ArgumentError.value(sampleRate, 'sampleRate', 'Must be positive.');
  }
  if (channels <= 0) {
    throw ArgumentError.value(channels, 'channels', 'Must be positive.');
  }
  if (samples.isEmpty || samples.length % channels != 0) {
    throw ArgumentError.value(
      samples.length,
      'samples',
      'Must contain at least one whole interleaved PCM frame.',
    );
  }
  if (samples.any((sample) => sample < -32768 || sample > 32767)) {
    throw ArgumentError.value(
      samples.length,
      'samples',
      'Every PCM16 sample must be between -32768 and 32767.',
    );
  }
  final dataLength = samples.length * bytesPerSample;
  final byteRate = sampleRate * channels * bytesPerSample;
  final blockAlign = channels * bytesPerSample;
  if (sampleRate > 0xffffffff ||
      channels > 0xffff ||
      byteRate > 0xffffffff ||
      blockAlign > 0xffff ||
      dataLength > 0xffffffff - 36) {
    throw ArgumentError(
      'PCM metadata exceeds the canonical RIFF/WAV integer fields.',
    );
  }
  final bytes = Uint8List(44 + dataLength);
  final data = ByteData.sublistView(bytes);

  void writeAscii(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes[offset + i] = value.codeUnitAt(i);
    }
  }

  writeAscii(0, 'RIFF');
  data.setUint32(4, 36 + dataLength, Endian.little);
  writeAscii(8, 'WAVE');
  writeAscii(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little); // PCM format
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, byteRate, Endian.little);
  data.setUint16(32, blockAlign, Endian.little);
  data.setUint16(34, 16, Endian.little); // bits per sample
  writeAscii(36, 'data');
  data.setUint32(40, dataLength, Endian.little);

  for (var i = 0; i < samples.length; i++) {
    data.setInt16(44 + i * bytesPerSample, samples[i], Endian.little);
  }
  return bytes;
}

/// Parses and strictly validates a PCM16 WAV byte array.
///
/// Every structural field is cross-checked, because a partially written or
/// re-encoded capture must fail here rather than silently degrade a transcript.
WavPcm16Info validatePcm16Wav(
  Uint8List bytes, {
  int? expectedSampleRate,
  int? expectedChannels,
  bool requireNonSilent = true,
}) {
  const bytesPerSample = 2;
  final fileLength = bytes.length;
  if (fileLength < 44 ||
      bytes[0] != 0x52 ||
      bytes[1] != 0x49 ||
      bytes[2] != 0x46 ||
      bytes[3] != 0x46 ||
      bytes[8] != 0x57 ||
      bytes[9] != 0x41 ||
      bytes[10] != 0x56 ||
      bytes[11] != 0x45) {
    throw const FormatException('Invalid or incomplete RIFF/WAVE header.');
  }

  final data = ByteData.sublistView(bytes);
  final riffSize = data.getUint32(4, Endian.little);
  if (riffSize != fileLength - 8) {
    throw FormatException(
      'RIFF size field ($riffSize) disagrees with the file length '
      '(${fileLength - 8}).',
    );
  }

  int? sampleRate;
  int? channels;
  int? dataOffset;
  int? dataLength;
  var sawFmt = false;
  var sawData = false;
  var offset = 12;

  while (offset + 8 <= fileLength) {
    final chunkSize = data.getUint32(offset + 4, Endian.little);
    final payloadOffset = offset + 8;
    final payloadEnd = payloadOffset + chunkSize;
    final paddedEnd = payloadEnd + (chunkSize.isOdd ? 1 : 0);
    if (payloadEnd > fileLength) {
      throw const FormatException('WAV chunk exceeds file length boundary.');
    }
    if (paddedEnd > fileLength) {
      throw const FormatException(
        'Odd-sized WAV chunk is missing its pad byte.',
      );
    }

    final chunkId = String.fromCharCodes(bytes.sublist(offset, offset + 4));
    if (chunkId == 'fmt ') {
      if (sawFmt) {
        throw const FormatException('Duplicate fmt chunk in WAV file.');
      }
      sawFmt = true;
      if (chunkSize < 16) {
        throw const FormatException('fmt chunk too small.');
      }
      final audioFormat = data.getUint16(payloadOffset, Endian.little);
      if (audioFormat != 1) {
        throw FormatException(
          'WAV is not uncompressed PCM (format $audioFormat).',
        );
      }
      final bitsPerSample = data.getUint16(payloadOffset + 14, Endian.little);
      if (bitsPerSample != 16) {
        throw FormatException('WAV is not 16-bit PCM ($bitsPerSample bits).');
      }
      channels = data.getUint16(payloadOffset + 2, Endian.little);
      if (channels < 1) {
        throw const FormatException('WAV declares zero channels.');
      }
      sampleRate = data.getUint32(payloadOffset + 4, Endian.little);
      if (sampleRate < 1) {
        throw const FormatException('WAV declares a zero sample rate.');
      }
      final byteRate = data.getUint32(payloadOffset + 8, Endian.little);
      final expectedByteRate = sampleRate * channels * bytesPerSample;
      if (byteRate != expectedByteRate) {
        throw FormatException(
          'WAV byte rate ($byteRate) disagrees with rate * channels * 2 '
          '($expectedByteRate).',
        );
      }
      final blockAlign = data.getUint16(payloadOffset + 12, Endian.little);
      final expectedBlockAlign = channels * bytesPerSample;
      if (blockAlign != expectedBlockAlign) {
        throw FormatException(
          'WAV block align ($blockAlign) disagrees with channels * 2 '
          '($expectedBlockAlign).',
        );
      }
    } else if (chunkId == 'data') {
      if (sawData) {
        throw const FormatException('Duplicate data chunk in WAV file.');
      }
      if (!sawFmt) {
        throw const FormatException('WAV data chunk appears before fmt chunk.');
      }
      sawData = true;
      dataOffset = payloadOffset;
      dataLength = chunkSize;
    }

    offset = paddedEnd;
  }

  if (offset != fileLength) {
    throw const FormatException('Unclaimed trailing bytes after final chunk.');
  }
  if (!sawFmt || !sawData) {
    throw const FormatException('Missing fmt or data chunk in WAV file.');
  }

  final resolvedRate = sampleRate!;
  final resolvedChannels = channels!;
  final resolvedOffset = dataOffset!;
  final resolvedLength = dataLength!;

  if (resolvedLength == 0) {
    throw const FormatException('WAV data chunk is empty.');
  }
  if (resolvedLength.isOdd) {
    throw FormatException(
      'WAV data length ($resolvedLength) is not a whole number of 16-bit '
      'samples.',
    );
  }
  final frameBytes = resolvedChannels * bytesPerSample;
  if (resolvedLength % frameBytes != 0) {
    throw FormatException(
      'WAV data length ($resolvedLength) is not a whole number of '
      '$resolvedChannels-channel frames.',
    );
  }

  if (expectedSampleRate != null && resolvedRate != expectedSampleRate) {
    throw FormatException(
      'WAV sample rate mismatch: expected $expectedSampleRate Hz, got '
      '$resolvedRate Hz.',
    );
  }
  if (expectedChannels != null && resolvedChannels != expectedChannels) {
    throw FormatException(
      'WAV channel count mismatch: expected $expectedChannels, got '
      '$resolvedChannels.',
    );
  }

  final sampleCount = resolvedLength ~/ bytesPerSample;
  var peak = 0;
  var sumSquares = 0.0;
  for (var i = 0; i < sampleCount; i++) {
    final sample = data.getInt16(
      resolvedOffset + i * bytesPerSample,
      Endian.little,
    );
    final mag = sample.abs();
    if (mag > peak) {
      peak = mag;
    }
    sumSquares += sample * sample;
  }

  final rms = math.sqrt(sumSquares / sampleCount);
  if (requireNonSilent && (peak == 0 || rms == 0.0)) {
    throw const FormatException('WAV audio contains only silent samples.');
  }

  return WavPcm16Info(
    sampleRate: resolvedRate,
    channels: resolvedChannels,
    sampleFrames: sampleCount ~/ resolvedChannels,
    peakAmplitude: peak,
    rmsAmplitude: rms,
    durationSeconds: (sampleCount ~/ resolvedChannels) / resolvedRate,
    dataOffset: resolvedOffset,
    dataLength: resolvedLength,
  );
}

/// Parses a PCM16 WAV file and returns normalized [-1.0, 1.0] float samples.
Float32List decodePcm16WavToFloat32(
  Uint8List bytes, {
  int? expectedSampleRate,
  int? expectedChannels,
  bool requireNonSilent = true,
}) {
  final info = validatePcm16Wav(
    bytes,
    expectedSampleRate: expectedSampleRate,
    expectedChannels: expectedChannels,
    requireNonSilent: requireNonSilent,
  );

  final data = ByteData.sublistView(bytes);
  final sampleCount = info.dataLength ~/ 2;
  final floatSamples = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    floatSamples[i] =
        data.getInt16(info.dataOffset + i * 2, Endian.little) / 32768.0;
  }
  return floatSamples;
}

/// Asserts that a synthesis result's frame, sample, and duration values agree.
void validateTtsResultPlausibility({
  required int framesGenerated,
  required int maxFrames,
  required int sampleFrames,
  required int sampleRateHz,
  required int channelCount,
  required Duration duration,
  required String label,
}) {
  void fail(String reason) => throw StateError('$label: $reason');

  if (sampleRateHz <= 0) {
    fail('sample rate must be positive, got $sampleRateHz.');
  }
  if (channelCount <= 0) {
    fail('channel count must be positive, got $channelCount.');
  }
  if (framesGenerated <= 0) {
    fail('expected a positive frame count, got $framesGenerated.');
  }
  if (framesGenerated > maxFrames) {
    fail('generated $framesGenerated frames beyond the cap of $maxFrames.');
  }
  if (sampleFrames <= 0) {
    fail('decoded audio is empty ($sampleFrames frames).');
  }
  final expectedSeconds = sampleFrames / sampleRateHz;
  final actualSeconds =
      duration.inMicroseconds / Duration.microsecondsPerSecond;
  if ((actualSeconds - expectedSeconds).abs() > 0.01) {
    fail(
      'duration ${actualSeconds.toStringAsFixed(3)}s contradicts $sampleFrames '
      'frames at $sampleRateHz Hz '
      '(${expectedSeconds.toStringAsFixed(3)}s).',
    );
  }
  if (!actualSeconds.isFinite || actualSeconds <= 0) {
    fail('duration must be finite and positive, got $actualSeconds s.');
  }
}

/// Canonical identifiers for the four validated speech rows.
const List<String> speechE2ERowIdsInOrder = <String>[
  'llama_cpp_qwen3_asr',
  'litert_lm_streaming_asr',
  'llama_cpp_qwen3_tts',
  'litert_lm_tts',
];

/// Canonical identifiers for set-based validation.
const Set<String> speechE2ERowIds = <String>{...speechE2ERowIdsInOrder};

/// Selector value that runs the complete physical-iOS speech matrix.
const String physicalIosSpeechAllRows = 'all';

/// Parses the optional row selector while preserving canonical row ordering.
///
/// The selector is intentionally exact and case-sensitive. An omitted
/// `IOS_SPEECH_ROW` define is supplied as [physicalIosSpeechAllRows] by the
/// integration target; an explicit invalid value fails closed rather than
/// silently running a different subset.
List<String> selectPhysicalIosSpeechRowIds(String rawSelection) {
  if (rawSelection.isEmpty || rawSelection != rawSelection.trim()) {
    throw ArgumentError.value(
      rawSelection,
      PhysicalIosSpeechEnvKeys.rowSelection,
      'Expected "$physicalIosSpeechAllRows" or one canonical speech row id '
      'without surrounding whitespace.',
    );
  }
  if (rawSelection == physicalIosSpeechAllRows) {
    return List<String>.unmodifiable(speechE2ERowIdsInOrder);
  }
  if (!speechE2ERowIds.contains(rawSelection)) {
    throw ArgumentError.value(
      rawSelection,
      PhysicalIosSpeechEnvKeys.rowSelection,
      'Expected "$physicalIosSpeechAllRows" or one of '
      '${speechE2ERowIdsInOrder.join(', ')}.',
    );
  }
  return <String>[rawSelection];
}

/// Stable sanitized backend label used before a row resolves its live backend.
String unresolvedSpeechBackendForRow(String id) => switch (id) {
  'llama_cpp_qwen3_asr' || 'llama_cpp_qwen3_tts' => 'llama.cpp CPU',
  'litert_lm_streaming_asr' => 'LiteRT-LM ASR CPU',
  'litert_lm_tts' => 'LiteRT-LM',
  _ => '<unresolved>',
};

/// Marker that tells the operator a run was blocked by device permissions
/// rather than by a defect in the library.
const String microphonePermissionActionMarker =
    'ACTION_REQUIRED_MICROPHONE_PERMISSION';

/// Marker for a runtime that has no microphone recorder at all.
const String microphoneUnavailableActionMarker =
    'ACTION_REQUIRED_MICROPHONE_UNAVAILABLE';

/// Status classification for an integration test row.
enum SpeechE2ERowStatus { pass, fail, unsupported, unavailable }

/// Classifies a row failure as an environment gap or a genuine defect.
SpeechE2ERowStatus classifySpeechRowFailure(Object error) {
  if (error is AudioRecordingException) {
    switch (error.failure) {
      case AudioRecordingFailure.permissionDenied:
      case AudioRecordingFailure.unsupported:
        return SpeechE2ERowStatus.unavailable;
      case AudioRecordingFailure.startFailed:
      case AudioRecordingFailure.stopFailed:
      case AudioRecordingFailure.readFailed:
        return SpeechE2ERowStatus.fail;
    }
  }
  return SpeechE2ERowStatus.fail;
}

/// Returns the operator-facing action marker for [error], when one applies.
String? speechRowFailureMarker(Object error) {
  if (error is AudioRecordingException) {
    switch (error.failure) {
      case AudioRecordingFailure.permissionDenied:
        return microphonePermissionActionMarker;
      case AudioRecordingFailure.unsupported:
        return microphoneUnavailableActionMarker;
      case AudioRecordingFailure.startFailed:
      case AudioRecordingFailure.stopFailed:
      case AudioRecordingFailure.readFailed:
        return null;
    }
  }
  return null;
}

/// A recorded row result with machine-readable serialization.
class SpeechE2ERowResult {
  final String id;
  final SpeechE2ERowStatus status;
  final String backend;
  final Duration duration;
  final Map<String, String> digestIdentifiers;
  final String assertionSummary;
  final Object? error;
  final String? actionMarker;

  SpeechE2ERowResult({
    required this.id,
    required this.status,
    required this.backend,
    required this.duration,
    this.digestIdentifiers = const <String, String>{},
    this.assertionSummary = '',
    this.error,
    this.actionMarker,
  });

  /// Emits one JSON record so backend labels and errors containing spaces or
  /// quotes stay parseable.
  String toResultLine() {
    final rawError = this.error;
    final error = rawError == null ? null : safeSpeechErrorDiagnostic(rawError);
    final record = <String, Object?>{
      'id': id,
      'status': status.name.toUpperCase(),
      'backend': sanitizeSpeechDiagnostic(backend, maxLength: 120),
      'elapsedMs': duration.inMilliseconds,
      'digests': digestIdentifiers,
      'assertions': sanitizeSpeechDiagnostic(assertionSummary, maxLength: 400),
      'error': ?error,
      'action': ?actionMarker,
    };
    return 'RESULT physical_ios_speech ${jsonEncode(record)}';
  }
}

/// Aggregate summary of all speech E2E rows.
class SpeechE2ESummary {
  final List<SpeechE2ERowResult> rows;

  SpeechE2ESummary(this.rows);

  int get total => rows.length;
  int get passCount => _count(SpeechE2ERowStatus.pass);
  int get failCount => _count(SpeechE2ERowStatus.fail);
  int get unsupportedCount => _count(SpeechE2ERowStatus.unsupported);
  int get unavailableCount => _count(SpeechE2ERowStatus.unavailable);

  int _count(SpeechE2ERowStatus status) =>
      rows.where((r) => r.status == status).length;

  String toSummaryLine() =>
      'SUMMARY physical_ios_speech total=$total pass=$passCount '
      'unsupported=$unsupportedCount fail=$failCount '
      'unavailable=$unavailableCount';

  /// Verifies each canonical row was recorded exactly once and nothing else was.
  void validateRowIds({Set<String> expectedIds = speechE2ERowIds}) {
    final seen = <String>{};
    final duplicates = <String>{};
    for (final row in rows) {
      if (!seen.add(row.id)) {
        duplicates.add(row.id);
      }
    }
    if (duplicates.isNotEmpty) {
      throw StateError(
        'Duplicate speech E2E row ids recorded: '
        '${(duplicates.toList()..sort()).join(', ')}',
      );
    }
    final missing = expectedIds.difference(seen);
    final unexpected = seen.difference(expectedIds);
    if (missing.isNotEmpty || unexpected.isNotEmpty) {
      throw StateError(
        'Speech E2E row id validation failed. '
        'Missing: ${missing.isEmpty ? '<none>' : (missing.toList()..sort()).join(', ')}. '
        'Unexpected: ${unexpected.isEmpty ? '<none>' : (unexpected.toList()..sort()).join(', ')}.',
      );
    }
  }

  /// Validates the exact row set and strict statuses for a full or selected
  /// physical-iOS speech run.
  void validateSelectedRows(Set<String> expectedIds) {
    if (expectedIds.isEmpty || !speechE2ERowIds.containsAll(expectedIds)) {
      throw StateError(
        'Expected one or more canonical physical-iOS speech row ids.',
      );
    }
    validateRowIds(expectedIds: expectedIds);
    final expectedUnsupported = expectedIds.contains('litert_lm_tts') ? 1 : 0;
    validateStrictCounts(
      expectedTotal: expectedIds.length,
      expectedPass: expectedIds.length - expectedUnsupported,
      expectedUnsupported: expectedUnsupported,
    );
  }

  void validateStrictCounts({
    int expectedTotal = 4,
    int expectedPass = 3,
    int expectedUnsupported = 1,
    int expectedFail = 0,
    int expectedUnavailable = 0,
  }) {
    if (total != expectedTotal ||
        passCount != expectedPass ||
        unsupportedCount != expectedUnsupported ||
        failCount != expectedFail ||
        unavailableCount != expectedUnavailable) {
      throw StateError(
        'Speech E2E count validation failed. Expected total=$expectedTotal, '
        'pass=$expectedPass, unsupported=$expectedUnsupported, '
        'fail=$expectedFail, unavailable=$expectedUnavailable. '
        'Actual: total=$total, pass=$passCount, '
        'unsupported=$unsupportedCount, fail=$failCount, '
        'unavailable=$unavailableCount',
      );
    }
  }
}

/// Validates that an STT task ended in cancelled state.
bool verifySttCancellation(SpeechToTextCompletion completion) =>
    completion.state == SpeechToTextCompletionState.cancelled;

/// Validates that a TTS task ended in cancelled state.
bool verifyTtsCancellation(TextToSpeechCompletion completion) =>
    completion.state == TextToSpeechCompletionState.cancelled;

/// Whether [event] proves synthesis has produced real audio, so cancelling now
/// exercises an in-flight generation rather than the prompt prefill.
bool shouldCancelOnTtsProgress(TextToSpeechProgressEvent event) =>
    event.phase == TextToSpeechProgressPhase.generating &&
    event.framesGenerated > 0;

/// Evaluates LiteRT-LM TTS capabilities for expected unsupported status.
SpeechE2ERowStatus classifyLiteRtLmTtsSupport(
  TextToSpeechCapabilities capabilities,
) {
  requireSpeechBackendIdentity(
    capabilities.backendName ?? '',
    SpeechE2EBackendKind.liteRtLm,
  );
  if (capabilities.isSupported) {
    throw StateError(
      'LiteRT-LM TTS was unexpectedly supported by the runtime. Reclassify the '
      'row instead of recording a misleading UNSUPPORTED result.',
    );
  }
  final reason = capabilities.unsupportedReason?.trim();
  if (reason == null || reason.isEmpty) {
    throw StateError(
      'LiteRT-LM TTS reported isSupported=false without an actionable '
      'unsupportedReason.',
    );
  }
  return SpeechE2ERowStatus.unsupported;
}

/// Verifies that LiteRT-LM TTS synthesis threw [LlamaUnsupportedException].
bool verifyLiteRtLmTtsSynthesisError(Object error) {
  if (error is LlamaUnsupportedException) {
    return true;
  }
  throw StateError(
    'Expected LlamaUnsupportedException for LiteRT-LM TTS synthesis, but '
    'received ${safeSpeechErrorDiagnostic(error)}.',
  );
}
