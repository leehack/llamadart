import 'dart:typed_data';

import 'package:test/test.dart';

import 'package:llamadart/src/core/exceptions.dart';
import 'package:llamadart/src/core/image/image_generation_model.dart';
import 'package:llamadart/src/core/image/image_model_classifier.dart';

import '../../../support/image_model_headers.dart';

ImageModelFileReader _reader(Uint8List bytes, {List<int>? fetched}) =>
    (offset, length) async {
      final start = offset.clamp(0, bytes.length);
      final end = (offset + length).clamp(0, bytes.length);
      fetched?.add(end - start);
      return Uint8List.sublistView(bytes, start, end);
    };

Future<ImageModelFileClassification> _classify(Uint8List bytes) async =>
    classifyImageModelFile(await readImageModelFileHeader(_reader(bytes)));

Future<ImageModelAssignment> _assign(List<Object> files) =>
    assignImageModelRoles([
      for (final file in files)
        switch (file) {
          Uint8List bytes => ImageModelFileInput(read: _reader(bytes)),
          (Uint8List bytes, ImageModelRole role) => ImageModelFileInput(
            read: _reader(bytes),
            role: role,
          ),
          _ => throw ArgumentError.value(file),
        },
    ]);

Matcher _modelError(Object messageMatcher) => throwsA(
  isA<LlamaModelException>().having(
    (error) => error.message,
    'message',
    messageMatcher,
  ),
);

void main() {
  group('classifyImageModelFile', () {
    test('assigns each component its role from GGUF or safetensors '
        'headers', () async {
      final cases = <String, (Uint8List, ImageModelRole, int?)>{
        'SDXS checkpoint': (
          ImageModelHeaders.sdxsCheckpoint,
          ImageModelRole.checkpoint,
          4,
        ),
        'SD-Turbo checkpoint': (
          ImageModelHeaders.sdTurboCheckpoint,
          ImageModelRole.checkpoint,
          4,
        ),
        'SDXL checkpoint': (
          ImageModelHeaders.sdxlCheckpoint,
          ImageModelRole.checkpoint,
          4,
        ),
        'SD 3.5 diffusion': (
          ImageModelHeaders.sd35Diffusion,
          ImageModelRole.diffusionModel,
          16,
        ),
        'FLUX diffusion': (
          ImageModelHeaders.fluxDiffusion,
          ImageModelRole.diffusionModel,
          16,
        ),
        'Z-Image diffusion': (
          ImageModelHeaders.zImageDiffusion,
          ImageModelRole.diffusionModel,
          16,
        ),
        'FLUX ae': (ImageModelHeaders.fluxVae, ImageModelRole.vae, 16),
        'SDXL VAE': (ImageModelHeaders.sdxlVae, ImageModelRole.vae, 4),
        'TAESD': (ImageModelHeaders.taesd, ImageModelRole.taesd, 4),
        'TAEF1': (ImageModelHeaders.taef1, ImageModelRole.taesd, 16),
        'CLIP-L': (ImageModelHeaders.clipL, ImageModelRole.clipL, null),
        'CLIP-G': (ImageModelHeaders.clipG, ImageModelRole.clipG, null),
        'T5-XXL': (ImageModelHeaders.t5xxl, ImageModelRole.t5xxl, null),
        'Qwen3': (ImageModelHeaders.qwen3Llm, ImageModelRole.llm, null),
      };
      for (final MapEntry(key: name, value: (bytes, role, channels))
          in cases.entries) {
        final classification = await _classify(bytes);
        expect(classification.kind, ImageModelFileKind.component, reason: name);
        expect(classification.role, role, reason: name);
        expect(classification.latentChannels, channels, reason: name);
      }
    });

    test('names what a non-component file is', () async {
      final cases = <String, (Uint8List, ImageModelFileKind)>{
        'LoRA': (ImageModelHeaders.lora, ImageModelFileKind.lora),
        'ControlNet': (
          ImageModelHeaders.controlNet,
          ImageModelFileKind.controlNet,
        ),
        'upscaler': (ImageModelHeaders.upscaler, ImageModelFileKind.upscaler),
        'mmproj': (ImageModelHeaders.mmproj, ImageModelFileKind.visionEncoder),
        'decoder-only TAESD': (
          ImageModelHeaders.decoderOnlyTaesd,
          ImageModelFileKind.decoderOnlyTaesd,
        ),
        'unknown': (ImageModelHeaders.unknown, ImageModelFileKind.unknown),
      };
      for (final MapEntry(key: name, value: (bytes, kind)) in cases.entries) {
        final classification = await _classify(bytes);
        expect(classification.kind, kind, reason: name);
        expect(classification.role, isNull, reason: name);
      }
    });

    test('a checkpoint reports an embedded tiny autoencoder', () async {
      expect(
        (await _classify(
          ImageModelHeaders.sdxsCheckpoint,
        )).embedsTinyAutoencoder,
        isTrue,
      );
      expect(
        (await _classify(
          ImageModelHeaders.sdTurboCheckpoint,
        )).embedsTinyAutoencoder,
        isFalse,
      );
    });
  });

  group('readImageModelFileHeader', () {
    test('stops a language-model GGUF at general.architecture', () async {
      final fetched = <int>[];

      final header = await readImageModelFileHeader(
        _reader(ImageModelHeaders.qwen3Llm, fetched: fetched),
      );

      expect(header.stoppedAtArchitecture, isTrue);
      expect(header.architecture, 'qwen3');
      expect(header.tensors, isEmpty);
      expect(
        fetched.fold<int>(0, (sum, bytes) => sum + bytes),
        lessThan(ImageModelHeaders.qwen3Llm.length),
      );
    });

    test('reads every tensor of other GGUFs and of safetensors', () async {
      final gguf = await readImageModelFileHeader(
        _reader(ImageModelHeaders.fluxDiffusion),
      );
      expect(gguf.isGguf, isTrue);
      expect(gguf.tensors.map((t) => t.name), [
        'double_blocks.0.img_attn.qkv.weight',
        'img_in.weight',
        'final_layer.linear.bias',
      ]);
      expect(gguf.tensors[1].shape, [64, 3072]);

      final safetensors = await readImageModelFileHeader(
        _reader(
          safetensorsHeader(
            [
              ('decoder.conv_in.weight', [512, 16, 3, 3]),
            ],
            metadata: {'format': 'pt'},
            dataBytes: 32,
          ),
        ),
      );
      expect(safetensors.isGguf, isFalse);
      expect(safetensors.metadata, {'format': 'pt'});
      expect(safetensors.tensors.single.shape, [512, 16, 3, 3]);
    });

    test('rejects files that are neither GGUF nor safetensors, and truncated '
        'headers', () async {
      for (final bytes in [
        ImageModelHeaders.pickle,
        Uint8List(3),
        Uint8List.sublistView(ImageModelHeaders.fluxDiffusion, 0, 40),
        Uint8List.sublistView(ImageModelHeaders.fluxVae, 0, 20),
      ]) {
        await expectLater(
          readImageModelFileHeader(_reader(bytes)),
          throwsFormatException,
        );
      }
    });
  });

  group('assignImageModelRoles', () {
    test('assigns roles whatever the order of the files', () async {
      final assignment = await _assign([
        ImageModelHeaders.t5xxl,
        ImageModelHeaders.fluxVae,
        ImageModelHeaders.fluxDiffusion,
        ImageModelHeaders.clipL,
      ]);

      expect(assignment.roles, {
        ImageModelRole.t5xxl: 0,
        ImageModelRole.vae: 1,
        ImageModelRole.diffusionModel: 2,
        ImageModelRole.clipL: 3,
      });
      expect(assignment.decodesWithTinyAutoencoder, isFalse);
    });

    test('reports a tiny autoencoder from a taesd file or an embedded '
        'one', () async {
      expect(
        (await _assign([
          ImageModelHeaders.sdxsCheckpoint,
        ])).decodesWithTinyAutoencoder,
        isTrue,
      );
      expect(
        (await _assign([
          ImageModelHeaders.sdTurboCheckpoint,
        ])).decodesWithTinyAutoencoder,
        isFalse,
      );
      expect(
        (await _assign([
          ImageModelHeaders.taesd,
          ImageModelHeaders.sdTurboCheckpoint,
        ])).decodesWithTinyAutoencoder,
        isTrue,
      );
    });

    test('refuses non-component files, naming them by position', () async {
      final cases = <Uint8List, String>{
        ImageModelHeaders.lora: 'Component 1 is a LoRA adapter',
        ImageModelHeaders.controlNet: 'Component 1 is a ControlNet',
        ImageModelHeaders.upscaler: 'Component 1 is an upscaler',
        ImageModelHeaders.mmproj: 'Component 1 is a vision encoder',
        ImageModelHeaders.decoderOnlyTaesd:
            'Component 1 is a decoder-only tiny autoencoder',
        ImageModelHeaders.unknown:
            'Component 1 is not a known image-model file',
        ImageModelHeaders.pickle: 'Cannot detect the role of component 1',
      };
      for (final MapEntry(key: bytes, value: message) in cases.entries) {
        await expectLater(
          _assign([ImageModelHeaders.sdTurboCheckpoint, bytes]),
          _modelError(startsWith(message)),
          reason: message,
        );
      }
      await expectLater(
        _assign([ImageModelHeaders.unknown]),
        _modelError(
          allOf(
            startsWith('The main file is not a known image-model file'),
            contains('ImageModelComponent(source, role: ...)'),
          ),
        ),
      );
    });

    test('a read failure names the file by position only', () async {
      await expectLater(
        assignImageModelRoles([
          ImageModelFileInput(
            read: _reader(ImageModelHeaders.sdTurboCheckpoint),
          ),
          ImageModelFileInput(
            read: (offset, length) async =>
                throw StateError('cannot open /private/models/vae.gguf'),
          ),
        ]),
        _modelError('Cannot read the header of component 1.'),
      );
    });

    test('takes an explicit role for a file it cannot classify', () async {
      final assignment = await _assign([
        (ImageModelHeaders.pickle, ImageModelRole.checkpoint),
        ImageModelHeaders.taesd,
      ]);

      expect(assignment.roles, {
        ImageModelRole.checkpoint: 0,
        ImageModelRole.taesd: 1,
      });
    });

    test('an explicit role resolves files with the same layout', () async {
      await expectLater(
        _assign([
          ImageModelHeaders.sdTurboCheckpoint,
          ImageModelHeaders.taesd,
          ImageModelHeaders.taesd,
        ]),
        _modelError(
          'Component 1 and component 2 are both taesd files; pass one file '
          'per role.',
        ),
      );

      final assignment = await _assign([
        ImageModelHeaders.sdTurboCheckpoint,
        ImageModelHeaders.sdxlVae,
        (ImageModelHeaders.fluxVae, ImageModelRole.taesd),
      ]);
      expect(assignment.roles[ImageModelRole.taesd], 2);
    });

    test('needs exactly one source of diffusion weights', () async {
      await expectLater(
        _assign([ImageModelHeaders.clipL, ImageModelHeaders.fluxVae]),
        _modelError(contains('None of the image model files holds diffusion')),
      );
      await expectLater(
        _assign([
          ImageModelHeaders.sdTurboCheckpoint,
          ImageModelHeaders.fluxDiffusion,
        ]),
        _modelError(
          allOf(
            contains('both a checkpoint (the main file)'),
            contains('separate diffusion weights (component 1)'),
          ),
        ),
      );
    });

    test('refuses a decoder for other latent channels', () async {
      await expectLater(
        _assign([
          ImageModelHeaders.fluxDiffusion,
          ImageModelHeaders.taesd,
          ImageModelHeaders.clipL,
          ImageModelHeaders.t5xxl,
        ]),
        _modelError(
          'The taesd file (component 1) decodes 4-channel latents, but the '
          'diffusion weights (the main file) produce 16-channel latents. Use '
          'the decoder made for this model family.',
        ),
      );
      await expectLater(
        _assign([ImageModelHeaders.sdxlVae, ImageModelHeaders.sd35Diffusion]),
        _modelError(startsWith('The vae file (the main file) decodes 4')),
      );
      await expectLater(
        _assign([ImageModelHeaders.sdTurboCheckpoint, ImageModelHeaders.taef1]),
        _modelError(contains('16-channel latents')),
      );

      final matched = await _assign([
        ImageModelHeaders.zImageDiffusion,
        ImageModelHeaders.fluxVae,
        ImageModelHeaders.qwen3Llm,
      ]);
      expect(matched.roles.keys, [
        ImageModelRole.diffusionModel,
        ImageModelRole.vae,
        ImageModelRole.llm,
      ]);
    });

    test('checks the channels of a file whose explicit role its header '
        'agrees with', () async {
      await expectLater(
        _assign([
          ImageModelHeaders.fluxDiffusion,
          (ImageModelHeaders.taesd, ImageModelRole.taesd),
        ]),
        _modelError(contains('decodes 4-channel latents')),
      );
    });
  });
}
