/// Native runtime release pins consumed by `hook/build.dart`.
///
/// `tool/native/sync_native_release_pins.py` rewrites this file from published
/// release metadata. Hook logic stays in `hook/build.dart`.
library;

/// `leehack/llamadart-native` release tag downloaded for the llama.cpp runtime.
const llamaCppTag = 'v1.0.0-3';

/// The first `llamadart_llama_cpp_flutter` release whose `Package.swift` pins
/// [llamaCppTag].
///
/// Incompatible-companion build errors name it, because a caret constraint on
/// an earlier companion can never resolve it. A core from
/// `appleCompanionLockstepStart` on names it only when it shares the core's
/// `MAJOR.MINOR`, and its own minor's first release otherwise. The native pin
/// sync sets it to the companion's next release whenever it moves the
/// companion pin.
const llamaCppAppleCompanionVersion = '0.20.2';

/// Earlier `leehack/llamadart-native` tags that a published Apple llama.cpp
/// companion pins and the build still accepts, each mapped to what its
/// frameworks lack compared with [llamaCppTag].
///
/// The Apple artifacts for `v1.0.0-1` and `v1.0.0-2` share the current ABI.
/// Pre-`v1.0.0` artifacts lack the ARM F16 accumulation fix. Native pin sync
/// clears this map on a pin change, so earlier tags need new compatibility proof.
const llamaCppCompatibleAppleCompanionTags = <String, String>{
  'v1.0.0-1': 'the v1.0.0-3 native speech fixes',
  'v1.0.0-2': 'the v1.0.0-3 native speech fixes',
};

/// Exact XCFramework checksums for [llamaCppTag] and any admitted earlier
/// [llamaCppCompatibleAppleCompanionTags] entries.
///
/// Native pin sync preserves this proof on a same-tag refresh and replaces it
/// with the newly published artifact's checksum when the pin moves.
const llamaCppCompatibleAppleCompanionChecksums = <String, String>{
  'v1.0.0-1':
      '0c66ca422bfc8ba266845b57fea99d2792ea67c84233f49358301a640846d669',
  'v1.0.0-2':
      '641020c50159a001096dcd66cc7356fe3c81915b26f985ebd48b2cec87169bcb',
  'v1.0.0-3':
      '0ba46bb6428ce0f32633aea84bdb4d9530089850461ea721cfb0430961ca24c1',
};

/// SHA-256 of each published `llamadart-native-<bundle>-<llamaCppTag>.tar.gz`
/// archive, keyed by bundle.
///
/// The hook verifies a downloaded or cached archive of the pinned release
/// against this map before extracting it.
const llamaCppBundleSha256 = <String, String>{
  'android-arm64':
      'fe838f4775d72842be64bb0279b86fd67c46ff6e4624c3beb35f2e51711f235c',
  'android-x64':
      '67732aa55eaa40a68265760321b75d5746b373efcb6ec9793d76e82f65f6b415',
  'ios-arm64':
      '8df21cb384b0c594e6499bd2c369c63d99c2e0f3cee9892fba3f03d3e7da2c44',
  'ios-arm64-sim':
      '717f8161811d7709a004aaf8ad2e403dec1d86253af2a130fb9a302e6b806beb',
  'ios-x86_64-sim':
      '237d7ded50b542e574bc48ba4b55dc10b203f94da21f9d5cabe6fa3784f820ac',
  'linux-arm64':
      '1701d938a5ceb1f4232cfdb5aa7bf8d5d5d1203ad1f435e1fcc225bdc3fe1be4',
  'linux-x64':
      'f1194c1af3319d7c6e40be67ed44c27176cf4d2758818327aaba68043c53ef0b',
  'macos-arm64':
      '80a467779049e045931d7a66cfce4e6726c337019d507f3aa483fab20f2318be',
  'macos-x86_64':
      'ee0e8af6104dd8bd3b5a75e514284bc1d96c571ac71b49ba0f131c8f9ed033f0',
  'windows-arm64':
      '3452c38d7cee41ddfcbfb130cdc3536725d65e34087f8a6084e3a175053120e3',
  'windows-x64':
      '3d2b0dd1da6a9bea7a430fa762280aa6880786dc2cb7ff94acb3becf41aeedfe',
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
    sha256: '7e54ff8679c337fde5db3f60b085ea8b641bd195a15b819c0437e76a7975577c',
  ),
];

/// `leehack/litert-lm-native` release tag downloaded for the LiteRT-LM runtime.
const liteRtLmReleaseTag = 'v0.19.1-5';

/// LiteRT-LM cache directory version derived from [liteRtLmReleaseTag].
const liteRtLmVersion = '0.19.1-5';

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
    sha256: '09da4ead66bfe95d32aefb890c5b45b10074c60545b99d6c10266d054d93e55f',
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
    sha256: 'c29c937ae7eb405dc34188fe1f63003a165146c24389dc51069d2bbe44db4d25',
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
    sha256: '375201e6b8ccb33f958318dd94aad4629b09a39d7dccbf40584276222d5f0839',
    requiredLibraries: {'CLiteRTLM', 'LiteRtLm'},
  ),
  LiteRtLmBundleSpec(
    'ios-arm64-sim',
    sha256: 'd0608be33ce98fbc72892941d23eb6fb5ba0799fb9a13acb92ffb8e0200b094c',
    requiredLibraries: {'CLiteRTLM', 'LiteRtLm'},
  ),
  LiteRtLmBundleSpec(
    'macos-arm64',
    sha256: '54696ced0a18a4f081724cdbf107061ee1d91b09199e2d1cd86d795de24de691',
    requiredLibraries: {
      'libCLiteRTLM_mac.dylib',
      'libGemmaModelConstraintProvider.dylib',
      'libLiteRtLm.dylib',
      'libwebgpu_dawn.dylib',
    },
  ),
  LiteRtLmBundleSpec(
    'linux-arm64',
    sha256: '6f6814354a8b1e6e74c91056adc67f345394dd1a0c448f7448c2196cac117a88',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtLm.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'linux-x64',
    sha256: '5709cc8e944be2370ab91c9054fbe435f19e80a703a6567fdcd9218962daa55a',
    requiredLibraries: {
      'libGemmaModelConstraintProvider.so',
      'libLiteRtLm.so',
      'libLiteRtWebGpuAccelerator.so',
      'libwebgpu_dawn.so',
    },
  ),
  LiteRtLmBundleSpec(
    'windows-x64',
    sha256: '618b489914283dfe99bac232ba99654bef0b2c26d0a11dc3062016cddb164de5',
    requiredLibraries: {
      'LiteRtLm.dll',
      'dxcompiler.dll',
      'dxil.dll',
      'libGemmaModelConstraintProvider.dll',
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
const stableDiffusionReleaseTag = 'v0.4.0';

/// First Apple companion release containing [stableDiffusionReleaseTag].
const stableDiffusionAppleCompanionVersion = '0.20.0';

/// Explicitly qualified older Apple SD pins that preserve existing app locks.
///
/// The v0.4.0 image generation parameter layout is incompatible with the
/// v0.3.0 line. Clear and requalify this map whenever
/// [stableDiffusionReleaseTag] changes.
const stableDiffusionCompatibleAppleCompanionTags = <String, String>{};

/// Checksums of the exact published XCFrameworks accepted by the SD hook.
const stableDiffusionAppleCompanionChecksums = <String, String>{
  'v0.4.0': '3a9d99a0f818c1511c62b585d3170c41c68f35756143979fe29f4a476bece3ce',
};

/// stable_diffusion cache directory version derived from
/// [stableDiffusionReleaseTag].
const stableDiffusionVersion = '0.4.0';

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
    sha256: 'b9f0e9b7b6daf62f48457cb36465397a8a7805cef3317a9b0a4cd5f3f20ea45b',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64',
    sha256: '21ea0cdd69545445d8f5e9579e300a415db6859437f5b92c8d78717ebaa82d25',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-arm64-sim',
    sha256: '84554867c86eb439ef4929722a9af75950b5c365f66c9691adadbe2ad2de84cc',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'ios-x64-sim',
    sha256: '73a1264dc7f396ad62f8765eeef48afd4ff26014204842c869ea524e909a5d4e',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-arm64',
    sha256: 'db386420ccd34b07dbd4ef5c943e49c04c7965a96aa32d437eac524a968893c6',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'macos-x64',
    sha256: 'cfd5228df4eea3706187fb8faf1afb2221e8537582f52e3cb9d3d553c6cda9ff',
    requiredLibraries: {'libstable-diffusion.dylib'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64',
    sha256: 'c6fd70911050931e6cfbae311fd6f9e40a2bd7b93f4740c4f56b15952f431747',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-arm64-vulkan',
    sha256: 'e2c253e056f4c7a605d334a67f2d845d7b23371ba0f69ead42e2d5e9f5abc148',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64',
    sha256: '97eed4c3a181d28b167c55b1b132d8e6ea75e14f0f4712b921eade086d437fc9',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'linux-x64-vulkan',
    sha256: '63637887575783b121d0cd0f00bbcbe2f72a3f22ffa550a9f5ea30820d079f9a',
    requiredLibraries: {'libstable-diffusion.so'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64',
    sha256: '9e807c03805475edebb88ee3675f06d79823dbe5696565517cf473f43b941c60',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
  StableDiffusionBundleSpec(
    'windows-x64-vulkan',
    sha256: 'cca8b94826f60bc172007acc44f15984fe233f8007120c3def572f14b074194f',
    requiredLibraries: {'stable-diffusion.dll'},
  ),
];
