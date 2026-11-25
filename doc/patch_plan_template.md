## M.m.N patch (`release/M.m.x`)

Status checked YYYY-MM-DD. Branch cut from [`vM.m.0`](<tag URL>) at `<sha>`.
Minor plan [#NNN](<URL>).

| Fix | Issue | Main PR (lands first) | Backport PR | State |
| --- | --- | --- | --- | --- |
| | [#N](<URL>) | [#N](<URL>) `<main SHA>` | [#N](<URL>) | open / merged, exact / adapted |

### Release-branch-only changes

| Change | Forward-port issue | State |
| --- | --- | --- |

### Release

- [ ] Parity passes after the patch-branch tooling rollout. Run
  `dart tool/release/patch_branch.dart parity --line M.m --branch origin/release/M.m.x --main origin/main`.
- [ ] Prep PR against `release/M.m.x` [#N](<URL>).
- [ ] Verify core and applicable companion packages on pub.dev, the GitHub
  Release, the docs cut on `main`, and the deployed docs.
- [ ] Record whether Genkit needs a new core floor on `main`. Link the PR if needed.

### Deferred fixes

Link individual triaged issues.
