import 'package:dio/dio.dart';
import 'package:meta/meta.dart';

import '../../domain/studio_model_descriptor.dart';

/// Summary of a Hugging Face repository discovered via search.
@immutable
class HuggingFaceRepoHit {
  /// Creates a [HuggingFaceRepoHit].
  const HuggingFaceRepoHit({
    required this.repoId,
    required this.downloads,
    required this.likes,
    this.pipelineTag,
    this.tags = const <String>[],
  });

  /// Repository slug (`owner/name`).
  final String repoId;

  /// 30-day download count.
  final int downloads;

  /// Community like count.
  final int likes;

  /// Optional Hugging Face pipeline tag.
  final String? pipelineTag;

  /// Model tags reported by Hugging Face Hub.
  final List<String> tags;
}

/// Pure-Dart Hugging Face Hub client discovering GGUF and `.litertlm` files
/// and automatically pairing `mmproj` vision/audio projectors when present.
class HuggingFaceDiscoveryService {
  /// Creates a [HuggingFaceDiscoveryService].
  HuggingFaceDiscoveryService({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              baseUrl: 'https://huggingface.co',
              connectTimeout: const Duration(seconds: 12),
              receiveTimeout: const Duration(seconds: 15),
            ),
          );

  final Dio _dio;

  /// Searches Hugging Face Hub for GGUF / LiteRT-LM repositories matching
  /// [query].
  Future<List<HuggingFaceRepoHit>> searchRepositories(
    String query, {
    int limit = 16,
    String? bearerToken,
  }) async {
    final trimmed = query.trim();
    final response = await _dio.get<List<dynamic>>(
      '/api/models',
      queryParameters: <String, Object?>{
        if (trimmed.isNotEmpty) 'search': trimmed,
        'filter': 'gguf',
        'sort': 'downloads',
        'direction': '-1',
        'limit': limit,
      },
      options: _authOptions(bearerToken),
    );
    final raw = response.data ?? const <dynamic>[];
    final hits = <HuggingFaceRepoHit>[];
    for (final item in raw) {
      if (item is! Map) {
        continue;
      }
      final map = Map<String, Object?>.from(item);
      final repoId = (map['id'] as String?) ?? (map['modelId'] as String?);
      if (repoId == null || repoId.isEmpty) {
        continue;
      }
      final rawTags = map['tags'];
      hits.add(
        HuggingFaceRepoHit(
          repoId: repoId,
          downloads: (map['downloads'] as num?)?.toInt() ?? 0,
          likes: (map['likes'] as num?)?.toInt() ?? 0,
          pipelineTag: map['pipeline_tag'] as String?,
          tags: rawTags is List
              ? rawTags.whereType<String>().toList(growable: false)
              : const <String>[],
        ),
      );
    }
    return hits;
  }

  /// Inspects a specific repository (`owner/name`) and converts its compatible
  /// `.gguf` / `.litertlm` files into loadable [StudioModelDescriptor]s.
  Future<List<StudioModelDescriptor>> inspectRepositoryFiles(
    String repoId, {
    String? bearerToken,
  }) async {
    final cleanRepo = repoId
        .trim()
        .replaceFirst(RegExp(r'^https?://huggingface\.co/'), '')
        .replaceAll(RegExp(r'/+$'), '');
    final treeResp = await _dio.get<List<dynamic>>(
      '/api/models/$cleanRepo/tree/main',
      options: _authOptions(bearerToken),
    );
    final entries = treeResp.data ?? const <dynamic>[];

    String? detectedMmprojPath;
    int mmprojBytes = 0;
    final modelEntries = <({String path, int sizeBytes})>[];

    for (final raw in entries) {
      if (raw is! Map) {
        continue;
      }
      final map = Map<String, Object?>.from(raw);
      if (map['type'] != 'file') {
        continue;
      }
      final path = (map['path'] as String?) ?? '';
      final lower = path.toLowerCase();
      final lfs = map['lfs'];
      final sizeBytes = lfs is Map
          ? ((lfs['size'] as num?)?.toInt() ??
                (map['size'] as num?)?.toInt() ??
                0)
          : ((map['size'] as num?)?.toInt() ?? 0);

      if (lower.contains('mmproj') && lower.endsWith('.gguf')) {
        // Prefer F16 or Q8_0 mmproj when multiple exist.
        if (detectedMmprojPath == null ||
            lower.contains('f16') ||
            lower.contains('q8_0')) {
          detectedMmprojPath = path;
          mmprojBytes = sizeBytes;
        }
        continue;
      }

      // Skip split shards like `-00002-of-00003.gguf`.
      final shardMatch = RegExp(
        r'-(\d{5})-of-(\d{5})\.gguf$',
      ).firstMatch(lower);
      if (shardMatch != null && shardMatch.group(1) != '00001') {
        continue;
      }

      if (lower.endsWith('.gguf') || lower.endsWith('.litertlm')) {
        modelEntries.add((path: path, sizeBytes: sizeBytes));
      }
    }

    final publisher = cleanRepo.contains('/')
        ? cleanRepo.split('/').first
        : 'Hugging Face';

    final descriptors = <StudioModelDescriptor>[];
    for (final entry in modelEntries) {
      final filename = entry.path.split('/').last;
      final quant = _extractQuantizationLabel(filename);
      final companions = <StudioModelCompanionAsset>[
        if (detectedMmprojPath != null &&
            filename.toLowerCase().endsWith('.gguf'))
          StudioModelCompanionAsset(
            role: 'projector',
            filename: '${cleanRepo.replaceAll('/', '_')}_$detectedMmprojPath'
                .replaceAll('/', '_'),
            sourceUri:
                'https://huggingface.co/$cleanRepo/resolve/main/$detectedMmprojPath?download=true',
            webSourceUri:
                'https://huggingface.co/$cleanRepo/resolve/main/$detectedMmprojPath',
            sizeBytes: mmprojBytes,
          ),
      ];
      final totalBytes = entry.sizeBytes + mmprojBytes;
      final estimatedRamGb = totalBytes > 0
          ? ((totalBytes / (1024 * 1024 * 1024)) * 1.6).ceil().clamp(2, 64)
          : 4;

      descriptors.add(
        StudioModelDescriptor(
          id: 'hf:$cleanRepo/${entry.path}',
          name: '$cleanRepo · ${quant ?? filename}',
          description: 'Discovered from Hugging Face repository $cleanRepo.',
          category: StudioModelCategory.chat,
          filename: filename,
          sourceUri:
              'https://huggingface.co/$cleanRepo/resolve/main/${entry.path}?download=true',
          webSourceUri:
              'https://huggingface.co/$cleanRepo/resolve/main/${entry.path}',
          sizeBytes: totalBytes,
          publisher: publisher,
          quantizationLabel: quant,
          minRamGb: estimatedRamGb,
          supportsVision: companions.isNotEmpty,
          supportsToolCalling: true,
          supportsThinking:
              cleanRepo.toLowerCase().contains('qwen3') ||
              cleanRepo.toLowerCase().contains('gemma-4') ||
              cleanRepo.toLowerCase().contains('deepseek'),
          companions: companions,
        ),
      );
    }
    return descriptors;
  }

  static Options? _authOptions(String? bearerToken) {
    final trimmed = bearerToken?.trim();
    if (trimmed == null || trimmed.isEmpty) {
      return null;
    }
    return Options(
      headers: <String, String>{'Authorization': 'Bearer $trimmed'},
    );
  }

  static String? _extractQuantizationLabel(String filename) {
    final match = RegExp(
      r'(UD-Q\d_[A-Z0-9_]+|IQ\d_[A-Z0-9_]+|Q\d_[A-Z0-9_]+|BF16|F16|F32)',
      caseSensitive: false,
    ).firstMatch(filename);
    return match?.group(1)?.toUpperCase();
  }
}
