/// Device an engine runs a model on.
///
/// Shared by llamadart engines; each engine documents the devices it
/// supports and throws `LlamaUnsupportedException` for the others.
/// `ImageGenerationEngine` supports [auto], [cpu] and [gpu].
enum ComputeDevice {
  /// The engine's best available device, such as the first GPU, otherwise
  /// the CPU.
  auto,

  /// The CPU.
  cpu,

  /// The first GPU the runtime reports.
  gpu,

  /// A neural processing unit.
  npu,
}
