/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.6.0-3';

/// SHA-256 of each published `llamadart-native-<bundle>-<llamaCppTag>.tar.gz`
/// archive, keyed by bundle.
///
/// The hook verifies a downloaded or cached archive of the pinned release
/// against this map before extracting it.
const llamaCppBundleSha256 = <String, String>{
  'android-arm64':
      '434e4f8b394fd80e96e094ef8e2720f7b6f38ee7a6bd1a036f9d7bbdbb898d0f',
  'android-x64':
      'e1e57532a0f0154c5b6a3f034de80f00f0eeb2354854b0e3e3e6f7e225a7d46a',
  'ios-arm64':
      '37a4e69cf6e1af5a56a9559dfd0bedeb2b5275af691bc7b6680690b16c6fa7d8',
  'ios-arm64-sim':
      'cbb9d481d1fc515d15670150fe44b8611166e886f2f9c46ba421f4fe6bf387bf',
  'ios-x86_64-sim':
      '74349811b95106e24ae929c9132c67b88d936de39d543cfe1f4a9f41eeba9a3a',
  'linux-arm64':
      '03154c5db784ce6e85a58c69b480c1925cc96cf35deddcdbfb69b0a9ea63cd68',
  'linux-x64':
      'ad8dc7272d44f8a58182b1de30764265de0e93313a914f470a681e418a0f98d0',
  'macos-arm64':
      'fbbe53ce1c63fda3e75f5573b013451396b085de8984eb071ee52614a5437629',
  'macos-x86_64':
      'a9964d3559c53613e9e38fa446c8292605e1b6de12b345e77f6e39a96272077a',
  'windows-arm64':
      'b08d94691573b3c48286096ffc47d752abdaef01077b633bcc331c8e8c736b45',
  'windows-x64':
      '61a245ea08e3738dc9c621571fafc894fc9c2ccb7dfa52e090b150a430ff845c',
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
