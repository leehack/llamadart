import '../models/config/compute_device.dart';
import '../models/inference/model_params.dart';

/// Runtime settings of a decision model: `params:` of `DecisionEngine.load`.
class DecisionModelParams {
  /// Device to run the encoder and head on, as `ModelParams.device`.
  ///
  /// [ComputeDevice.auto] offloads every layer to the best GPU the backend
  /// loads, otherwise uses the CPU; on Android it uses the CPU.
  /// [ComputeDevice.gpu] runs on a GPU (Vulkan on Android) or
  /// `DecisionEngine.load` throws `LlamaUnsupportedException` from the
  /// encoder load. [ComputeDevice.npu] is not supported and throws
  /// `LlamaUnsupportedException`.
  final ComputeDevice device;

  /// CPU threads of the encoder and the head. `0` uses the runtime default.
  final int threads;

  /// Creates runtime settings.
  const DecisionModelParams({
    this.device = ComputeDevice.auto,
    this.threads = 0,
  });

  /// The encoder parameters `DecisionEngine.load` uses: a 512-token context,
  /// since decisions run in the head's own encoder context, with [device]
  /// and [threads] applied.
  ///
  /// Load the encoder with them before `DecisionEngine.attach`.
  ModelParams get encoderModelParams => ModelParams(
    contextSize: 512,
    device: device,
    numberOfThreads: threads,
    numberOfThreadsBatch: threads,
  );
}
