#!/usr/bin/env bash
set -euo pipefail

read -r -a shards <<< "$1"
count=${#shards[@]}
timing_dir=$2
scratch=$(mktemp -d "${RUNNER_TEMP:?}/lvm-linux-vm.XXXXXX")

run_shard() (
  local shard=$1 status=0 files path
  export RUNNER_TEMP="$scratch/$shard"
  local events="$RUNNER_TEMP/test_events.jsonl"
  mkdir -p "$RUNNER_TEMP" "$timing_dir/$shard" || return 1

  # The canary normally exports temp paths to later Actions steps.
  GITHUB_ENV="$RUNNER_TEMP/env" bash tool/ci/litert_lm_temp_canary.sh seed || return 1
  while IFS= read -r setting; do
    export "${setting?}" || return 1
  done < "$RUNNER_TEMP/env"

  files=$(GITHUB_OUTPUT='' dart tool/ci/test_shards.dart linux-vm "$shard" "$count") || return 1
  [[ -n "$files" ]] || return 1
  local -a suites=()
  while IFS= read -r path; do
    suites+=("$path")
  done <<< "$files"

  # Warm Node before tooling fixtures start their own timers.
  if [[ "$files" == *test/unit/tooling/playwright_chat_app_real_model_smoke_test.dart* ]]; then
    timeout --kill-after=30s 5m node -e 'console.log(process.version)' || status=1
  fi
  timeout --kill-after=30s 30m dart test -p vm -j 1 --exclude-tags local-only \
    "--file-reporter=json:$events" "${suites[@]}" || status=1
  bash tool/ci/litert_lm_temp_canary.sh check || status=1
  if [[ -f "$events" ]]; then
    dart tool/ci/native_test_timing.dart "$events" "$timing_dir/$shard/test_timing.json" || status=1
  fi
  return "$status"
)

printf '| Shard | Result | Seconds |\n| --- | --- | ---: |\n' >> "${GITHUB_STEP_SUMMARY:?}"
failed=0
for shard in "${shards[@]}"; do
  label="Linux VM shard $shard/$count"
  echo "::group::$label"
  start=$SECONDS
  if run_shard "$shard"; then
    result=Passed
  else
    result=Failed
    failed=1
  fi
  echo '::endgroup::'
  printf '| %s | %s | %s |\n' "$label" "$result" "$((SECONDS - start))" >> "$GITHUB_STEP_SUMMARY"
  if [[ "$result" == Failed ]]; then
    echo "::error title=$label failed::See the $label log group." >&2
  fi
done
exit "$failed"
