import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'clipboard_attachment_types.dart';

final Map<ClipboardPasteEventListener, web.EventListener> _pasteListeners = {};

/// Reads image, audio, and text formats through the asynchronous Clipboard API.
Future<ClipboardPasteContent?> readSystemClipboard({
  required bool allowImage,
  required bool allowAudio,
  required bool allowText,
}) async {
  final items = (await web.window.navigator.clipboard.read().toDart).toDart;
  final attachments = <ClipboardAttachment>[];
  String? plainText;

  for (final item in items) {
    for (final jsType in item.types.toDart) {
      final type = jsType.toDart;
      if (allowText && type == 'text/plain' && plainText == null) {
        final blob = await item.getType(type).toDart;
        plainText = (await blob.text().toDart).toDart;
        continue;
      }
      final kind = inferClipboardAttachmentKind(mimeType: type);
      final allowed = switch (kind) {
        ClipboardAttachmentKind.image => allowImage,
        ClipboardAttachmentKind.audio => allowAudio,
        null => false,
      };
      if (allowed && !_containsKind(attachments, kind!)) {
        final blob = await item.getType(type).toDart;
        attachments.add(await _readBlob(blob, kind));
      }
    }
  }
  return ClipboardPasteContent(attachments: attachments, plainText: plainText);
}

/// Registers a listener that only suppresses browser paste after it is read.
void registerPasteEventListener(ClipboardPasteEventListener listener) {
  if (_pasteListeners.containsKey(listener)) {
    return;
  }
  final web.EventListener jsListener = ((web.Event event) {
    final clipboardEvent = event as web.ClipboardEvent;
    listener(
      ({required bool allowImage, required bool allowAudio}) => _readPasteEvent(
        clipboardEvent,
        allowImage: allowImage,
        allowAudio: allowAudio,
      ),
    );
  }).toJS;
  _pasteListeners[listener] = jsListener;
  web.document.addEventListener('paste', jsListener);
}

/// Unregisters a browser paste-event listener.
void unregisterPasteEventListener(ClipboardPasteEventListener listener) {
  final jsListener = _pasteListeners.remove(listener);
  if (jsListener != null) {
    web.document.removeEventListener('paste', jsListener);
  }
}

Future<ClipboardPasteContent> _readPasteEvent(
  web.ClipboardEvent event, {
  required bool allowImage,
  required bool allowAudio,
}) async {
  event.preventDefault();
  final data = event.clipboardData;
  if (data == null) {
    return const ClipboardPasteContent();
  }

  final plainText = data.getData('text/plain');
  final files = <({web.Blob blob, ClipboardAttachmentKind kind})>[];
  final items = data.items;
  for (var index = 0; index < items.length; index += 1) {
    final item = items[index];
    if (item.kind != 'file') {
      continue;
    }
    final file = item.getAsFile();
    if (file == null) {
      continue;
    }
    final kind = inferClipboardAttachmentKind(
      mimeType: item.type,
      fileName: file.name,
    );
    final allowed = switch (kind) {
      ClipboardAttachmentKind.image => allowImage,
      ClipboardAttachmentKind.audio => allowAudio,
      null => false,
    };
    if (allowed && !files.any((entry) => entry.kind == kind)) {
      files.add((blob: file as web.Blob, kind: kind!));
    }
  }

  final attachments = <ClipboardAttachment>[];
  for (final file in files) {
    attachments.add(await _readBlob(file.blob, file.kind));
  }
  return ClipboardPasteContent(
    attachments: attachments,
    plainText: plainText.isEmpty ? null : plainText,
  );
}

bool _containsKind(
  List<ClipboardAttachment> attachments,
  ClipboardAttachmentKind kind,
) {
  return attachments.any((attachment) => attachment.kind == kind);
}

Future<ClipboardAttachment> _readBlob(
  web.Blob blob,
  ClipboardAttachmentKind kind,
) async {
  validateClipboardAttachmentSize(blob.size);
  final buffer = await blob.arrayBuffer().toDart;
  final bytes = buffer.toDart.asUint8List();
  validateClipboardAttachmentSize(bytes.length);
  return ClipboardAttachment(kind: kind, bytes: Uint8List.fromList(bytes));
}
