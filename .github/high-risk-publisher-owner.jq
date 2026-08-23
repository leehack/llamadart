[
  .[].workflow_runs[] |
  select(
    .path == ".github/workflows/trusted_high_risk_regression_gate.yml" and
    .head_repository.full_name == $repository and
    ((.display_title // "") | endswith($suffix)) and
    (.event == "pull_request_target" or .event == "workflow_run")
  )
] |
sort_by(.id, .run_attempt) |
last |
if . == null then
  ""
else
  [.id, .run_attempt] | @tsv
end
