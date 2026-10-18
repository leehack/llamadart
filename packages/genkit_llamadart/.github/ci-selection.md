# CI selection

Known prose files in `.github/select_ci.py` skip runtime, browser and model
tests and the lower-bound job's SDK/dependency setup. Documentation links and
anchors always run; prose-only PRs also analyze Dart snippets against the public
API. Full runtime PRs include snippet analysis in their fast suite.
Latest-compatible dependency resolution, formatting, analysis, Pana and publish
dry-run still run. All other inputs retain both latest-compatible and lower-bound
coverage, including the real-model suite.
Only superseded PR runs are cancelled; main pushes remain independent.

Only pull requests are narrowed; main pushes and manual runs (where supported)
keep full validation. The selector compares the PR merge base with its head,
counts both sides of renames and deletions, and keeps all checks for empty or
unavailable diffs. Existing jobs always start and report their original status
names; unselected steps are skipped, while selected failures/cancellation retain
normal GitHub Actions job results. No separate aggregate is needed.

The link checker resolves local and canonical repository links without fetching
external URLs. Snippet analysis covers README, the other root Markdown documents,
skills and nested guides. Each guide retains its path so matching basenames in
different directories cannot hide snippets.

Run the policy and documentation checks with:

```sh
python3 -B -m unittest discover -s .github -p 'test_*.py'
python3 .github/check_docs.py
dart test test/tooling/package_documentation_test.dart
```

New prose files require explicit classification; unknown files retain full
validation. Update dependency cases when adding packages or changing example
dependencies. Prose-only PRs avoid model-cache access and runtime qualification;
full-input PRs retain the existing work.
