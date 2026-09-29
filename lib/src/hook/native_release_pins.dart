/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.5.0';

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.17.0-6';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.17.0-6';

/// A published LiteRT-LM runtime archive and the libraries it must contain.
class LiteRtLmBundleSpec {
  /// Release bundle key such as `linux-x64`.
  final String bundle;

  /// SHA-256 of the published `.tar.gz` archive.
  final String sha256;

  /// Library file names the extracted archive must provide.
  final Set<String> requiredLibraries;

  /// Creates a spec for [bundle].
  const LiteRtLmBundleSpec(
    this.bundle, {
    required this.sha256,
    required this.requiredLibraries,
  });
}

/// Every LiteRT-LM bundle the hook can download, keyed by [LiteRtLmBundleSpec.bundle].
const liteRtLmBundleSpecs = <LiteRtLmBundleSpec>[
  LiteRtLmBundleSpec(
    'android-arm64',
    sha256: '807021ae83dc36a40c7cae1fee6dd4ab37d5611e1e847fc6ad49da9edbfb4b09',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtTopKOpenClSampler.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'android-x64',
    sha256: '45a169baa9c3231c620fe242b2dc1f2ff9a6072f6482d61713e1093119e38ec1',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtTopKOpenClSampler.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64',
    sha256: '8a3b9d15fb7f058602ea376766e64793716b2f4ead4febea1f0cbddd54783a63',
    requiredLibraries: {
      'CLiteRTLM',
      'GemmaModelConstraintProvider',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: 'd0b8d926e512251c3c735a5455b6a4661c30fe6256b8a7fd72d97c317caac446',
    requiredLibraries: {
      'CLiteRTLM',
      'GemmaModelConstraintProvider',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: 'dceade08abc09a8e652cf182d7c9de633244db6cbffb1d125e52e535b356ec66',
    requiredLibraries: {
      'libCLiteRTLM_mac.dylib',
      'libGemmaModelConstraintProvider.dylib',
      'libLiteRt.dylib',
      'libLiteRtLm.dylib',
      'libLiteRtMetalAccelerator.dylib',
      'libLiteRtTopKMetalSampler.dylib',
      'libLiteRtTopKWebGpuSampler.dylib',
      'libLiteRtWebGpuAccelerator.dylib',
      'libwebgpu_dawn.dylib',
    },
  ),
  LiteRtLmBundleSpec(
    'macos-x64',
    sha256: '82cf3b4034d36d234699fb506ad87e5575813b8346bb87d4603b9f89c6dfb1e4',
    requiredLibraries: {'libCLiteRTLM_mac.dylib', 'libLiteRtLm.dylib'},
  ),
  LiteRtLmBundleSpec(
    'linux-arm64',
    sha256: '89d5d65a0a0090028441527894108ce2913a76a33eeece1b918271776be53980',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'linux-x64',
    sha256: 'a6c049d97f4e72d59fb6307d8c7c62fb3fffa0434471f6e9204ee501952ca9db',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtTopKWebGpuSampler.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'windows-x64',
    sha256: 'af49f2189deb504b57e275ad5aa1934f04c1a01632ee7e52d08464ea9915e625',
    requiredLibraries: {
      'LiteRtLm.dll',
      'dxcompiler.dll',
      'dxil.dll',
      'libGemmaModelConstraintProvider.dll',
      'libLiteRt.dll',
      'libLiteRtTopKWebGpuSampler.dll',
      'libLiteRtWebGpuAccelerator.dll',
      'libwebgpu_dawn.dll',
    },
  ),
];

/// `leehack/stable-diffusion-native` release tag downloaded for the opt-in
/// stable-diffusion.cpp runtime.
const stableDiffusionReleaseTag = 'v0.1.0';

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.1.0';

/// A published stable-diffusion-native runtime archive and the library it must
/// contain under `lib/`.
class StableDiffusionBundleSpec {
  /// Release bundle key such as `linux-x64-vulkan`.
  final String bundle;

  /// SHA-256 of the published `.tar.gz` archive.
  final String sha256;

  /// Library file names the archive must provide under `lib/`.
  final Set<String> requiredLibraries;

  /// Creates a spec for [bundle].
  const StableDiffusionBundleSpec(
    this.bundle, {
    required this.sha256,
    required this.requiredLibraries,
  });
}

/// Every stable_diffusion bundle the hook can download, keyed by
/// [StableDiffusionBundleSpec.bundle].
const stableDiffusionBundleSpecs = <StableDiffusionBundleSpec>[
  StableDiffusionBundleSpec(
    'android-arm64',
    sha256: 'f845703f4c4447b280c9fda4cc0f1ad7f68fd2b1ebc36182fc7d50b5d4c66455',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: '1e59db14c12c093705073f0db2a44377c111c208c6778c47cc3f483771671e86',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: 'f80e6c3d6b5807ddb80d74e680ba053d760a04e765d26d9236ecac94e13c9676',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: '1c861b33d5463c85ada89b54d40a7b440074d98298af49555212c5364d8534e3',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: 'e9c067c5c40864e4f4afdb523c757eb8b009171b9240fc28d8e4614d0b340503',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: 'a0f5532f979ff57c9b18c245d4a32b245ed53c122b0284a7d2b7597b26d7150f',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: '7bc90af228e098efebf102bcbfa2ec7b08111194d9304a3e701fbd71cc4df517',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: 'a7028bf593da0d284dc5de63fec37dc777198cd3c27b262de553b68e505091bc',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: 'd667cc8c980d9664662f92e72c9f3be5fd13b4f9757138a02b85505a341837ff',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: 'b1957763b873ef674dce717d05bff0c3fb77deb59acf6a625554446f770fe798',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: 'd583e9276d93e6dc1af646cb27d8e1fb6584d4b008c08b57e7b3a316be83636a',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
