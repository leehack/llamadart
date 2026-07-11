import 'clipboard_attachment_platform_stub.dart'
    if (dart.library.io) 'clipboard_attachment_platform_io.dart'
    if (dart.library.js_interop) 'clipboard_attachment_platform_web.dart'
    as platform;
import 'clipboard_attachment_types.dart';

export 'clipboard_attachment_types.dart';

/// Reads supported image, audio, and fallback text clipboard formats.
class ClipboardAttachmentService {
  /// Reads the current system clipboard when it is available.
  Future<ClipboardPasteContent?> readSystemClipboard({
    required bool allowImage,
    required bool allowAudio,
    required bool allowText,
  }) async {
    final content = await platform.readSystemClipboard(
      allowImage: allowImage,
      allowAudio: allowAudio,
      allowText: allowText,
    );
    if (content == null) {
      return null;
    }
    return selectSupportedContent(
      content,
      allowImage: allowImage,
      allowAudio: allowAudio,
    );
  }

  /// Keeps the first attachment supported by the active model.
  ClipboardPasteContent selectSupportedContent(
    ClipboardPasteContent content, {
    required bool allowImage,
    required bool allowAudio,
  }) {
    for (final attachment in content.attachments) {
      final supported = switch (attachment.kind) {
        ClipboardAttachmentKind.image => allowImage,
        ClipboardAttachmentKind.audio => allowAudio,
      };
      if (supported) {
        return ClipboardPasteContent(
          attachments: [attachment],
          plainText: content.plainText,
        );
      }
    }
    return ClipboardPasteContent(plainText: content.plainText);
  }

  /// Registers a browser paste-event listener when the platform supports it.
  void registerPasteEventListener(ClipboardPasteEventListener listener) {
    platform.registerPasteEventListener(listener);
  }

  /// Unregisters a browser paste-event listener.
  void unregisterPasteEventListener(ClipboardPasteEventListener listener) {
    platform.unregisterPasteEventListener(listener);
  }
}
