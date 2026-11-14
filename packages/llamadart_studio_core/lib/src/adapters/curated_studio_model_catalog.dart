import '../domain/curated_model_catalog.dart';
import '../domain/studio_model_descriptor.dart';
import '../ports/studio_context_ports.dart';

/// Default [StudioModelCatalog] backed by [CuratedModelCatalog] plus optional
/// extra descriptors.
class CuratedStudioModelCatalog implements StudioModelCatalog {
  /// Creates a [CuratedStudioModelCatalog].
  const CuratedStudioModelCatalog({
    this.extraModels = const <StudioModelDescriptor>[],
  });

  /// Additional descriptors appended after built-in curated models.
  final List<StudioModelDescriptor> extraModels;

  @override
  List<StudioModelDescriptor> get models => extraModels.isEmpty
      ? CuratedModelCatalog.models
      : List<StudioModelDescriptor>.unmodifiable(<StudioModelDescriptor>[
          ...CuratedModelCatalog.models,
          ...extraModels,
        ]);

  @override
  List<StudioModelDescriptor> forCategory(
    StudioModelCategory? category, {
    required bool isWeb,
    required bool isMobile,
  }) {
    final builtIn = CuratedModelCatalog.forCategory(
      category,
      isWeb: isWeb,
      isMobile: isMobile,
    );
    if (extraModels.isEmpty) {
      return builtIn;
    }
    return <StudioModelDescriptor>[
      ...builtIn,
      ...extraModels.where(
        (StudioModelDescriptor m) =>
            (category == null || m.category == category) &&
            m.isSupportedOn(isWeb: isWeb, isMobile: isMobile),
      ),
    ];
  }

  @override
  StudioModelDescriptor? byId(String? id) {
    if (id == null) {
      return null;
    }
    for (final extra in extraModels) {
      if (extra.id == id) {
        return extra;
      }
    }
    return CuratedModelCatalog.byId(id);
  }
}
