import 'dart:ffi';
import 'dart:io';

import '../../../../test/fixtures/image_vm_shutdown_probe.dart' as probe;

Future<void> main(List<String> arguments) async {
  if (Platform.isMacOS) {
    final frameworks = Platform.environment['IMAGE_VM_FRAMEWORKS']!;
    DynamicLibrary.open('$frameworks/llama.framework/llama');
    DynamicLibrary.open(
      '$frameworks/stable_diffusion.framework/stable_diffusion',
    );
  }
  await probe.main(arguments);
}
