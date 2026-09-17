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
  for (final native in [true, false]) {
    for (final focused in [false, true]) {
      test(
        'NPU proof requires all generations: native=$native focused=$focused',
        () {
          final data = profile.toJson();
          if (native) data['execution_path'] = 'native_c_api';
          if (focused) {
            data['selection'] = 'focused';
            data['focus_features'] = ['lifecycle'];
          }
          final target = data['npu_target'] as Map;
          final locks = target['libraries'] as Map;
          final manifest = <String, dynamic>{
            'schema_version': focused ? 2 : 1,
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
            if (!native) 'C03.raw',
            'C04.hello',
            'C04.arithmetic',
            'C06.history',
            if (native) ...[
              'C06.history.public_system_wire',
              'C06.history.no_system',
              'C06.history.combined',
            ],
            if (!native) 'C08.cancel',
            'C09.reload',
            if (!native) ...['C10.limit', 'C12.recovery'],
            'B01.warmup',
            'B01.1',
            'B01.2',
            'B01.3',
            if (focused) 'C09.reload.second',
          ]) {
            Map<String, dynamic> generation() {
              final before = [1, count, count, 0, 0, 0, 0];
              count++;
              return {
                'npu_execution': {
                  'before': before,
                  'after': [1, count, count, 0, 0, 0, 0],
                  'verified': true,
                },
              };
            }

            final control = id == 'C08.cancel' ? generation() : null;
            final record = generation();
            cases.add({
              'case_id': id,
              'status': 'PASS',
              ...record,
              if (control != null) ...{
                'uncancelled_control': control,
                'recovery': generation(),
              },
            });
          }
          expect(inspectPlacement(manifest, cases, null)['verified'], true);
          expect(
            inspectPlacement(manifest, cases, null)['proven_generations'],
            (native ? 11 : 14) + (focused ? 1 : 0),
          );
          for (final missing in cases.map((record) => record['case_id'])) {
            expect(
              inspectPlacement(
                manifest,
                cases.where((record) => record['case_id'] != missing).toList(),
                null,
              )['verified'],
              false,
              reason: '$missing requires independent NPU proof',
            );
          }
          expect(
            inspectPlacement(manifest, cases.sublist(1), null)['verified'],
            false,
          );
          final proof = cases.last.remove('npu_execution');
          expect(inspectPlacement(manifest, cases, null)['verified'], false);
          cases.last['npu_execution'] = proof;
          (cases.last['npu_execution'] as Map)['after'] = [1, 6, 6, 0, 1, 0, 0];
          expect(inspectPlacement(manifest, cases, null)['verified'], false);
        },
      );
    }
  }
}
