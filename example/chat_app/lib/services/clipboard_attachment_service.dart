import 'dart:async';
import 'dart:typed_data';

import 'package:super_clipboard/super_clipboard.dart';

/// The media type represented by a clipboard attachment.
enum ClipboardAttachmentKind { image, audio }

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
  /// A supported media attachment, when one was available.
  final ClipboardAttachment? attachment;

  /// Plain text used as the fallback for an ordinary text paste.
  final String? plainText;

  /// Creates clipboard paste content.
  const ClipboardPasteContent({this.attachment, this.plainText});
}

/// A user-actionable clipboard attachment failure.
class ClipboardAttachmentException implements Exception {
  /// The message suitable for display in the UI.
  final String message;

  /// Creates a clipboard attachment failure.
  const ClipboardAttachmentException(this.message);

  @override
  String toString() => message;
}

/// Reads supported image, audio, and fallback text clipboard formats.
class ClipboardAttachmentService {
  /// Maximum accepted clipboard attachment size.
  static const int maxAttachmentBytes = 64 * 1024 * 1024;

  static const List<FileFormat> _imageFormats = [
    Formats.png,
    Formats.jpeg,
    Formats.webp,
    Formats.gif,
    Formats.bmp,
    Formats.heic,
    Formats.heif,
    Formats.tiff,
  ];

  static const List<FileFormat> _audioFormats = [
    Formats.mp3,
    Formats.m4a,
    Formats.aac,
    Formats.wav,
    Formats.ogg,
    Formats.oga,
    Formats.opus,
    Formats.flac,
  ];

  /// Reads the current system clipboard when it is available.
  Future<ClipboardPasteContent?> readSystemClipboard({
    required bool allowImage,
    required bool allowAudio,
  }) async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) {
      return null;
    }
    final reader = await clipboard.read();
    return read(reader, allowImage: allowImage, allowAudio: allowAudio);
  }

  /// Reads the first supported attachment or plain-text fallback from [reader].
  Future<ClipboardPasteContent> read(
    ClipboardReader reader, {
    required bool allowImage,
    required bool allowAudio,
  }) async {
    if (allowImage) {
      final image = await _readFirstAttachment(
        reader,
        formats: _imageFormats,
        kind: ClipboardAttachmentKind.image,
      );
      if (image != null) {
        return ClipboardPasteContent(attachment: image);
      }
    }

    if (allowAudio) {
      final audio = await _readFirstAttachment(
        reader,
        formats: _audioFormats,
        kind: ClipboardAttachmentKind.audio,
      );
      if (audio != null) {
        return ClipboardPasteContent(attachment: audio);
      }
    }

    final plainText = reader.canProvide(Formats.plainText)
        ? await reader.readValue(Formats.plainText)
        : null;
    return ClipboardPasteContent(plainText: plainText);
  }

  Future<ClipboardAttachment?> _readFirstAttachment(
    ClipboardReader reader, {
    required List<FileFormat> formats,
    required ClipboardAttachmentKind kind,
  }) async {
    for (final format in formats) {
      if (!reader.canProvide(format)) {
        continue;
      }
      final attachment = await _readAttachment(reader, format, kind);
      if (attachment != null) {
        return attachment;
      }
    }
    return null;
  }

  Future<ClipboardAttachment?> _readAttachment(
    ClipboardReader reader,
    FileFormat format,
    ClipboardAttachmentKind kind,
  ) {
    final completer = Completer<ClipboardAttachment?>();
    final progress = reader.getFile(
      format,
      (file) async {
        try {
          final fileSize = file.fileSize;
          if (fileSize != null && fileSize > maxAttachmentBytes) {
            throw const ClipboardAttachmentException(
              'Clipboard attachment is larger than 64 MB.',
            );
          }
          final bytes = await file.readAll();
          if (bytes.length > maxAttachmentBytes) {
            throw const ClipboardAttachmentException(
              'Clipboard attachment is larger than 64 MB.',
            );
          }
          if (!completer.isCompleted) {
            completer.complete(ClipboardAttachment(kind: kind, bytes: bytes));
          }
        } catch (error, stackTrace) {
          if (!completer.isCompleted) {
            completer.completeError(error, stackTrace);
          }
        }
      },
      onError: (error) {
        if (!completer.isCompleted) {
          completer.completeError(error);
        }
      },
    );
    if (progress == null && !completer.isCompleted) {
      completer.complete(null);
    }
    return completer.future;
  }
}
