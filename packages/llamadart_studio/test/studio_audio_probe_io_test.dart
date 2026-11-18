@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_studio/src/app/studio_audio_probe_io.dart';

void main() {
  test('non-Linux never initializes GStreamer', () {
    expect(
      probeAudioPlaybackUnavailableReason(
        isLinux: false,
        initialize: () => throw StateError('must not initialize'),
      ),
      isNull,
    );
  });
  test('failed initialization reports installation prerequisites', () {
    final reason = probeAudioPlaybackUnavailableReason(
      isLinux: true,
      initialize: () => false,
      canCreateElement: (_) => throw StateError('must not create'),
    );
    expect(reason, contains('initialize GStreamer'));
    expect(reason, contains('gstreamer1.0-plugins-base'));
    expect(reason, contains('gstreamer1.0-plugins-good'));
  });
  for (final missing in ['playbin', 'autoaudiosink', 'wavparse']) {
    test('missing $missing blocks playback before plugin creation', () {
      expect(
        probeAudioPlaybackUnavailableReason(
          isLinux: true,
          initialize: () => true,
          canCreateElement: (name) => name != missing,
        ),
        contains('cannot create $missing'),
      );
    });
  }
  test('available runtime checks each WAV playback element', () {
    final checked = <String>[];
    expect(
      probeAudioPlaybackUnavailableReason(
        isLinux: true,
        initialize: () => true,
        canCreateElement: (name) {
          checked.add(name);
          return true;
        },
      ),
      isNull,
    );
    expect(checked, ['playbin', 'autoaudiosink', 'wavparse']);
  });
  test('runtime errors report a recoverable unavailable reason', () {
    expect(
      probeAudioPlaybackUnavailableReason(
        isLinux: true,
        initialize: () => throw ArgumentError('missing symbol'),
        canCreateElement: (_) => true,
      ),
      contains('could not load its GStreamer runtime'),
    );
  });
}
