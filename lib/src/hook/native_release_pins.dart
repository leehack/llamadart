/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.7.0-2';

/// The first `llamadart_llama_cpp_flutter` release whose `Package.swift` pins
/// [llamaCppTag].
///
/// Incompatible-companion build errors name it, because a caret constraint on
/// an earlier companion can never resolve it. A core from
/// `appleCompanionLockstepStart` on names it only when it shares the core's
/// `MAJOR.MINOR`, and its own minor's first release otherwise. The native pin
/// sync sets it to the companion's next release whenever it moves the
/// companion pin.
const llamaCppAppleCompanionVersion = '0.15.2';

/// Earlier `leehack/llamadart-native` tags that a published Apple llama.cpp
/// companion pins and the build still accepts, each mapped to what its
/// frameworks lack compared with [llamaCppTag].
///
/// Every entry must be a wrapper rebuild of the same upstream llama.cpp
/// release as [llamaCppTag]: the same `vMAJOR.MINOR.PATCH` prefix, which the
/// native release manifest binds to one upstream commit, with the same header
/// declarations and the same exported symbols on every framework slice, so
/// its frameworks are ABI- and symbol-identical to the ones the Dart bindings
/// expect. `test/fixtures/native/llama_cpp_apple_compatibility.json` records
/// that comparison for the exact XCFramework checksums. The build accepts
/// such a companion with a warning. The native pin sync clears this map
/// whenever it moves [llamaCppTag], because each entry is verified against
/// one pin.
const llamaCppCompatibleAppleCompanionTags = <String, String>{
  'v0.7.0-1': 'the fix that seeds every Qwen3-TTS codebook from the request',
};

/// The exact XCFramework checksum a companion pinning each
/// [llamaCppCompatibleAppleCompanionTags] entry must declare.
///
/// A tag alone establishes no ABI compatibility, so the build rejects a
/// compatible tag whose checksum is missing here or differs. The native pin
/// sync clears it together with [llamaCppCompatibleAppleCompanionTags].
const llamaCppCompatibleAppleCompanionChecksums = <String, String>{
  'v0.7.0-1':
      '90fee6868a611c5b053179e6944baba36975cf0d91b5e9888f51e03a74b4cbe0',
};

/// SHA-256 of each published `llamadart-native-<bundle>-<llamaCppTag>.tar.gz`
/// archive, keyed by bundle.
///
/// The hook verifies a downloaded or cached archive of the pinned release
/// against this map before extracting it.
const llamaCppBundleSha256 = <String, String>{
  'android-arm64':
      '72fd7d6ed2bec218cbc23901b6c82fc7ddaac989d7ea287a1054d3e20c538a89',
  'android-x64':
      'ee3d096f214d1790c34c516b511f0386cefc9a52ed19024573b0cc2f62873026',
  'ios-arm64':
      'fb9fb1ce49c1a91a07da4baadb7abaddc47ed172ec45cc5da21350a05c6971f0',
  'ios-arm64-sim':
      '8d0f8aad3ae3b854b809c3f7d3d8e1c0b97e10c4b850f0f8bac36d76394aecdc',
  'ios-x86_64-sim':
      '471e62bd3b07c626e0499ed5679cadf10fbf81c35e0d7ad6c63acc4e32fe88b7',
  'linux-arm64':
      'e491a5300b2994774c7cc130ec20ad75f0ac0d9db8e08698e47f6382e09cb6b7',
  'linux-x64':
      '2c3671399545c409b69707aca04a85c46b1f9cceb8020c234b392104a299652b',
  'macos-arm64':
      'c57c9e2cff650ba0f34844b99a5dbcf70fb6358899792ac117f4ddf028ede718',
  'macos-x86_64':
      'd840fec8eb5846b88f17e8f0041b3418a24cf5c7f566787fd7572f03ebc58f91',
  'windows-arm64':
      'bbea24506fe5551d092a0efb5a6dc3915a066f5a80a62cab9e24d5f5af97dcbd',
  'windows-x64':
      '0bec255d9336eab934f601408f2871b53f83a29432587e01b0fa71a4d33840e2',
};

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.18.1-1';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.18.1-1';

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
    sha256: 'b10ed75c6f5cac4142ecd8a9538a36a9ea125f1a91a09e755d1953ef259f4e22',
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
    sha256: '79b59d36d6248e042fe1cc2fbb675b1010ee84643bb0e8c803b0c8c5a917af14',
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
    sha256: 'a198f9e348d6303fbb2595e0f48c552a12fd9a387201a3795124b6afc13bef75',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: '181aa4347f2e0c3d5cd0604f32125397b4cb514f3ddf8de3f9b9af153d4ba09b',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: '311a12dc626f0abbe533c9eba39f5862fffc8cdaedb875ec17e3cf65078c017b',
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
    sha256: '0894ef1e5c4dc98e2217e0f2502d9fb534907920d8554bea7ccbe1e59d664237',
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
    sha256: '3031e20440d9d5dcbda4629b1675ff1ffb18c3b783f42ec43b8bf48be5ff2a3b',
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
    sha256: 'e922aca4680f43e047aec4b30a6aefffcd35b25b48794f89b4e69d3a1e6c5fd3',
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
const stableDiffusionReleaseTag = 'v0.3.0';

/// First Apple companion release containing [stableDiffusionReleaseTag].
const stableDiffusionAppleCompanionVersion = '0.16.0';

/// Explicitly qualified older Apple SD pins that preserve existing app locks.
///
/// These builds share the pinned upstream and C ABI, not identical machine
/// code. The Dart worker rejects recorded Metal backend failures even when
/// native generation returns images; the newer native guard remains preferred.
/// Clear and requalify this map whenever [stableDiffusionReleaseTag] changes.
const stableDiffusionCompatibleAppleCompanionTags = <String, String>{};

/// Checksums of the exact published XCFrameworks accepted by the SD hook.
const stableDiffusionAppleCompanionChecksums = <String, String>{
  'v0.3.0': '3b83a0c21a00f6418890b679ea45b00c20d012da0a57fe989635b793e09f096a',
};

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.3.0';

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
    sha256: 'a505480ada6a5f8af1fb1195b60320c5b263d86e9e320e46b97dd5d1c00b7bb0',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: 'ca9cf1efbf2592131d4703f08a5de66b9f6d869ffe4719ef64f98a50e3e2f5ea',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: 'f153335a912f1038b3a7263404e5512d3d5dec836fa33b03ef522540aa3e4c2b',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: '73b74129d3a4db6b165eb0aa080b9f8f4a523c1e0848dd9ae7e20832864fc984',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: '6bff063ffae8d6a274fad1be3e648e5e6ea66d26f140ade2494a624a5214b2ec',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: '35e77cadf496b002413106c292e9df31abec489ee37e35fd3243973485985438',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: '6a65294706cb8766abe508730c1494ff85fe9e526d86f4a6f126af82b1aa7bf4',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: 'a57c9cfe939f50f4ecd72a688193e5fbf87bc34637daef88105c3e28a8400049',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: 'da16772f26f2f3d8921e8d0b98f9e8d7e351c2e6c1d255df51b6d5eb559e4e34',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: '1bb2cc9308bf4a63c212cc44d42d54e4397762fb8dacd90470be70635c628492',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: '6abc9fe2eecea7f7deffde32a8d519c757b7675ce627cdb22545130a481c6b07',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: '8a243beb1c59afd94e932b6b914916ebabe7a2b2c1bedfd6fad1da56d6122ec3',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
