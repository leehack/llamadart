/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v0.8.0-3';

/// The first `llamadart_llama_cpp_flutter` release whose `Package.swift` pins
/// [llamaCppTag].
///
/// Incompatible-companion build errors name it, because a caret constraint on
/// an earlier companion can never resolve it. A core from
/// `appleCompanionLockstepStart` on names it only when it shares the core's
/// `MAJOR.MINOR`, and its own minor's first release otherwise. The native pin
/// sync sets it to the companion's next release whenever it moves the
/// companion pin.
const llamaCppAppleCompanionVersion = '0.18.0';

/// Earlier `leehack/llamadart-native` tags that a published Apple llama.cpp
/// companion pins and the build still accepts, each mapped to what its
/// frameworks lack compared with [llamaCppTag].
///
/// No older Apple runtime is admitted for v0.8.0-3: consumers need its
/// speculative rollback and model-creation ownership fixes, with the unused
/// embedding query retired. Native pin sync clears this map whenever the pin
/// moves; additions require exact artifact
/// compatibility evidence and matching checksums below.
const llamaCppCompatibleAppleCompanionTags = <String, String>{};

/// Exact XCFramework checksums for [llamaCppTag] and any admitted earlier
/// [llamaCppCompatibleAppleCompanionTags] entries.
///
/// Native pin sync preserves this proof on a same-tag refresh and replaces it
/// with the newly published artifact's checksum when the pin moves.
const llamaCppCompatibleAppleCompanionChecksums = <String, String>{
  'v0.8.0-3':
      '6f069871b33ccab82f70b4dfe6a7f358e593961748ba9496e7b9101410ee3cd2',
};

/// SHA-256 of each published `llamadart-native-<bundle>-<llamaCppTag>.tar.gz`
/// archive, keyed by bundle.
///
/// The hook verifies a downloaded or cached archive of the pinned release
/// against this map before extracting it.
const llamaCppBundleSha256 = <String, String>{
  'android-arm64':
      'd55b7df7307307e2bbffde8c1afdcea74294cc8df0076466012a86337570f37c',
  'android-x64':
      'a6058e5124f2b4fa59585db66253c810a5ba31622c5e4e041e5b603ebc11620c',
  'ios-arm64':
      '889e729b97be5611ef62888aae0a02dcb19bb3d474d2bb94eaa38e150554a0c0',
  'ios-arm64-sim':
      '05db2b25f1f8c8b1c710a49ac89c134c7c3a1cf426d1faf5e59047e2adc9df63',
  'ios-x86_64-sim':
      '94e6243b441d50388dae8a8afad37aca8f9dc24ff87571b4fbc5f6287cd174a7',
  'linux-arm64':
      '069ddd5b63b2b17601425700c9a03d50ef9a171ea728080e79d7be39b9cd1dc8',
  'linux-x64':
      'a7c4e70556fb7487704dfbc5fc8534b014ca494c75d024957eb149db08a1482e',
  'macos-arm64':
      '632946dbe37964c1172b753ddfed7754d5f7398c7078f73f57f464e759d2b586',
  'macos-x86_64':
      '3ff6f6be5d1572d8aa1e07780964d817eccfa51298b70ef31830b4b3eaebae73',
  'windows-arm64':
      '3b0f13bbf3d321dd8ac0dea1757c4a95793cda93e6c5c6358c92728d59df87ec',
  'windows-x64':
      '86fbae8a6133c22b2bfc9e9bbc565d097ed40dc83feee0a70b73f124de708b9b',
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
    sha256: '967e29a4af1f1ad62fce5e49d74df524cca79b250d1c9f80c7a4d5f56b4a867e',
  ),
];

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.19.0';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.19.0';

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
    sha256: '6a4609798e8eb1bbf5e31fcf076b8b07326b850f4b1733d4ad805534c179d5d6',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'android-x64',
    sha256: '9b23afe5e970794810eb319a92afd8005f1108f7b86f250da7eebd012516547b',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtGpuAccelerator.so',
      'libLiteRtLm.so',
      'libLiteRtOpenClAccelerator.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64',
    sha256: '1a877b3289671829b1655c4c32d076e9165dfe9e8bcc32ffde3b6823f8c09bc5',
    requiredLibraries: {'CLiteRTLM', 'LiteRtLm', 'LiteRtMetalAccelerator'},
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: 'a6851a8358be0fe13cacde4d2c135c03faebe9aaec94ffdc32003231f8c6b9a7',
    requiredLibraries: {'CLiteRTLM', 'LiteRtLm', 'LiteRtMetalAccelerator'},
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: 'b5d7855378500b68e9395bc17bef431ee852c68ddb8ac88e4d6686c5e09e505f',
    requiredLibraries: {
      'libCLiteRTLM_mac.dylib',
      'libGemmaModelConstraintProvider.dylib',
      'libLiteRt.dylib',
      'libLiteRtLm.dylib',
      'libLiteRtMetalAccelerator.dylib',
      'libLiteRtWebGpuAccelerator.dylib',
      'libwebgpu_dawn.dylib',
    },
  ),
  LiteRtLmBundleSpec(
    'linux-arm64',
    sha256: '85133f85c1413af4c62bce40d78b47567bc1213cce40b47205dc8648b5225e2f',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'linux-x64',
    sha256: '9b0a0518edd7059726c7f24411f4519207814ec8d7039a8fc131ce6428cf4247',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRt.so',
      'libLiteRtLm.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'windows-x64',
    sha256: '77a2f84a342d1341cecb9a12470bee35ff3eb200eecbbb7ff3294ed099422a17',
    requiredLibraries: {
      'LiteRtLm.dll',
      'dxcompiler.dll',
      'dxil.dll',
      'libGemmaModelConstraintProvider.dll',
      'libLiteRt.dll',
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
const stableDiffusionReleaseTag = 'v0.3.0-3';

/// First Apple companion release containing [stableDiffusionReleaseTag].
const stableDiffusionAppleCompanionVersion = '0.18.0';

/// Explicitly qualified older Apple SD pins that preserve existing app locks.
///
/// These builds share the pinned upstream and C ABI, not identical machine
/// code. The Dart worker rejects recorded Metal backend failures even when
/// native generation returns images; the newer native guard remains preferred.
/// Clear and requalify this map whenever [stableDiffusionReleaseTag] changes.
const stableDiffusionCompatibleAppleCompanionTags = <String, String>{};

/// Checksums of the exact published XCFrameworks accepted by the SD hook.
const stableDiffusionAppleCompanionChecksums = <String, String>{
  'v0.3.0-3':
      '8f35c67f72d1d4bf86d31f20f3437d04baaf3b6ac7389908000fd166e387783f',
};

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.3.0-3';

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
    sha256: '0ba2a126bed223e2783736791ddcacaec2545c34d55b6358eea4afc7827889db',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: 'f91ad7b00592385e6a6e1a1af3989255886a08f0f22ea3c242da2de66a68a38a',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: '6f4badad4a56ac3c6bfa696a8184cd0d4f4a12f2f185fa2ddc84183665532d61',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: 'a969b7ed0e27f9099e5abfc46d2136f0c956382cd638332d2b207380221692bf',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: '2a198413707f8a6a70cd11dfc97d5fb8e6979f7fd389efdc9afa2e6c0bf0f6b5',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: '0b72b8c5a6dbf87ce630e1c3a7af9129c770481e3813d7623c23ae8afdce1d1b',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: '71f59f5ba02d3ef56c7d82bd475efa2a68de5f0641ed142bf5b6f42ab9d30bab',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: '1a2a089f229204e94a61f19d1ffe977aecd561d40f6d05ec9a740bd23c06506d',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: 'df062e77cd8f1d365946d436f4c5e795ec22b7ef49f2ccfeb4506c9548e0cccc',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: '8b58ffed2a2719080d70cdac884dc3769ad245824cf1a1e5480472abc406e0fc',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: '4185409411f1b1a23988da232bf6c4fa044b46cd48fccb30b379ea915de57384',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: '05d4c2545cac4e5c96b14c9440584c9c634572329183334a55a84c113aeb0aef',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
