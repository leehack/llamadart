import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/services/clipboard_attachment_service.dart';

void main() {
  group('ClipboardAttachmentService', () {
    final service = ClipboardAttachmentService();
    final image = ClipboardAttachment(
      kind: ClipboardAttachmentKind.image,
      bytes: Uint8List.fromList(const [1]),
    );
    final audio = ClipboardAttachment(
      kind: ClipboardAttachmentKind.audio,
      bytes: Uint8List.fromList(const [2]),
    );

    test('selects the first attachment supported by the active model', () {
      final selected = service.selectSupportedContent(
        ClipboardPasteContent(
          attachments: [image, audio],
          plainText: 'fallback',
        ),
        allowImage: false,
        allowAudio: true,
      );

      expect(selected.attachment, same(audio));
      expect(selected.plainText, 'fallback');
    });

    test('preserves text when no attachment type is supported', () {
      final selected = service.selectSupportedContent(
        ClipboardPasteContent(
          attachments: [image, audio],
          plainText: 'paste me',
        ),
        allowImage: false,
        allowAudio: false,
      );

      expect(selected.attachment, isNull);
      expect(selected.plainText, 'paste me');
    });

    test('rejects attachments larger than the clipboard limit', () {
      expect(
        () => validateClipboardAttachmentSize(maxClipboardAttachmentBytes + 1),
        throwsA(isA<ClipboardAttachmentException>()),
      );
      expect(
        () => validateClipboardAttachmentSize(maxClipboardAttachmentBytes),
        returnsNormally,
      );
    });

    test('infers media kind consistently from MIME or filename', () {
      expect(
        inferClipboardAttachmentKind(mimeType: 'audio/wav'),
        ClipboardAttachmentKind.audio,
      );
      expect(
        inferClipboardAttachmentKind(fileName: '/tmp/SCREENSHOT.PNG'),
        ClipboardAttachmentKind.image,
      );
      expect(
        inferClipboardAttachmentKind(fileName: '/tmp/document.pdf'),
        isNull,
      );
    });
  });
}
