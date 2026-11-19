import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

void main() {
  test('Web load abort offers recovery without build instructions', () {
    final message = humanizeStudioError(
      StateError(
        'The Web runtime could not load the model. (Aborted(). Build with -sASSERTIONS for more info.)',
      ),
    );
    expect(message, contains('Expert tuning'));
    expect(message, contains('batch'));
    expect(message, isNot(contains('sASSERTIONS')));
  });

  test('runtime messages still strip secrets and retain unrelated failures', () {
    final message = humanizeStudioError(
      StateError(
        'Fetch failed: https://user:password@example.invalid/model?token=secret#fragment Bearer private-token',
      ),
    );
    expect(message, contains('Fetch failed'));
    for (final secret in ['password', 'secret', 'fragment', 'private-token']) {
      expect(message, isNot(contains(secret)));
    }
    expect(
      humanizeStudioError(StateError('Aborted an unrelated operation')),
      'Aborted an unrelated operation',
    );
  });

  test('MediaEngine playback error suggests checking a playback device', () {
    final message = humanizeStudioError(
      'PlatformException(4, MediaEngine error, Failed to set source, null)',
    );
    expect(message.toLowerCase(), contains('check a playback device'));
    expect(message, isNot(contains('PlatformException')));
  });
}
