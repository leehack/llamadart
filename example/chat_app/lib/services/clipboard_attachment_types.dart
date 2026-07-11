import 'dart:async';
import 'dart:typed_data';

/// Maximum accepted clipboard attachment size.
const int maxClipboardAttachmentBytes = 64 * 1024 * 1024;

/// The media type represented by a clipboard attachment.
enum ClipboardAttachmentKind { image, audio }

const Set<String> _imageExtensions = {
  'png',
  'jpg',
  'jpeg',
  'webp',
  'gif',
  'bmp',
  'heic',
  'heif',
  'tif',
  'tiff',
};

const Set<String> _audioExtensions = {
  'mp3',
  'm4a',
  'aac',
  'wav',
  'ogg',
  'oga',
  'opus',
  'flac',
};

/// Infers a supported clipboard attachment type from MIME or filename data.
ClipboardAttachmentKind? inferClipboardAttachmentKind({
  String? mimeType,
  String? fileName,
}) {
  final normalizedMime = mimeType?.toLowerCase() ?? '';
  if (normalizedMime.startsWith('image/')) {
    return ClipboardAttachmentKind.image;
  }
  if (normalizedMime.startsWith('audio/')) {
    return ClipboardAttachmentKind.audio;
  }

  final normalizedName = fileName?.toLowerCase() ?? '';
  final dot = normalizedName.lastIndexOf('.');
  if (dot < 0 || dot == normalizedName.length - 1) {
    return null;
  }
  final extension = normalizedName.substring(dot + 1);
  if (_imageExtensions.contains(extension)) {
    return ClipboardAttachmentKind.image;
  }
  if (_audioExtensions.contains(extension)) {
    return ClipboardAttachmentKind.audio;
  }
  return null;
}

/// Media bytes read from the system clipboard.
class ClipboardAttachment {
  /// Whether the attachment contains image or audio data.
  final ClipboardAttachmentKind kind;

  /// The attachment payload.
  final Uint8List bytes;

  /// Creates a clipboard attachment.
  const ClipboardAttachment({required this.kind, required this.bytes});
}

/// Clipboard content that can be staged or inserted into the composer.
class ClipboardPasteContent {
  /// Media attachments supplied by the clipboard.
  final List<ClipboardAttachment> attachments;

  /// Plain text used as the fallback for an ordinary text paste.
  final String? plainText;

  /// Creates clipboard paste content.
  const ClipboardPasteContent({this.attachments = const [], this.plainText});

  /// The first selected attachment, when one is available.
  ClipboardAttachment? get attachment =>
      attachments.isEmpty ? null : attachments.first;
}

/// Reads the clipboard content associated with a browser paste event.
typedef ClipboardPasteReader =
    Future<ClipboardPasteContent> Function({
      required bool allowImage,
      required bool allowAudio,
    });

/// Receives a lazy browser paste-event reader.
typedef ClipboardPasteEventListener =
    void Function(ClipboardPasteReader reader);

/// A user-actionable clipboard attachment failure.
class ClipboardAttachmentException implements Exception {
  /// The message suitable for display in the UI.
  final String message;

  /// Creates a clipboard attachment failure.
  const ClipboardAttachmentException(this.message);

  @override
  String toString() => message;
}

/// Throws when clipboard media exceeds the supported size limit.
void validateClipboardAttachmentSize(int bytes) {
  if (bytes > maxClipboardAttachmentBytes) {
    throw const ClipboardAttachmentException(
      'Clipboard attachment is larger than 64 MB.',
    );
  }
}
