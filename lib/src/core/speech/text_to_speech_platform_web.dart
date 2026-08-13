/// Typed text-to-speech is not available in the published Web runtime.
const bool isTextToSpeechPlatformSupported = false;

/// Actionable reason returned by Web capability discovery.
const String textToSpeechPlatformUnsupportedReason =
    'Typed text-to-speech is not available on Web. The published WebGPU '
    'runtime does not export the native audio-generation ABI.';
