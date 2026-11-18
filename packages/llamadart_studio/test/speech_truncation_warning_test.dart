import 'dart:typed_data';

// Keep Material types compatible with flutter_markdown (see README).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart_studio/llamadart_studio.dart';
import 'package:llamadart_studio_core/llamadart_studio_core.dart';

import 'studio_widget_test_helpers.dart';

const _warning =
    'Audio stopped at the generation limit. This clip may be incomplete. '
    'Synthesize shorter sections.';

void main() {
  for (final truncated in [true, false]) {
    testWidgets('speech discloses incomplete clips (truncated=$truncated)', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.platformDispatcher.textScaleFactorTestValue = 1.8;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final deps = await buildTestDeps(speechPort: _TruncatedSpeech(truncated));
      addTearDown(deps.dispose);
      await deps.speechController.loadTtsModel(
        CuratedModelCatalog.byId('qwen3-tts-1.7b-base-q4-k-m')!,
      );
      final entry = await deps.speechController.synthesizeText(
        text: 'An excerpt',
      );
      expect(entry, isNotNull);
      await tester.pumpWidget(LlamadartStudioApp(dependencies: deps));
      await tester.pumpAndSettle();
      await deps.shellController.selectWorkspace(StudioWorkspace.speech);
      await tester.pumpAndSettle();
      expect(find.text('Speech Studio'), findsOneWidget);
      final prompt = find.text('An excerpt');
      await tester.scrollUntilVisible(
        prompt,
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text(_warning), truncated ? findsOneWidget : findsNothing);
      expect(find.byTooltip('Save WAV'), findsOneWidget);
      expect(find.byTooltip('Remove clip'), findsOneWidget);
      expect(
        deps
            .speechController
            .state
            .synthesizedHistory
            .single
            .clip
            .wavBytes
            .length,
        44,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

class _TruncatedSpeech extends FakeSpeechPort {
  _TruncatedSpeech(this.truncated);
  final bool truncated;

  @override
  Future<StudioSynthesizedClip> synthesize({
    required String text,
    required bool isWeb,
    String? language,
    String? voice,
    Uint8List? speakerReferenceBytes,
    String? speakerReferencePath,
    double temperature = 0.8,
    void Function(int framesGenerated, TextToSpeechProgressPhase phase)?
    onProgress,
  }) async => StudioSynthesizedClip(
    wavBytes: Uint8List(44),
    duration: const Duration(seconds: 42),
    sampleRateHz: 24000,
    framesGenerated: 512,
    truncated: truncated,
  );
}
