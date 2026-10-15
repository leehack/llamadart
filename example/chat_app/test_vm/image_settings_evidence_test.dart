import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/src/core/image/png_encoder.dart';
import 'package:path/path.dart' as p;

import '../integration_test/support/image_settings_evidence.dart';
import '../integration_test/support/process_peak_memory.dart';

const _commit = 'dfc58e7998bd751a9084bfa36d9ab9a90ba6d963';

Uint8List _png(int value, {int size = 512}) => encodePng(
  width: size,
  height: size,
  channels: 3,
  pixels: Uint8List.fromList(List.filled(size * size * 3, value)),
);

String _hash(Uint8List bytes) => sha256.convert(bytes).toString();

Map<String, dynamic> _load(
  String variant,
  String arm, {
  int round = 0,
  List<int> ms = const [100],
  String? hash,
  int peak = 1000,
  String status = 'ok',
  String backend = 'CPU',
}) => {
  'type': 'load',
  'variant': variant,
  'arm': arm,
  'round': round,
  'status': status,
  if (status == 'ok') ...{
    'backend': backend,
    'load_ms': 10,
    'warmup': {'wall_ms': 150},
    'generations': [
      for (final value in ms)
        {
          'wall_ms': value,
          'sampling_ms': value ~/ 2,
          'decode_ms': value - value ~/ 2,
          'sha256': hash,
        },
    ],
    'memory': {'peak_bytes': peak},
  } else ...{
    'error_type': 'LlamaModelException',
    'error_message':
        'The image model needs about 2.6 GiB, but only 2.4 GiB is available. '
        'Set $imageSettingsMemoryRefusalMarker to false to try anyway.',
  },
};

Matcher _rejects(String detail) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', contains(detail)),
);

void main() {
  late Directory directory;
  setUp(
    () => directory = Directory.systemTemp.createTempSync(
      'image-settings-evidence-test-',
    ),
  );
  tearDown(() => directory.deleteSync(recursive: true));

  group('summarizeImageSettingsLoads', () {
    test('takes medians and per-load peak spread against auto', () {
      final a = _hash(_png(1));
      final b = _hash(_png(2));
      final rows = summarizeImageSettingsLoads([
        _load('sdxs', 'auto', ms: [100], hash: a, peak: 900),
        _load('sdxs', 'both_off', ms: [200], hash: b, peak: 1200),
        _load('sdxs', 'both_off', round: 1, ms: [300], hash: b, peak: 1100),
        _load('sdxs', 'auto', round: 1, ms: [120], hash: a, peak: 950),
      ], imageSettingsVariants.keys.toList());
      final auto = rows.firstWhere((row) => row['arm'] == 'auto');
      final off = rows.firstWhere((row) => row['arm'] == 'both_off');
      expect(auto['ms_per_image_median'], 110);
      expect(auto['peak_bytes_min'], 900);
      expect(auto['peak_bytes_max'], 950);
      expect(auto['deterministic'], isTrue);
      expect(off['ms_per_image_median'], 250);
      expect(off['decode_ms_median'], 125);
      expect(off['vs_auto'], {
        'auto_ms_ratio': 0.44,
        'auto_peak_delta_bytes': -200,
        'same_image': false,
      });
      expect(
        rows.where((row) => row['variant'] == 'sd_turbo_vae'),
        hasLength(3),
      );
      expect(
        rows.where((row) => row['variant'] != 'sdxs').map((r) => r['status']),
        everyElement('not_run'),
      );
    });

    test('marks a changing hash as not deterministic', () {
      final rows = summarizeImageSettingsLoads(
        [
          _load('sdxs', 'auto', hash: _hash(_png(1))),
          _load('sdxs', 'auto', round: 1, hash: _hash(_png(2))),
        ],
        ['sdxs'],
      );
      expect(rows.first['deterministic'], isFalse);
      expect(rows.first['sha256'], isNull);
    });

    test('summarizes only the variants a run compares', () {
      final rows = summarizeImageSettingsLoads([], ['sd_turbo_vae']);
      expect(rows.map((row) => row['arm']), [
        'auto',
        'both_off',
        'vae_direct_off',
      ]);
      expect(rows.map((row) => row['status']), everyElement('not_run'));
    });
  });

  group('image settings receipts', () {
    final png = _png(7);
    final hash = _hash(png);
    final refusedVariants = ['sd_turbo_taesd', 'sd_turbo_vae'];

    Future<Map<String, dynamic>> write({
      List<Map<String, dynamic>>? loads,
      Map<String, Uint8List>? pngs,
      List<String>? variants,
      List<String>? expectedRefusals,
      int rounds = 1,
      int measured = 1,
    }) {
      return writeImageSettingsEvidence(
        directory: directory,
        pngs:
            pngs ??
            {
              for (final arm in imageSettingsVariants['sdxs']!)
                imageSettingsArtifactName('sdxs', arm): png,
            },
        receipt: {
          'source_commit': _commit,
          'source_dirty': false,
          'runtime_tag': 'v0.2.0-3',
          'model_locks': [
            {'filename': 'a.gguf'},
          ],
          'request': {'seed': 42, 'width': 512, 'height': 512},
          'variants':
              variants ??
              (loads == null ? imageSettingsVariants.keys.toList() : ['sdxs']),
          'expected_refusals':
              expectedRefusals ?? (loads == null ? refusedVariants : []),
          'rounds': rounds,
          'measured_per_load': measured,
          'loads':
              loads ??
              [
                for (final arm in imageSettingsVariants['sdxs']!)
                  _load('sdxs', arm, hash: hash),
                for (final variant in refusedVariants)
                  _load(variant, 'auto', status: 'refused'),
              ],
        },
      );
    }

    List<Map<String, dynamic>> sdxsLoads({int rounds = 1}) => [
      for (var round = 0; round < rounds; round++)
        for (final arm in imageSettingsVariants['sdxs']!)
          _load('sdxs', arm, round: round, hash: hash),
    ];

    test('verify completed arms and declared memory refusals', () async {
      final manifest = await write();
      expect(manifest['artifacts'], hasLength(2));
      final verified = verifyImageSettingsEvidence(
        directory,
        expectedCommit: _commit,
        expectedBackend: 'CPU',
        expectedRuntimeTag: 'v0.2.0-3',
        expectedModelLocks: [
          {'filename': 'a.gguf'},
        ],
        expectedRefusals: refusedVariants,
      );
      expect(
        (verified['summary'] as List).map((row) => (row as Map)['status']),
        containsAll(['ok', 'refused']),
      );
    });

    test('reject a run whose every variant was refused', () async {
      await expectLater(
        write(
          variants: ['sd_turbo_vae'],
          expectedRefusals: ['sd_turbo_vae'],
          pngs: {},
          loads: [_load('sd_turbo_vae', 'auto', status: 'refused')],
        ),
        _rejects('no measured arm'),
      );
    });

    test(
      'reject a refusal the receipt or the profile does not declare',
      () async {
        await expectLater(
          write(expectedRefusals: ['sd_turbo_taesd']),
          _rejects('undeclared refusal: sd_turbo_vae'),
        );
        await write();
        expect(
          () => verifyImageSettingsEvidence(
            directory,
            expectedRefusals: ['sd_turbo_vae'],
          ),
          _rejects('undeclared refusal: sd_turbo_taesd'),
        );
        expect(
          () => verifyImageSettingsEvidence(directory, expectedRefusals: ['x']),
          _rejects('expected refusals mismatch'),
        );
      },
    );

    test('reject a refusal that is not the memory check', () async {
      final refusals = <String, List<Map<String, dynamic>>>{
        'other error': [
          {
            ..._load('sd_turbo_vae', 'auto', status: 'refused'),
            'error_message': 'Out of memory',
          },
        ],
        'other exception': [
          {
            ..._load('sd_turbo_vae', 'auto', status: 'refused'),
            'error_type': 'LlamaException',
          },
        ],
        'more loads after the refusal': [
          _load('sd_turbo_vae', 'auto', status: 'refused'),
          _load('sd_turbo_vae', 'both_off', hash: hash),
        ],
      };
      for (final entry in refusals.entries) {
        await expectLater(
          write(
            variants: ['sdxs', 'sd_turbo_vae'],
            expectedRefusals: ['sd_turbo_vae'],
            loads: [...sdxsLoads(), ...entry.value],
          ),
          _rejects('other than the load-time memory check'),
          reason: entry.key,
        );
      }
    });

    test('reject a run smaller than its rounds and images per load', () async {
      await write(loads: sdxsLoads(rounds: 2), rounds: 2);
      await expectLater(
        write(loads: sdxsLoads(), rounds: 2),
        _rejects('run size mismatch: sdxs'),
      );
      await expectLater(
        write(loads: [...sdxsLoads(), sdxsLoads().first]),
        _rejects('run size mismatch: sdxs'),
      );
      await expectLater(
        write(loads: sdxsLoads(), measured: 2),
        _rejects('run size mismatch: sdxs'),
      );
      await expectLater(
        write(
          loads: [
            ...sdxsLoads(),
            _load('sd_turbo_vae', 'auto', hash: hash),
          ],
        ),
        _rejects('loads of other variants'),
      );
      await expectLater(
        write(loads: sdxsLoads(), rounds: 0),
        _rejects('run size missing'),
      );
    });

    test('reject arms that failed, were skipped or did not run', () async {
      for (final status in ['failed', 'skipped']) {
        await expectLater(
          write(
            loads: [
              _load('sdxs', 'auto', hash: hash),
              _load('sdxs', 'both_off', status: status),
            ],
          ),
          _rejects('did not complete'),
          reason: status,
        );
      }
      await expectLater(
        write(loads: [_load('sdxs', 'auto', hash: hash)]),
        _rejects('run size mismatch'),
      );
    });

    test('reject an arm whose loads disagree on the image', () async {
      await expectLater(
        write(
          rounds: 2,
          loads: [
            ...sdxsLoads(),
            _load('sdxs', 'auto', round: 1, hash: _hash(_png(8))),
            _load('sdxs', 'both_off', round: 1, hash: hash),
          ],
        ),
        _rejects('sdxs/auto did not complete deterministically (ok)'),
      );
    });

    test('reject a missing, altered or unexpected PNG', () async {
      await write();
      final auto = File(
        p.join(directory.path, imageSettingsArtifactName('sdxs', 'auto')),
      )..writeAsBytesSync(_png(8));
      expect(
        () => verifyImageSettingsEvidence(directory),
        _rejects('PNG identity mismatch'),
      );
      // The receipt's artifact entry alone does not vouch for the bytes: a
      // replaced PNG must also be the arm's generated image.
      final receipt = File(p.join(directory.path, imageSettingsReceiptName));
      final manifest = jsonDecode(receipt.readAsStringSync()) as Map;
      (manifest['artifacts'] as Map)[imageSettingsArtifactName(
        'sdxs',
        'auto',
      )] = {
        'bytes': auto.lengthSync(),
        'sha256': _hash(auto.readAsBytesSync()),
        'width': 512,
        'height': 512,
      };
      receipt.writeAsStringSync(jsonEncode(manifest));
      expect(
        () => verifyImageSettingsEvidence(directory),
        _rejects('PNG identity mismatch'),
      );
      await expectLater(
        write(pngs: {imageSettingsArtifactName('sdxs', 'auto'): _png(7)}),
        _rejects('artifact missing'),
      );
      await expectLater(
        write(
          pngs: {
            for (final arm in ['auto', 'both_off', 'vae_direct_off'])
              imageSettingsArtifactName('sdxs', arm): _png(7),
          },
        ),
        _rejects('extra artifacts'),
      );
    });

    test('reject a summary that its loads do not give', () async {
      await write();
      final file = File(p.join(directory.path, imageSettingsReceiptName));
      final manifest = jsonDecode(file.readAsStringSync()) as Map;
      ((manifest['summary'] as List).first as Map)['ms_per_image_median'] = 1;
      file.writeAsStringSync(jsonEncode(manifest));
      expect(
        () => verifyImageSettingsEvidence(directory),
        _rejects('summary does not match'),
      );
    });

    test('reject another build, backend, pin or model lock', () async {
      await write();
      for (final (detail, verify) in [
        (
          'source does not match',
          () =>
              verifyImageSettingsEvidence(directory, expectedCommit: 'a' * 40),
        ),
        (
          'backend mismatch',
          () => verifyImageSettingsEvidence(directory, expectedBackend: 'MTL0'),
        ),
        (
          'runtime pin mismatch',
          () =>
              verifyImageSettingsEvidence(directory, expectedRuntimeTag: 'v1'),
        ),
        (
          'model lock mismatch',
          () => verifyImageSettingsEvidence(
            directory,
            expectedModelLocks: [
              {'filename': 'b.gguf'},
            ],
          ),
        ),
        (
          'variants mismatch',
          () => verifyImageSettingsEvidence(
            directory,
            expectedVariants: ['sd_turbo_vae'],
          ),
        ),
      ]) {
        expect(verify, _rejects(detail));
      }
    });
  });

  test('procStatusBytes reads kB fields of /proc/<pid>/status', () {
    const status = 'VmHWM:\t  2048 kB\nVmRSS:\t  1024 kB\n';
    expect(procStatusBytes(status, 'VmRSS'), 1024 * 1024);
    expect(procStatusBytes(status, 'VmHWM'), 2048 * 1024);
    expect(procStatusBytes(status, 'VmSwap'), isNull);
  });
}
