import 'dart:io';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:llamadart_validation/io.dart';
import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'host.dart';

/// Creates the mobile/desktop Flutter filesystem host.
ValidationHost createHost() => _NativeHost();

class _NativeHost implements ValidationHost {
  FileValidationJournal? _journal;
  Directory? _output;
  http.Client? _client;
  @override
  void cancelPreparation() => _client?.close();

  @override
  String get outputLocation => _output?.path ?? '';

  @override
  Future<({String path, Map<String, dynamic> evidence})> prepare(
    ValidationProfile profile,
  ) async {
    _client = http.Client();
    try {
      return await prepareModel(
        profile,
        Directory(
          p.join(
            (await getApplicationSupportDirectory()).path,
            'validation',
            'models',
          ),
        ),
        client: _client,
        timeout: const Duration(minutes: 10),
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
