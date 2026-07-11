import 'clipboard_attachment_types.dart';

/// Returns no clipboard content on unsupported platforms.
Future<ClipboardPasteContent?> readSystemClipboard({
  required bool allowImage,
  required bool allowAudio,
  required bool allowText,
}) async => null;

/// Browser paste events are unavailable on this platform.
void registerPasteEventListener(ClipboardPasteEventListener listener) {}

/// Browser paste events are unavailable on this platform.
void unregisterPasteEventListener(ClipboardPasteEventListener listener) {}
