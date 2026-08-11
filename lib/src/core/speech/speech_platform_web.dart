/// Whether the typed speech-to-text adapter is available on Web.
bool get isSpeechToTextPlatformSupported => false;

/// Actionable explanation for the current Web limitation.
String get speechToTextPlatformUnsupportedReason =>
    'Typed speech-to-text is not available on Web yet. WebGPU audio '
    'content remains model-dependent generic audio input.';
