#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${repo_root}"

echo "[template-parity] detection parity"
dart test -p vm -j 1 test/integration/core/template/llama_cpp_template_detection_integration_test.dart

echo "[template-parity] diagnostic fixture matrix"
dart test -p vm -j 1 test/integration/core/template/template_diagnostic_integration_test.dart

echo "[template-parity] unit template suite"
dart test -p vm -j 1 test/unit/core/template --exclude-tags local-only

echo "[template-parity] upstream llama.cpp chat/template parser suites"
dart test -p vm -j 1 test/e2e/template/llama_cpp_chat_tests_e2e_test.dart --run-skipped

echo "[template-parity] compiled specialized grammar acceptance"
LLAMA_CPP_GBNF_VALIDATOR="${LLAMA_CPP_CHAT_TEST_BUILD_DIR:-${repo_root}/.dart_tool/llama_cpp_chat_tests}/bin/test-gbnf-validator" \
  dart test -p vm -j 1 test/e2e/template/specialized_tool_grammar_validation_e2e_test.dart --run-skipped
