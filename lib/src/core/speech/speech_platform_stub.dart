/// Whether the typed speech-to-text adapter is available on this platform.
bool get isSpeechToTextPlatformSupported => true;

/// Actionable explanation when speech-to-text is unavailable.
String? get speechToTextPlatformUnsupportedReason => null;

/// Whether this platform requires a backend runtime opt-in for prompt ASR.
bool get speechToTextRequiresBackendCapability => false;

/// Whether local filesystem speech input is available on this platform.
bool get speechToTextSupportsFileInput => true;

/// Whether byte inputs require explicit encoding metadata on this platform.
bool get speechToTextRequiresEncodedAudioFormat => false;

/// Encoded formats validated for prompt-adapted speech input.
Set<String> get speechToTextEncodedAudioFormats => const <String>{
  'wav',
  'mp3',
  'flac',
};
