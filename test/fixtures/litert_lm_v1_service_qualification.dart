// Real-model child; only the owning outer scenario runs and bounds it.
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_native_settlement.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_finish_reason.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_service.dart';
import 'package:llamadart/src/backends/litert_lm/litert_lm_v1_runtime.dart';

const prefix = 'LITERT_V1_SERVICE_EVENT ';

void event(String stage, [Map<String, Object?> data = const {}]) {
  stdout.writeln('$prefix${jsonEncode({'stage': stage, ...data})}');
}

Future<String> digest(String path) async =>
    (await sha256.bind(File(path).openRead()).first).toString();

Future<void> main(List<String> args) async {
  if (args.length != 6) {
    throw ArgumentError(
      'Expected library, model, both SHA256 digests, scratch and source revision.',
    );
  }
  final libraryPath = args[0],
      modelPath = args[1],
      librarySha = args[2],
      modelSha = args[3];
  final scratch = Directory(args[4]);
  LiteRtLmService? service;
  final clients = <LiteRtLmV1RuntimeClient>[];
  var success = false;
  try {
    if (await digest(libraryPath) != librarySha ||
        await digest(modelPath) != modelSha) {
      throw StateError(
        'Expected runtime/model SHA256 did not match the supplied files.',
      );
    }
    if (Platform.isMacOS) {
      final version = await Process.run('/usr/bin/sw_vers', [
        '-productVersion',
      ]);
      final major = int.tryParse('${version.stdout}'.trim().split('.').first);
      if (version.exitCode != 0 || major == null || major < 14) {
        throw LlamaUnsupportedException(
          'The prepared LiteRT v1 macOS artifact requires macOS 14.0 or later.',
        );
      }
    }
    event('identity', {
      'source_revision': args[5],
      'library_sha256': librarySha,
      'model_sha256': modelSha,
      'abi': Abi.current().toString(),
      'os': Platform.operatingSystemVersion,
      'requested_backend': 'cpu',
      'requested_threads': 2,
      'requested_context_size': 1024,
      'accelerator_execution_verified': false,
    });
    final library = DynamicLibrary.open(libraryPath);
    final probe = LiteRtLmV1RuntimeClient(library);
    if (!probe.supportsFinishReasons || !probe.supportsMessageRendering) {
      throw StateError(
        'Actual loaded v1 core lacks the required finish/render contract.',
      );
    }
    probe.dispose();
    service = LiteRtLmService(
      runtimeClientFactory: () {
        final client = LiteRtLmV1RuntimeClient(library);
        clients.add(client);
        return client;
      },
      linkParentDirectory: Directory('${scratch.path}/links')
        ..createSync(recursive: true),
      useTempCacheDir: false,
    );
    final params = ModelParams(
      liteRtLmBackend: LiteRtLmBackendPreference.cpu,
      numberOfThreads: 2,
      contextSize: 1024,
      liteRtLmCacheDir: '${scratch.path}/cache',
    );
    final active = service;
    Future<void> arithmetic(int context, String stage) async {
      final bytes = <int>[];
      await for (final chunk in active.generateChat(
        context,
        const [
          LlamaChatMessage.fromText(
            role: LlamaChatRole.user,
            text: 'What is 2 + 2? Reply with only the digit 4.',
          ),
        ],
        const GenerationParams(maxTokens: 32, temp: 0, seed: 7),
        enableThinking: false,
      )) {
        bytes.addAll(chunk);
      }
      final answer = utf8.decode(bytes).trim();
      if (answer != '4') {
        throw StateError(
          'Arithmetic oracle expected exactly 4; received ${answer.length} characters.',
        );
      }
      if (active.nativeSettlement != LiteRtLmNativeSettlement.settled) {
        throw StateError('Completed chat retained native work.');
      }
      final metrics = active.getPerformanceContext(context);
      if (metrics == null ||
          metrics.promptEvalTokens <= 0 ||
          metrics.evalTokens <= 0) {
        throw StateError(
          'Completed chat did not provide positive native token metrics.',
        );
      }
      for (final value in [
        metrics.loadMs,
        metrics.promptEvalMs,
        metrics.evalMs,
      ]) {
        if (!value.isFinite || value < 0) {
          throw StateError('Native metrics were invalid.');
        }
      }
      event(stage, {
        'answer': answer,
        'input_tokens': metrics.promptEvalTokens,
        'output_tokens': metrics.evalTokens,
        'load_ms': metrics.loadMs,
        'prefill_ms': metrics.promptEvalMs,
        'decode_ms': metrics.evalMs,
      });
    }

    final firstModel = await active.loadModel(modelPath, params);
    final firstContext = active.createContext(firstModel, params);
    await arithmetic(firstContext, 'chat');
    var cancellationSent = false;
    var received = 0;
    LiteRtLmV1RuntimeClient? cancelledClient;
    await for (final chunk in active.generateChat(
      firstContext,
      const [
        LlamaChatMessage.fromText(
          role: LlamaChatRole.user,
          text:
              'Write the numbers 1 through 1000, one per line. Start immediately.',
        ),
      ],
      const GenerationParams(maxTokens: 512, temp: 0, seed: 7),
      enableThinking: false,
    )) {
      received += chunk.length;
      if (!cancellationSent && chunk.isNotEmpty) {
        final pending = clients
            .where(
              (client) =>
                  client.nativeSettlement == LiteRtLmNativeSettlement.pending,
            )
            .toList();
        if (pending.length != 1) {
          throw StateError(
            'Cancellation did not observe exactly one active native client.',
          );
        }
        cancelledClient = pending.single;
        active.cancelGeneration();
        cancellationSent = true;
      }
    }
    if (!cancellationSent ||
        received == 0 ||
        active.nativeSettlement != LiteRtLmNativeSettlement.settled ||
        cancelledClient?.lastFinishReason != LiteRtLmFinishReason.cancelled) {
      throw StateError(
        'Real cancellation did not settle with the actual cancelled native cause.',
      );
    }
    event('cancel', {
      'received_bytes': received,
      'native_finish': 'cancelled',
      'native_settlement': 'settled',
    });
    final secondModel = await active.loadModel(modelPath, params);
    final secondContext = active.createContext(secondModel, params);
    if (secondModel == firstModel || secondContext == firstContext) {
      throw StateError('Reload reused the old service handles.');
    }
    await arithmetic(secondContext, 'reload_chat');
    success = true;
  } on Object catch (error) {
    event('failure', {
      'type': error.runtimeType.toString(),
      'detail': error.toString().substring(
        0,
        error.toString().length.clamp(0, 512),
      ),
    });
  } finally {
    if (service?.nativeSettlement != null &&
        service!.nativeSettlement != LiteRtLmNativeSettlement.settled) {
      event('cleanup_retained', {
        'native_settlement': service.nativeSettlement.name,
      });
      // The outer owner kills this process at its deadline. Do not run C exit
      // teardown or delete leases while native work may still use them.
      await Completer<void>().future;
    }
    service?.dispose();
    for (final client in clients) {
      client.dispose();
    }
    event('cleanup', {'native_settlement': 'settled'});
  }
  event('run_end', {'success': success});
  exitCode = success ? 0 : 1;
}
