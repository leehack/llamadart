/// Whether the dedicated speech-to-text API is available on Web.
bool get isSpeechToTextPlatformSupported => false;

/// Actionable explanation for the current Web limitation.
String get speechToTextPlatformUnsupportedReason =>
    'Dedicated speech-to-text is not available on Web yet. WebGPU audio '
    'content remains model-dependent generic audio input.';
