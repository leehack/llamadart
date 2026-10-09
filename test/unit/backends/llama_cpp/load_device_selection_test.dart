@TestOn('vm')
library;

import 'package:llamadart/src/backends/llama_cpp/bindings.dart';
import 'package:llamadart/src/backends/llama_cpp/load_device_selection.dart';
import 'package:llamadart/src/backends/llama_cpp/vulkan_device_probe.dart';
import 'package:test/test.dart';

final _cpuType = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_CPU.value;
final _accelType = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_ACCEL.value;
final _gpuType = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_GPU.value;
final _igpuType = ggml_backend_dev_type.GGML_BACKEND_DEVICE_TYPE_IGPU.value;

const _none = 0;
const _layer = 1;
const _tensor = 3;

const _vulkan11 = 1 << 22 | 1 << 12;
const _vulkan13 = 1 << 22 | 3 << 12;

GgmlDeviceEntry _device(
  String name, {
  int? type,
  String? registry,
  String? deviceId,
}) => GgmlDeviceEntry(
  name: name,
  type: type ?? _gpuType,
  registry: registry ?? name.replaceAll(RegExp(r'\d+$'), ''),
  deviceId: deviceId,
);

final _cpu = _device('CPU', type: _cpuType);
final _blas = _device('BLAS', type: _accelType);

// Vulkan facts by device index: the driver API version of each.
VulkanDeviceProbe Function() _facts(List<int> apiVersions) =>
    () => VulkanDeviceProbe.devices([
      for (final (index, version) in apiVersions.indexed)
        VulkanDeviceFacts(
          index: index,
          name: 'GPU $index',
          instanceApiVersion: _vulkan13,
          apiVersion: version,
          subgroupSize: 32,
        ),
    ]);

void main() {
  test('split modes match the llama_split_mode values', () {
    expect(llama_split_mode.LLAMA_SPLIT_MODE_NONE.value, _none);
    expect(llama_split_mode.LLAMA_SPLIT_MODE_LAYER.value, _layer);
    expect(llama_split_mode.LLAMA_SPLIT_MODE_TENSOR.value, _tensor);
  });

  group('selectModelDevices', () {
    List<String> select(
      List<GgmlDeviceEntry> registered, {
      List<GgmlDeviceEntry>? listed,
      int splitMode = _layer,
      int mainGpu = 0,
    }) => [
      for (final device in selectModelDevices(
        registered: registered,
        listed: listed,
        splitMode: splitMode,
        mainGpu: mainGpu,
      ))
        device.name,
    ];

    test('uses the listed devices as they are', () {
      final listed = [_device('Vulkan1', type: _igpuType), _device('Vulkan0')];

      expect(select([_cpu, _device('CUDA0')], listed: listed), [
        'Vulkan1',
        'Vulkan0',
      ]);
    });

    test('without a list takes the discrete GPUs and skips CPU and '
        'accelerator devices', () {
      expect(select([_cpu, _blas, _device('CUDA0'), _device('Vulkan0')]), [
        'CUDA0',
        'Vulkan0',
      ]);
    });

    test('takes integrated GPUs only when there is no discrete GPU, and '
        'then those of one backend', () {
      final igpu = _device('Vulkan1', type: _igpuType);

      expect(select([_cpu, _device('Vulkan0'), igpu]), ['Vulkan0']);
      expect(select([_cpu, igpu]), ['Vulkan1']);
      expect(
        select([
          igpu,
          _device('OpenCL0', type: _igpuType),
          _device('Vulkan2', type: _igpuType),
        ]),
        ['Vulkan1', 'Vulkan2'],
        reason: 'an integrated GPU of another backend is skipped',
      );
      expect(select([igpu, _device('Vulkan2', type: _igpuType)]), [
        'Vulkan1',
        'Vulkan2',
      ]);
    });

    test('skips a discrete GPU whose device id an earlier one has', () {
      expect(
        select([
          _device('CUDA0', deviceId: '0000:01:00.0'),
          _device('Vulkan0', deviceId: '0000:01:00.0'),
          _device('Vulkan1', deviceId: '0000:02:00.0'),
          _device('Vulkan2'),
          _device('Vulkan3'),
        ]),
        ['CUDA0', 'Vulkan1', 'Vulkan2', 'Vulkan3'],
      );
    });

    test('puts RPC servers first, and they do not count as discrete '
        'GPUs', () {
      final igpu = _device('Vulkan0', type: _igpuType);

      expect(select([igpu, _device('RPC0')]), ['RPC0', 'Vulkan0']);
      expect(select([_device('CUDA0'), igpu, _device('RPC0')]), [
        'RPC0',
        'CUDA0',
      ]);
    });

    test('tensor split mode takes every device that is not a CPU or an '
        'accelerator', () {
      expect(
        select([
          _cpu,
          _blas,
          _device('Vulkan0'),
          _device('Vulkan1', type: _igpuType),
        ], splitMode: _tensor),
        ['Vulkan0', 'Vulkan1'],
      );
    });

    test('single-device mode keeps the device mainGpu indexes, or none', () {
      final registered = [_device('Vulkan0'), _device('Vulkan1')];

      expect(select(registered, splitMode: _none), ['Vulkan0']);
      expect(select(registered, splitMode: _none, mainGpu: 1), ['Vulkan1']);
      expect(select(registered, splitMode: _none, mainGpu: 2), isEmpty);
      expect(select(registered, splitMode: _none, mainGpu: -1), isEmpty);
      expect(
        select(const [], listed: registered, splitMode: _none, mainGpu: 1),
        ['Vulkan1'],
      );
      expect(select([_cpu], splitMode: _none), isEmpty);
    });
  });

  group('resolveVulkanLoadDecision', () {
    late int registryReads;
    late int probeReads;

    setUp(() {
      registryReads = 0;
      probeReads = 0;
    });

    VulkanLoadDecision decide(
      List<GgmlDeviceEntry> registered,
      VulkanDeviceProbe Function() probe, {
      String? backend,
      bool usesGpu = true,
      int splitMode = _layer,
      int mainGpu = 0,
    }) => resolveVulkanLoadDecision(
      usesGpu: usesGpu,
      backendRegistry: backend,
      splitMode: splitMode,
      mainGpu: mainGpu,
      registered: () {
        registryReads++;
        return registered;
      },
      probe: () {
        probeReads++;
        return probe();
      },
    );

    Matcher unchanged() => isA<VulkanLoadDecision>()
        .having((d) => d.unsupported, 'unsupported', isNull)
        .having((d) => d.devices, 'devices', isNull)
        .having((d) => d.refused, 'refused', isFalse);

    Matcher without(String excluded, List<String> usable) =>
        isA<VulkanLoadDecision>()
            .having((d) => d.unsupported, 'unsupported', contains(excluded))
            .having(
              (d) => [for (final device in d.devices ?? const []) device.name],
              'devices',
              usable,
            )
            .having((d) => d.refused, 'refused', isFalse);

    Matcher refused(String device) => isA<VulkanLoadDecision>()
        .having((d) => d.unsupported, 'unsupported', contains(device))
        .having((d) => d.devices, 'devices', isNull)
        .having((d) => d.refused, 'refused', isTrue);

    final rtx = _device('Vulkan0', deviceId: '0000:01:00.0');
    final uhd = _device('Vulkan1', type: _igpuType);
    final cuda = _device('CUDA0', deviceId: '0000:01:00.0');

    test('a load that offloads nothing reads neither the registry nor the '
        'facts', () {
      expect(
        decide([_device('Vulkan0')], _facts([_vulkan11]), usesGpu: false),
        unchanged(),
      );
      expect((registryReads, probeReads), (0, 0));
    });

    test('refuses when the only selected device is below Vulkan 1.2, naming '
        'it and its versions', () {
      final decision = decide([_cpu, _device('Vulkan0')], _facts([_vulkan11]));

      expect(decision, refused('"GPU 0" (Vulkan0)'));
      expect(
        decision.unsupported,
        "llama.cpp's Vulkan backend needs Vulkan 1.2 or later from both the "
        'Vulkan loader and the GPU driver, and "GPU 0" (Vulkan0) reports '
        'driver API 1.1 with loader API 1.3',
      );
      expect(
        decide([_device('Vulkan0', type: _igpuType)], _facts([_vulkan11])),
        refused('(Vulkan0)'),
        reason: 'an integrated GPU is selected when it is the only GPU',
      );
    });

    test('a capable discrete GPU beside an integrated GPU on an old driver '
        'changes nothing: the integrated one is not selected', () {
      for (final registered in [
        [_cpu, rtx, uhd],
        [_cpu, cuda, rtx, uhd],
      ]) {
        expect(decide(registered, _facts([_vulkan13, _vulkan11])), unchanged());
      }
    });

    test('a CUDA GPU beside an old Vulkan device does not read the Vulkan '
        'facts when llama.cpp would not select that device', () {
      // The same physical GPU through Vulkan, and an integrated GPU.
      expect(
        decide([cuda, rtx, uhd], () => fail('no Vulkan device is selected')),
        unchanged(),
      );
      expect(probeReads, 0);
    });

    test('leaves out a selected device below Vulkan 1.2 when usable devices '
        'remain', () {
      expect(
        decide([
          _device('CUDA0', deviceId: '0000:01:00.0'),
          _device('Vulkan0', deviceId: '0000:02:00.0'),
        ], _facts([_vulkan11])),
        without('(Vulkan0)', ['CUDA0']),
      );
      expect(
        decide([
          _device('Vulkan0'),
          _device('Vulkan1'),
          _device('Vulkan2'),
        ], _facts([_vulkan13, _vulkan11, _vulkan13])),
        without('"GPU 1" (Vulkan1)', ['Vulkan0', 'Vulkan2']),
      );
    });

    test('an explicit backend is judged by its own devices only', () {
      final oldVulkan = _device('Vulkan0', deviceId: '0000:02:00.0');

      expect(
        decide(
          [cuda, oldVulkan],
          () => fail('CUDA lists no Vulkan device'),
          backend: 'CUDA',
        ),
        unchanged(),
      );
      expect(probeReads, 0);

      // The Vulkan backend lists every Vulkan device, integrated ones too.
      expect(
        decide(
          [cuda, rtx, uhd],
          _facts([_vulkan13, _vulkan11]),
          backend: 'Vulkan',
        ),
        without('(Vulkan1)', ['Vulkan0']),
      );
      expect(
        decide(
          [cuda, rtx, uhd],
          _facts([_vulkan11, _vulkan11]),
          backend: 'vulkan',
        ),
        refused('(Vulkan0)'),
      );
    });

    test('an explicit backend without a registered device falls back to '
        "llama.cpp's own selection", () {
      expect(
        decide([_device('Vulkan0')], _facts([_vulkan11]), backend: 'CUDA'),
        refused('(Vulkan0)'),
      );
    });

    test('single-device mode judges the device mainGpu selects', () {
      final registered = [_device('Vulkan0'), _device('Vulkan1')];
      final facts = _facts([_vulkan13, _vulkan11]);

      expect(decide(registered, facts, splitMode: _none), unchanged());
      expect(
        decide(registered, facts, splitMode: _none, mainGpu: 1),
        refused('(Vulkan1)'),
      );
      expect(
        decide(registered, facts, splitMode: _none, mainGpu: 5),
        unchanged(),
        reason: 'llama.cpp rejects the load before it starts a device',
      );
    });

    test('tensor split mode judges every GPU, integrated ones included', () {
      expect(
        decide([rtx, uhd], _facts([_vulkan13, _vulkan11]), splitMode: _tensor),
        without('(Vulkan1)', ['Vulkan0']),
      );
    });

    test('unknown devices are not refused', () {
      final registered = [_device('Vulkan0'), _device('Vulkan1')];

      expect(
        decide(
          registered,
          () => const VulkanDeviceProbe.unavailable('no loader'),
        ),
        unchanged(),
      );
      expect(
        decide(registered, _facts([_vulkan13])),
        unchanged(),
        reason: 'the facts do not cover Vulkan1',
      );
      expect(
        decide([_device('Renamed', registry: 'Vulkan')], _facts([_vulkan11])),
        unchanged(),
        reason: 'a name that is not VulkanN has no facts',
      );
      expect(decide([_device('Vulkan0')], _facts([_vulkan13])), unchanged());
    });

    test('a loader below Vulkan 1.2 counts like a driver below it', () {
      expect(
        decide(
          [_device('Vulkan0')],
          () => const VulkanDeviceProbe.devices([
            VulkanDeviceFacts(
              index: 0,
              name: 'Mali-G52',
              instanceApiVersion: _vulkan11,
              apiVersion: _vulkan13,
              subgroupSize: 4,
            ),
          ]),
        ).unsupported,
        endsWith(
          '"Mali-G52" (Vulkan0) reports driver API 1.3 with loader API 1.1',
        ),
      );
    });
  });
}
