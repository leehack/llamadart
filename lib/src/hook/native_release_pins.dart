/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.5.0-2';

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.17.0-8';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.17.0-8';

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
    sha256: '8afd2d06905f7d30f093a03a88a81cc387c018ef2002e77a8387c54db66a44e3',
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
    sha256: '559db3603551c86febc14d561794dd67cee13441f9a646865f05444bc5dbea88',
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
    sha256: '58e303376a36725b2890db5e08b6e8b98ff65bda22a399eb37919ff651e70d80',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: '708ec4d98acd7f39f40874f75674bd2f51cfceeec52acd623d01ef91b436fba0',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: 'fb4492a02cfa94080bf1b8b27c2ad20a011093dd4f6c88fea483e2c1b46d11f4',
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
    sha256: '89bf4fe36745d1ddddba0e194810d148cb1fbbdd76471298740769fd959ad551',
    requiredLibraries: {'libCLiteRTLM_mac.dylib', 'libLiteRtLm.dylib'},
  ),
  LiteRtLmBundleSpec(
    'linux-arm64',
    sha256: '8f98404ecc2b4580e4d475f630b5d91b9df90a802dd63a62a3c3e1b08d8a2113',
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
    sha256: '95f48ad2fcc97d33a847226a3f4917562e03957cb288fa9405889760f92ffbbc',
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
    sha256: 'a3515a6411ab4ed50f62b28531b2bbc725f3f1cc610bd48196e5b998affe1a89',
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
const stableDiffusionReleaseTag = 'v0.2.0';

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.2.0';

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
    sha256: '8c8c270a99612a4d33e9be87ec5fe67be790bcac89cece43da50fc12c05eb003',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: 'bedcd95f4f670ab38bec2b5140e2b907ad08b28cb84371af6170756a679aaa80',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: 'e131e9d519b2c9bed64b596e5026877aae295c152dca0498c8c940bdc26c47f0',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: '09323057b0941fd06edc08fb013d117661ba51457feda7ddddf39d57e7ebe9f5',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: '47c16a31bedbd755618f349b44a04605c4de504454dbc24a10ed581bb92c2652',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: '22bd8feea2cd05318c1e06f97663bb4c1301e97aef7979b6a084a9d038fc46c0',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: 'a6f8d8a2e4959d910ab8bb36088be71962a996de471570d429b2cdbec4b7681f',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: 'a64be0e2a1507d04844703bf1de08401c793060a8db555c77160a40fc95f19a4',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: 'af253cc4c4a17ca29f895c1c576d4aa92b35257df54832775d2ef6259463c07f',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: 'ea22ecc84d418eaf8b9473117dcceaf6df527014d07722634b46200d0f337c5e',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: 'cfef71403378a3555e7abbd15c10297dd24797548767cbd2a953b38af920ec47',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: 'a114817a3d933ae55cf0f49940a2909d6be3025db3dbc55399b0c63fc3fc9982',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
