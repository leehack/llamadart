import 'dart:io';

import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;

import '../../domain/curated_model_catalog.dart';
import '../../domain/studio_model_descriptor.dart';
import '../../ports/model_storage_port.dart';
import 'local_model_scanner.dart';

const int _minModelFileBytes = 1024 * 1024; // 1 MiB minimum to skip test stubs.
const int _maxScanDepth = 3;

/// Creates an IO-backed [LocalModelScanner].
LocalModelScanner createLocalModelScanner({
  List<String> defaultRoots = const <String>[],
}) => _IoLocalModelScanner(defaultRoots: defaultRoots);

/// Standard per-user `llamadart` cache directories on macOS, Linux, and Windows.
List<String> defaultDesktopModelRoots() {
  if (Platform.isAndroid || Platform.isIOS) {
    return const <String>[];
  }
  final roots = <String>{};
  try {
    roots.add(DefaultModelDownloadManager.defaultSharedCacheDirectory());
  } catch (_) {
    // Ignore if environment lacks home variables.
  }

  final home =
      Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (home != null && home.trim().isNotEmpty) {
    if (Platform.isMacOS) {
      roots.add(p.join(home, 'Library', 'Caches', 'llamadart', 'models'));
      roots.add(
        p.join(home, 'Library', 'Application Support', 'llamadart', 'models'),
      );
    } else if (Platform.isLinux) {
      final xdgCache = Platform.environment['XDG_CACHE_HOME'];
      if (xdgCache != null && xdgCache.isNotEmpty) {
        roots.add(p.join(xdgCache, 'llamadart', 'models'));
      }
      roots.add(p.join(home, '.cache', 'llamadart', 'models'));
      roots.add(p.join(home, '.local', 'share', 'llamadart', 'models'));
    } else if (Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.isNotEmpty) {
        roots.add(p.join(localAppData, 'llamadart', 'models'));
      }
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        roots.add(p.join(appData, 'llamadart', 'models'));
      }
    }
  }
  return roots.toList(growable: false);
}

class _IoLocalModelScanner implements LocalModelScanner {
  _IoLocalModelScanner({required List<String> defaultRoots})
    : defaultRoots = List<String>.unmodifiable(defaultRoots);

  @override
  final List<String> defaultRoots;

  @override
  Future<LocalModelScanResult> scan({
    List<String> extraDirectories = const <String>[],
  }) async {
    final uniqueRoots = <String>{
      for (final root in defaultRoots)
        if (root.trim().isNotEmpty) p.normalize(root.trim()),
      for (final extra in extraDirectories)
        if (extra.trim().isNotEmpty) p.normalize(extra.trim()),
    };

    if (uniqueRoots.isEmpty) {
      return const LocalModelScanResult();
    }

    final discovered = <LocalScannedModelFile>[];
    final seenCanonicalPaths = <String>{};

    for (final rootPath in uniqueRoots) {
      final dir = Directory(rootPath);
      if (!await dir.exists()) {
        continue;
      }
      await _walkDirectory(
        dir,
        depth: 0,
        seenPaths: seenCanonicalPaths,
        out: discovered,
      );
    }

    if (discovered.isEmpty) {
      return const LocalModelScanResult();
    }

    // Deduplicate by lowercase filename preferring larger complete files, then
    // more recent mtime.
    final byLowerName = <String, LocalScannedModelFile>{};
    for (final file in discovered) {
      final key = file.filename.toLowerCase();
      final existing = byLowerName[key];
      if (existing == null ||
          file.sizeBytes > existing.sizeBytes ||
          (file.sizeBytes == existing.sizeBytes &&
              file.modifiedAt.isAfter(existing.modifiedAt))) {
        byLowerName[key] = file;
      }
    }

    // 1. Match CuratedModelCatalog entries whose primary + companion files are
    // all present locally.
    final curatedMatches = <String, ResolvedModelAssets>{};
    final claimedCuratedFilenames = <String>{};

    for (final descriptor in CuratedModelCatalog.models) {
      final primaryMatch = byLowerName[descriptor.filename.toLowerCase()];
      if (primaryMatch == null) {
        continue;
      }
      final companionSources = <String, ModelSource>{};
      var allCompanionsPresent = true;
      final matchedCompanionNames = <String>[];

      for (final companion in descriptor.companions) {
        final compMatch = _resolveCompanionFile(
          companion: companion,
          primaryFile: primaryMatch,
          byLowerName: byLowerName,
          allFiles: discovered,
        );
        if (compMatch == null) {
          allCompanionsPresent = false;
          break;
        }
        companionSources[companion.role] = ModelSource.path(compMatch.path);
        matchedCompanionNames.add(compMatch.filename.toLowerCase());
      }

      if (allCompanionsPresent) {
        curatedMatches[descriptor.id] = ResolvedModelAssets(
          descriptor: descriptor,
          primarySource: ModelSource.path(
            primaryMatch.path,
            format: descriptor.format,
          ),
          companionSources: companionSources,
        );
        claimedCuratedFilenames.add(primaryMatch.filename.toLowerCase());
        claimedCuratedFilenames.addAll(matchedCompanionNames);
      }
    }

    // 2. Classify remaining primary model files into standalone descriptors.
    final standalone = <StudioModelDescriptor>[];
    final sortedCandidates = byLowerName.values.toList()
      ..sort(
        (LocalScannedModelFile a, LocalScannedModelFile b) =>
            a.filename.toLowerCase().compareTo(b.filename.toLowerCase()),
      );

    for (final candidate in sortedCandidates) {
      final lower = candidate.filename.toLowerCase();
      if (claimedCuratedFilenames.contains(lower)) {
        continue;
      }
      if (_isAuxiliaryOrDraftFile(lower)) {
        continue;
      }
      final descriptor = _classifyStandaloneModel(
        file: candidate,
        byLowerName: byLowerName,
        allFiles: discovered,
      );
      if (descriptor != null) {
        standalone.add(descriptor);
      }
    }

    return LocalModelScanResult(
      curatedAssetsById: curatedMatches,
      standaloneModels: standalone,
      allFiles: byLowerName.values.toList(growable: false),
    );
  }

  Future<void> _walkDirectory(
    Directory dir, {
    required int depth,
    required Set<String> seenPaths,
    required List<LocalScannedModelFile> out,
  }) async {
    if (depth > _maxScanDepth) {
      return;
    }
    Stream<FileSystemEntity> entities;
    try {
      entities = dir.list(followLinks: false);
    } catch (_) {
      return;
    }

    await for (final entity in entities) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) {
        continue;
      }
      if (entity is Directory) {
        final lowerDir = name.toLowerCase();
        if (lowerDir == 'v080-ref-src' || lowerDir == 'locks') {
          continue;
        }
        await _walkDirectory(
          entity,
          depth: depth + 1,
          seenPaths: seenPaths,
          out: out,
        );
      } else if (entity is File) {
        if (!_hasSupportedExtension(name)) {
          continue;
        }
        final normalized = p.normalize(entity.path);
        if (!seenPaths.add(normalized)) {
          continue;
        }
        try {
          final stat = await entity.stat();
          if (stat.size < _minModelFileBytes &&
              !name.toLowerCase().endsWith('.json')) {
            continue;
          }
          out.add(
            LocalScannedModelFile(
              path: normalized,
              filename: name,
              sizeBytes: stat.size,
              modifiedAt: stat.modified,
            ),
          );
        } catch (_) {
          // Ignore unreadable or transient files.
        }
      }
    }
  }

  static bool _hasSupportedExtension(String filename) {
    final lower = filename.toLowerCase();
    return lower.endsWith('.gguf') ||
        lower.endsWith('.litertlm') ||
        lower.endsWith('.tflite') ||
        lower.endsWith('.safetensors') ||
        lower == 'moonshine_tokenizer.json' ||
        lower == 'tokenizer.json';
  }

  static bool _isAuxiliaryOrDraftFile(String lower) {
    if (lower.endsWith('.safetensors') || lower.endsWith('.json')) {
      return true;
    }
    if (lower.startsWith('mmproj') ||
        lower.contains('-mmproj') ||
        lower.contains('.mmproj') ||
        lower.contains('_mmproj')) {
      return true;
    }
    if (lower.startsWith('ggml-vocab-') ||
        lower.startsWith('adapter') ||
        lower.contains('lora') ||
        lower.startsWith('mtp-') ||
        lower.contains('dflash') ||
        lower.contains('speculator') ||
        lower == 'test_model.gguf') {
      return true;
    }
    return false;
  }

  static LocalScannedModelFile? _resolveCompanionFile({
    required StudioModelCompanionAsset companion,
    required LocalScannedModelFile primaryFile,
    required Map<String, LocalScannedModelFile> byLowerName,
    required List<LocalScannedModelFile> allFiles,
  }) {
    final exact = byLowerName[companion.filename.toLowerCase()];
    if (exact != null) {
      return exact;
    }

    if (companion.role == 'taesd') {
      return byLowerName['taesd.safetensors'] ??
          byLowerName['diffusion_pytorch_model.safetensors'];
    }

    if (companion.role == 'decisionHead') {
      return byLowerName['laya-head.safetensors'];
    }

    if (companion.role == 'tokenizer') {
      return byLowerName['moonshine_tokenizer.json'] ??
          byLowerName['tokenizer.json'];
    }

    if (companion.role == 'projector') {
      // Check sibling files in the same directory first.
      final parentDir = p.dirname(primaryFile.path);
      for (final file in allFiles) {
        if (p.dirname(file.path) == parentDir &&
            file.filename.toLowerCase().contains('mmproj')) {
          return file;
        }
      }
      // Match family stem (e.g., Qwen3.5-0.8B -> Qwen3.5-0.8B-mmproj-F16.gguf).
      return _findProjectorForModelName(primaryFile.filename, byLowerName);
    }

    return null;
  }

  static LocalScannedModelFile? _findProjectorForModelName(
    String primaryFilename,
    Map<String, LocalScannedModelFile> byLowerName,
  ) {
    final stem = _familyStem(primaryFilename.toLowerCase());
    if (stem.isEmpty) {
      return null;
    }
    for (final entry in byLowerName.entries) {
      final candidate = entry.key;
      if (!candidate.endsWith('.gguf') || !candidate.contains('mmproj')) {
        continue;
      }
      final normalizedCandidate = _normalizeTokens(candidate);
      if (normalizedCandidate.contains(stem) ||
          (stem.startsWith('ultravox') &&
              normalizedCandidate.contains('ultravox'))) {
        return entry.value;
      }
    }
    return null;
  }

  static StudioModelDescriptor? _classifyStandaloneModel({
    required LocalScannedModelFile file,
    required Map<String, LocalScannedModelFile> byLowerName,
    required List<LocalScannedModelFile> allFiles,
  }) {
    final lower = file.filename.toLowerCase();
    if (!lower.endsWith('.gguf') &&
        !lower.endsWith('.litertlm') &&
        !lower.endsWith('.tflite')) {
      return null;
    }

    final quant = _extractQuantization(file.filename);
    final prettyName = _humanizeModelTitle(file.filename);
    final id = 'local:${file.filename.toLowerCase()}';

    // 1. Speech TTS
    if (lower.contains('tts')) {
      final proj = _findProjectorForModelName(file.filename, byLowerName);
      return StudioModelDescriptor(
        id: id,
        name: prettyName,
        description: 'Installed local neural Text-to-Speech model.',
        category: StudioModelCategory.speech,
        specialty: StudioModelSpecialty.qwen3Tts,
        filename: file.filename,
        sourceUri: file.path,
        sizeBytes: file.sizeBytes + (proj?.sizeBytes ?? 0),
        publisher: 'Local Cache',
        quantizationLabel: quant,
        supportsTextToSpeech: true,
        companions: <StudioModelCompanionAsset>[
          if (proj != null)
            StudioModelCompanionAsset(
              role: 'projector',
              filename: proj.filename,
              sourceUri: proj.path,
              sizeBytes: proj.sizeBytes,
            ),
        ],
      );
    }

    // 2. Speech ASR / STT
    if (lower.contains('asr') ||
        lower.contains('whisper') ||
        lower.contains('moonshine')) {
      if (lower.endsWith('.tflite')) {
        final tok =
            byLowerName['moonshine_tokenizer.json'] ??
            byLowerName['tokenizer.json'];
        if (tok == null) {
          return null;
        }
        return StudioModelDescriptor(
          id: id,
          name: prettyName,
          description: 'Installed local LiteRT Speech-to-Text model.',
          category: StudioModelCategory.speech,
          specialty: StudioModelSpecialty.liteRtAsr,
          liteRtAsrPreset: LiteRtLmAsrModelPreset.moonshineTiny,
          availability: StudioModelAvailability.nativeOnly,
          filename: file.filename,
          sourceUri: file.path,
          sizeBytes: file.sizeBytes + tok.sizeBytes,
          publisher: 'Local Cache',
          quantizationLabel: quant,
          supportsSpeechToText: true,
          companions: <StudioModelCompanionAsset>[
            StudioModelCompanionAsset(
              role: 'tokenizer',
              filename: tok.filename,
              sourceUri: tok.path,
              sizeBytes: tok.sizeBytes,
            ),
          ],
        );
      }

      final proj = _findProjectorForModelName(file.filename, byLowerName);
      return StudioModelDescriptor(
        id: id,
        name: prettyName,
        description: 'Installed local Speech-to-Text ASR model.',
        category: StudioModelCategory.speech,
        specialty: StudioModelSpecialty.qwen3Asr,
        filename: file.filename,
        sourceUri: file.path,
        sizeBytes: file.sizeBytes + (proj?.sizeBytes ?? 0),
        publisher: 'Local Cache',
        quantizationLabel: quant,
        supportsSpeechToText: true,
        companions: <StudioModelCompanionAsset>[
          if (proj != null)
            StudioModelCompanionAsset(
              role: 'projector',
              filename: proj.filename,
              sourceUri: proj.path,
              sizeBytes: proj.sizeBytes,
            ),
        ],
      );
    }

    // 3. Diffusion Image models
    if (lower.startsWith('sd_') ||
        lower.startsWith('sd-') ||
        lower.startsWith('sdxs') ||
        lower.startsWith('sdxl') ||
        lower.contains('stable-diffusion') ||
        lower.contains('tinystablediffusion') ||
        lower.contains('tinysd')) {
      final taesd = lower.contains('turbo')
          ? (byLowerName['taesd.safetensors'] ??
                byLowerName['diffusion_pytorch_model.safetensors'])
          : null;
      return StudioModelDescriptor(
        id: id,
        name: prettyName,
        description: 'Installed local Stable Diffusion checkpoint.',
        category: StudioModelCategory.image,
        specialty: StudioModelSpecialty.stableDiffusion,
        availability: StudioModelAvailability.nativeOnly,
        filename: file.filename,
        sourceUri: file.path,
        sizeBytes: file.sizeBytes + (taesd?.sizeBytes ?? 0),
        publisher: 'Local Cache',
        quantizationLabel: quant,
        companions: <StudioModelCompanionAsset>[
          if (taesd != null)
            StudioModelCompanionAsset(
              role: 'taesd',
              filename: taesd.filename,
              sourceUri: taesd.path,
              sizeBytes: taesd.sizeBytes,
            ),
        ],
      );
    }

    // 4. Laya System-1 Decision models
    if (lower.startsWith('laya-') || lower.startsWith('laya_')) {
      final head = byLowerName['laya-head.safetensors'];
      if (head == null) {
        return null;
      }
      return StudioModelDescriptor(
        id: id,
        name: prettyName,
        description:
            'Installed local System-1 Decision encoder + safetensors head.',
        category: StudioModelCategory.playground,
        specialty: StudioModelSpecialty.decision,
        filename: file.filename,
        sourceUri: file.path,
        sizeBytes: file.sizeBytes + head.sizeBytes,
        publisher: 'Local Cache',
        quantizationLabel: quant,
        companions: <StudioModelCompanionAsset>[
          StudioModelCompanionAsset(
            role: 'decisionHead',
            filename: head.filename,
            sourceUri: head.path,
            sizeBytes: head.sizeBytes,
          ),
        ],
      );
    }

    // 5. Reranker models
    if (lower.contains('rerank')) {
      return StudioModelDescriptor(
        id: id,
        name: prettyName,
        description: 'Installed local cross-encoder Reranker model.',
        category: StudioModelCategory.playground,
        specialty: StudioModelSpecialty.reranker,
        availability: StudioModelAvailability.nativeOnly,
        filename: file.filename,
        sourceUri: file.path,
        sizeBytes: file.sizeBytes,
        publisher: 'Local Cache',
        quantizationLabel: quant,
      );
    }

    // 6. Embedding models
    if (lower.contains('embed')) {
      final isGemma2 = lower.contains('embeddinggemma-2');
      final proj = _findProjectorForModelName(file.filename, byLowerName);
      return StudioModelDescriptor(
        id: id,
        name: prettyName,
        description: isGemma2
            ? 'Installed local EmbeddingGemma 2 multimodal encoder (text, image, audio).'
            : 'Installed local semantic Embedding encoder.',
        category: StudioModelCategory.playground,
        specialty: StudioModelSpecialty.embedding,
        availability: lower.endsWith('.litertlm')
            ? StudioModelAvailability.nativeOnly
            : StudioModelAvailability.all,
        embeddingProfile: isGemma2
            ? LlamaEmbeddingProfile.embeddingGemma2
            : LlamaEmbeddingProfile.raw,
        filename: file.filename,
        sourceUri: file.path,
        sizeBytes: file.sizeBytes + (proj?.sizeBytes ?? 0),
        publisher: 'Local Cache',
        quantizationLabel: quant,
        supportsVision: isGemma2 || proj != null,
        supportsAudio: isGemma2 && lower.endsWith('.litertlm'),
        companions: <StudioModelCompanionAsset>[
          if (proj != null)
            StudioModelCompanionAsset(
              role: 'projector',
              filename: proj.filename,
              sourceUri: proj.path,
              sizeBytes: proj.sizeBytes,
            ),
        ],
      );
    }

    // 7. General Chat / Multimodal / Reasoning / Tool-Calling models
    if (lower.endsWith('.tflite') || lower.endsWith('-web.litertlm')) {
      return null;
    }
    final proj = _findProjectorForModelName(file.filename, byLowerName);
    final hasVision =
        proj != null || lower.contains('-vl') || lower.contains('vlm');
    final hasAudio =
        lower.contains('omni') ||
        lower.contains('ultravox') ||
        lower.contains('gemma-4') ||
        lower.contains('gemma-3n');
    final hasThinking =
        lower.contains('qwen3') ||
        lower.contains('deepseek-r1') ||
        lower.contains('reasoning') ||
        lower.contains('gemma-4') ||
        lower.contains('glm-4');
    final hasTools =
        lower.contains('qwen') ||
        lower.contains('gemma') ||
        lower.contains('llama-3') ||
        lower.contains('mistral') ||
        lower.contains('ministral') ||
        lower.contains('function') ||
        lower.contains('granite') ||
        lower.contains('glm') ||
        lower.contains('phi-4');

    return StudioModelDescriptor(
      id: id,
      name: prettyName,
      description: proj != null
          ? 'Installed local multimodal model (paired with ${proj.filename}).'
          : 'Installed local model discovered in your llamadart cache.',
      category: StudioModelCategory.chat,
      specialty: StudioModelSpecialty.generalChat,
      filename: file.filename,
      sourceUri: file.path,
      sizeBytes: file.sizeBytes + (proj?.sizeBytes ?? 0),
      publisher: 'Local Cache',
      quantizationLabel: quant,
      minRamGb: _estimateMinRamGb(file.sizeBytes),
      supportsVision: hasVision,
      supportsAudio: hasAudio,
      supportsThinking: hasThinking,
      supportsToolCalling: hasTools,
      companions: <StudioModelCompanionAsset>[
        if (proj != null)
          StudioModelCompanionAsset(
            role: 'projector',
            filename: proj.filename,
            sourceUri: proj.path,
            sizeBytes: proj.sizeBytes,
          ),
      ],
    );
  }

  static int _estimateMinRamGb(int bytes) {
    final gib = bytes / (1024 * 1024 * 1024);
    if (gib < 1.0) return 2;
    if (gib < 2.2) return 4;
    if (gib < 4.2) return 8;
    if (gib < 8.5) return 12;
    if (gib < 16.0) return 24;
    return 32;
  }

  static String? _extractQuantization(String filename) {
    final match = RegExp(
      r'(UD-Q\d_[A-Z0-9_]+|IQ\d_[A-Z0-9_]+|Q\d_[A-Z0-9_]+|Q\d_0|F16|BF16|INT8|INT4)',
      caseSensitive: false,
    ).firstMatch(filename);
    return match?.group(1)?.toUpperCase();
  }

  static String _humanizeModelTitle(String filename) {
    final stem = filename
        .replaceAll(
          RegExp(r'\.(gguf|litertlm|tflite)$', caseSensitive: false),
          '',
        )
        .replaceAll('_', ' ');
    return stem.trim();
  }

  static String _familyStem(String lowerFilename) {
    var stem = lowerFilename.replaceAll(
      RegExp(r'\.(gguf|litertlm|tflite)$'),
      '',
    );
    // Strip quantization suffixes like -q4_k_m, .q4_k_m, -ud-q4_k_xl, -q8_0, -f16.
    stem = stem.replaceAll(
      RegExp(
        r'[-._](qat[-._])?(ud[-._])?(iq\d[-_a-z0-9]*|q\d[-_a-z0-9]*|f16|bf16|int8|int4)$',
      ),
      '',
    );
    stem = stem.replaceAll(RegExp(r'[-._](instruct|it)$'), '');
    return _normalizeTokens(stem);
  }

  static String _normalizeTokens(String raw) {
    return raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
  }
}
