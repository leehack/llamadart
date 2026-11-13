import 'markdown_readers.dart';

const String _localOnly = 'Tagged local-only, which this job excludes.';
const String _tempTree = 'Runs against Markdown it writes to a temp directory.';
const String _pinTables =
    'Uses the pin tables of sync_native_release_pins.py, not its doc updates.';
const String _validationTooling =
    'Its validation tooling names Markdown; with every tracked Markdown file '
    'removed the suite still passes.';
const String _llamaCppSource =
    'Its source helper clones upstream llama.cpp into a work directory; it '
    'reads no repository Markdown.';

/// Files that several exempt suites reach, with the tokens discovery finds.
const Map<String, String> _ciToolFiles = {
  'packages/genkit_llamadart/.github/check_docs.py':
      '.md | CHANGELOG | CONTRIBUTING | README | doc/ | glob | skills/',
  'packages/llamadart_validation/bin/run.dart': 'listSync',
  'packages/llamadart_validation/lib/src/manifest.dart': '.md',
  'scripts/build_chat_app_web.sh': 'git diff',
  'test/ci/test_deploy_guard.py':
      '.md | CHANGELOG | README | git checkout | git diff | website/',
  'test/ci/test_genkit_package_score.py': 'git checkout | git clone | git show',
  'test/ci/test_genkit_release.py': '.md | CHANGELOG | README | doc/',
  'test/ci/test_nonpublishing_auth_probe.py': 'listdir',
  'test/ci/test_preview_guard.py': '.md | README',
  'test/ci/test_select_jobs.py':
      '.md | AGENTS | CHANGELOG | CONTRIBUTING | README | SKILL | doc/ | glob | skills/ | website/',
  'test/ci/test_stage_genkit_package.py':
      '.md | CHANGELOG | README | SKILL | doc/ | glob | skills/',
  'test/ci/test_supervise_chrome_test.py': 'glob | listdir',
  'test/ci/test_web_deployment.py': '.md | README | doc/ | glob',
  'test/fixtures/native_default_consumer_qualification/qualify.py': 'ls-files',
  'tool/ci/check_genkit_package_score.py': 'git clone | git ls-tree | git show',
  'tool/ci/deploy_guard.py': '.md | git diff',
  'tool/ci/preview_guard.py': '.md | README | git diff | git show',
  'tool/ci/select_jobs.py':
      '.md | AGENTS | CHANGELOG | CONTRIBUTING | README | doc/ | git diff | website/',
  'tool/ci/web_deployment.py': 'git diff',
  'tool/native/sync_native_headers_and_bindings.sh': 'find',
  'tool/native/sync_native_release_pins.py':
      '.md | CHANGELOG | README | find | website/',
  'tool/native/test_native_header_archive.py': 'copytree | listdir',
  'tool/native/test_sync_native_headers_and_bindings.py': 'glob',
  'tool/native/test_sync_native_release_pins.py':
      '.md | CHANGELOG | README | copytree | find | glob | listdir | website/',
  'tool/native/test_sync_stable_diffusion_bindings.py': 'glob | listdir',
  'tool/prepare_workspace.dart': 'listSync',
  'tool/release/pub_content_limits.dart': '.md | CHANGELOG | README | doc/',
  'tool/release/stage_genkit_package.py': '.md | CHANGELOG | README | glob',
  'tool/testing/check_platform_boundaries.dart': 'listSync',
  'tool/testing/check_released_changelog_sections.dart':
      '.md | CHANGELOG | doc/ | find | git cat-file | git show | website/',
  'tool/testing/check_webgpu_bridge_tag.dart':
      '.md | CHANGELOG | README | doc/ | ls-files | website/',
  'tool/testing/prepare_llama_cpp_source.sh': 'git checkout | git clone',
  'tool/testing/run_local_e2e.dart': '.md',
  'tool/testing/test_matrix.dart':
      '.md | CHANGELOG | CONTRIBUTING | README | doc/',
  'tool/testing/validation/bundle.dart': 'git archive',
  'tool/testing/validation/coverage_catalog.dart': '.md',
  'tool/testing/validation/internal_diagnostic.dart': 'ls-files',
  'tool/testing/validation/remote.dart': 'listSync',
  'tool/testing/verify_release_docs_versions.dart':
      '.md | CHANGELOG | README | git show | website/',
  'website/lib/src/site/sidebar.dart': 'doc/',
  'website/lib/src/site/site_model.dart': '.md',
};

const Map<String, String> _validationFiles = {
  'packages/llamadart_validation/bin/run.dart': 'listSync',
  'packages/llamadart_validation/lib/src/manifest.dart': '.md',
  'scripts/build_chat_app_web.sh': 'git diff',
  'tool/testing/validation/bundle.dart': 'git archive',
  'tool/testing/validation/internal_diagnostic.dart': 'ls-files',
};

const Map<String, String> _releaseToolFiles = {
  'tool/release/pub_content_limits.dart': '.md | CHANGELOG | README | doc/',
  'tool/testing/check_released_changelog_sections.dart':
      '.md | CHANGELOG | doc/ | find | git cat-file | git show | website/',
  'tool/testing/verify_release_docs_versions.dart':
      '.md | CHANGELOG | README | git show | website/',
};

const Map<String, String> _pinTableFiles = {
  'tool/native/sync_native_release_pins.py':
      '.md | CHANGELOG | README | find | website/',
};

/// Non-suite files that many suites reach and whose tokens are not reads. A
/// listed file stops counting as evidence in every suite, so claim only what
/// holds for every caller. Its tokens stay pinned here.
const Map<String, Exemption> helperExemptions = {
  'lib/src/backends/llama_cpp/llama_cpp_service.dart': (
    reason:
        'Native library lookup lists cache and .dart_tool directories found '
        'from the working directory; it reads no Markdown.',
    evidence: {'lib/src/backends/llama_cpp/llama_cpp_service.dart': 'listSync'},
    gate: null,
  ),
  'lib/src/backends/llama_cpp/library_loading.dart': (
    reason:
        'Native library lookup lists the cache and working directory for '
        'library files; it reads no Markdown.',
    evidence: {'lib/src/backends/llama_cpp/library_loading.dart': 'listSync'},
    gate: null,
  ),
};

/// Suites that name Markdown, directly or through a file they reach, without
/// reading the repository's own Markdown in
/// `dart test -p vm --exclude-tags local-only`.
///
/// Add a suite here only after reading each walk root and git call in its
/// evidence. A suite that reads a tracked `.md` file, or a tool that does,
/// belongs in `tool/ci/markdown_test_suites.txt`: a Markdown-only change runs
/// nothing else from the root test tree. The evidence is what discovery finds
/// today, so a new or changed reader fails until it is re-checked.
const Map<String, Exemption> suiteExemptions = {
  'test/e2e/backends/multimodal_embedding_native_e2e_test.dart': (
    reason: _localOnly,
    evidence: {
      'test/e2e/backends/multimodal_embedding_native_e2e_test.dart': '.md',
    },
    gate: 'local-only',
  ),
  'test/e2e/backends/native_reranking_e2e_test.dart': (
    reason: _localOnly,
    evidence: {
      'test/e2e/backends/native_reranking_e2e_test.dart': '.md | doc/',
    },
    gate: 'local-only',
  ),
  'test/e2e/template/llama_cpp_chat_tests_e2e_test.dart': (
    reason:
        'Its source helper clones upstream llama.cpp into a work directory; it reads no repository Markdown.',
    evidence: {
      'tool/testing/prepare_llama_cpp_source.sh': 'git checkout | git clone',
    },
    gate: 'local-only',
  ),
  'test/integration/apple_companion_flutter_cache_test.dart': (
    reason:
        'Clones the checkout into a temp directory to run Flutter there; it reads no Markdown.',
    evidence: {
      'test/integration/apple_companion_flutter_cache_test.dart': 'git clone',
    },
    gate: 'local-only',
  ),
  'test/integration/backends/llama_cpp/native_symbol_integration_test.dart': (
    reason:
        'Lists native library directories by file name; its find match is prose in an error message.',
    evidence: {
      'test/integration/backends/llama_cpp/native_symbol_integration_test.dart':
          'find | listSync',
    },
    gate: null,
  ),
  'test/integration/core/template/llama_cpp_template_detection_integration_test.dart': (
    reason:
        'Lists the vendored llama.cpp .jinja templates; the source helper only clones llama.cpp.',
    evidence: {
      'test/integration/core/template/llama_cpp_template_detection_integration_test.dart':
          'listSync',
      'tool/testing/prepare_llama_cpp_source.sh': 'git checkout | git clone',
    },
    gate: null,
  ),
  'test/integration/core/template/template_diagnostic_integration_test.dart': (
    reason: 'Lists test/fixtures/templates, which hold Jinja templates.',
    evidence: {
      'test/integration/core/template/template_diagnostic_integration_test.dart':
          'listSync',
    },
    gate: null,
  ),
  'test/integration/native_diagnostics_test.dart': (
    reason: 'Copies lib and bin, which hold no Markdown, into a temp package.',
    evidence: {'test/integration/native_diagnostics_test.dart': 'listSync'},
    gate: 'local-only',
  ),
  'test/integration/stable_diffusion_runtime_hook_test.dart': (
    reason: 'Lists the hook runner logs under a temp consumer package.',
    evidence: {
      'test/integration/stable_diffusion_runtime_hook_test.dart': 'listSync',
    },
    gate: 'local-only',
  ),
  'test/integration/windows_ggml_registry_qualification_test.dart': (
    reason:
        'Its PowerShell scripts list the runtime and export roots of a qualification run, not the checkout Markdown.',
    evidence: {
      'test/fixtures/windows_ggml_registry_qualification/qualification.ps1':
          'Get-ChildItem | cp -r',
      'test/fixtures/windows_ggml_registry_qualification/runtime.ps1':
          'Get-ChildItem',
    },
    gate: 'local-only',
  ),
  'test/unit/backends/litert_lm/litert_lm_service_test.dart': (
    reason: 'Lists link and lease directories it creates in temp directories.',
    evidence: {
      'test/unit/backends/litert_lm/litert_lm_service_test.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/backends/llama_cpp/llama_cpp_service_test.dart': (
    reason:
        'Lists temp directories and native library directories under .dart_tool.',
    evidence: {
      'test/unit/backends/llama_cpp/llama_cpp_service_test.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/backends/llama_cpp/reranking_transport_test.dart': (
    reason: 'Passes the string doc as a rerank document.',
    evidence: {
      'test/unit/backends/llama_cpp/reranking_transport_test.dart': 'doc/',
    },
    gate: null,
  ),
  'test/unit/core/engine/chat_session_tool_loop_template_test.dart': (
    reason: _llamaCppSource,
    evidence: {
      'tool/testing/prepare_llama_cpp_source.sh': 'git checkout | git clone',
    },
    gate: null,
  ),
  'test/unit/core/template/chat_format_registry_test.dart': (
    reason:
        'Lists the Dart template handlers under lib/src/core/template/handlers.',
    evidence: {
      'test/unit/core/template/chat_format_registry_test.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/hook/build_hook_android_integration_test.dart': (
    reason: _pinTables,
    evidence: {..._pinTableFiles},
    gate: null,
  ),
  'test/unit/hook/build_hook_archive_digest_test.dart': (
    reason: _pinTables,
    evidence: {
      ..._pinTableFiles,
      'test/unit/hook/build_hook_archive_digest_test.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/hook/build_hook_archive_extraction_test.dart': (
    reason: _pinTables,
    evidence: {..._pinTableFiles},
    gate: null,
  ),
  'test/unit/hook/build_hook_backend_sidecar_test.dart': (
    reason: _pinTables,
    evidence: {
      ..._pinTableFiles,
      'test/unit/hook/build_hook_backend_sidecar_test.dart': 'find',
    },
    gate: null,
  ),
  'test/unit/hook/build_hook_download_test.dart': (
    reason: _pinTables,
    evidence: {..._pinTableFiles},
    gate: null,
  ),
  'test/unit/hook/build_hook_integration_test.dart': (
    reason: _pinTables,
    evidence: {..._pinTableFiles},
    gate: null,
  ),
  'test/unit/hook/build_hook_linux_integration_test.dart': (
    reason: _pinTables,
    evidence: {..._pinTableFiles},
    gate: null,
  ),
  'test/unit/hook/build_hook_litert_lm_integration_test.dart': (
    reason: _pinTables,
    evidence: {
      ..._pinTableFiles,
      'test/unit/hook/build_hook_litert_lm_integration_test.dart': 'find',
    },
    gate: null,
  ),
  'test/unit/hook/build_hook_stable_diffusion_integration_test.dart': (
    reason: _pinTables,
    evidence: {..._pinTableFiles},
    gate: null,
  ),
  'test/unit/hook/hook_cache_isolation_test.dart': (
    reason: 'Lists the Dart tests under test/unit/hook.',
    evidence: {'test/unit/hook/hook_cache_isolation_test.dart': 'listSync'},
    gate: null,
  ),
  'test/unit/hook/native_runtime_coexistence_test.dart': (
    reason: _pinTables,
    evidence: {..._pinTableFiles},
    gate: null,
  ),
  'test/unit/platform/io/native_diagnostics_test.dart': (
    reason: 'Asserts a private temp directory is empty.',
    evidence: {
      'test/unit/platform/io/native_diagnostics_test.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/public_entrypoints_test.dart': (
    reason: 'Walks example for Dart sources.',
    evidence: {'test/unit/public_entrypoints_test.dart': 'listSync'},
    gate: null,
  ),
  'test/unit/test_structure/mirrored_unit_structure_test.dart': (
    reason: 'Lists the Dart files under lib/src.',
    evidence: {
      'test/unit/test_structure/mirrored_unit_structure_test.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/tooling/build_llama_cpp_runtime_gbnf_validator_script_test.dart': (
    reason: _llamaCppSource,
    evidence: {
      'tool/testing/prepare_llama_cpp_source.sh': 'git checkout | git clone',
    },
    gate: null,
  ),
  'test/unit/tooling/build_site_script_test.dart': (
    reason: _tempTree,
    evidence: {
      'test/unit/tooling/build_site_script_test.dart': 'website/',
      'website/lib/src/site/sidebar.dart': 'doc/',
      'website/lib/src/site/site_model.dart': '.md',
    },
    gate: null,
  ),
  'test/unit/tooling/check_native_release_digests_test.dart': (
    reason: _pinTables,
    evidence: {..._pinTableFiles},
    gate: null,
  ),
  'test/unit/tooling/check_platform_boundaries_test.dart': (
    reason: 'The checker it runs lists Dart files only.',
    evidence: {'tool/testing/check_platform_boundaries.dart': 'listSync'},
    gate: null,
  ),
  'test/unit/tooling/checkout_workflow_contract_test.dart': (
    reason: 'Lists .github/workflows, which holds YAML.',
    evidence: {
      'test/unit/tooling/checkout_workflow_contract_test.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/tooling/chrome_test_supervisor_test.dart': (
    reason: 'Its Python tests glob .github/workflows/*.yml.',
    evidence: {'test/ci/test_supervise_chrome_test.py': 'glob | listdir'},
    gate: null,
  ),
  'test/unit/tooling/ci_workflow_selection_test.dart': (
    reason: 'Only passes Markdown paths to the selector.',
    evidence: {
      ..._validationFiles,
      ..._pinTableFiles,
      'test/unit/tooling/ci_workflow_selection_test.dart':
          '.md | AGENTS | CONTRIBUTING | README | doc/ | git checkout | git clone | listSync | website/',
      'tool/ci/deploy_guard.py': '.md | git diff',
      'tool/ci/select_jobs.py':
          '.md | AGENTS | CHANGELOG | CONTRIBUTING | README | doc/ | git diff | website/',
      'tool/testing/validation/coverage_catalog.dart': '.md',
      'tool/testing/validation/remote.dart': 'listSync',
      'website/lib/src/site/sidebar.dart': 'doc/',
      'website/lib/src/site/site_model.dart': '.md',
    },
    gate: null,
  ),
  'test/unit/tooling/classify_high_risk_changes_test.dart': (
    reason: 'Only classifies Markdown path strings.',
    evidence: {
      ..._ciToolFiles,
      'test/unit/tooling/classify_high_risk_changes_test.dart':
          '.md | CONTRIBUTING | README | doc/ | git checkout | ls-files | website/',
      'tool/git/safe_pr_head_update.dart': 'git cat-file',
      'tool/testing/classify_high_risk_changes.dart':
          '.md | AGENTS | CONTRIBUTING | doc/ | git diff',
      'tool/testing/high_risk_readiness.dart':
          '.md | git cat-file | git diff | git ls-tree',
      'tool/testing/release_metadata_readiness.dart':
          '.md | CHANGELOG | README | website/',
    },
    gate: null,
  ),
  'test/unit/tooling/companion_package_contents_test.dart': (
    reason: _tempTree,
    evidence: {
      ..._releaseToolFiles,
      'test/unit/tooling/companion_package_contents_test.dart':
          '.md | CHANGELOG | README',
      'tool/release/companion_pub_preflight.dart': 'cp -r | listSync',
      'tool/testing/release_metadata_readiness.dart':
          '.md | CHANGELOG | README | website/',
    },
    gate: null,
  ),
  'test/unit/tooling/companion_pub_preflight_test.dart': (
    reason: _tempTree,
    evidence: {
      ..._releaseToolFiles,
      'tool/release/companion_pub_preflight.dart': 'cp -r | listSync',
    },
    gate: null,
  ),
  'test/unit/tooling/core_archive_test.dart': (
    reason:
        'Runs the archive gate against temp roots and mocked pub runs; the validation manifest and pin tool it reaches are not read for Markdown.',
    evidence: {
      ..._pinTableFiles,
      'packages/llamadart_validation/lib/src/manifest.dart': '.md',
    },
    gate: null,
  ),
  'test/unit/tooling/genkit_package_score_test.dart': (
    reason:
        'Clones and shows files of a fixture repository it creates in a temp directory.',
    evidence: {
      'test/ci/test_genkit_package_score.py':
          'git checkout | git clone | git show',
      'tool/ci/check_genkit_package_score.py':
          'git clone | git ls-tree | git show',
    },
    gate: null,
  ),
  'test/unit/tooling/install_doc_versions_test.dart': (
    reason: _tempTree,
    evidence: {
      ..._releaseToolFiles,
      'test/unit/tooling/install_doc_versions_test.dart': '.md | CHANGELOG',
    },
    gate: null,
  ),
  'test/unit/tooling/litert_lm_tokenizer_fixture_test.dart': (
    reason: _validationTooling,
    evidence: {..._ciToolFiles},
    gate: null,
  ),
  'test/unit/tooling/litert_lm_v1_schema_qualification_test.dart': (
    reason:
        'Only reads the JSON CPU profile and renders dry-run plans; it does not execute validation or read Markdown.',
    evidence: {..._ciToolFiles},
    gate: null,
  ),
  'test/unit/tooling/macos_litert_lm_prepare_app_script_test.dart': (
    reason:
        'Reads the installation docs only on macOS; this job runs on Linux.',
    evidence: {
      'test/unit/tooling/macos_litert_lm_prepare_app_script_test.dart':
          '.md | website/',
    },
    gate: null,
  ),
  'test/unit/tooling/native_default_consumer_qualification_test.dart': (
    reason:
        'Runs the qualification driver against a fixture core in a temp directory with git faked.',
    evidence: {
      'test/fixtures/native_default_consumer_qualification/qualify.py':
          'ls-files',
      'test/fixtures/native_default_consumer_qualification/test_qualification.py':
          'git archive | ls-files',
    },
    gate: null,
  ),
  'test/unit/tooling/native_default_consumer_qualification_workflow_test.dart': (
    reason:
        'Names the qualification driver in argv assertions; runs only path-initializer and preflight fakes, not its tracked-source export.',
    evidence: {
      'test/fixtures/native_default_consumer_qualification/qualify.py':
          'ls-files',
    },
    gate: null,
  ),
  'test/unit/tooling/prepare_workspace_test.dart': (
    reason:
        'The tool it runs discovers pubspec.yaml files under example and packages.',
    evidence: {'tool/prepare_workspace.dart': 'listSync'},
    gate: null,
  ),
  'test/unit/tooling/preview_guard_test.dart': (
    reason:
        'Runs the guards against fixture checkouts it writes to temp directories.',
    evidence: {
      ..._validationFiles,
      ..._pinTableFiles,
      'test/ci/test_preview_guard.py': '.md | README',
      'test/ci/test_web_deployment.py': '.md | README | doc/ | glob',
      'tool/ci/preview_guard.py': '.md | README | git diff | git show',
      'tool/ci/select_jobs.py':
          '.md | AGENTS | CHANGELOG | CONTRIBUTING | README | doc/ | git diff | website/',
      'tool/ci/web_deployment.py': 'git diff',
      'tool/testing/validation/coverage_catalog.dart': '.md',
      'tool/testing/validation/remote.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/tooling/run_llama_cpp_chat_tests_script_test.dart': (
    reason: _llamaCppSource,
    evidence: {
      'tool/testing/prepare_llama_cpp_source.sh': 'git checkout | git clone',
    },
    gate: null,
  ),
  'test/unit/tooling/run_local_e2e_test.dart': (
    reason: _validationTooling,
    evidence: {
      ..._ciToolFiles,
      'test/unit/tooling/run_local_e2e_test.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/tooling/run_template_parity_suites_script_test.dart': (
    reason: _llamaCppSource,
    evidence: {
      'tool/testing/prepare_llama_cpp_source.sh': 'git checkout | git clone',
    },
    gate: null,
  ),
  'test/unit/tooling/sync_stable_diffusion_bindings_script_test.dart': (
    reason: 'Its Python tests list a temp header tree.',
    evidence: {
      'tool/native/test_sync_stable_diffusion_bindings.py': 'glob | listdir',
    },
    gate: null,
  ),
  'test/unit/tooling/validation_android_java_home_test.dart': (
    reason: _validationTooling,
    evidence: {
      ..._validationFiles,
      ..._pinTableFiles,
      'test/unit/tooling/validation_android_java_home_test.dart':
          'git checkout',
    },
    gate: null,
  ),
  'test/unit/tooling/validation_embedding_profile_test.dart': (
    reason: _validationTooling,
    evidence: {
      ..._validationFiles,
      ..._pinTableFiles,
      'tool/testing/validation/coverage_catalog.dart': '.md',
      'tool/testing/validation/remote.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/tooling/validation_image_profile_test.dart': (
    reason: _validationTooling,
    evidence: {
      ..._validationFiles,
      ..._pinTableFiles,
      'test/unit/tooling/validation_image_profile_test.dart': 'git checkout',
      'tool/testing/validation/remote.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/tooling/validation_internal_diagnostic_test.dart': (
    reason: _validationTooling,
    evidence: {
      ..._validationFiles,
      ..._pinTableFiles,
      'test/unit/tooling/validation_internal_diagnostic_test.dart': 'ls-files',
    },
    gate: null,
  ),
  'test/unit/tooling/validation_npu_test.dart': (
    reason: _validationTooling,
    evidence: {..._validationFiles, ..._pinTableFiles},
    gate: null,
  ),
  'test/unit/tooling/validation_remote_test.dart': (
    reason: _validationTooling,
    evidence: {
      ..._validationFiles,
      ..._pinTableFiles,
      'test/unit/tooling/validation_remote_test.dart': 'listSync',
      'tool/testing/validation/coverage_catalog.dart': '.md',
      'tool/testing/validation/remote.dart': 'listSync',
    },
    gate: null,
  ),
  'test/unit/tooling/verify_release_docs_companion_core_constraint_test.dart': (
    reason: _tempTree,
    evidence: {
      ..._releaseToolFiles,
      'test/unit/tooling/verify_release_docs_companion_core_constraint_test.dart':
          'git checkout',
    },
    gate: null,
  ),
};
