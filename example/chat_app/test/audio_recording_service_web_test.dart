@TestOn('browser')
library;

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart_chat_example/services/audio_recording_service.dart';
import 'package:record_platform_interface/record_platform_interface.dart';
import 'package:record_web/record_web.dart';
import 'package:web/web.dart' as web;

@JS('Promise.reject')
external JSPromise<JSAny?> _reject(JSAny? reason);

JSObject get _mediaDevices => web.window.navigator.mediaDevices as JSObject;

/// Replaces getUserMedia with a source of synthetic streams, or with a
/// rejection carrying a named DOMException.
class _FakeMediaDevices {
  _FakeMediaDevices._(this._context, this._original, this.rejectWith);

  final web.AudioContext _context;
  final JSAny? _original;
  final String? rejectWith;
  final List<web.MediaStreamTrack> tracks = <web.MediaStreamTrack>[];

  static _FakeMediaDevices install({String? rejectWith}) {
    final fake = _FakeMediaDevices._(
      web.AudioContext(),
      _mediaDevices['getUserMedia'],
      rejectWith,
    );
    _mediaDevices['getUserMedia'] = ((JSAny? _) {
      final name = fake.rejectWith;
      if (name != null) {
        return _reject(web.DOMException('injected', name));
      }
      final stream = fake._context.createMediaStreamDestination().stream;
      fake.tracks.addAll(stream.getAudioTracks().toDart);
      return Future<JSAny?>.value(stream).toJS;
    }).toJS;
    return fake;
  }

  Future<void> uninstall() async {
    _mediaDevices['getUserMedia'] = _original;
    for (final track in tracks) {
      track.stop();
    }
    await _context.close().toDart;
  }
}

Future<AudioRecordingException> _startFailure(
  AudioRecordingService recorder,
) async {
  try {
    await recorder.start().timeout(const Duration(seconds: 15));
  } on AudioRecordingException catch (error) {
    return error;
  }
  fail('start() must fail.');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  RecordPlatform.instance = RecordPluginWebWrapper();

  test('browser recorder is exposed from a secure test origin', () async {
    final recorder = AudioRecordingService();
    addTearDown(recorder.dispose);

    expect(recorder.isSupported, isTrue);
  });

  test('a missing input device is not reported as permission denied', () async {
    final devices = _FakeMediaDevices.install(rejectWith: 'NotFoundError');
    addTearDown(devices.uninstall);
    final recorder = AudioRecordingService();
    addTearDown(recorder.dispose);

    final error = await _startFailure(recorder);

    expect(error.failure, AudioRecordingFailure.noInputDevice);
  });

  test('a denied permission is reported as permission denied', () async {
    final devices = _FakeMediaDevices.install(rejectWith: 'NotAllowedError');
    addTearDown(devices.uninstall);
    final recorder = AudioRecordingService();
    addTearDown(recorder.dispose);

    final error = await _startFailure(recorder);

    expect(error.failure, AudioRecordingFailure.permissionDenied);
  });

  test('a failed start releases every microphone track', () async {
    final devices = _FakeMediaDevices.install();
    addTearDown(devices.uninstall);
    final prototype =
        (globalContext['AudioWorklet'] as JSObject)['prototype'] as JSObject;
    final original = prototype['addModule'];
    prototype['addModule'] = ((JSAny? _) {
      return _reject(web.DOMException('injected', 'AbortError'));
    }).toJS;
    addTearDown(() => prototype['addModule'] = original);
    final recorder = AudioRecordingService();
    addTearDown(recorder.dispose);

    final error = await _startFailure(recorder);

    expect(error.failure, AudioRecordingFailure.startFailed);
    expect(devices.tracks, isNotEmpty);
    expect(
      devices.tracks.map((track) => track.readyState),
      everyElement('ended'),
    );
  });
}
