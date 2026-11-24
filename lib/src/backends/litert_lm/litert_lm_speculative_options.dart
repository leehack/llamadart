import '../../core/models/inference/generation_params.dart';

/// The speculative controls LiteRT-LM cannot apply.
List<String> liteRtLmUnsupportedSpeculativeOptions(GenerationParams params) {
  final config = params.resolvedSpeculativeDecodingConfig;
  if (config == null) return const [];
  final strategies = config.effectiveStrategies;
  return [
    if (strategies.length > 1 ||
        strategies.any(
          (strategy) =>
              strategy != SpeculativeDecodingStrategy.backendDefault &&
              strategy != SpeculativeDecodingStrategy.mtp,
        ))
      'speculativeDecodingConfig.strategy',
    for (final (field, value) in [
      ('draftTokenMax', config.draftTokenMax),
      ('draftTokenMin', config.draftTokenMin),
      ('minProbability', config.minProbability),
      ('draftSplitProbability', config.draftSplitProbability),
      ('draftMicroBatchSize', config.draftMicroBatchSize),
      ('draftModel', config.draftModelPath),
      ('ngramSize', config.ngramSize),
      ('ngramSizeN', config.ngramSizeN),
      ('ngramSizeM', config.ngramSizeM),
      ('ngramMinHits', config.ngramMinHits),
      ('ngramMatch', config.ngramMatch),
      ('ngramTokenMin', config.ngramTokenMin),
      ('ngramTokenMax', config.ngramTokenMax),
      ('ngramCacheStaticPath', config.ngramCacheStaticPath),
      ('ngramCacheDynamicPath', config.ngramCacheDynamicPath),
    ])
      if (value != null) 'speculativeDecodingConfig.$field',
  ];
}
