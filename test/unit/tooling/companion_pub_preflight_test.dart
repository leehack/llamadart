@TestOn('vm')
library;

import 'dart:io';

import 'package:test/test.dart';

import '../../../tool/release/companion_pub_preflight.dart';

const _preflightCommand = 'dart run tool/release/companion_pub_preflight.dart';
const _validateStep = '- name: Validate release state';
const _publishStep = '- name: Publish companion packages and core tag';

/// Why [workflow] could push a release tag before the companion preflight.
List<String> _preflightContractProblems(String workflow) {
  final problems = <String>[];
  final commands = RegExp(
    '^\\s+${RegExp.escape(_preflightCommand)}\\s*\$',
    multiLine: true,
  ).allMatches(workflow).toList();
  if (commands.length != 1) {
    problems.add(
      'expected exactly one bare companion preflight, found '
      '${commands.length}',
    );
    return problems;
  }
  final preflight = commands.single.start;
  final validate = workflow.indexOf(_validateStep);
  final publish = workflow.indexOf(_publishStep);
  final firstTagPush = workflow.indexOf(
    RegExp(r'^\s+push_tag "', multiLine: true),
  );
  if (validate == -1 || publish == -1 || firstTagPush == -1) {
    problems.add('release validation, publication or tag push is missing');
  } else if (!(validate < preflight && preflight < publish)) {
    problems.add(
      'the companion preflight must run in release validation, before any '
      'tag is pushed',
    );
  }
  return problems;
}

void main() {
  final companions = discoverAppleCompanionPackages(Directory.current);

  test('discovers every Flutter Apple companion and nothing else', () {
    expect(companions, [
      (
        name: 'llamadart_litert_lm_flutter',
        path: 'packages/llamadart_litert_lm_flutter',
      ),
      (
        name: 'llamadart_llama_cpp_flutter',
        path: 'packages/llamadart_llama_cpp_flutter',
      ),
      (
        name: 'llamadart_stable_diffusion_flutter',
        path: 'packages/llamadart_stable_diffusion_flutter',
      ),
    ]);
  });

  test('packages pub.dev knows pass', () async {
    final asked = <Uri>[];
    final problems = await companionPubPreflightProblems(companions, (
      uri,
    ) async {
      asked.add(uri);
      return HttpStatus.ok;
    });

    expect(problems, isEmpty);
    expect(asked, [
      for (final companion in companions)
        Uri.parse('https://pub.dev/api/packages/${companion.name}'),
    ]);
  });

  test('a package missing from pub.dev gets the first-publish steps', () async {
    final problems = await companionPubPreflightProblems(
      companions,
      (uri) async => uri.path.endsWith('/llamadart_stable_diffusion_flutter')
          ? HttpStatus.notFound
          : HttpStatus.ok,
    );

    expect(problems, hasLength(1));
    expect(
      problems.single,
      allOf(
        startsWith('llamadart_stable_diffusion_flutter does not exist on pub'),
        contains('no release tags were pushed'),
        contains('packages/llamadart_stable_diffusion_flutter/'),
        contains('flutter pub publish)'),
        contains('transfer the package to the\n     leehack.com publisher'),
        contains(
          'repository leehack/llamadart with tag pattern '
          'llamadart_stable_diffusion_flutter-v{{version}}',
        ),
      ),
    );
  });

  test('an unconfirmed package fails closed', () async {
    final problems = await companionPubPreflightProblems(
      companions.take(2).toList(),
      (uri) async => uri.path.endsWith('/llamadart_litert_lm_flutter')
          ? throw const SocketException('offline')
          : HttpStatus.serviceUnavailable,
    );

    expect(problems, [contains('offline'), contains('HTTP 503')]);
  });

  test('the release workflow runs the preflight before any tag push', () {
    final workflow = File(
      '.github/workflows/release_on_prep_merge.yml',
    ).readAsStringSync();

    expect(_preflightContractProblems(workflow), isEmpty);
  });

  test('the preflight contract rejects deletion, bypass and late runs', () {
    final workflow = File(
      '.github/workflows/release_on_prep_merge.yml',
    ).readAsStringSync();

    for (final mutated in [
      workflow.replaceFirst(_preflightCommand, ''),
      workflow.replaceFirst(_preflightCommand, '$_preflightCommand || true'),
      workflow
          .replaceFirst(_preflightCommand, '')
          .replaceFirst(
            'push_tag "\$CORE_TAG"',
            '$_preflightCommand\n          push_tag "\$CORE_TAG"',
          ),
    ]) {
      expect(_preflightContractProblems(mutated), isNotEmpty);
    }
  });
}
