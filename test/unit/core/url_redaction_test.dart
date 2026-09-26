import 'package:llamadart/src/core/url_redaction.dart';
import 'package:test/test.dart';

void main() {
  group('redactUrlSecrets', () {
    for (final (url, display, secrets) in const [
      (
        'https://alice:Pw1secret@example.com/m.gguf',
        'https://example.com/m.gguf',
        <String>['Pw1secret', 'alice'],
      ),
      (
        '//alice:Pw2secret@example.com/m.gguf?token=Tk2secret',
        '//example.com/m.gguf',
        <String>['Pw2secret', 'Tk2secret', 'alice'],
      ),
      ('models/m.gguf?token=Tk3secret', 'models/m.gguf', <String>['Tk3secret']),
      (
        'https://example.com/m.gguf#Fr4secretfrag',
        'https://example.com/m.gguf',
        <String>['Fr4secretfrag'],
      ),
      (
        'https://bucket.example.com/m.gguf?X-Amz-Signature=Sig5secret',
        'https://bucket.example.com/m.gguf',
        <String>['Sig5secret'],
      ),
    ]) {
      test('redacts $display in a message that echoes it', () {
        final redacted = redactUrlSecrets(
          'Model file not found: $url',
          sourceUrls: <String>[url],
        );
        expect(redacted, contains('Model file not found: $display'));
        for (final secret in secrets) {
          expect(redacted, isNot(contains(secret)), reason: secret);
        }
      });
    }

    test('removes secrets only a URL parser reports', () {
      const url = 'https://user:pw@example.com/m.gguf';
      String redact(ParseUrl? parseUrl) => redactUrlSecrets(
        'Rejected NormalizedSecret9 for $url',
        sourceUrls: const <String>[url],
        parseUrl: parseUrl,
      );

      expect(redact(null), contains('NormalizedSecret9'));
      expect(
        redact(
          (_) => (
            href: url,
            username: 'user',
            password: 'NormalizedSecret9',
            search: '',
            hash: '',
          ),
        ),
        'Rejected  for https://example.com/m.gguf',
      );
    });

    test('keeps a plain file path', () {
      const path = '/Users/me/models/qwen2.5-0.5b-instruct-q4_k_m.gguf';
      expect(
        redactUrlSecrets(
          'Model file not found: $path',
          sourceUrls: const <String>[path],
        ),
        'Model file not found: $path',
      );
    });
  });

  test('sourceUrlDisplay drops userinfo, query and fragment', () {
    expect(
      sourceUrlDisplay('https://u:Pw6secret@example.com:8443/a/m.gguf?t=1#f'),
      'https://example.com:8443/a/m.gguf',
    );
  });
}
