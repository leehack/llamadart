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

/// The `hook_contract_version` of the [llamaCppTag] release's `assets.json`.
const llamaCppHookContractVersion = 1;

/// A backend module that [llamaCppTag] publishes as its own archive,
/// `llamadart-native-<archive>-<llamaCppTag>.tar.gz`, extracted over the
/// [bundle] archive when [backend] is selected.
class LlamaCppBackendSidecarSpec {
  /// Core bundle the sidecar extends, such as `windows-x64`.
  final String bundle;

  /// Backend the sidecar adds, such as `cuda`.
  final String backend;

  /// Archive key, such as `windows-x64-cuda12`.
  final String archive;

  /// SHA-256 of the published `.tar.gz` archive.
  final String sha256;

  /// Creates a spec for the [archive] sidecar.
  const LlamaCppBackendSidecarSpec({
    required this.bundle,
    required this.backend,
    required this.archive,
    required this.sha256,
  });
}

/// Every backend sidecar archive the [llamaCppTag] release publishes.
const llamaCppBackendSidecarSpecs = <LlamaCppBackendSidecarSpec>[];

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.18.1-4';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.18.1-4';

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
    sha256: '0bbca576bd4b5d36ae78b262079ac4a4fd12806e9b463783895994bb867c90de',
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
    sha256: 'b1f16fc017a214a8607ad6d0ca96f76f1b6b656af20aae98d1bddc33bc9d33ae',
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
    sha256: 'ca392ebb8aafe9a75d5907376efa51c66a67a75e74ead6ce42d2375f1a961838',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: '078d28b539050b5f16fc98b99d85657fcf88ee79b4457456311a0d6d2481daad',
    requiredLibraries: {
      'CLiteRTLM',
      'LiteRtLm',
      'LiteRtMetalAccelerator',
      'LiteRtTopKMetalSampler',
    },
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: '14bfe47e9beb032fd62c4020a79b555a3909df4940a443eb40daf47bbad7817a',
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
    sha256: '3e29ede495035369366cf0ab1562f8d96c32d2e6405cab7212565d748a076f29',
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
    sha256: 'c8246d836120c97595a7ed6844d0b16ef2fd6db0fdacf739b4d67bb5566d845c',
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
    sha256: 'f253a32582d140cae62d777a8df8be5320c927a97fe652e186d466aab6581250',
    requiredLibraries: {
      'LiteRtLm.dll',
      'dxcompiler.dll',
      'dxil.dll',
      'libGemmaModelConstraintProvider.dll',
      'libLiteRt.dll',
      'libLiteRtTopKWebGpuSampler.dll',
      'libLiteRtWebGpuAccelerator.dll',
      'libwebgpu_dawn.dll',
      'msvcp140.dll',
      'vcruntime140.dll',
      'vcruntime140_1.dll',
      'vcruntime140_threads.dll',
      'webgpu_dawn.dll',
    },
  ),
];

/// `leehack/stable-diffusion-native` release tag downloaded for the opt-in
/// stable-diffusion.cpp runtime.
const stableDiffusionReleaseTag = 'v0.3.0-1';

/// First Apple companion release containing [stableDiffusionReleaseTag].
const stableDiffusionAppleCompanionVersion = '0.16.1';

/// Explicitly qualified older Apple SD pins that preserve existing app locks.
///
/// These builds share the pinned upstream and C ABI, not identical machine
/// code. The Dart worker rejects recorded Metal backend failures even when
/// native generation returns images; the newer native guard remains preferred.
/// Clear and requalify this map whenever [stableDiffusionReleaseTag] changes.
const stableDiffusionCompatibleAppleCompanionTags = <String, String>{};

/// Checksums of the exact published XCFrameworks accepted by the SD hook.
const stableDiffusionAppleCompanionChecksums = <String, String>{
  'v0.3.0-1':
      'cebe0771734a657ff02420daa1190257185ced49f606e177c8e42789bd4323a2',
};

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.3.0-1';

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
    sha256: '3709300d46208dcd0fb1f7177a36269328345daf27ca08050349e1f5e7be66a4',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: 'dc817d828a50549d18fc4563a8ca76c1eab72a3294e8195f5d329d295bd4aeed',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: 'd708a5ebbab21d63a6cb296087dc70b92a8af8e8f9c449d3bca332649f6e630d',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: '528333d7f522e0e0de99f7d814da5711b2c2829b975fd5b8568508528f9a0497',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: '79c3517b363e6509df17af4d20056ed6e47bbbd134681fb9321520702534cb40',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: '64b280155495994e14398df2fda2017349d280763ba0615bd8863fbb6e5aa85e',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: 'b0bfcc920b9c1ff509b30a56e06520151199624b290cfe49348b92e7e054fdc9',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: '8b31fc6e8db12af475122161649b70c2af6c59d07101f0fe928aa720031ff278',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: '68fe2084ff1769446d9b9b91639a7264b39ea13053b09bd2a02cc55087677010',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: '41c4b43f27dae27bdb6fda2b0b81356462ff1b09972cef2bfff1d88a7f4acb64',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: '372b46b406becd55050515d3ae7250012bbc6d915c0381128c95804a798083f5',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: '730a5290bd99b85c189dfad9871bd900bf433cdb750bc0b566f6e20d1eea1e0f',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
