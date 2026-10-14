/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.6.0-2';

/// SHA-256 of each published `llamadart-native-<bundle>-<llamaCppTag>.tar.gz`
/// archive, keyed by bundle.
///
/// The hook verifies a downloaded or cached archive of the pinned release
/// against this map before extracting it.
const llamaCppBundleSha256 = <String, String>{
  'android-arm64':
      'e227f5b3b72fe7c2d727a18a3b9172f6e186a609422f14b2abbcc5e48f855d6e',
  'android-x64':
      'd0c3bc9310109ef4e94a683674481b6be99e9b5a7a83167fad4c35ca001f6d60',
  'ios-arm64':
      '3d709de622e218b4c9ea6e64a28ea9e00b4b6343953392635b9b4bd8961b773d',
  'ios-arm64-sim':
      'd47edd9a71a601a4b5f68cf637042ad6734c8c39ebfa9f7a1e107c50c85143bd',
  'ios-x86_64-sim':
      '052139c8c0166dae650db9faed4d59005574f19de3e9f945c65389666b5b2615',
  'linux-arm64':
      '36eab76ba292ac42f287903d5244f2eca44715c91819ce3090e84452b3e422e9',
  'linux-x64':
      'c28749b408e022f3a28337aa48d2aecdde4d8497eb0fc15e6888a706149da411',
  'macos-arm64':
      'fc4bf705c40a8958881f5f5ca99531a6afe2fa86ee9600e78a744e90b0bdd92c',
  'macos-x86_64':
      '5333975482fc652cc975ed1f8f81e9b41645f264ebb590a78fca7e977c10aab7',
  'windows-arm64':
      '7d189db3759ec1798ac48634114fb2a1a2005fd4bae3a469ca31a9a847f1a3c2',
  'windows-x64':
      '47710c7f920ac84e90c6be19e7b7c7ae2ee5bb7be15805527f4c28d24805f98b',
};

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.18.0';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.18.0';

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
    sha256: 'd83f437ce720d78d5fceb07dae681d8db35faa5f276513f70a1209fd552ef276',
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
    sha256: 'cfacb036610e4d1b76681be18ef29c54d3f23abb487dcad7c532c1c1ec28e083',
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
    sha256: 'a4266862f92eeaa242331f855a956ce3da0cdca8c9c8618a1ae8c1a13c75fe5f',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: '6634cbc7d0e416d387eca727103ea6093fc352d46188f53d7285eeb89c895217',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: '94662b75c45d2d55200e0c846c69f034d94f9724c6e8d0a65d9107b6d1f928c7',
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
    sha256: '2f00840579f2d01d38b9bf8549719655e4070c6d6123c1420a6e3e9ecc7a8440',
    requiredLibraries: {'libCLiteRTLM_mac.dylib', 'libLiteRtLm.dylib'},
  ),
  LiteRtLmBundleSpec(
    'linux-arm64',
    sha256: '38b46dc99a38919c24f7374d3b509e08671c62529f77d4aad12aa14467df628c',
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
    sha256: 'a25c539eeed38bd54d2cc7ddf297a8c4c3ec6b9ac210f5b7833797af03cff850',
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
    sha256: '7e9918833a807f9aa216f528f609c10eac528a33e9a8041451de918ea979b3bf',
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
