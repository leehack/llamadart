[
  .[].workflow_runs[] |
  select(
    .path == ".github/workflows/trusted_high_risk_regression_gate.yml" and
    .head_repository.full_name == $repository and
    (((.display_title // "") | endswith($pr_suffix)) or
      .display_title == $ci_title) and
    (.event == "pull_request_target" or .event == "workflow_run") and
    .status == "in_progress"
  )
] |
sort_by(.id, .run_attempt) |
last |
if . == null then
  ""
else
  [.id, .run_attempt] | @tsv
end
