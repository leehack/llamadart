import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:llamadart_validation/io.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:llamadart_validation/npu_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'host.dart';

/// Creates the mobile/desktop Flutter filesystem host.
ValidationHost createHost() => _NativeHost();

class _NativeHost implements ValidationHost {
  static const _npuChannel = MethodChannel('llamadart_validation/npu');
  AndroidNpuMonitor? _npu;
  String? _probeLibrary;
  ({String head, String? config, Map<String, dynamic> evidence})? _decision;
  @override
  ValidationEngine createEngine(ValidationProfile profile) =>
      profile.nativeReference
      ? NativeNpuReferenceEngine(_npu!, _probeLibrary!)
      : PublicValidationEngine(
          npu: _npu,
          decisionHead: _decision?.head,
          decisionConfig: _decision?.config,
        );
  FileValidationJournal? _journal;
  Directory? _output;
  http.Client? _client;
  @override
  void cancelPreparation() {
    _client?.close();
    if (Platform.isAndroid) {
      _npuChannel.invokeMethod<void>('cancel').catchError((Object _) {});
    }
  }

  @override
  String get outputLocation => _output?.path ?? '';

  @override
  Future<({String path, Map<String, dynamic> evidence})> prepare(
    ValidationProfile profile,
  ) async {
    _npu = null;
    _probeLibrary = null;
    _decision = null;
    if (profile.backend == 'npu') {
      if (!Platform.isAndroid) {
        throw UnsupportedError('NPU app validation requires Android');
      }
      final value = Map<String, dynamic>.from(
        (await _npuChannel
            .invokeMapMethod<String, dynamic>('prepare', {
              'profile': profile.id,
            })
            .timeout(
              const Duration(minutes: 10),
              onTimeout: () {
                cancelPreparation();
                throw TimeoutException('NPU preparation exceeded ten minutes');
              },
            ))!,
      );
      final kit =
          jsonDecode(value.remove('kit') as String) as Map<String, dynamic>;
      final directory = value.remove('dispatch_directory') as String;
      final path = value.remove('path') as String;
      final target = profile.data['npu_target'] as Map;
      validateNpuDevice(profile, value);
      if (value['verified'] != true ||
          value['sha256'] != profile.modelHash ||
          kit['target'] != target['soc'] ||
          kit['runtime_tag'] !=
              const String.fromEnvironment('VALIDATION_LITERT_TAG') ||
          kit['litert_revision'] !=
              '9fe5be45564c868408e6514c8aabb83e211a0911' ||
          kit['dispatch_header_sha256'] !=
              '11dd4d98bd084157ac987b1ee1951f3f96e2b3ca6b51a27c10e645686bf0e3ee') {
        throw StateError(
          'Installed NPU host identity does not match the profile/runtime',
        );
      }
      _probeLibrary = (target['libraries'] as Map).keys
          .cast<String>()
          .singleWhere((name) => name.startsWith('libLiteRtDispatch_'));
      final identity = {'device': value, 'kit': kit};
      _npu = AndroidNpuMonitor(directory, _probeLibrary!, identity);
      return (path: path, evidence: {...value, 'npu': identity});
    }
    final cache = Directory(
      p.join(
        (await getApplicationSupportDirectory()).path,
        'validation',
        'models',
      ),
    );
    _client = http.Client();
    try {
      final model = await prepareModel(
        profile,
        cache,
        client: _client,
        onProgress: _journal!.emitPreparation,
        timeout: const Duration(minutes: 10),
      );
      if (!profile.isDecision) return model;
      final decision = _decision = await prepareDecisionAssets(
        profile,
        cache,
        client: () => _client = http.Client(),
        onProgress: _journal!.emitPreparation,
        timeout: const Duration(minutes: 10),
      );
      return (
        path: model.path,
        evidence: {...model.evidence, ...decision.evidence},
      );
    } finally {
      _client?.close();
      _client = null;
    }
  }

  @override
  Future<void> start(String runId) async {
    final base = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : await getApplicationDocumentsDirectory();
    if (base == null) {
      throw StateError('No validation output directory available');
    }
    _output = Directory(p.join(base.path, 'validation', 'runs', runId));
    _journal = FileValidationJournal(_output!);
  }

  @override
  Future<void> emit(Map<String, dynamic> event) => _journal!.emit(event);

  @override
  Future<ValidationReport> finish() async {
    _journal!.close();
    return writeReports(_output!);
  }

  @override
  Future<void> export(String name, String text) async {
    await FilePicker.platform.saveFile(
      fileName: name,
      bytes: Uint8List.fromList(utf8.encode(text)),
    );
  }
}
