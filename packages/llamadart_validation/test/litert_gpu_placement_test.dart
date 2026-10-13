import 'dart:convert';
import 'dart:io';

import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:llamadart_validation/src/placement.dart';
import 'package:test/test.dart';

const _fixtures = 'test/fixtures/android_logcat';
const _label = 'gpu_delegate_initialized_per_load_execution_unobserved';
const _mali =
    'Mali-G715, arch=valhall, vendor=arm, backend=Vulkan, '
    'adapterType=Integrated GPU';
const _adreno =
    'Adreno (TM) 750, arch=adreno-7xx, vendor=qualcomm, backend=Vulkan, '
    'adapterType=Integrated GPU';
const _kernel = 'external tensors are used for delegate inputs and outputs';

String _read(String name) =>
    File('$_fixtures/$name').readAsStringSync().replaceAll('\r\n', '\n');

/// The app-process lines from the test start record onward: what collection
/// keeps of a device log it has bound to the journal.
String _bound(String logcat) {
  final lines = const LineSplitter().convert(logcat);
  final start = lines.indexWhere(
    (line) => line.contains(' I flutter : 00:00 +0: shared validation: '),
  );
  final pid = lines[start].split(RegExp(' +'))[2];
  return lines
      .skip(start)
      .where((line) => line.split(RegExp(' +')).elementAtOrNull(2) == pid)
      .map((line) => '$line\n')
      .join();
}

String _replaceNth(String text, Pattern from, String to, int index) {
  final match = from.allMatches(text).elementAt(index);
  return text.replaceRange(match.start, match.end, to);
}

String _withoutLine(String text, String containing, {int index = 0}) {
  final lines = const LineSplitter().convert(text);
  final hits = [
    for (var i = 0; i < lines.length; i++)
      if (lines[i].contains(containing)) i,
  ];
  lines.removeAt(hits[index]);
  return lines.map((line) => '$line\n').join();
}

void main() {
  final pixelJournal = _read('pixel9pro-gemma4-litert-gpu.events.jsonl');
  final pixel = _bound(_read('pixel9pro-gemma4-litert-gpu.logcat.txt'));
  final galaxyJournal = _read('galaxys24-gemma4-litert-gpu.events.jsonl');
  final galaxy = _bound(_read('galaxys24-gemma4-litert-gpu.logcat.txt'));
  final cpuControl = _bound(_read('pixel9pro-chat-litert-cpu.logcat.txt'));

  List<Map<String, dynamic>> events(String journal) => [
    for (final line in const LineSplitter().convert(journal))
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
  ];
  Map<String, dynamic> manifest() => events(pixelJournal).first;
  List<Map<String, dynamic>> cases() =>
      events(pixelJournal).where((event) => event['type'] == 'case').toList();
  Map<String, dynamic> inspect(
    String? log, {
    Map<String, dynamic>? of,
    List<Map<String, dynamic>>? records,
  }) => inspectPlacement(of ?? manifest(), records ?? cases(), log);
  void rejects(String log, {String? reason}) {
    final placement = inspect(log);
    expect(placement['verified'], isFalse, reason: reason ?? '$placement');
    expect(placement['placement'], 'unverified', reason: reason);
  }

  group('LiteRT GPU delegate evidence', () {
    for (final (name, journal, log, adapter) in [
      ('Pixel 9 Pro Mali', pixelJournal, pixel, _mali),
      ('Galaxy S24 Adreno', galaxyJournal, galaxy, _adreno),
    ]) {
      test('$name device log verifies a delegate for every load', () {
        final recorded = events(journal);
        final placement = inspectPlacement(
          recorded.first,
          recorded.where((event) => event['type'] == 'case').toList(),
          log,
        );
        expect(placement, {
          'required': true,
          'verified': true,
          'reason': contains('per-request execution and embedding-model'),
          'log_sha256': matches(r'^[a-f0-9]{64}$'),
          'placement': _label,
          'expected_loads': 3,
          'adapter': adapter,
          'adapter_records': 3,
          'environment_records': 3,
          'signatures_per_load': 4,
          'delegate_records': 12,
          'failure_markers': isEmpty,
        });

        final report = ValidationReport.parse(journal, nativeLog: log);
        expect(report.qualified, isTrue);
        expect(report.qualificationGaps, isEmpty);
        expect(
          report.toHtml(),
          allOf(
            contains('per-request execution unobserved'),
            isNot(contains('verified native offload')),
          ),
        );

        final without = ValidationReport.parse(journal);
        expect(without.assertionsPassed, isTrue);
        expect(without.qualified, isFalse);
        expect(without.qualificationGaps, ['accelerator_evidence_missing']);
        expect(without.placement, {
          'required': true,
          'verified': false,
          'reason': 'native placement evidence unavailable',
        });
      });
    }

    test('accelerator registration is not evidence in either direction', () {
      for (final record in [
        'Dynamically loaded GPU accelerator(libLiteRtGpuAccelerator.so) '
            'registered.',
        'RegisterAccelerator: ',
        'XNNPACK CPU accelerator registered.',
      ]) {
        expect(cpuControl, contains(record));
        expect(pixel, contains(record));
      }
      final placement = inspect(cpuControl);
      expect(placement['verified'], isFalse);
      expect(placement['adapter_records'], 0);
      expect(placement['delegate_records'], 0);

      final unregistered = const LineSplitter()
          .convert(pixel)
          .where(
            (line) =>
                !line.contains('gpu_registry') &&
                !line.contains('RegisterAccelerator') &&
                !line.contains('XNNPACK'),
          )
          .map((line) => '$line\n')
          .join();
      expect(unregistered, isNot(pixel));
      expect(inspect(unregistered)['verified'], isTrue);
    });

    test('a GPU accelerator that did not load cannot verify', () {
      const failure =
          '10-13 02:44:27.834 22950 26936 W litert  : [gpu_registry.cc:1] '
          'GPU accelerator could not be loaded and registered: '
          'kLiteRtStatusErrorNotFound.\n';
      rejects(failure);
      rejects('$cpuControl$failure');
      final placement = inspect('$failure$pixel');
      expect(placement['verified'], isFalse);
      expect(placement['failure_markers'], [
        'GPU accelerator could not be loaded and registered',
      ]);
      // The NPU accelerator is absent on both devices and is not a GPU failure.
      expect(pixel, contains('NPU accelerator could not be loaded'));
    });

    for (final marker in [
      'Some ops are not accelerated. Add kLiteRtHwAcceleratorCpu',
      'Failed to modify graph with delegate',
      'vkCreateDevice failed: VK_ERROR_INITIALIZATION_FAILED',
      'Validation error: Binding size (155582464) is larger than the maximum',
      'Falling back to CPU',
      'falling back to cpu',
    ]) {
      test('failure marker "$marker" cannot verify', () {
        final placement = inspect('${pixel}E native : $marker\n');
        expect(placement['verified'], isFalse);
        expect(placement['failure_markers'], hasLength(1));
        expect(
          placement['reason'],
          'native log reports a GPU delegate failure or CPU fallback',
        );
      });
    }

    test('every expected load needs its own adapter and environment', () {
      final lines = const LineSplitter().convert(pixel);
      final third = lines.lastIndexWhere(
        (line) => line.contains('Selected adapter:'),
      );
      final twoLoads = lines.take(third).map((line) => '$line\n').join();
      final placement = inspect(twoLoads);
      expect(placement['verified'], isFalse);
      expect(placement['adapter_records'], 2);
      expect(placement['expected_loads'], 3);

      rejects('$pixel$pixel', reason: 'six loads for three load cases');
      rejects(
        '${pixel}I native  : Selected adapter: Mali-G715\n',
        reason: 'a fourth, unparsed adapter selection',
      );
      // Two complete loads and a third that only names an adapter.
      final partial = [
        ...lines.take(third),
        'I native  : Selected adapter: Mali-G715',
      ].map((line) => '$line\n').join();
      expect(inspect(partial)['adapter_records'], 3);
      rejects(partial, reason: 'the third load selected no parsed adapter');
      for (var load = 0; load < 3; load++) {
        rejects(
          _withoutLine(pixel, 'Created a WebGPU environment.', index: load),
          reason: 'load $load has no created environment',
        );
        rejects(
          _withoutLine(pixel, 'Selected adapter:', index: load),
          reason: 'load $load selected no adapter',
        );
      }
      rejects(
        '$pixel'
        'I litert  : [delegate_webgpu.cc:1] Created a WebGPU environment.\n',
      );
    });

    test('every main-model signature of every load needs a delegate', () {
      for (var record = 0; record < 12; record++) {
        final placement = inspect(_withoutLine(pixel, _kernel, index: record));
        expect(placement['verified'], isFalse, reason: 'record $record');
        expect(placement['delegate_records'], 11);
      }
      rejects('${pixel}I native  : Total 31 $_kernel\n', reason: 'thirteen');

      // Twelve records, but one load has three and another five.
      final lines = const LineSplitter().convert(pixel);
      final first = lines.indexWhere((line) => line.contains(_kernel));
      final moved = lines.removeAt(first);
      lines.add(moved);
      final uneven = lines.map((line) => '$line\n').join();
      expect(RegExp(_kernel).allMatches(uneven), hasLength(12));
      rejects(uneven, reason: 'uneven');

      // Records logged before any adapter selection belong to no load.
      rejects(
        'I native  : Total 31 $_kernel\n$pixel',
        reason: 'delegate kernel before the first load',
      );
      rejects(
        'I litert  : Created a WebGPU environment.\n$pixel',
        reason: 'environment before the first load',
      );
    });

    test('the signature count comes from each load\'s main model', () {
      const main = 'Loaded: num_subgraphs=976, num_signatures=4';
      expect(RegExp(main).allMatches(pixel), hasLength(3));
      // The embedding models load after the delegate kernels of each load.
      expect(
        RegExp('Loaded: num_subgraphs=1, num_signatures=1').allMatches(pixel),
        hasLength(12),
      );
      for (var load = 0; load < 3; load++) {
        rejects(
          _replaceNth(
            pixel,
            main,
            'Loaded: num_subgraphs=976, num_signatures=5',
            load,
          ),
          reason: 'load $load declares five signatures',
        );
        rejects(
          _withoutLine(pixel, main, index: load),
          reason: 'load $load has no main-model record',
        );
      }
      final none = const LineSplitter()
          .convert(
            pixel.replaceAll(
              main,
              'Loaded: num_subgraphs=976, num_signatures=0',
            ),
          )
          .where((line) => !line.contains(_kernel))
          .map((line) => '$line\n')
          .join();
      rejects(none, reason: 'zero signatures');
    });

    test('only one hardware Vulkan adapter qualifies', () {
      String adapter(String identity) => pixel.replaceAll(_mali, identity);
      for (final identity in [
        'Mali-G715, arch=valhall, vendor=arm, backend=Vulkan, adapterType=CPU',
        'SwiftShader Device (Subzero), arch=swiftshader, vendor=google, '
            'backend=Vulkan, adapterType=CPU',
        'SwiftShader Device (Subzero), arch=swiftshader, vendor=google, '
            'backend=Vulkan, adapterType=Integrated GPU',
        'Mali-G715, arch=swiftshader, vendor=google, backend=Vulkan, '
            'adapterType=Integrated GPU',
        'llvmpipe (LLVM 17.0.6 256 bits), arch=, vendor=mesa, backend=Vulkan, '
            'adapterType=Integrated GPU',
        'Intel lavapipe, arch=, vendor=mesa, backend=Vulkan, '
            'adapterType=Discrete GPU',
        'Microsoft Basic Render Driver, arch=, vendor=microsoft, '
            'backend=Vulkan, adapterType=Integrated GPU',
        'Intel Basic Render, arch=, vendor=, backend=Vulkan, '
            'adapterType=Integrated GPU',
        'Adreno software renderer, arch=, vendor=, backend=Vulkan, '
            'adapterType=Integrated GPU',
        'Mali CPU fallback, arch=, vendor=arm, backend=Vulkan, '
            'adapterType=Integrated GPU',
        'Generic Accelerator, arch=, vendor=, backend=Vulkan, '
            'adapterType=Integrated GPU',
        'Mali-G715, arch=valhall, vendor=arm, backend=Vulkan, '
            'adapterType=Unknown',
        'Mali-G715, arch=valhall, vendor=arm, backend=OpenGLES, '
            'adapterType=Integrated GPU',
        'Apple A18 Pro GPU, arch=, vendor=apple, backend=Metal, '
            'adapterType=Integrated GPU',
        'NVIDIA L4, arch=, vendor=nvidia, backend=D3D12, '
            'adapterType=Discrete GPU',
        'Mali-G715',
      ]) {
        expect(
          RegExp('Selected adapter').allMatches(adapter(identity)),
          hasLength(3),
        );
        rejects(adapter(identity), reason: identity);
      }
      const discrete =
          'NVIDIA L4, arch=, vendor=nvidia, backend=Vulkan, '
          'adapterType=Discrete GPU';
      expect(inspect(adapter(discrete))['adapter'], discrete);
      expect(inspect(adapter(discrete))['verified'], isTrue);

      for (var load = 0; load < 3; load++) {
        final mixed = inspect(_replaceNth(pixel, _mali, _adreno, load));
        expect(mixed['verified'], isFalse, reason: 'load $load');
        expect(mixed['adapter'], isNull);
        expect(mixed['adapter_records'], 3);
      }
    });

    test('load cases must each pass once reporting the GPU backend', () {
      List<Map<String, dynamic>> edited(
        void Function(List<Map<String, dynamic>>) edit,
      ) {
        final records = cases();
        edit(records);
        return records;
      }

      Map<String, dynamic> load(
        List<Map<String, dynamic>> records,
        String id,
      ) => records.singleWhere((record) => record['case_id'] == id);

      for (final id in ['C01.load', 'C09.reload', 'C12.recovery']) {
        for (final (reason, records) in [
          (
            'reports the CPU backend',
            edited(
              (records) =>
                  (load(records, id)['diagnostics'] as Map)['backend_name'] =
                      'LiteRT-LM cpu',
            ),
          ),
          (
            'has no diagnostics',
            edited((records) => load(records, id).remove('diagnostics')),
          ),
          ('failed', edited((records) => load(records, id)['status'] = 'FAIL')),
          (
            'is missing',
            edited((records) => records.remove(load(records, id))),
          ),
          (
            'passed twice',
            edited((records) => records.add({...load(records, id)})),
          ),
        ]) {
          final placement = inspect(pixel, records: records);
          expect(placement['verified'], isFalse, reason: '$id $reason');
          expect(
            placement['reason'],
            'expected load cases did not each pass once reporting the GPU '
            'backend',
          );
        }
      }
    });

    test('GGUF and LiteRT evidence do not cross runtimes', () {
      const offload =
          'load_tensors: offloaded 7/7 layers to GPU\n'
          'Vulkan0 compute buffer size = 64.0 MiB\n';
      const device = 'ggml_vulkan: 0 = Mali-G715\n';
      rejects('$device${offload * 3}');

      final gguf = <String, dynamic>{
        'schema_version': 1,
        'profile': jsonDecode(
          File('assets/profiles/tiny-gguf-vulkan.json').readAsStringSync(),
        ),
        'environment': manifest()['environment'],
      };
      final loads = [
        for (final id in ['C01.load', 'C09.reload', 'C12.recovery'])
          <String, dynamic>{
            'case_id': id,
            'status': 'PASS',
            'diagnostics': {'backend_name': 'Vulkan0 gpu'},
          },
      ];
      expect(
        inspectPlacement(gguf, loads, '$device${offload * 3}')['verified'],
        isTrue,
      );
      final crossed = inspectPlacement(gguf, loads, pixel);
      expect(crossed['verified'], isFalse);
      expect(crossed.containsKey('placement'), isFalse);
    });

    test('only the Android WebGPU-on-Vulkan shape is defined', () {
      Map<String, dynamic> on(Map<String, dynamic> environment) => {
        ...manifest(),
        'environment': {...manifest()['environment'] as Map, ...environment},
      };
      for (final environment in [
        {'platform': 'ios'},
        {'platform': 'macos'},
        {'platform': 'windows'},
        {'platform': 'linux'},
        {'platform': 'web'},
        {'web': true},
        {'platform': null},
      ]) {
        final placement = inspect(pixel, of: on(environment));
        expect(placement['verified'], isFalse, reason: '$environment');
        expect(
          placement['reason'],
          'LiteRT GPU placement evidence is defined only for Android WebGPU '
          'on Vulkan',
        );
      }
      expect(
        inspect(pixel, of: {...manifest()}..remove('environment'))['verified'],
        isFalse,
      );
      expect((manifest()['environment'] as Map)['litert_tag'], '0.18.0');
      for (final tag in ['0.19.0', '0.18.1', '0.18.0-1', '0.17.0-8', null]) {
        final placement = inspect(pixel, of: on({'litert_tag': tag}));
        expect(placement['verified'], isFalse, reason: '$tag');
        expect(
          placement['reason'],
          'LiteRT-LM tag is not source-qualified for GPU-only delegation',
        );
      }

      // An iPhone log names no adapter; nothing else in it can stand in.
      final adapterless = const LineSplitter()
          .convert(pixel)
          .where((line) => !line.contains('Selected adapter:'))
          .map((line) => '$line\n')
          .join();
      rejects(adapterless);
      expect(
        inspect(adapterless, of: on({'platform': 'ios'}))['verified'],
        isFalse,
      );
      rejects('');
      rejects('GPU success');
    });
  });
}
