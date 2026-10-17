/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.7.0-1';

/// The first `llamadart_llama_cpp_flutter` release whose `Package.swift` pins
/// [llamaCppTag].
///
/// Incompatible-companion build errors name it, because a caret constraint on
/// an earlier companion can never resolve it. A core from
/// `appleCompanionLockstepStart` on names it only when it shares the core's
/// `MAJOR.MINOR`, and its own minor's first release otherwise. The native pin
/// sync sets it to the companion's next release whenever it moves the
/// companion pin.
const llamaCppAppleCompanionVersion = '0.14.1';

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
      'e25056a80c0520e0198350da395814285dc5a116da581e90e49b02e106b56174',
  'android-x64':
      '600ab700681f879bef3f583ca001ac7cea50f04085f4ccd5dd9789f599354850',
  'ios-arm64':
      '022f29fccab8f2abb521d5270bf774c079cee9a66525272655278291b4a050f8',
  'ios-arm64-sim':
      '1438643353a02aec1343509b23841d750930b849c3edbb038d05e72c410b18ea',
  'ios-x86_64-sim':
      '449a760fabc32688a27c4ce5183c1d422fe4ed626568c45c2386e09f664a475b',
  'linux-arm64':
      'cd679e88094921eef0dd2983e407aaf087d55a8a375336c4f3a345105916aff0',
  'linux-x64':
      'af61abad6457f98a93da226db48e3d3144e4542f24d5b803f9636d4ad482d2aa',
  'macos-arm64':
      '091524ad25e1f083f08e08ee078f74e777ed3045700b6fc9de7c28465d427c1d',
  'macos-x86_64':
      'f4c70bdbe5a735dc1c35a3e2cdf21a2563bd8aef71ed82f2b02357fce2379f1f',
  'windows-arm64':
      '13aec59acad0621ce8f0f64ac098dd2ab0255ae52084559201d4414c7328f99e',
  'windows-x64':
      'b3499bf92f532392698421a39d1246665b469d6f2b0988a9000960275e179727',
};

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.18.0-2';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.18.0-2';

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
    sha256: 'd6203343b8b11c2fff17337f464389511e9793544f275351aa47752dfff56008',
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
    sha256: '2adb600c508f94f4c20e32fe470eb3db67c6ff0da3d15f74ad50fbdff87d7363',
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
    sha256: '60ee1075e98957ec21eda6f553f810b6ee2daf4bb5044fbde44dff5916a40343',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: 'a8aa89cf34da7a24a4f3fe15f9e07406a5fbf75ef71a404ce914a3884599d7c2',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: 'e1da8be7168d3e33180d72abc454f636a2e5dd4a1ead8521d9990b4fd0819502',
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
    sha256: '519889568c36511fdba69af4b414a6460b05108d577fbd9fc44d7a14f9a142d5',
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
    sha256: '314fe89228cdfc0ac2f69ebe824129fae0efca8d9608b5b0e3c23fcd0a3f3673',
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
    sha256: 'cc0eb6e54f412c5ea62eb1f60066de3b5744f2715cf5b574dbfe6567b58fdc02',
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
