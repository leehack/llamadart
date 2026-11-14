import 'package:llamadart/llamadart.dart';

import 'studio_model_descriptor.dart';

/// Curated, SHA/URL-verified starter models showcasing every `llamadart`
/// capability across Chat, Vision, Audio, Tools, Speech, Diffusion,
/// Embeddings, Reranking, and System-1 Decision Heads.
abstract final class CuratedModelCatalog {
  /// Full curated model catalog ordered by category and footprint.
  static const List<StudioModelDescriptor> models = <StudioModelDescriptor>[
    StudioModelDescriptor(
      id: 'qwen3.5-0.8b-q4-k-m',
      name: 'Qwen3.5 0.8B Instruct',
      description:
          'Fast everyday starter assistant with vision, tool calling, and '
          'chain-of-thought reasoning.',
      category: StudioModelCategory.chat,
      filename: 'Qwen3.5-0.8B-Q4_K_M.gguf',
      sourceUri:
          'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/Qwen3.5-0.8B-Q4_K_M.gguf?download=true',
      sizeBytes: 754903104,
      publisher: 'Unsloth',
      quantizationLabel: 'Q4_K_M',
      minRamGb: 3,
      supportsVision: true,
      supportsToolCalling: true,
      supportsThinking: true,
      isRecommended: true,
      companions: <StudioModelCompanionAsset>[
        StudioModelCompanionAsset(
          role: 'projector',
          filename: 'Qwen3.5-0.8B-mmproj-F16.gguf',
          sourceUri:
              'https://huggingface.co/unsloth/Qwen3.5-0.8B-GGUF/resolve/main/mmproj-F16.gguf?download=true',
        ),
      ],
      preset: StudioModelTuningPreset(
        temperature: 0.7,
        topK: 20,
        topP: 0.8,
        penalty: 1.0,
        contextSize: 4096,
        maxTokens: 2048,
        thinkingEnabled: true,
      ),
    ),
    StudioModelDescriptor(
      id: 'functiongemma-270m-q4-k-m',
      name: 'FunctionGemma 270M',
      description:
          'Ultra-compact specialist for instant tool-calling and structured '
          'JSON extraction.',
      category: StudioModelCategory.chat,
      filename: 'functiongemma-270m-it-Q4_K_M.gguf',
      sourceUri:
          'https://huggingface.co/unsloth/functiongemma-270m-it-GGUF/resolve/main/functiongemma-270m-it-Q4_K_M.gguf?download=true',
      sizeBytes: 253127904,
      publisher: 'Unsloth',
      quantizationLabel: 'Q4_K_M',
      minRamGb: 2,
      supportsToolCalling: true,
      preset: StudioModelTuningPreset(
        temperature: 0.0,
        topK: 40,
        topP: 0.9,
        contextSize: 4096,
        maxTokens: 1024,
      ),
    ),
    StudioModelDescriptor(
      id: 'gemma-4-e2b-it-q4-k-s',
      name: 'Gemma 4 E2B it',
      description:
          'Balanced multimodal assistant supporting images, audio clips, '
          'tools, and reasoning.',
      category: StudioModelCategory.chat,
      filename: 'gemma-4-E2B-it-Q4_K_S.gguf',
      sourceUri:
          'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/90f9618340396838ee7ff5b0ba2da27da62953d3/gemma-4-E2B-it-Q4_K_S.gguf?download=true',
      webSourceUri:
          'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_S.gguf?download=true',
      sizeBytes: 4029586368,
      webSizeBytes: 4029588384,
      sha256:
          '0a2fac16f388b4839f075dedb681357aec3e73a96bd66b413e462b6853550c99',
      publisher: 'Unsloth',
      quantizationLabel: 'Q4_K_S',
      minRamGb: 8,
      supportsVision: true,
      supportsAudio: true,
      webSupportsAudio: false,
      supportsToolCalling: true,
      supportsThinking: true,
      isRecommended: true,
      companions: <StudioModelCompanionAsset>[
        StudioModelCompanionAsset(
          role: 'projector',
          filename: 'gemma-4-E2B-it-mmproj-F16.gguf',
          sourceUri:
              'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/90f9618340396838ee7ff5b0ba2da27da62953d3/mmproj-F16.gguf?download=true',
          webSourceUri:
              'https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/mmproj-F16.gguf?download=true',
          sizeBytes: 985654080,
          sha256:
              '140be8d7849741f88c50757d529b84373ee8e27052cc2236855b537f4a8215fa',
        ),
      ],
      preset: StudioModelTuningPreset(
        temperature: 1.0,
        topK: 64,
        topP: 0.95,
        penalty: 1.0,
        contextSize: 8192,
        maxTokens: 2048,
        thinkingEnabled: true,
      ),
    ),
    StudioModelDescriptor(
      id: 'gemma-4-e2b-litertlm',
      name: 'Gemma 4 E2B LiteRT-LM',
      description:
          'LiteRT-LM bundle with direct native audio input and fast WebGPU '
          'execution.',
      category: StudioModelCategory.chat,
      filename: 'gemma-4-E2B-it.litertlm',
      sourceUri:
          'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/6b78abd019e61a1ca4cbe3b212d2c9ce8ff38a94/gemma-4-E2B-it.litertlm?download=true',
      webSourceUri:
          'https://huggingface.co/litert-community/gemma-4-E2B-it-litert-lm/resolve/main/gemma-4-E2B-it-web.litertlm?download=true',
      sizeBytes: 2588147712,
      webSizeBytes: 2008432640,
      sha256:
          '181938105e0eefd105961417e8da75903eacda102c4fce9ce90f50b97139a63c',
      publisher: 'LiteRT Community',
      quantizationLabel: 'INT4',
      minRamGb: 8,
      supportsAudio: true,
      webSupportsAudio: false,
      supportsThinking: true,
      preset: StudioModelTuningPreset(
        temperature: 1.0,
        topK: 64,
        topP: 0.95,
        penalty: 1.0,
        contextSize: 8192,
        maxTokens: 2048,
        thinkingEnabled: true,
      ),
    ),
    StudioModelDescriptor(
      id: 'gemma-4-e4b-it-q4-k-s',
      name: 'Gemma 4 E4B it',
      description:
          'Higher-capacity multimodal model for capable edge and desktop '
          'machines.',
      category: StudioModelCategory.chat,
      filename: 'gemma-4-E4B-it-Q4_K_S.gguf',
      sourceUri:
          'https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/gemma-4-E4B-it-Q4_K_S.gguf?download=true',
      sizeBytes: 4844848288,
      publisher: 'Unsloth',
      quantizationLabel: 'Q4_K_S',
      minRamGb: 12,
      supportsVision: true,
      supportsAudio: true,
      webSupportsAudio: false,
      supportsToolCalling: true,
      supportsThinking: true,
      companions: <StudioModelCompanionAsset>[
        StudioModelCompanionAsset(
          role: 'projector',
          filename: 'gemma-4-E4B-it-mmproj-F16.gguf',
          sourceUri:
              'https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/resolve/main/mmproj-F16.gguf?download=true',
        ),
      ],
      preset: StudioModelTuningPreset(
        temperature: 1.0,
        topK: 64,
        topP: 0.95,
        penalty: 1.0,
        contextSize: 8192,
        maxTokens: 2048,
        thinkingEnabled: true,
      ),
    ),
    StudioModelDescriptor(
      id: 'gemma-4-12b-it-q4-k-s',
      name: 'Gemma 4 12B it',
      description:
          'Strong multimodal reasoning tier for 16 GB+ desktop workstations.',
      category: StudioModelCategory.chat,
      filename: 'gemma-4-12b-it-Q4_K_S.gguf',
      sourceUri:
          'https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/gemma-4-12b-it-Q4_K_S.gguf?download=true',
      sizeBytes: 6764524960,
      publisher: 'Unsloth',
      quantizationLabel: 'Q4_K_S',
      minRamGb: 16,
      availability: StudioModelAvailability.desktopOnly,
      supportsVision: true,
      supportsAudio: true,
      supportsToolCalling: true,
      supportsThinking: true,
      companions: <StudioModelCompanionAsset>[
        StudioModelCompanionAsset(
          role: 'projector',
          filename: 'gemma-4-12b-it-mmproj-F16.gguf',
          sourceUri:
              'https://huggingface.co/unsloth/gemma-4-12b-it-GGUF/resolve/main/mmproj-F16.gguf?download=true',
        ),
      ],
      preset: StudioModelTuningPreset(
        temperature: 1.0,
        topK: 64,
        topP: 0.95,
        penalty: 1.0,
        contextSize: 8192,
        maxTokens: 2048,
        thinkingEnabled: true,
      ),
    ),
    StudioModelDescriptor(
      id: 'qwen3.8-27b-ud-q4-k-xl',
      name: 'Qwen3.8 27B Coding',
      description:
          'Latest Qwen3.8 dense coding, vision & agentic reasoning model for '
          'repository editing, MCP tool loops, and refactoring on 24 GB+ Macs.',
      category: StudioModelCategory.chat,
      filename: 'Qwen3.8-27B-UD-Q4_K_XL.gguf',
      sourceUri:
          'https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/Qwen3.8-27B-UD-Q4_K_XL.gguf?download=true',
      sizeBytes: 17659407264,
      sha256:
          '2a5f3565f39cf885103da591182c1266da64745737b42b452fd3e675369f1211',
      publisher: 'Unsloth',
      quantizationLabel: 'UD-Q4_K_XL',
      minRamGb: 24,
      availability: StudioModelAvailability.desktopOnly,
      supportsVision: true,
      supportsToolCalling: true,
      supportsThinking: true,
      isRecommended: true,
      companions: <StudioModelCompanionAsset>[
        StudioModelCompanionAsset(
          role: 'projector',
          filename: 'Qwen3.8-27B-mmproj-F16.gguf',
          sourceUri:
              'https://huggingface.co/unsloth/Qwen3.8-27B-GGUF/resolve/main/mmproj-F16.gguf?download=true',
          sizeBytes: 927607488,
          sha256:
              'cbb841a9ee0636b2ec172f5bb8df2ea8dfeb01e90fe7c6126581d662a0b4e43e',
        ),
      ],
      preset: StudioModelTuningPreset(
        temperature: 0.6,
        topK: 20,
        topP: 0.95,
        minP: 0.0,
        penalty: 1.0,
        contextSize: 16384,
        maxTokens: 4096,
        thinkingEnabled: true,
        thinkingBudgetTokens: 512,
      ),
    ),
    StudioModelDescriptor(
      id: 'qwen3.6-27b-ud-q4-k-xl',
      name: 'Qwen3.6 27B Coding',
      description:
          'Previous-generation dense coding & agentic reasoning model for '
          'repository editing, MCP tool loops, and refactoring on 24 GB+ Macs.',
      category: StudioModelCategory.chat,
      filename: 'Qwen3.6-27B-UD-Q4_K_XL.gguf',
      sourceUri:
          'https://huggingface.co/unsloth/Qwen3.6-27B-GGUF/resolve/main/Qwen3.6-27B-UD-Q4_K_XL.gguf?download=true',
      sizeBytes: 17612564704,
      publisher: 'Unsloth',
      quantizationLabel: 'UD-Q4_K_XL',
      minRamGb: 24,
      availability: StudioModelAvailability.desktopOnly,
      supportsToolCalling: true,
      supportsThinking: true,
      isRecommended: false,
      preset: StudioModelTuningPreset(
        temperature: 0.2,
        topK: 20,
        topP: 0.9,
        penalty: 1.0,
        contextSize: 16384,
        maxTokens: 4096,
        thinkingEnabled: true,
        thinkingBudgetTokens: 512,
      ),
    ),
    StudioModelDescriptor(
      id: 'qwen3.6-35b-a3b-ud-q4-k-s',
      name: 'Qwen3.6 35B A3B MoE',
      description:
          'High-speed mixture-of-experts model for coding, agents, and vision '
          'on 32 GB+ desktops.',
      category: StudioModelCategory.chat,
      filename: 'Qwen3.6-35B-A3B-UD-Q4_K_S.gguf',
      sourceUri:
          'https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q4_K_S.gguf?download=true',
      sizeBytes: 20893015008,
      publisher: 'Unsloth',
      quantizationLabel: 'UD-Q4_K_S',
      minRamGb: 32,
      availability: StudioModelAvailability.desktopOnly,
      supportsVision: true,
      supportsToolCalling: true,
      supportsThinking: true,
      companions: <StudioModelCompanionAsset>[
        StudioModelCompanionAsset(
          role: 'projector',
          filename: 'Qwen3.6-35B-A3B-mmproj-F16.gguf',
          sourceUri:
              'https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/mmproj-F16.gguf?download=true',
        ),
      ],
      preset: StudioModelTuningPreset(
        temperature: 0.7,
        topK: 20,
        topP: 0.8,
        penalty: 1.0,
        contextSize: 16384,
        maxTokens: 4096,
        thinkingEnabled: true,
      ),
    ),

    // Speech Studio models
    StudioModelDescriptor(
      id: 'qwen3-tts-1.7b-base-q4-k-m',
      name: 'Qwen3-TTS 1.7B Base',
      description:
          'Neural text-to-speech with multi-language support and optional '
          'speaker-reference voice cloning.',
      category: StudioModelCategory.speech,
      specialty: StudioModelSpecialty.qwen3Tts,
      filename: 'Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf',
      sourceUri:
          'https://huggingface.co/ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF/resolve/ca27d74bc954b73dadab5b71ca265d87fc861a7c/Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf?download=true',
      webSourceUri:
          'https://huggingface.co/ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF/resolve/ca27d74bc954b73dadab5b71ca265d87fc861a7c/Qwen3-TTS-12Hz-1.7B-Base-Q4_K_M.gguf',
      sizeBytes: 1482388192,
      webSizeBytes: 1482388192,
      sha256:
          '8d18c94acb2addd042f97da63c98be144eafa76d0d9495177eab65130cf85129',
      publisher: 'ggml-org',
      quantizationLabel: 'Q4_K_M',
      minRamGb: 6,
      supportsTextToSpeech: true,
      isRecommended: true,
      companions: <StudioModelCompanionAsset>[
        StudioModelCompanionAsset(
          role: 'projector',
          filename: 'mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf',
          sourceUri:
              'https://huggingface.co/ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF/resolve/ca27d74bc954b73dadab5b71ca265d87fc861a7c/mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf?download=true',
          webSourceUri:
              'https://huggingface.co/ggml-org/Qwen3-TTS-12Hz-1.7B-Base-GGUF/resolve/ca27d74bc954b73dadab5b71ca265d87fc861a7c/mmproj-Qwen3-TTS-12Hz-1.7B-Base-Q8_0.gguf',
          sizeBytes: 446422912,
          sha256:
              '6fd65188839bcd6ecc91b277ad471e22a0edfada4699a0fe82f1165c18cfcce2',
        ),
      ],
      preset: StudioModelTuningPreset(
        temperature: 0.8,
        topK: 40,
        topP: 0.95,
        penalty: 1.0,
        contextSize: 4096,
        maxTokens: 512,
      ),
    ),
    StudioModelDescriptor(
      id: 'qwen3-asr-0.6b-q8-0',
      name: 'Qwen3-ASR 0.6B',
      description:
          'Multilingual whole-audio speech-to-text transcription across native '
          'and WebGPU.',
      category: StudioModelCategory.speech,
      specialty: StudioModelSpecialty.qwen3Asr,
      filename: 'Qwen3-ASR-0.6B-Q8_0.gguf',
      sourceUri:
          'https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/928ab958557df9aa2ef1c93e0e83c7ad0933fae2/Qwen3-ASR-0.6B-Q8_0.gguf?download=true',
      webSourceUri:
          'https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/928ab958557df9aa2ef1c93e0e83c7ad0933fae2/Qwen3-ASR-0.6B-Q8_0.gguf',
      sizeBytes: 1019141728,
      sha256:
          'bca259818b50ca7c4c05e9bdb35a5dc04fa039653a6d6f3f0f331f96f6aa1971',
      publisher: 'ggml-org',
      quantizationLabel: 'Q8_0',
      minRamGb: 4,
      supportsSpeechToText: true,
      isRecommended: true,
      companions: <StudioModelCompanionAsset>[
        StudioModelCompanionAsset(
          role: 'projector',
          filename: 'mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
          sourceUri:
              'https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/928ab958557df9aa2ef1c93e0e83c7ad0933fae2/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf?download=true',
          webSourceUri:
              'https://huggingface.co/ggml-org/Qwen3-ASR-0.6B-GGUF/resolve/928ab958557df9aa2ef1c93e0e83c7ad0933fae2/mmproj-Qwen3-ASR-0.6B-Q8_0.gguf',
          sizeBytes: 214392480,
          sha256:
              '41a342b5e4c514e968cb756de6cd1b7be39eff43c44c57a2ef5fc6522e36603d',
        ),
      ],
      preset: StudioModelTuningPreset(
        temperature: 0.0,
        topK: 1,
        topP: 1.0,
        penalty: 1.0,
        contextSize: 4096,
        maxTokens: 1024,
      ),
    ),
    StudioModelDescriptor(
      id: 'litert-moonshine-tiny-i8',
      name: 'Moonshine Tiny Live STT',
      description:
          'Ultra-lightweight 54 MB English dictation model using 5-second '
          'LiteRT windows.',
      category: StudioModelCategory.speech,
      specialty: StudioModelSpecialty.liteRtAsr,
      liteRtAsrPreset: LiteRtLmAsrModelPreset.moonshineTiny,
      availability: StudioModelAvailability.nativeOnly,
      filename: 'moonshine_tiny_5s_i8.tflite',
      sourceUri:
          'https://huggingface.co/litert-community/moonshine-tiny/resolve/beb49ee5028b4fb21eb989bcbd2db30a433373db/moonshine_tiny_5s_i8.tflite?download=true',
      sizeBytes: 53922426,
      sha256:
          '97abdeea122d579229091659c24c59d988c6419d453a200f6471241a53b9a9b9',
      publisher: 'LiteRT Community',
      quantizationLabel: 'INT8',
      minRamGb: 2,
      supportsSpeechToText: true,
      companions: <StudioModelCompanionAsset>[
        StudioModelCompanionAsset(
          role: 'tokenizer',
          filename: 'moonshine_tokenizer.json',
          sourceUri:
              'https://huggingface.co/moonshine-ai/moonshine-tiny/resolve/390624ed33d594443aa4aa221f5b9f283b545b5a/tokenizer.json?download=true',
          sizeBytes: 1985530,
          sha256:
              '6579793438bc4fbafffacf699169ff53e3769c5a0a0f5e71cdee8853e8130deb',
        ),
      ],
    ),

    // Image Studio models
    StudioModelDescriptor(
      id: 'sdxs-512-q8_0',
      name: 'SDXS-512 Distilled',
      description:
          'Single-step 512x512 diffusion checkpoint compact enough for phones '
          'and laptops.',
      category: StudioModelCategory.image,
      specialty: StudioModelSpecialty.stableDiffusion,
      availability: StudioModelAvailability.nativeOnly,
      filename: 'sdxs-512-tinySDdistilled_Q8_0.gguf',
      sourceUri:
          'https://huggingface.co/concedo/sdxs-512-tinySDdistilled-GGUF/resolve/3144d898d61492f8382ffcabec055733fc5b2a0e/sdxs-512-tinySDdistilled_Q8_0.gguf?download=true',
      sizeBytes: 682847200,
      sha256:
          '409ab23582ee074c6b9d5395784fc0741b0599fb9d138686c69087c71678eb6a',
      publisher: 'concedo',
      quantizationLabel: 'Q8_0',
      minRamGb: 4,
      isRecommended: true,
      preset: StudioModelTuningPreset(imageSteps: 1, imageGuidanceScale: 1.0),
    ),
    StudioModelDescriptor(
      id: 'sd-turbo-q8_0-taesd',
      name: 'SD-Turbo + TAESD',
      description:
          'Higher-detail SD 2.1 Turbo paired with the fast TAESD decoder '
          '(1 to 4 steps).',
      category: StudioModelCategory.image,
      specialty: StudioModelSpecialty.stableDiffusion,
      availability: StudioModelAvailability.nativeOnly,
      filename: 'sd_turbo-f16-q8_0.gguf',
      sourceUri:
          'https://huggingface.co/Green-Sky/SD-Turbo-GGUF/resolve/19a31586d02d64a73b4419bc193b3ecfaf38e1f0/sd_turbo-f16-q8_0.gguf?download=true',
      sizeBytes: 2033538668,
      sha256:
          'd50be7655f0a554cf8041c145d88b210bd5f3c545423119dee62ae08cae51580',
      publisher: 'Green-Sky',
      quantizationLabel: 'Q8_0',
      minRamGb: 8,
      memoryNote: 'Requires ~3.1 GB free memory during diffusion decode.',
      companions: <StudioModelCompanionAsset>[
        StudioModelCompanionAsset(
          role: 'taesd',
          filename: 'taesd.safetensors',
          sourceUri:
              'https://huggingface.co/madebyollin/taesd/resolve/614f76814bbe30edbe2e627ace1c2234c81a2c0e/diffusion_pytorch_model.safetensors?download=true',
          sizeBytes: 9793292,
          sha256:
              'db169d69145ec4ff064e49d99c95fa05d3eb04ee453de35824a6d0f325513549',
        ),
      ],
      preset: StudioModelTuningPreset(imageSteps: 2, imageGuidanceScale: 1.0),
    ),

    // Playground / Retrieval / Decision models
    StudioModelDescriptor(
      id: 'nomic-embed-text-v1.5-q8-0',
      name: 'Nomic Embed Text v1.5',
      description:
          'Compact semantic embedding encoder for vector search and cosine '
          'similarity experiments.',
      category: StudioModelCategory.playground,
      specialty: StudioModelSpecialty.embedding,
      filename: 'nomic-embed-text-v1.5.Q8_0.gguf',
      sourceUri:
          'https://huggingface.co/nomic-ai/nomic-embed-text-v1.5-GGUF/resolve/main/nomic-embed-text-v1.5.Q8_0.gguf?download=true',
      sizeBytes: 146159104,
      publisher: 'Nomic AI',
      quantizationLabel: 'Q8_0',
      minRamGb: 2,
      isRecommended: true,
    ),
    StudioModelDescriptor(
      id: 'bge-reranker-v2-m3-q8-0',
      name: 'BGE Reranker v2 M3',
      description:
          'Multilingual cross-encoder reranker scoring candidate documents '
          'against a query.',
      category: StudioModelCategory.playground,
      specialty: StudioModelSpecialty.reranker,
      availability: StudioModelAvailability.nativeOnly,
      filename: 'bge-reranker-v2-m3-Q8_0.gguf',
      sourceUri:
          'https://huggingface.co/gpustack/bge-reranker-v2-m3-GGUF/resolve/main/bge-reranker-v2-m3-Q8_0.gguf?download=true',
      sizeBytes: 635742208,
      publisher: 'BAAI / GPUStack',
      quantizationLabel: 'Q8_0',
      minRamGb: 3,
    ),
    StudioModelDescriptor(
      id: 'laya-decision-q8-0',
      name: 'Laya System-1 Decision Model',
      description:
          'Single-pass encoder + safetensors head answering typed choice, '
          'score, and yes/no (noul) questions.',
      category: StudioModelCategory.playground,
      specialty: StudioModelSpecialty.decision,
      filename: 'laya-Q8_0.gguf',
      sourceUri: 'hf://fr0stbit3/laya-gguf/laya-Q8_0.gguf',
      sizeBytes: 165000000,
      publisher: 'ConvAI / fr0stbit3',
      quantizationLabel: 'Q8_0',
      minRamGb: 2,
      companions: <StudioModelCompanionAsset>[
        StudioModelCompanionAsset(
          role: 'decisionHead',
          filename: 'laya-head.safetensors',
          sourceUri: 'hf://fr0stbit3/laya-gguf/laya-head.safetensors',
        ),
      ],
    ),
  ];

  /// Looks up a curated model by [id], or returns `null`.
  static StudioModelDescriptor? byId(String? id) {
    if (id == null || id.isEmpty) {
      return null;
    }
    for (final model in models) {
      if (model.id == id) {
        return model;
      }
    }
    return null;
  }

  /// Filters curated models by [category] and target host capabilities.
  static List<StudioModelDescriptor> forCategory(
    StudioModelCategory? category, {
    required bool isWeb,
    required bool isMobile,
  }) {
    return models
        .where((model) => category == null || model.category == category)
        .where((model) => model.isSupportedOn(isWeb: isWeb, isMobile: isMobile))
        .toList(growable: false);
  }
}
