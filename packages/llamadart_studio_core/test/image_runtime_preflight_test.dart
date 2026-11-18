import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';
import 'package:test/test.dart';

String? _missingIcd() => 'Linux Vulkan ICD is unavailable';

void main() {
  test(
    'unusable Linux Vulkan refuses before the native runtime probe',
    () async {
      final port = DirectLlamaImagePort(
        requiresLinuxVulkan: true,
        linuxVulkanProbe: _missingIcd,
      );
      addTearDown(port.dispose);

      final capabilities = await port.checkRuntime();

      expect(capabilities.isSupported, isFalse);
      expect(capabilities.unsupportedReason, _missingIcd());
    },
  );

  test('programmatic image load cannot bypass an unavailable ICD', () async {
    final port = DirectLlamaImagePort(
      requiresLinuxVulkan: true,
      linuxVulkanProbe: _missingIcd,
    );
    addTearDown(port.dispose);
    final assets = ResolvedModelAssets(
      descriptor: const StudioModelDescriptor(
        id: 'unread-image',
        name: 'Unread image',
        description: '',
        category: StudioModelCategory.image,
        filename: 'missing.gguf',
        sourceUri: '/not-a-model.gguf',
      ),
      primarySource: ModelSource.path('/not-a-model.gguf'),
    );

    await expectLater(
      port.loadModel(assets: assets),
      throwsA(
        isA<LlamaUnsupportedException>().having(
          (error) => error.toString(),
          'reason',
          contains(_missingIcd()),
        ),
      ),
    );
  });
}
