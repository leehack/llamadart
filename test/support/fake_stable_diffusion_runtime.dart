import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:llamadart/src/backends/isolate_shutdown_releases.dart';
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_bindings.dart'
    as sd;
import 'package:llamadart/src/backends/stable_diffusion/stable_diffusion_calls.dart';

const _workerIsolateName = 'llamadart-image-generation';

// Byte offsets into the state block both isolates share.
const _enabled = 0;
const _cancelled = 1;
const _resume = 2;
const _missingInWorker = 3;
const _rejectLoad = 4;
const _videoOnly = 5;
const _throwInGenerate = 6;
const _holdStart = 7;
const _pauseAfter = 8;
const _loadReports = 12;
const _decodeReports = 16;
const _reportsPerRead = 20;
const _racingReads = 28;
const _latest = 32;
const _modelVersion = 40;
const _ring = 64;
const _ringSlots = 16384;
const _stateBytes = _ring + _ringSlots * 8;

/// A stand-in for the stable_diffusion runtime, shared by the two isolates of
/// a `StableDiffusionImageWorker`.
///
/// It records every call made through [resolver] with the isolate that made
/// it, and reports progress the way stable-diffusion.cpp does: a generation
/// clears a pending cancel when it starts, samples every image of a batch
/// (`0/steps` when a pass starts, `k/steps` after step `k`) and only then
/// decodes, and looks at a cancel before each step and before each decode.
/// Like the real recorder it numbers reports from 1 for the whole process and
/// keeps the [history] most recent ones.
final class FakeStableDiffusionRuntime {
  /// Creates a runtime that keeps [history] progress reports.
  FakeStableDiffusionRuntime({
    this.history = StableDiffusionCalls.progressHistory,
  }) : _state = calloc<Uint8>(_stateBytes) {
    _state.cast<Int32>()[_pauseAfter ~/ 4] = -1;
    final version = 'SD 2.x'.codeUnits;
    for (var i = 0; i < version.length; i++) {
      _state[_modelVersion + i] = version[i];
    }
    _port = RawReceivePort(_received, 'fake-stable-diffusion-calls');
  }

  /// Reports the runtime keeps.
  final int history;

  final Pointer<Uint8> _state;
  late final RawReceivePort _port;
  final List<(String, String)> _calls = [];
  final List<(String, Completer<void>)> _waiting = [];
  final List<String> _arrived = [];
  int _flushes = 0;

  /// What a worker resolves its native calls with, in either isolate.
  StableDiffusionCalls? Function() get resolver =>
      _FakeCalls(_state.address, _port.sendPort, history).resolve;

  /// Makes [resolver] return `null` in the worker isolate only.
  set missingInWorker(bool value) => _state[_missingInWorker] = value ? 1 : 0;

  /// Makes the load fail.
  set rejectLoad(bool value) => _state[_rejectLoad] = value ? 1 : 0;

  /// Makes the loaded model one that cannot generate images.
  set videoOnly(bool value) => _state[_videoOnly] = value ? 1 : 0;

  /// Makes a generation throw a Dart error in the worker.
  set throwInGenerate(bool value) => _state[_throwInGenerate] = value ? 1 : 0;

  /// Keeps a generation from starting, so from clearing a pending cancel,
  /// while it is set.
  set holdStart(bool value) => _state[_holdStart] = value ? 1 : 0;

  /// Pauses a generation once it has reported this many times (0 pauses it
  /// right after it starts), until [resume]; `-1` never pauses.
  set pauseAfter(int reports) =>
      _state.cast<Int32>()[_pauseAfter ~/ 4] = reports;

  /// Reports a load records.
  set loadReports(int count) => _state.cast<Int32>()[_loadReports ~/ 4] = count;

  /// Tile reports the decode of a batch records.
  set decodeReports(int count) =>
      _state.cast<Int32>()[_decodeReports ~/ 4] = count;

  /// Reports recorded during each of the next 200 reads that ask for some,
  /// as a runtime that reports faster than its reader reads does.
  set reportsPerRead(int count) {
    _state.cast<Int32>()[_reportsPerRead ~/ 4] = count;
    _state.cast<Int32>()[_racingReads ~/ 4] = 200;
  }

  /// Whether a cancel is pending.
  bool get cancelPending => _state[_cancelled] != 0;

  /// Lets a paused generation continue.
  void resume() => _state[_resume] = 1;

  /// Names of the calls [isolate] (`caller` or `worker`) made so far that
  /// have arrived here; await [flush] first.
  List<String> calls(String isolate) => [
    for (final (from, name) in _calls)
      if (from == isolate) name,
  ];

  /// Forgets the calls recorded so far.
  void clearCalls() => _calls.clear();

  /// Completes when the worker reports that [generation] is paused, and
  /// fails when it ends without pausing.
  Future<void> pausedIn(Future<Object?> generation) => Future.any([
    _next('paused'),
    generation.then(
      (_) => throw StateError('The generation ended without pausing.'),
    ),
  ]);

  /// Completes once every call made before this one has arrived.
  Future<void> flush() {
    final marker = 'flush-${_flushes++}';
    final arrived = _next(marker);
    _port.sendPort.send(('signal', marker));
    return arrived;
  }

  /// Frees the state. Call after the worker is disposed.
  void close() {
    _port.close();
    calloc.free(_state);
  }

  Future<void> _next(String name) {
    if (_arrived.remove(name)) {
      return Future.value();
    }
    final completer = Completer<void>();
    _waiting.add((name, completer));
    return completer.future.timeout(const Duration(seconds: 15));
  }

  void _received(Object? message) {
    final (isolate, name) = message! as (String, String);
    if (isolate != 'signal') {
      _calls.add((isolate, name));
      return;
    }
    final waiting = _waiting.indexWhere((entry) => entry.$1 == name);
    if (waiting >= 0) {
      _waiting.removeAt(waiting).$2.complete();
    } else {
      _arrived.add(name);
    }
  }
}

final class _FakeCalls {
  const _FakeCalls(this._stateAddress, this._log, this._history);

  final int _stateAddress;
  final SendPort _log;
  final int _history;

  Pointer<Uint8> get _state => Pointer.fromAddress(_stateAddress);
  Pointer<Int32> get _ints => _state.cast();
  Pointer<Uint64> get _latestSequence =>
      Pointer.fromAddress(_stateAddress + _latest);

  bool get _inWorker => Isolate.current.debugName == _workerIsolateName;

  void _record(String name) =>
      _log.send((_inWorker ? 'worker' : 'caller', name));

  /// How the worker isolate holds its context for its own shutdown.
  String get _held {
    final held = IsolateShutdownReleases.current.debugHeldForTesting;
    if (held.isEmpty) {
      return '';
    }
    final expected =
        held.length == 1 &&
        held.single.free == malloc.nativeFree &&
        held.single.stage == ShutdownStage.model;
    return expected ? '+held' : '+held-wrong';
  }

  void _report(int step, int steps) {
    final sequence = _latestSequence.value + 1;
    final slot = Pointer<Int32>.fromAddress(
      _stateAddress + _ring + (sequence % _ringSlots) * 8,
    );
    slot[0] = step;
    slot[1] = steps;
    _latestSequence.value = sequence;
  }

  StableDiffusionCalls? resolve() {
    if (_inWorker && _state[_missingInWorker] != 0) {
      return null;
    }
    return StableDiffusionCalls(
      progressEnable: () {
        _record('sd_dart_progress_enable');
        _state[_enabled] = 1;
      },
      progressRead: _progressRead,
      newContext: (params) {
        _record(
          _state[_enabled] != 0
              ? 'sd_dart_new_sd_ctx'
              : 'sd_dart_new_sd_ctx:before-enable',
        );
        if (_state[_rejectLoad] != 0) {
          return nullptr;
        }
        final reports = _ints[_loadReports ~/ 4];
        for (var i = 1; i <= reports; i++) {
          _report(i, reports);
        }
        return malloc<Uint8>(16).cast();
      },
      generateImage: _generateImage,
      cancelGeneration: (context) {
        _record('sd_dart_cancel_generation');
        _state[_cancelled] = 1;
      },
      exitFree: (context) {
        _record('sd_dart_exit_free$_held');
        malloc.free(context);
      },
      exitFreeAddress: malloc.nativeFree,
      contextParamsInit: (params) => _record('sd_ctx_params_init'),
      supportsImageGeneration: (context) {
        _record('sd_ctx_supports_image_generation$_held');
        return _state[_videoOnly] == 0;
      },
      modelVersionName: (context) {
        _record('sd_get_model_version_name$_held');
        return Pointer.fromAddress(_stateAddress + _modelVersion);
      },
      imageGenerationParamsInit: (params) =>
          _record('sd_img_gen_params_init$_held'),
      freeImages: (images, count) {
        _record('free_sd_images$_held');
        for (var i = 0; i < count; i++) {
          malloc.free(images[i].data);
        }
        malloc.free(images);
      },
    );
  }

  int _progressRead(
    int after,
    Pointer<sd.sd_dart_progress_t> reports,
    int capacity,
    Pointer<Uint64> latest,
  ) {
    if (capacity == 0) {
      _record('sd_dart_progress_read:mark');
    } else {
      _record('sd_dart_progress_read');
      final racing = _ints[_reportsPerRead ~/ 4];
      if (racing > 0 && _ints[_racingReads ~/ 4]-- > 0) {
        for (var i = 1; i <= racing; i++) {
          _report(i, racing);
        }
      }
    }
    final newest = _latestSequence.value;
    if (latest != nullptr) {
      latest.value = newest;
    }
    final oldest = newest - _history + 1;
    var sequence = after + 1 > oldest ? after + 1 : oldest;
    var count = 0;
    while (count < capacity && sequence <= newest) {
      final slot = Pointer<Int32>.fromAddress(
        _stateAddress + _ring + (sequence % _ringSlots) * 8,
      );
      reports[count]
        ..sequence = sequence
        ..step = slot[0]
        ..steps = slot[1]
        ..time = 0;
      count++;
      sequence++;
    }
    return count;
  }

  void _waitWhile(bool Function() blocked) {
    final waited = Stopwatch()..start();
    while (blocked()) {
      if (waited.elapsed > const Duration(seconds: 10)) {
        throw StateError('The fake generation was never released.');
      }
      sleep(const Duration(milliseconds: 1));
    }
  }

  bool _generateImage(
    Pointer<sd.sd_ctx_t> context,
    Pointer<sd.sd_img_gen_params_t> params,
    Pointer<Pointer<sd.sd_image_t>> imagesOut,
    Pointer<Int> countOut,
  ) {
    _record('sd_dart_generate_image$_held');
    imagesOut.value = nullptr;
    countOut.value = 0;
    _waitWhile(() => _state[_holdStart] != 0);
    _state[_cancelled] = 0;
    if (_state[_throwInGenerate] != 0) {
      throw StateError('The fake generation failed.');
    }
    final steps = params.ref.sample_params.sample_steps;
    final images = params.ref.batch_count;
    final pauseAfter = _ints[_pauseAfter ~/ 4];
    var reported = 0;
    void pauseAt(int count) {
      if (count != pauseAfter) {
        return;
      }
      _log.send(('signal', 'paused'));
      _waitWhile(() => _state[_resume] == 0);
      _state[_resume] = 0;
    }

    void report(int step, int total) {
      _report(step, total);
      pauseAt(++reported);
    }

    pauseAt(0);
    for (var image = 0; image < images; image++) {
      report(0, steps);
      for (var step = 1; step <= steps; step++) {
        if (_state[_cancelled] != 0) {
          return false;
        }
        report(step, steps);
      }
    }
    if (_state[_cancelled] != 0) {
      return false;
    }
    final tiles = _ints[_decodeReports ~/ 4];
    for (var tile = 1; tile <= tiles; tile++) {
      report(tile, tiles);
    }

    final width = params.ref.width;
    final height = params.ref.height;
    final result = malloc<sd.sd_image_t>(images);
    for (var image = 0; image < images; image++) {
      final length = width * height * 3;
      final data = malloc<Uint8>(length);
      data.asTypedList(length).fillRange(0, length, image + 1);
      result[image]
        ..width = width
        ..height = height
        ..channel = 3
        ..data = data;
    }
    imagesOut.value = result;
    countOut.value = images;
    return true;
  }
}

/// The progress timers a worker started, which a test fires by hand.
final class ManualProgressTimers {
  /// Intervals of the timers started so far.
  final List<Duration> intervals = [];

  final List<_ManualTimer> _timers = [];

  /// Timers started and not cancelled.
  int get active => _timers.where((timer) => timer.isActive).length;

  /// Starts a timer that fires only on [poll].
  Timer start(Duration interval, void Function(Timer timer) poll) {
    intervals.add(interval);
    final timer = _ManualTimer(poll);
    _timers.add(timer);
    return timer;
  }

  /// Fires the one active timer once.
  void poll() {
    final timer = _timers.singleWhere((timer) => timer.isActive);
    timer._poll(timer);
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this._poll);

  final void Function(Timer timer) _poll;

  @override
  bool isActive = true;

  @override
  int get tick => 0;

  @override
  void cancel() => isActive = false;
}
