import 'dart:async';
import 'dart:convert';
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
const _olderRelease = 24;
const _logEnabled = 25;
const _quietReject = 26;
const _racingReads = 28;
const _latest = 32;
const _modelVersion = 40;
const _ring = 64;
const _ringSlots = 16384;
const _logState = _ring + _ringSlots * 8;
const _logThreshold = _logState;
const _logHistory = _logState + 4;
const _logLatest = _logState + 8;
const _logReadTo = _logState + 16;
const _logDropped = _logState + 24;
const _gpuCount = _logState + 32;
const _freeDelay = _logState + 36;
const _lastErrorLength = _logState + 56;
const _lastError = _logState + 64;
const _lastErrorBytes = 1024;
const _modelPath = _lastError + _lastErrorBytes;
const _modelPathBytes = 512;
const _logSlots = _modelPath + _modelPathBytes;
const _logSlotCount = 256;
const _logSlotBytes = 512;
// One GPU: status and type as Int32, then total and free as Int64.
const _gpus = _logSlots + _logSlotCount * _logSlotBytes;
const _gpuBytes = 24;
const _maxGpus = 4;
const _stateBytes = _gpus + _maxGpus * _gpuBytes;

// sd_log_level_t.
const _sdLogDebug = 0;
const _sdLogInfo = 2;
const _sdLogError = 4;

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
///
/// It logs the way the runtime of `StableDiffusionCalls.optionalNativeRelease`
/// does once its recorder is enabled: a load logs the file it loads at
/// `SD_LOG_INFO` and why it failed at `SD_LOG_ERROR`, and a generation logs
/// one `SD_LOG_DEBUG` and one `SD_LOG_INFO` message. Messages below the level
/// set are not recorded, and the oldest ones leave when more than
/// `logHistory` are kept.
final class FakeStableDiffusionRuntime {
  /// Creates a runtime that keeps [history] progress reports and [logHistory]
  /// log messages.
  FakeStableDiffusionRuntime({
    this.history = StableDiffusionCalls.progressHistory,
    int logHistory = 64,
  }) : _state = calloc<Uint8>(_stateBytes) {
    _state.cast<Int32>()[_pauseAfter ~/ 4] = -1;
    _state.cast<Int32>()[_logThreshold ~/ 4] = _sdLogInfo;
    _state.cast<Int32>()[_logHistory ~/ 4] = logHistory;
    _state.cast<Int32>()[_gpuCount ~/ 4] = -2;
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

  /// Makes a failed load log no error.
  set quietReject(bool value) => _state[_quietReject] = value ? 1 : 0;

  /// Makes [resolver] return the calls of a runtime older than
  /// `StableDiffusionCalls.optionalNativeRelease`: no log and no device
  /// memory.
  set olderRelease(bool value) => _state[_olderRelease] = value ? 1 : 0;

  /// The GPUs the runtime lists: device `i` is `Vulkan<i>`, a `Fake GPU <i>`,
  /// with its total and free bytes, and `sd_dart_gpu_device_memory` answers
  /// its status when that is not 0. Past the last one it answers
  /// `SD_DART_GPU_NO_DEVICE`.
  set gpus(List<({int total, int free, bool integrated, int status})> devices) {
    _state.cast<Int32>()[_gpuCount ~/ 4] = devices.length;
    for (final (index, device) in devices.indexed) {
      final entry = _state + _gpus + index * _gpuBytes;
      entry.cast<Int32>()[0] = device.status;
      entry.cast<Int32>()[1] = device.integrated ? 2 : 1;
      entry.cast<Int64>()[1] = device.total;
      entry.cast<Int64>()[2] = device.free;
    }
  }

  /// What `sd_dart_gpu_device_count` answers instead of a count:
  /// `SD_DART_GPU_NO_BACKEND` at first.
  set gpuCountStatus(int status) =>
      _state.cast<Int32>()[_gpuCount ~/ 4] = status;

  /// One GPU, as [gpus].
  void setGpuMemory({
    int status = 0,
    int total = 0,
    int free = 0,
    bool integrated = false,
  }) => gpus = [
    (total: total, free: free, integrated: integrated, status: status),
  ];

  /// Adds [count] to the messages the runtime dropped without recording
  /// one, as a recorder that could not take its buffer in time does.
  void dropUnrecorded(int count) =>
      _state.cast<Int64>()[_logDropped ~/ 8] += count;

  /// The model path the last load read from its context parameters, or an
  /// empty string when they had none.
  String get loadedModelPath =>
      Pointer<Utf8>.fromAddress(_state.address + _modelPath).toDartString();

  /// Records [bytes] as a log message at `sd_log_level_t` [level], as a
  /// thread of the runtime does.
  void log(int level, List<int> bytes) => _FakeCalls(
    _state.address,
    _port.sendPort,
    history,
  )._logMessage(level, bytes);

  /// Makes the loaded model one that cannot generate images.
  set videoOnly(bool value) => _state[_videoOnly] = value ? 1 : 0;

  /// Makes a generation throw a Dart error in the worker. The worker records
  /// `uncaught generation error`, with how it holds its context, when the
  /// error ends it.
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

  /// How long the worker's explicit context free takes.
  set freeDelay(Duration delay) =>
      _state.cast<Int32>()[_freeDelay ~/ 4] = delay.inMilliseconds;

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

  Pointer<Int64> get _longs => _state.cast();

  Pointer<Uint8> _logSlot(int sequence) =>
      _state + _logSlots + (sequence % _logSlotCount) * _logSlotBytes;

  /// Records a message when the recorder is enabled and [level] reaches the
  /// level set. The oldest message kept leaves when there are too many, and
  /// counts as dropped when no read had reached it.
  void _logMessage(int level, List<int> bytes) {
    if (_state[_logEnabled] == 0 || level < _ints[_logThreshold ~/ 4]) {
      return;
    }
    final sequence = ++_longs[_logLatest ~/ 8];
    final slot = _logSlot(sequence);
    slot.cast<Int32>()[0] = level;
    slot.cast<Int32>()[1] = bytes.length;
    (slot + 8).asTypedList(bytes.length).setAll(0, bytes);
    final gone = sequence - _ints[_logHistory ~/ 4];
    if (gone > _longs[_logReadTo ~/ 8]) {
      _longs[_logDropped ~/ 8]++;
    }
  }

  void _logText(int level, String text) =>
      _logMessage(level, utf8.encode(text));

  int _logRead(
    int after,
    Pointer<Char> text,
    int capacity,
    Pointer<Int32> level,
    Pointer<Size> length,
  ) {
    _record('sd_dart_log_read');
    final newest = _longs[_logLatest ~/ 8];
    final oldest = newest - _ints[_logHistory ~/ 4] + 1;
    final sequence = after + 1 > oldest ? after + 1 : oldest;
    if (sequence > newest) {
      return 0;
    }
    final slot = _logSlot(sequence);
    final size = slot.cast<Int32>()[1];
    final copied = size < capacity ? size : capacity - 1;
    text.cast<Uint8>().asTypedList(capacity)
      ..setRange(0, copied, (slot + 8).asTypedList(copied))
      ..[copied] = 0;
    level.value = slot.cast<Int32>()[0];
    if (length != nullptr) {
      length.value = size;
    }
    if (sequence > _longs[_logReadTo ~/ 8]) {
      _longs[_logReadTo ~/ 8] = sequence;
    }
    return sequence;
  }

  int _readLastError(Pointer<Char> text, int capacity) {
    _record('sd_dart_last_error');
    final size = _ints[_lastErrorLength ~/ 4];
    text.cast<Uint8>().asTypedList(capacity)
      ..setRange(0, size, (_state + _lastError).asTypedList(size))
      ..[size] = 0;
    return size;
  }

  int _gpuDeviceMemory(
    int deviceIndex,
    Pointer<sd.sd_dart_gpu_device_memory_t> out,
  ) {
    _record(
      _state[_logEnabled] != 0
          ? 'sd_dart_gpu_device_memory:$deviceIndex'
          : 'sd_dart_gpu_device_memory:$deviceIndex:before-log-enable',
    );
    if (deviceIndex < 0 || deviceIndex >= _ints[_gpuCount ~/ 4]) {
      return -3;
    }
    final entry = _state + _gpus + deviceIndex * _gpuBytes;
    final status = entry.cast<Int32>()[0];
    if (status != 0) {
      return status;
    }
    out.ref
      ..total_bytes = entry.cast<Int64>()[1]
      ..free_bytes = entry.cast<Int64>()[2]
      ..type = entry.cast<Int32>()[1];
    for (final (index, unit) in 'Vulkan$deviceIndex\x00'.codeUnits.indexed) {
      out.ref.name[index] = unit;
    }
    for (final (index, unit) in 'Fake GPU $deviceIndex\x00'.codeUnits.indexed) {
      out.ref.description[index] = unit;
    }
    return 0;
  }

  int _gpuDeviceCount() {
    _record(
      _state[_logEnabled] != 0
          ? 'sd_dart_gpu_device_count'
          : 'sd_dart_gpu_device_count:before-log-enable',
    );
    return _ints[_gpuCount ~/ 4];
  }

  Pointer<sd.sd_ctx_t> _newContext(Pointer<sd.sd_ctx_params_t> params) {
    _record(
      _state[_enabled] != 0
          ? 'sd_dart_new_sd_ctx'
          : 'sd_dart_new_sd_ctx:before-enable',
    );
    final modelPath = params.ref.model_path == nullptr
        ? ''
        : params.ref.model_path.cast<Utf8>().toDartString();
    (_state + _modelPath).asTypedList(_modelPathBytes)
      ..fillRange(0, _modelPathBytes, 0)
      ..setAll(0, utf8.encode(modelPath));
    _ints[_lastErrorLength ~/ 4] = 0;
    _logText(
      _sdLogInfo,
      "stable-diffusion.cpp:262 - loading model from '$modelPath'",
    );
    if (_state[_rejectLoad] != 0) {
      if (_state[_quietReject] == 0 && _state[_logEnabled] != 0) {
        final error = utf8.encode(
          "model_loader.cpp:1061 - cannot inspect model source '$modelPath': "
          'No such file or directory',
        );
        _logMessage(_sdLogError, error);
        _ints[_lastErrorLength ~/ 4] = error.length;
        (_state + _lastError).asTypedList(error.length).setAll(0, error);
      }
      return nullptr;
    }
    final reports = _ints[_loadReports ~/ 4];
    for (var i = 1; i <= reports; i++) {
      _report(i, reports);
    }
    return malloc<Uint8>(16).cast();
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
      newContext: _newContext,
      generateImage: _generateImage,
      cancelGeneration: (context) {
        _record('sd_dart_cancel_generation');
        _state[_cancelled] = 1;
      },
      exitFree: (context) {
        _record('sd_dart_exit_free$_held');
        sleep(Duration(milliseconds: _ints[_freeDelay ~/ 4]));
        malloc.free(context);
      },
      exitFreeAddress: malloc.nativeFree,
      contextParamsInit: (params) {
        _record('sd_ctx_params_init');
        // What sd_ctx_params_init leaves, whatever the caller wrote before.
        params.ref.model_path = nullptr;
      },
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
      log: _state[_olderRelease] != 0
          ? null
          : StableDiffusionLogCalls(
              enable: () {
                _record('sd_dart_log_enable');
                _state[_logEnabled] = 1;
              },
              setLevel: (level) {
                _record('sd_dart_log_set_level:$level');
                _ints[_logThreshold ~/ 4] = level;
              },
              read: _logRead,
              dropped: () {
                _record('sd_dart_log_dropped');
                return _longs[_logDropped ~/ 8];
              },
              lastError: _readLastError,
            ),
      gpu: _state[_olderRelease] != 0
          ? null
          : StableDiffusionGpuCalls(
              deviceCount: _gpuDeviceCount,
              deviceMemory: _gpuDeviceMemory,
            ),
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
    _logText(_sdLogDebug, 'stable-diffusion.cpp:3120 - sampling');
    _logText(_sdLogInfo, 'stable-diffusion.cpp:3391 - generating');
    imagesOut.value = nullptr;
    countOut.value = 0;
    _waitWhile(() => _state[_holdStart] != 0);
    _state[_cancelled] = 0;
    if (_state[_throwInGenerate] != 0) {
      throw _GenerationFailure(this);
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

/// Records how the worker holds its context when the VM reports this error
/// as uncaught, which is after any handler of the worker ran.
final class _GenerationFailure extends Error {
  _GenerationFailure(this._calls);

  final _FakeCalls _calls;

  @override
  String toString() {
    _calls._record('uncaught generation error${_calls._held}');
    return 'The fake generation failed.';
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
