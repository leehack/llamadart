import 'dart:convert';
import 'dart:io';

import 'package:llamadart_validation/llamadart_validation.dart';
import 'package:llamadart_validation/src/placement.dart';
import 'package:test/test.dart';

void main() {
  final profile = ValidationProfile.fromJson(
    jsonDecode(
          File('assets/profiles/npu-qualcomm-sm8650.json').readAsStringSync(),
        )
        as Map<String, dynamic>,
  );
  test(
    'NPU device guard rejects the wrong SoC, ABI and API before loading',
    () {
      final valid = <String, dynamic>{
        'soc_model': 'SM8650',
        'abi': 'arm64-v8a',
        'android_api': 36,
      };
      validateNpuDevice(profile, valid);
      for (final invalid in [
        {...valid, 'soc_model': 'Tensor G4'},
        {...valid, 'abi': 'x86_64'},
        {...valid, 'android_api': 30},
        {...valid, 'android_api': null},
      ]) {
        expect(() => validateNpuDevice(profile, invalid), throwsStateError);
      }
    },
  );
  test(
    'only completed synchronous work in this generation is positive proof',
    () {
      const before = [1, 10, 10, 0, 0, 0, 0];
      expect(
        npuGenerationEvidence(before, [1, 12, 12, 0, 0, 0, 0])['verified'],
        true,
      );
      for (final after in [
        before,
        [1, 12, 11, 1, 0, 0, 0],
        [1, 12, 12, 0, 0, 0, 1],
        [1, 0, 0, 0, 0, 0, 0],
        [1, 10, 10, 0, 1, 0, 0],
        [1, 10, 10, 0, 0, 1, 0],
        [2, 12, 12, 0, 0, 0, 0],
        [1],
      ]) {
        expect(
          npuGenerationEvidence(before, after)['verified'],
          false,
          reason: '$after',
        );
      }
    },
  );
  test('report rechecks raw deltas and requires every reference generation', () {
    final data = profile.toJson()..['execution_path'] = 'native_c_api';
    final target = data['npu_target'] as Map;
    final locks = target['libraries'] as Map;
    final manifest = <String, dynamic>{
      'profile': data,
      'accelerator_evidence_required': true,
      'environment': {'litert_tag': '0.17.0-3'},
      'preparation': {
        'npu': {
          'device': {
            'soc_model': 'SM8650',
            'abi': 'arm64-v8a',
            'verified': true,
            'android_api': 36,
          },
          'kit': {
            'schema_version': 1,
            'litert_revision': '9fe5be45564c868408e6514c8aabb83e211a0911',
            'dispatch_header_sha256':
                '11dd4d98bd084157ac987b1ee1951f3f96e2b3ca6b51a27c10e645686bf0e3ee',
            'target': target['soc'],
            'runtime_tag': '0.17.0-3',
            'libraries': {
              for (final entry in locks.entries)
                entry.key: {
                  'bytes': 1024,
                  'sha256':
                      (entry.value as Map)['sha256'] ??
                      List.filled(64, 'a').join(),
                },
            },
          },
        },
      },
    };
    final cases = <Map<String, dynamic>>[];
    var count = 0;
    for (final id in [
      'C04.hello',
      'C04.arithmetic',
      'C06.history',
      'C06.history.public_system_wire',
      'C06.history.no_system',
      'C06.history.combined',
      'C09.reload',
      'B01.warmup',
      'B01.1',
      'B01.2',
      'B01.3',
    ]) {
      cases.add({
        'case_id': id,
        'status': 'PASS',
        'npu_execution': {
          'before': [1, count, count, 0, 0, 0, 0],
          'after': [1, count + 1, count + 1, 0, 0, 0, 0],
          'verified': true,
        },
      });
      count++;
    }
    expect(inspectPlacement(manifest, cases, null)['verified'], true);
    for (final missing in [
      'C06.history',
      'C06.history.public_system_wire',
      'C06.history.no_system',
      'C06.history.combined',
    ]) {
      expect(
        inspectPlacement(
          manifest,
          cases.where((record) => record['case_id'] != missing).toList(),
          null,
        )['verified'],
        false,
        reason: 'Every history control requires independent NPU proof',
      );
    }
    expect(
      inspectPlacement(manifest, cases.sublist(1), null)['verified'],
      false,
    );
    (cases.last['npu_execution'] as Map)['after'] = [1, 6, 6, 0, 1, 0, 0];
    expect(inspectPlacement(manifest, cases, null)['verified'], false);
  });
}
