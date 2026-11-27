/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v1.1.0';

/// The first `llamadart_llama_cpp_flutter` release whose `Package.swift` pins
/// [llamaCppTag].
///
/// Incompatible-companion build errors name it, because a caret constraint on
/// an earlier companion can never resolve it. A core from
/// `appleCompanionLockstepStart` on names it only when it shares the core's
/// `MAJOR.MINOR`, and its own minor's first release otherwise. The native pin
/// sync sets it to the companion's next release whenever it moves the
/// companion pin.
const llamaCppAppleCompanionVersion = '0.22.1';

/// Earlier `leehack/llamadart-native` tags that a published Apple llama.cpp
/// companion pins and the build still accepts, each mapped to what its
/// frameworks lack compared with [llamaCppTag].
///
/// The Apple artifacts for `v1.0.0-1` through `v1.0.0-3` share the current
/// ABI for singleton budgets. The SDK probes the multi-end export at runtime.
/// Pre-`v1.0.0` artifacts lack the ARM F16 accumulation fix. Native pin sync
/// clears this map on a pin change, so earlier tags need new compatibility proof.
const llamaCppCompatibleAppleCompanionTags = <String, String>{};

/// Exact XCFramework checksums for [llamaCppTag] and any admitted earlier
/// [llamaCppCompatibleAppleCompanionTags] entries.
///
/// Native pin sync preserves this proof on a same-tag refresh and replaces it
/// with the newly published artifact's checksum when the pin moves.
const llamaCppCompatibleAppleCompanionChecksums = <String, String>{
  'v1.1.0':
      'c43b2dee1e68aa88c592fa3c6a71c36ed42e02bd791fec68588506a232452fee',
};

/// SHA-256 of each published `llamadart-native-<bundle>-<llamaCppTag>.tar.gz`
/// archive, keyed by bundle.
///
/// The hook verifies a downloaded or cached archive of the pinned release
/// against this map before extracting it.
const llamaCppBundleSha256 = <String, String>{
  'android-arm64':
      '7ef4009ea6e08509b1113b90aa6d50dcc2277072fc09ca5888ba623c615d3871',
  'android-x64':
      '73b7f0add51d77b523741201c553ef9ea7d7f91d21525cfe873c00ad8f2819d6',
  'ios-arm64':
      '248947edcf229ff389c25235ab0303efda064d3334b05810c1502fc215e715f3',
  'ios-arm64-sim':
      '909465976242142448309ffc8db9420143badac2577a3194df8958479b9239ba',
  'ios-x86_64-sim':
      'e1bb80a08c5ffdc32cf9b56209b028943293e41351c797f299b03590cb653de4',
  'linux-arm64':
      'c5c212f0fcb6966cffbff7069351a17b55a435a821a5d7df4d1cb178aa67c4df',
  'linux-x64':
      'c30b9fd6dd6bcb571bac1b89cde2362b56762212f14516c0c7028ca01d224ea8',
  'macos-arm64':
      '31559d3b8c27b1c642b06dd6416dac74f80147c8953659f279d549e494101d32',
  'macos-x86_64':
      'c172ac519370124c3df908c5cdfdbc0cad4f501681d0d4454bb6335024bdb172',
  'windows-arm64':
      '939c665987c6ba8699b95af95c13bce8e9edd4a5cca43a6730160710b3cffc95',
  'windows-x64':
      'b69fc46291fc2b49b6b48dcb0e12597cbb76aab07807991d0ca666c819706b65',
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
    sha256: '8c5375003cd17771839697631d76262d660921a20ef6859ef645bbd8bb093f17',
  ),
];

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.20.0';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.20.0';

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
    sha256: '93e00094fb080f4355ca3a385f71844e44376807fb2771600e1d6e0ad1b316e2',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtLm.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'android-x64',
    sha256: 'f9ddcd56a99ad3f1db7470dff20aa36f5a0f9f1ee83a1a59985c442401852541',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtLm.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'ios-arm64',
    sha256: '177e191867754f15841a9ed1673f9045ed4f2e525e9de349f612ccec4966b829',
    requiredLibraries: {'CLiteRTLM', 'LiteRtLm'},
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: 'ba6e5646982a133432f36de45a1248a7d054d1e1f1543a789fd3e2ee593f5f89',
    requiredLibraries: {'CLiteRTLM', 'LiteRtLm'},
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: '1a5d8e320ffa7728dc809fb76d6311929a26ffd88529905eb34aab069ce7984c',
    requiredLibraries: {
      'libCLiteRTLM_mac.dylib',
      'libGemmaModelConstraintProvider.dylib',
      'libLiteRtLm.dylib',
      'libwebgpu_dawn.dylib',
    },
  ),
  LiteRtLmBundleSpec(
    'linux-arm64',
    sha256: '66f15d29ea6738c059a943ed5d2f412a80973175ebb7c246a6bfb66f142cc1bd',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtLm.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'linux-x64',
    sha256: '98f937aa093e76753fdb2dfd4e2d39becbcf2eeaa70bcc4a14eef32e66051655',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtLm.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'windows-x64',
    sha256: '339f7c5ee7e32700fe5ad2e3a3831c6061f862f3b2caf94cb26d5624730b7bfa',
    requiredLibraries: {
      'LiteRtLm.dll',
      'dxcompiler.dll',
      'dxil.dll',
      'libGemmaModelConstraintProvider.dll',
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
const stableDiffusionReleaseTag = 'v0.4.0-1';

/// First Apple companion release containing [stableDiffusionReleaseTag].
const stableDiffusionAppleCompanionVersion = '0.20.7';

/// Explicitly qualified older Apple SD pins that preserve existing app locks.
///
/// The v0.4.0 image generation parameter layout is incompatible with the
/// v0.3.0 line. Clear and requalify this map whenever
/// [stableDiffusionReleaseTag] changes.
const stableDiffusionCompatibleAppleCompanionTags = <String, String>{
  'v0.4.0':
      'no Apple changes (v0.4.0-1 only bundles Windows Visual C++ runtime DLLs)',
};

/// Checksums of the exact published XCFrameworks accepted by the SD hook.
const stableDiffusionAppleCompanionChecksums = <String, String>{
  'v0.4.0': '3a9d99a0f818c1511c62b585d3170c41c68f35756143979fe29f4a476bece3ce',
  'v0.4.0-1':
      '3a9d99a0f818c1511c62b585d3170c41c68f35756143979fe29f4a476bece3ce',
};

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.4.0-1';

/// A published stable-diffusion-native runtime archive and its required libraries.
class StableDiffusionBundleSpec {
  /// Release bundle key such as `linux-x64-vulkan`.
  final String bundle;

  /// SHA-256 of the published `.tar.gz` archive.
  final String sha256;

  /// Library file names the archive must provide under `lib/`.
  final Set<String> requiredLibraries;

  /// Library that exposes the stable-diffusion.cpp API.
  String get primaryLibrary => switch (bundle.split('-').first) {
    'windows' => 'stable-diffusion.dll',
    'android' || 'linux' => 'libstable-diffusion.so',
    _ => 'libstable-diffusion.dylib',
  };

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
    sha256: 'b0bac4c11847536d3562e155bca021292666963729514ae80eec86d6a15f2613',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: '10fd003b6e4742abf4815960d2105ba60b39a3fda36b1c021754b254f98d4b66',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: '2a84e5bedf05fba1eb151c45d2b47cfc11137db743bb69b5309dde4c2acb05b3',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: 'f5ce1616472c5ba8cbcb03cc4c52156b2856e2dd384e4578db97b147ffb152ff',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: '7ba9cbfc3f37193c945bfbd0816b048d138f057076490e94d7c024543a10478d',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: 'd873ece9051f6713d776e4e4ea762866ebc9c0dabb371e894609bb4828d8a2e5',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: '5b1425402f8c3ab704b2c3817dc5d57f78a1054669a6bd5d170fa14e8790df12',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: '5201da9d08501d9f5d27e7e78c8d3c83624ef6a27417339fef03813539aa6180',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: '02db0554b8eee4adf5d46f75ee5869d5fb81d75de0059d55136cd614b70368fb',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: 'ff7104003c6bdb3a2bd2fc04ac11bdb636192a71aa33f57d18f2673624a6e6f3',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: 'd09e8b322fcbdbfb09869e7f6362ec9a52d0c36efb3e3f2b1a90d445bbfd0ff9',
    requiredLibraries: {
      'msvcp140.dll',
      'msvcp140_codecvt_ids.dll',
      'stable-diffusion.dll',
      'vcruntime140.dll',
      'vcruntime140_1.dll',
    },
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: '5c5663f5460c933236d48da579affd7af0beee167a10bda64ef45e7f4a9439f0',
    requiredLibraries: {
      'msvcp140.dll',
      'msvcp140_codecvt_ids.dll',
      'stable-diffusion.dll',
      'vcruntime140.dll',
      'vcruntime140_1.dll',
    },
  ),
];
