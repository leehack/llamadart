import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import 'clipboard_attachment_types.dart';

const MethodChannel _androidClipboardChannel = MethodChannel(
  'llamadart_chat/clipboard',
);

/// Reads image bytes, copied media files, and fallback text.
Future<ClipboardPasteContent?> readSystemClipboard({
  required bool allowImage,
  required bool allowAudio,
  required bool allowText,
}) async {
  final attachments = <ClipboardAttachment>[];

  if (Platform.isAndroid || Platform.isIOS) {
    final attachment = await _readNativeChannelAttachment(
      allowImage: allowImage,
      allowAudio: allowAudio,
    );
    if (attachment != null) {
      attachments.add(attachment);
    }
  } else {
    if (allowImage) {
      final imageBytes = await Pasteboard.image;
      if (imageBytes != null && imageBytes.isNotEmpty) {
        validateClipboardAttachmentSize(imageBytes.length);
        attachments.add(
          ClipboardAttachment(
            kind: ClipboardAttachmentKind.image,
            bytes: imageBytes,
          ),
        );
      }
    }

    ClipboardAttachment? imageFile;
    ClipboardAttachment? audioFile;
    for (final path in await Pasteboard.files()) {
      final kind = inferClipboardAttachmentKind(fileName: path);
      if (kind == null ||
          (kind == ClipboardAttachmentKind.image && !allowImage) ||
          (kind == ClipboardAttachmentKind.audio && !allowAudio) ||
          (kind == ClipboardAttachmentKind.image &&
              (attachments.isNotEmpty || imageFile != null)) ||
          (kind == ClipboardAttachmentKind.audio && audioFile != null)) {
        continue;
      }
      final attachment = await _readFile(path, kind);
      if (kind == ClipboardAttachmentKind.image) {
        imageFile = attachment;
      } else {
        audioFile = attachment;
      }
    }
    if (imageFile != null) {
      attachments.add(imageFile);
    }
    if (audioFile != null) {
      attachments.add(audioFile);
    }
  }

  final clipboardData = allowText
      ? await Clipboard.getData(Clipboard.kTextPlain)
      : null;
  return ClipboardPasteContent(
    attachments: attachments,
    plainText: clipboardData?.text,
  );
}

Future<ClipboardAttachment?> _readNativeChannelAttachment({
  required bool allowImage,
  required bool allowAudio,
}) async {
  try {
    final data = await _androidClipboardChannel
        .invokeMapMethod<String, Object?>('readMedia', {
          'allowImage': allowImage,
          'allowAudio': allowAudio,
        });
    final kindName = data?['kind'];
    final bytes = data?['bytes'];
    if (kindName is! String || bytes is! Uint8List || bytes.isEmpty) {
      return null;
    }
    validateClipboardAttachmentSize(bytes.length);
    final kind = switch (kindName) {
      'image' => ClipboardAttachmentKind.image,
      'audio' => ClipboardAttachmentKind.audio,
      _ => null,
    };
    return kind == null ? null : ClipboardAttachment(kind: kind, bytes: bytes);
  } on MissingPluginException {
    return null;
  } on PlatformException catch (error) {
    if (error.code == 'attachment_too_large') {
      throw const ClipboardAttachmentException(
        'Clipboard attachment is larger than 64 MB.',
      );
    }
    rethrow;
  }
}

Future<ClipboardAttachment> _readFile(
  String path,
  ClipboardAttachmentKind kind,
) async {
  final file = File(path);
  validateClipboardAttachmentSize(await file.length());
  final bytes = await file.readAsBytes();
  validateClipboardAttachmentSize(bytes.length);
  return ClipboardAttachment(kind: kind, bytes: bytes);
}

/// Browser paste events are unavailable on native platforms.
void registerPasteEventListener(ClipboardPasteEventListener listener) {}

/// Browser paste events are unavailable on native platforms.
void unregisterPasteEventListener(ClipboardPasteEventListener listener) {}
