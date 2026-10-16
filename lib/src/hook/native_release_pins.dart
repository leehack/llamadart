/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.7.0';

/// The first `llamadart_llama_cpp_flutter` release whose `Package.swift` pins
/// [llamaCppTag].
///
/// Incompatible-companion build errors name it, because a caret constraint on
/// an earlier companion can never resolve it. A core from
/// `appleCompanionLockstepStart` on names it only when it shares the core's
/// `MAJOR.MINOR`, and its own minor's first release otherwise. The native pin
/// sync sets it to the companion's next release whenever it moves the
/// companion pin.
const llamaCppAppleCompanionVersion = '0.14.0';

/// Earlier `leehack/llamadart-native` tags that a published Apple llama.cpp
/// companion pins and the build still accepts, each mapped to what its
/// frameworks lack compared with [llamaCppTag].
///
/// Every entry must be a wrapper rebuild of the same upstream llama.cpp
/// release as [llamaCppTag]: the same `vMAJOR.MINOR.PATCH` prefix, which the
/// native release manifest binds to one upstream commit, with byte-identical
/// headers and thin binaries, so its frameworks are ABI- and symbol-identical
/// to the ones the Dart bindings expect. The build accepts such a companion
/// with a warning. The native pin sync clears this map whenever it moves
/// [llamaCppTag], because each entry is verified against one pin.
const llamaCppCompatibleAppleCompanionTags = <String, String>{};

/// SHA-256 of each published `llamadart-native-<bundle>-<llamaCppTag>.tar.gz`
/// archive, keyed by bundle.
///
/// The hook verifies a downloaded or cached archive of the pinned release
/// against this map before extracting it.
const llamaCppBundleSha256 = <String, String>{
  'android-arm64':
      'a272fb8e5ea692fe4b93f2368c4c1a774f37320a1038b6145cae4e6186064fdd',
  'android-x64':
      '4be5ee439bc26402a288d5e08796c8d42604b4fa8880a3395b7f6d24f46026d1',
  'ios-arm64':
      '6824bb95723d9a88e5edeb9ddf4ea48b8e7df4d0873824c6759683e56eed885d',
  'ios-arm64-sim':
      '4af2962e1705f3a812d0b3599eac18e6b62955c2c36b24ce2b8b7d17899ab54c',
  'ios-x86_64-sim':
      'c9c2c130d1f469011d07aa377b582ee3f841e1ba7c6d8504480a7d4f4a3ab4af',
  'linux-arm64':
      '1e5bcdb180aa464e71746187baab5233b1b399f99aee1216c9292c1a03c061b9',
  'linux-x64':
      'f56a68ec18875420bf751d7900cdecddea426f82666f428a3259d1d05c0a0b40',
  'macos-arm64':
      'a555b551a7fe1424f75119f30d824561dab4cb5f87b0b751f590a3b5913dbb3c',
  'macos-x86_64':
      '5ea274cd68747e7ca0798515a0ae02a1c752b63d5b32fc49b13c545558c8dac2',
  'windows-arm64':
      'fe6119e827c8dc319ed2089718f9c8c02aa80f61dbd95eab433f48afc2cc3f2d',
  'windows-x64':
      '6f658286925f37e71a0a6f50fb034bd0c52ff44f0661b58f6bdfb011a35e4a18',
};

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.18.0-1';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.18.0-1';

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
    sha256: '32faae80f4b800776a28047be9954214150869d139110d35e842d6f2f45e4ed5',
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
    sha256: '8a88620f45d5fe08b9ac3d6cfc48e456e2b251f9cb257dc6faaca4ccff5536b1',
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
    sha256: '4c89e57e237bd2740610f8f62dff632414c5e23a7fce4826d6ed962318a02ed9',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: '9e9c126ecdd0a74a35f4a4ec8cb72e0bf37de9ca1264a8e411e5a97f012cba86',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: 'b55ff6d2ae4b891e34e85134c0e5fb93891fdc263f2aeb81182a2982aa68b7db',
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
    'linux-arm64',
    sha256: 'afde83c930f7469eedaa16b315dea0c39015b647ca449c54f008d07fc375a61f',
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
    sha256: 'eb5a474410cc6f16a845d0da9b6b4e5ae6bb1561ffa2a8372daaa3a24fa46e7c',
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
    sha256: 'dde4d5c709a0a3f2d5cd19db2c9f7d3c60feb52eda7a13a83f510522538c85b4',
    requiredLibraries: {
      'LiteRtLm.dll',
      'dxcompiler.dll',
      'dxil.dll',
      'libGemmaModelConstraintProvider.dll',
      'libLiteRt.dll',
      'libLiteRtTopKWebGpuSampler.dll',
      'libLiteRtWebGpuAccelerator.dll',
      'libwebgpu_dawn.dll',
      'webgpu_dawn.dll',
    },
  ),
];

/// `leehack/stable-diffusion-native` release tag downloaded for the opt-in
/// stable-diffusion.cpp runtime.
const stableDiffusionReleaseTag = 'v0.2.0-3';

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.2.0-3';

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
    sha256: '6cae1f46a56a4aa11205a611d93ab75931d0a7e771b054396aea969e597b85fe',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: '5dd2005eade8c60069ce8ba9b310bad089c144439c19956384c76dc9bbdd55d8',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: 'd7eafd0327ab688e3b6a1a4c1573b7c6daf5a717de9ba91e22494dea177eec8c',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: 'd525d6975b31aa9b9cfd1b5795e8fb64a50e267a1b34f653dd6ade358eb9537f',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: '7af45de4276a51ac0cd02897bb60822a8ec59d7ffa1d0b8650cb1c2ae04733bd',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: 'd9e8eef8f4c5641c071d2d824edbafe0db3968806d42dfd77b1b1127d6367a53',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: '005f5a1607c9dcc62d1159a41fcf7d7c1dd99f520d4d1d5ff2a317007010d52b',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: 'ee6e70551d86f0d587242e8b9cd6a70b91e1ccf3a3bfdcb3c075afa97e192da5',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: '16ca23868a051210a994733638055a691707a852114af7bfd325c48fa96c6731',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: '13917d337d1ced5a3df1bfd4020bb665af7a3c3a00c1a19fb16e485f00c2f1eb',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: '6bf69947527ccf8c1b10558fb1fe82f2f50289cc2a1911e90a8797ff7d2a266a',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: '39afba90a64e06c31ab91bd403ff0e9d504630f905cdbdf5de796ea917c17872',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
