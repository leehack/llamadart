/// Whether the typed speech-to-text adapter is available on Web.
bool get isSpeechToTextPlatformSupported => true;

/// Web support is refined by the active backend capability probe.
String? get speechToTextPlatformUnsupportedReason => null;

/// Web requires an explicitly validated bridge runtime.
bool get speechToTextRequiresBackendCapability => true;

/// Browsers do not expose local filesystem paths to the runtime.
bool get speechToTextSupportsFileInput => false;

/// Browser byte inputs must declare their encoded container.
bool get speechToTextRequiresEncodedAudioFormat => true;

/// WAV is the encoded format validated by the published WebGPU smoke.
Set<String> get speechToTextEncodedAudioFormats => const <String>{'wav'};
