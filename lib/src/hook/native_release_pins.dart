/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.8.0';

/// The first `llamadart_llama_cpp_flutter` release whose `Package.swift` pins
/// [llamaCppTag].
///
/// Incompatible-companion build errors name it, because a caret constraint on
/// an earlier companion can never resolve it. A core from
/// `appleCompanionLockstepStart` on names it only when it shares the core's
/// `MAJOR.MINOR`, and its own minor's first release otherwise. The native pin
/// sync sets it to the companion's next release whenever it moves the
/// companion pin.
const llamaCppAppleCompanionVersion = '0.17.1';

/// Earlier `leehack/llamadart-native` tags that a published Apple llama.cpp
/// companion pins and the build still accepts, each mapped to what its
/// frameworks lack compared with [llamaCppTag].
///
/// An entry may come from an earlier upstream release. Its frameworks stand in
/// for [llamaCppTag] only because the core calls no symbol they lack and passes
/// them no struct they would read or write out of bounds, as
/// `test/fixtures/native/llama_cpp_apple_compatibility.json` records for the
/// exact XCFramework checksums in
/// [llamaCppCompatibleAppleCompanionChecksums]. A test keeps the core off the
/// symbols and layouts only [llamaCppTag] has, so calling one needs a runtime
/// probe. The build accepts such a companion with a warning. The native pin
/// sync clears this map whenever it moves [llamaCppTag], because each entry is
/// verified against one pin.
const llamaCppCompatibleAppleCompanionTags = <String, String>{
  'v0.7.0-3': 'the llama.cpp v0.8.0 fixes and model families',
};

/// The exact XCFramework checksum a companion pinning each
/// [llamaCppCompatibleAppleCompanionTags] entry must declare.
///
/// A tag alone establishes no ABI compatibility, so the build rejects a
/// compatible tag whose checksum is missing here or differs. The native pin
/// sync clears it together with [llamaCppCompatibleAppleCompanionTags].
const llamaCppCompatibleAppleCompanionChecksums = <String, String>{
  'v0.7.0-3':
      '749c9bc9fa846fb2386b3cf20ac1e6754182cd145aaf21affa2634c1f1177192',
};

/// SHA-256 of each published `llamadart-native-<bundle>-<llamaCppTag>.tar.gz`
/// archive, keyed by bundle.
///
/// The hook verifies a downloaded or cached archive of the pinned release
/// against this map before extracting it.
const llamaCppBundleSha256 = <String, String>{
  'android-arm64':
      '5753e6ab78393e7316eb90549addd692f6bf6d6ff397372242d2dda919c0cfa0',
  'android-x64':
      '871fa6347ebdc4c5f8acc1228ddaf8613ad9466f17b37be64c8ebf01fd158992',
  'ios-arm64':
      '8d86afc9a23d0c4a34bef0aebca2e8079ea78346dc68b8963ad80f6ac53dab41',
  'ios-arm64-sim':
      '304ce731090ae3ad1f12757a5302d0df09a423c0cf169cccb0d2c9765c22f845',
  'ios-x86_64-sim':
      '46cfacaa687f025fd52b49d40cc98d95517a2b135fa2e2616d89e024545753f2',
  'linux-arm64':
      '75ab71c65fd5be5ea4441ad3ac430c3666bd51e8c7cd8c2aee1d299d46598c5d',
  'linux-x64':
      'be531c5809c30dd1b9698eae748ceedd2301214bfc08c3d2aa4f3ca34732a014',
  'macos-arm64':
      '6bb91eb26ed1788c4964a96ebca0205f23c202dd475e8c10089e61cec72005a2',
  'macos-x86_64':
      '0bffb9c5975b6ca914d2e60e7f548f24c63ebe95347b6b321bfc123bd7ef1700',
  'windows-arm64':
      'c917ccfbde5ce0b4b85b5840db8b19a008b8863d3eb9079ea980ee30e65cb24f',
  'windows-x64':
      '358844485e22397daa7f2b4e6b2f830bf2e4e871564751d277e81431e577bf5f',
};

/// The `hook_contract_version` of the [llamaCppTag] release's `assets.json`.
const llamaCppHookContractVersion = 2;

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
const llamaCppBackendSidecarSpecs = <LlamaCppBackendSidecarSpec>[
  LlamaCppBackendSidecarSpec(
    bundle: 'windows-x64',
    backend: 'cuda',
    archive: 'windows-x64-cuda12',
    sha256: '6e3604ae635b1c960e8e2d0cd770707cfac71832f52f4695faef8fd36e43e822',
  ),
];

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
const stableDiffusionAppleCompanionVersion = '0.17.0';

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
