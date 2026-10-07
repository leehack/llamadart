/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.5.0-2';

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.17.0-7';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.17.0-7';

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
    sha256: '7a636b43456a61987a65d81b274e8efdf28c3ac2a5a2619d57936e47a0528360',
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
    sha256: '68db8dae0c4e8248c7bdb346fdcb9ee49e4f539b1f1a34f6c2f28b28d1fc887f',
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
    sha256: '0711ba06ed6b9cffef6b6c66b5b2c56cfac0c7a68f58e8a47b1350ab9d2b04a8',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: 'ce5017b02ae5f7b3c5049bbcfa50ec95fa8012e49843b01cb54aa73eb87d3629',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: '51e1848ccd1cc2a6e33500812d8fccb27e7838e86dabbe3059d6641356f86c38',
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
    sha256: '7cecdd5bf754dc5195d95ffff12d2eb6bb4a95e0cc0c9f7a232586fc830fb358',
    requiredLibraries: {'libCLiteRTLM_mac.dylib', 'libLiteRtLm.dylib'},
  ),
  LiteRtLmBundleSpec(
    'linux-arm64',
    sha256: '89f76b9c709d842ecbc0ecbae345b75c2adbf6fe43f0a72985ef5f9559fea2fb',
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
    sha256: '645c1405d1b47d5f50425b7c5939e81adc74a31e62b209b01c80daad75b7e069',
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
    sha256: '1786c771322e7f87fedc917ef405c50a4a4de5daafe5f323eb7bee08ce11e741',
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
const stableDiffusionReleaseTag = 'v0.2.0-1';

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.2.0-1';

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
    sha256: 'a0bef58480c213a87dffb72f02bd47a89366510b7ac24f64120e2cfd64ed2c76',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: '82ebb318d695db75d6b384d84aaddb69a2dd369cf68e8411dc345c32e423a714',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: 'b6fa5ac2d35503d4183bf083ce10ed7a6c54a5a8db2eabfbaed5bfda8686d397',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: '1789de5de4c36821b677cff95307f5522d190c6621eeca86fccbc0880ebf27ed',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: '931f53883c1a31092e28d565c23e5b23e16fba655e1dc000621996d69f8721b1',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: '9c5c4d93c9ee6f4640f758a62ff3cfd4aa9ec28e0a6ae01aa12029a5104f7745',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: 'a32fac5728322e4d3aa985868bae6dcc7a1eda41a2a7cb322021c7a3302bec4d',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: 'ff9383e61f183ce5fc005a5bede927c57df35e701f690e70d68b741d9ed06cae',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: 'acad806da58a9aedf9e549bd8f949b24cef0535fca0d7b0870b4093ef6bcb103',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: '731008d6df747527ec91525d59ca44077f0b97ff0b16849ab77a410787336b0b',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: '3aa4028117330149cbb3c6b739841145381a9e0e9fba9e45c0a58c70c31d671a',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: '127234dcce7ab84a8ba740dfdd57206a0587c2b54edf5683335bae7b06776de3',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
