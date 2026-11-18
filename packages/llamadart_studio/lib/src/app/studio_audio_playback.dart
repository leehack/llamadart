import 'package:audioplayers/audioplayers.dart';

import 'studio_audio_probe_stub.dart'
    if (dart.library.io) 'studio_audio_probe_io.dart'
    as platform;

/// Creates a playback plugin only after its runtime prerequisites are available.
class StudioAudioPlayback {
  /// Creates a lazy player with injectable runtime and plugin factories.
  StudioAudioPlayback({
    Future<String?> Function()? unavailableReason,
    AudioPlayer Function()? createPlayer,
  }) : _unavailableReason = unavailableReason ?? _probe,
       _createPlayer = createPlayer ?? AudioPlayer.new;

  final Future<String?> Function() _unavailableReason;
  final AudioPlayer Function() _createPlayer;
  AudioPlayer? _player;
  Future<AudioPlayer?>? _creating;
  Future<void>? _disposing;
  bool _disposed = false;

  static Future<String?> _probe() async =>
      platform.probeAudioPlaybackUnavailableReason();

  /// The existing player, without initializing the platform plugin.
  AudioPlayer? get current => _player;

  /// Returns one guarded player, or null if its owner has been disposed.
  Future<AudioPlayer?> getOrCreate() {
    if (_disposed) return Future<AudioPlayer?>.value();
    if (_player != null) return Future<AudioPlayer?>.value(_player);
    return _creating ??= _create();
  }

  Future<AudioPlayer?> _create() async {
    try {
      final reason = await Future<String?>.sync(_unavailableReason);
      if (_disposed) return null;
      if (reason != null) throw StateError(reason);
      return _player = _createPlayer();
    } finally {
      _creating = null;
    }
  }

  /// Prevents pending probes from creating a player and releases an existing one.
  Future<void> dispose() {
    _disposed = true;
    return _disposing ??= _player?.dispose() ?? Future<void>.value();
  }
}
