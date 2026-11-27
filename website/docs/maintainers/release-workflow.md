---
title: Release checklist
description: Use this checklist to cut a llamadart release, snapshot docs, and verify the published artifacts afterward.
---

Use this checklist when releasing `llamadart`. The independently versioned
Genkit adapter follows [its own procedure](./genkit-package); it is not an Apple
companion and is not released by this checklist.

## Patch branches

**Rollout status.** Before the first patch from a branch cut before this
rollout, backport the patch guards (PR2), branch-aware changelog collector
(PR3a), docs cut (PR4), and workflow wiring (PR5) to `release/M.m.x`.
Backport the patch changelog import (PR3b) before the `0.22.0` prep.

- Squash work for the next minor into `main`. When the latest released minor
  needs a patch, cut `release/M.m.x` from `vM.m.0`. Maintain only the latest
  released minor. Prepare and publish `M.m.N` patches (`N >= 1`) from that
  branch, and minor releases from `main`. Release verification checks
  that the version matches its base branch.
- Land each fix on `main` first. Create a backport branch from
  `origin/release/M.m.x` and run `git cherry-pick -x <main-squash-sha>`.
  Open one squash PR per fix against `release/M.m.x`. Copy the main PR's
  authored description, including its changelog entry or N/A, and add these
  lines under `## Summary` so they survive the squash:

  ```text
  Backport of https://github.com/leehack/llamadart/pull/<N>
  (cherry picked from commit <40-hex main SHA>)
  ```

- A version-specific fix that cannot land on `main` first needs a triaged
  forward-port issue. Add `Forward-port: <issue URL>` under `## Summary`.
  The Backport and parity checks verify the metadata. Close forward-port
  issues before the next minor prep. Never merge a release branch back into
  `main`.
- Parity fails a backport whose source `main` later reverted, naming the
  source, the revert and the backport. Backport the revert after the original
  backport with `git cherry-pick -x <revert SHA>`, or re-apply the source on
  `main` exactly. A revert declares `This reverts commit <full SHA>.` or
  `Reverts leehack/llamadart#<N>` on its own line, or is the exact inverse
  patch. A well-formed SHA declaration counts only if its SHA identifies an
  existing commit. A `Revert "` subject or a malformed `This reverts commit `
  body line with no resolvable target triggers a shared-path check.
  To keep the backport instead, open a triaged forward-port issue and land one
  release-branch commit that adds
  `tool/release/retained_backports/<backport SHA>.json` and carries
  `Forward-port: <issue URL>`. The file is one line of compact JSON with the
  keys `backport`, `source`, `revert` (the current revert SHA) and `issue`
  (the issue number) in that order. A later revert needs a new record. The
  backport guard rejects a source reverted on `main`.
- Classify each backport diff. For a high-risk exact backport of an audited
  main commit, run a delta audit covering patch equivalence, dependencies on
  the release branch, and CI at the backport head. An adapted high-risk
  backport needs a full audit.
- Keep a minor plan for `main` and a separate
  [patch plan](https://github.com/leehack/llamadart/blob/main/doc/patch_plan_template.md)
  for `release/M.m.x`. Track follow-ups as individual triaged issues.
  The next minor prep will import the published patch changelog sections
  verbatim from their tags. Each patch tag outside main's first-parent chain
  must fork from the previous minor tag. Pause patch publication from the start
  of minor prep until the minor is tagged so its notes receipt stays current.

Configure the GitHub ruleset manually for `release/*.x`. Restrict deletion
and force pushes, require squash PRs and Copilot review, and start with no
required status checks. Allow branch creation and leave the bypass list
empty. Use the branch preview to confirm the ruleset covers the release
branch and excludes prep and Genkit PR branches. Release-branch PRs run
native release digests, LiteRT-LM smoke, and validation bundle checks. Pushes
to release branches also build selected validation targets, including those
deferred on PRs. Hosted demos stay on `main`.

[Genkit releases](./genkit-package) continue from `main`. Drop Genkit package
changes from a core backport and treat the backport as adapted.

## 1. Pre-release validation

```bash
# Print release-tier rows for evidence planning; this does not run validation.
dart run tool/testing/test_matrix.dart --tier release
dart run tool/prepare_workspace.dart
python3 tool/ci/check_format.py
dart analyze
dart run tool/testing/check_platform_boundaries.dart
TMPDIR="$(mktemp -d)" dart test -p vm -j 1 --exclude-tags local-only
dart test -p chrome --exclude-tags local-only
dart test -p vm test/unit/tooling/validation_coverage_test.dart
dart run tool/testing/verify_release_docs_versions.dart --release-prep
python3 tool/release/check_core_archive.py
./tool/docs/build_site.sh # fails on broken internal links
```

`python3 tool/ci/check_format.py` excludes `packages/llamadart_studio` and
`packages/llamadart_studio_core`; check their formatting, analysis, and tests
locally with the Flutter SDK pinned in
`packages/llamadart_studio/.flutter-version` (`3.50.0`). On macOS, keep
`TMPDIR="$(mktemp -d)"` for VM tests so LiteRT-LM cache pruning stays isolated.

Ensure migration/changelog docs reflect behavior in the release branch.

**Backport** checks release-branch PRs using the tool from the PR's base.
It verifies the main source commit, copied PR description and core
changelog notes, or checks that the linked forward-port issue is open.

Before and after the squash merge, `verify_release_candidate.sh` requires
`main` for `M.m.0` or `release/M.m.x` for `M.m.N` with `N >= 1`. On a patch
branch the version must advance by exactly one patch within the same line,
using unsuffixed stable versions. A changed companion version must increase
within the core's release line and keeps its own patch numbering.
Parity checks the patch branch through the
prep's parent. For a minor prep it checks all patch lines and requires
closed forward-port issues. To rehearse, fetch the
owner branches and tags in a clean clone. Set `through` to the exact
pre-prep SHA and `line` to the patch branch's `M.m` if applicable.

```bash
dart run tool/release/patch_branch.dart parity --line "$line" \
  --branch "$through" --main refs/remotes/origin/main
dart run tool/release/patch_branch.dart parity --main "$through" \
  --require-closed-forward-ports
```

Review the capability inventory's printed exemptions against the release scope.
Pack/case/profile bindings do not establish device qualification or waive
existing evidence requirements. This model-free gate adds no blanket
Firebase/GCE run requirement; choose affected validation rows and retain the
existing cost/approval boundaries.

The archive check uses pub's actual selected-file inventory, stages that file
set, and resolves/analyzes a fresh consumer plus the packaged basic example.
The chat app and its private validation harness stay together in a repository
checkout, outside the core archive. Run this check from a clean checkout after
workspace preparation, with the pinned SDK on PATH.

Before publishing a release that changes native runtime pins, verify native
version alignment:

- `lib/src/hook/native_release_pins.dart` native-assets pins and companion
  package `Package.swift` Apple SPM pins should reference compatible native repo
  releases.
- Companion package README and CHANGELOG files should name the native repo tags
  they publish.
- `llamadart-native` owns llama.cpp bridge artifacts for native-assets and
  Apple SPM-compatible companion packages.
- `litert-lm-native` owns LiteRT-LM bridge artifacts for native-assets and
  Apple SPM-compatible companion packages.
- `stable-diffusion-native` owns stable-diffusion.cpp runtime artifacts for
  native-assets and the Apple SPM-compatible companion package.
- If native versions changed, prefer the `Sync Native Version & Bindings`
  workflow PR over hand-editing core pins. It also updates Apple SPM companion
  package pins under `packages/` when Apple XCFramework releases changed.
- Stable llama.cpp native pins use strict `vMAJOR.MINOR.PATCH`; historical
  `bNNNN` pins remain explicit compatibility inputs. Verify `assets.json`,
  `SHA256SUMS`, hook contract version, bundle coverage, and manifest/release
  checksum agreement before accepting a stable pin change. `SHA256SUMS`, the
  manifest, and GitHub asset digests must agree. Stable wrapper-only rebuilds
  use `vM.m.p-N` for upstream `vM.m.p`; the suffix advances the native sequence
  but must never appear in the manifest's upstream llama.cpp ref. GitHub marks
  newly published wrapper and nightly releases as prereleases, so select them
  explicitly. Historical `bNNNN` and `bNNNN-llamadart.N` artifacts may retain
  older `prerelease=false` metadata, but remain explicit compatibility inputs;
  `latest` accepts only unsuffixed `vMAJOR.MINOR.PATCH` regardless of GitHub
  metadata. Nightly cores and positive rebuild counters must use canonical
  decimal spelling without leading zeros.

## 2. Version and docs updates

- Update `pubspec.yaml` version.
- Generate both core changelogs from the exact reviewed target-branch revision
  as described below.
- Regenerate tracked path-dependency locks after the core bump. Workspace
  preparation updates the chat-app lock; run `dart pub get` in
  `packages/llamadart_validation` and `website/examples/observability` too.
  A stale validation-harness lock changes during a desktop bundle build and
  fails its clean-source provenance check. The bounded core-patch metadata
  evidence route requires all three generated locks and permits only their
  local core version changes; it does not admit other dependency churn.
- Companion versions share the core's `MAJOR.MINOR`; their patch numbers move
  independently. Core `0.13.0` ships with every companion at `0.13.0`, and a
  later companion change within that minor bumps only the companion patch.
  From core `0.13.0` on, `verify_release_docs_versions.dart` fails, with or
  without `--release-prep`, when a companion's `MAJOR.MINOR` differs from the
  core's; the `0.0.x` companions released beside earlier cores predate the
  rule. Native pin sync records changed companion native pins under
  `Unreleased` but does not bump companion package versions by default.
- Release automation publishes only stable core versions and stops before any
  tag on a prerelease such as `0.13.0-dev.1`: no companion constraint
  `>=M.m.0 <M.(m+1).0` admits a prerelease of `M.m.0`. Build metadata, as in
  `0.13.0+1`, is not a prerelease.
- A companion-only release still needs a new core version: the release
  workflow publishes only for a core version that has no release tag at
  another commit, so bump the core patch with the companion.
- Each companion constrains the core to the core's own minor, for example
  `llamadart: '>=0.13.0 <0.14.0'` for core `0.13.x`, so pub refuses to pair it
  with a core minor whose native pins it does not match. A release that bumps
  the core minor must therefore set that constraint in every companion and
  bump every companion version, even one whose native pin did not move:
  pub.dev never changes a published version's constraint, and the release
  workflow skips a companion version that is already published.
- A companion native repin can ship in a core patch only with verified
  compatibility for every older companion whose published constraint admits
  that patch. Keep accepted older artifacts explicit, with warning/limitations
  and exact identity checks; otherwise use a new core minor.
- With `--release-prep`, the verifier checks both published companion -> new
  core and new companion -> published core pairings from full tag history.
  Narrow a new companion's core lower bound past every core whose hook rejects
  its pin, and bump the companion version: published constraints are immutable.
  For SD `v0.2.0-4`, prepare companion `0.15.2` with
  `llamadart: '>=0.15.2 <0.16.0'`. Core `0.15.2` retains explicitly qualified
  SD `v0.2.0-3` companions with an upgrade warning and a Dart backstop for
  recorded Metal backend failures. Updating core alone retains the old native
  payload; use the new companion to obtain the native failure guard.
- In the release-prep PR, bump only companion packages whose native pins or
  publishable package contents changed, move their accumulated `Unreleased`
  notes into the new version section, and keep unchanged companion package
  versions as-is.
- Companion packages publish only after the release-prep PR is merged. The
  release-prep PR merge is the approval boundary; automation pushes the relevant
  package-specific tags, and the publish workflow skips a companion package
  version that already exists on pub.dev.
- Keep current install snippets aligned with root and companion `pubspec.yaml`
  versions. Run
  `dart run tool/testing/verify_release_docs_versions.dart --release-prep`
  before opening or merging the release-prep PR. Without `--release-prep` the
  gate only reports pending companion bumps; with it, a companion whose
  `Package.swift` pin is still recorded under `## Unreleased` fails the run.
  `release_on_prep_merge.yml` runs the same strict check, so an unresolved
  pending bump aborts the release before any tag is pushed instead of shipping
  the previous pin.
- Before any tag is pushed, `tool/release/companion_pub_preflight.dart` also
  fails when a companion's checked-out version is already on pub.dev with a
  different `llamadart` constraint or publishable contents. It stages with the
  same helper as the publisher, uses pub's selected-file inventory and checks
  the bytes against the checksum-verified published archive. Unchanged packages
  and publication-excluded caches do not require a bump.
  The current install-version verifier requires companion README snippets to
  name the new core patch, so normal core patch preparation changes all three
  companion payloads and requires documentation version bumps. A bounded
  core-metadata readiness record does not bypass this unconditional pre-tag
  check. Archive selection skips dependency validation because the candidate
  core is not published yet; companion publishing retains its normal dependency
  resolution, dry-run validation and publication checks.
- The collector mirrors core notes and keeps the current and previous
  published minor on the docs page, including rollover to a new major.
  It moves whole root sections verbatim to the archive when the published
  file exceeds 256 KiB. See [Changelog size](#changelog-size).
- Each current core release section must state the pinned WebGPU bridge tag.
  If it is unchanged, use an explicit baseline instead of repeating the old
  release's fixes. In `CHANGELOG.md`, use:

  ```markdown
  - Keep the default WebGPU bridge assets at `vX.Y.Z` (unchanged from A.B.C).
  ```

  In `website/docs/changelog/recent-releases.md`, use:

  ```markdown
  - Keep default WebGPU bridge assets at `vX.Y.Z` (unchanged from A.B.C).
  ```

  Replace `vX.Y.Z` with the pinned asset tag and `A.B.C` with the published core
  version it is retained from. Keep a separate runtime-baseline paragraph with
  the existing upstream llama.cpp tag and commit, native tag, Web LiteRT-LM
  module version and manifest SHA-256; the release-note tests still require
  that provenance in the current section. This records retained versions, not
  newly shipped fixes. The bridge-tag gate checks the complete baseline wording,
  rejects missing, stale or multiple claims, and never borrows a baseline from
  an older release when the promoted current section omits it.
- Update `MIGRATION.md` if breaking behavior changed.
- Keep docs pages aligned with new defaults/options.
- Keep local SwiftPM artifact caches out of pub archives. Apple SPM binary
  target pins live in the Flutter runtime companion packages, not in the core
  `llamadart` package.

## 3. Publish flow

A release-prep PR updates versions, changelogs, docs, and pins only; it must not
publish companion packages or the core package before merge. Merging a
release-prep PR is the explicit approval boundary for publishing. After merge,
`release_on_prep_merge.yml` owns companion package tag ordering, the core
`vX.Y.Z` tag, pub.dev publication, docs versioning, and GitHub Release creation.

For automation to run, the merged PR must either carry the `release-prep` label
or use a versioned release-prep branch name such as `release/prep-0.8.12` or
`release/0.8.12-prep`. The automation requires a `RELEASE_AUTOMATION_TOKEN`
repository secret containing a fine-scoped PAT or GitHub App token that can push
tags and trigger tag-based workflows. Do not use the default `GITHUB_TOKEN` for
this step because GitHub suppresses most workflow runs caused by that token.
Prefer a GitHub App token or fine-scoped PAT with only the repository permissions
needed to create tags, and rotate it on a regular maintainer cadence. Never echo
the token or derived credential-bearing URLs in workflow logs.

Release automation and publication-sensitive files are covered by
`.github/CODEOWNERS`. CODEOWNERS is only advisory until the repository's branch
protection or ruleset requires code-owner review, so keep that setting enabled
before relying on the post-merge workflow as the publication approval boundary.
When adding new workflow, release, version, or native-runtime publication
surfaces, update `.github/CODEOWNERS` in the same PR.

### Nonpublishing token diagnostic

After an independent review and merge, `nonpublishing_release_auth_probe.yml`
can be manually run on owner `main` with its reviewed current full SHA as
`expected_sha`. Before that run, review current effective tag rules, inherited
policies, actor restrictions and deletion eligibility for `ci-auth-probe-*`.
Also inspect every workflow's direct and transitive triggers at that exact
source SHA: this diagnostic prefix must not enter publishing, docs or deployment
routes. Stop if policy or trigger safety is uncertain; do not alter governance
to make the probe pass.

The diagnostic first requires a read-only-token write denial and exact ref
absence. It then uses the current `RELEASE_AUTOMATION_TOKEN` to create one
unpredictable, invocation-owned `ci-auth-probe-<runId>-<32hex>` tag at that SHA,
requires the actual read-only push receiver and its bound receipt, and deletes
only the same verified ref. Intent and outcome artifacts include run attempts
and never overwrite existing artifacts. A failure is not automatically retried.

The sender retains `negative-denial.json` with fixed boolean observations and
an allowlisted permission-header classification. GitHub documents
[comma-separated required permissions and semicolon-separated alternatives](https://docs.github.com/en/rest/using-the-rest-api/troubleshooting-the-rest-api#resource-not-accessible).
Every alternative must be exactly `contents=write` or
`contents=write,workflows=write`, the documented
[Create Reference permission sets](https://docs.github.com/en/rest/git/refs#create-a-reference).
The parser accepts either ordering and space/tab around items, with at most
256 ASCII characters, two unique alternatives and two permissions per set.
Unknown, malformed or duplicate sets are refused before positive-token access.
The guard and receipt use the same parse result. The exact-literal comparison,
header-presence and rate-limit decimal-shape fields remain diagnostic only.
Raw headers, bodies and URLs are never retained, so a literal mismatch cannot
identify the returned representation or establish a credential or policy cause.

API traffic stays on `api.github.com` and rejects redirects. The sole exception
is the exact receiver-artifact download: its validated API redirect is followed
once with a fresh request carrying no credentials, cookies or referrer, only to
an HTTPS `*.blob.core.windows.net` artifact host. The signed URL stays in memory.
Compressed size and SHA-256 must match immutable artifact metadata, and the
bounded ZIP must contain only the expected JSON receipt. Other hosts and further
redirects fail closed.

An ambiguous create/delete, source drift, moved ref or receiver failure retains
its failure. Cancellation or runner loss can leave a diagnostic tag: use the
retained exact intent for independent inspection and an explicitly assessed
cleanup, never a prefix sweep. The ref API's DELETE has no expected-SHA atomic
compare-and-swap; the immediately preceding exact GET guards against observed
movement but cannot eliminate a concurrent writer race.

A pass proves this diagnostic ref's creation, push delivery and deletion at that
time. It does not prove release-prefix policy eligibility, future token validity,
workflow-dispatch permission or pub.dev publication. It never creates a release
tag, GitHub Release or package version, and never calls a publishing workflow.
The code-owner protection context and the user's final explicit core/Apple
publication approval remain separate requirements.

### Propagation waits

The post-merge workflow waits for pub.dev and GitHub Release propagation using
repository-variable defaults that can be tuned without editing the workflow:

| Variable | Default | Meaning |
| --- | --- | --- |
| `RELEASE_AUTOMATION_PUBDEV_WAIT_ATTEMPTS` | `180` | Number of pub.dev version URL checks. |
| `RELEASE_AUTOMATION_PUBDEV_WAIT_INTERVAL_SECONDS` | `10` | Delay between pub.dev checks. |
| `RELEASE_AUTOMATION_GITHUB_RELEASE_WAIT_ATTEMPTS` | `180` | Number of GitHub Release existence checks. |
| `RELEASE_AUTOMATION_GITHUB_RELEASE_WAIT_INTERVAL_SECONDS` | `10` | Delay between GitHub Release checks. |

Companions depend on the core version they constrain, and `pub publish`
resolves that dependency from pub.dev, so release automation publishes the core
first and every missing companion version right after it. For the few minutes
in between, the core's install docs name a companion version that is not on
pub.dev yet. The release sequence is:

1. Confirm the native GitHub releases referenced by `Package.swift` are live and
   include the pinned XCFramework zip/checksum assets.
2. For each companion package named in current install docs, check whether its
   `pubspec.yaml` version exists on pub.dev:

   ```bash
   package_path=packages/llamadart_llama_cpp_flutter
   package_name="$(awk '/^name:[[:space:]]*/ {print $2; exit}' "$package_path/pubspec.yaml")"
   package_version="$(awk '/^version:[[:space:]]*/ {print $2; exit}' "$package_path/pubspec.yaml")"
   curl -fsSL "https://pub.dev/api/packages/$package_name/versions/$package_version"
   ```

   For each missing companion version, also confirm on
   `https://pub.dev/packages/<package>/admin` that automated publishing from
   GitHub Actions is enabled for `leehack/llamadart` with tag pattern
   `<package>-v{{version}}`. The preflight cannot see that setting, and without
   it the companion's publish run fails after the core has shipped.

3. If a changed companion version is missing, keep the PR scoped to release
   prep and merge it only when the release is approved. The post-merge release
   workflow pushes the core `vX.Y.Z` tag and waits until the pub.dev package
   listing, which pub resolves against, includes the new core.
4. The workflow then pushes each missing companion's package-specific tag,
   waits for `publish_companion_pubdev.yml` to publish it, and re-checks the
   pub.dev listing. Pub.dev serves that listing with `max-age=120`, so the
   companion publish retries `flutter pub get` twice, a minute apart, when
   its first resolution misses the new core.
5. A rerun at the same merge commit finds the core tag already there, skips
   pushing it, and publishes the companions still missing; a core tag at any
   other commit stops the run.
   - If `publish_pubdev.yml` failed after the core tag was pushed, a rerun of
     `release_on_prep_merge.yml` alone waits for the core on pub.dev and fails.
     Rerun the tag's failed `publish_pubdev.yml` run first, wait for the core
     version on pub.dev, then rerun `release_on_prep_merge.yml`.
   - A companion tag at another commit whose version is not on pub.dev stops
     the run: rerunning its publish would ship that commit's package. Release
     it from a new release-prep PR that bumps the core version and the
     companion's patch version.

   A companion whose tag exists at the release commit but whose version is
   not on pub.dev also stops the rerun, because that tag already ran
   `publish_companion_pubdev.yml`:
   - For a transient failure, such as a pub.dev or runner outage, or
     automated publishing not yet enabled for the package, fix the cause,
     rerun that tag's failed `publish_companion_pubdev.yml` run, wait for the
     version on pub.dev, then rerun `release_on_prep_merge.yml`.
   - For a cause in the repository, such as a package that fails
     `pub publish` validation, the tagged commit cannot publish that version.
     Fix it in a new release-prep PR that bumps the core version and the
     companion's patch version; what already published stays as it is.

Current workflows involved:

- `publish_pubdev.yml`: publishes the core package on version tags, creates or
  updates the GitHub Release after pub.dev publishing succeeds, and does not
  publish companion packages.
- `publish_companion_pubdev.yml`: publishes one companion package from a
  package-specific version tag after that package already exists on pub.dev:
  `llamadart_llama_cpp_flutter-v{{version}}`,
  `llamadart_litert_lm_flutter-v{{version}}` or
  `llamadart_stable_diffusion_flutter-v{{version}}`. Pub.dev automated publishing
  cannot create a new package, so publish each companion's first version
  manually from a temporary copy, then configure automated publishing on that
  package's pub.dev Admin tab with the matching tag pattern. Use the same
  temp-copy shape as the publish workflow before running `flutter pub publish`.
  Leaving out the checkout's `pubspec_overrides.yaml` makes pub resolve the
  companion's `llamadart` constraint from pub.dev, so a new companion can first
  publish only against a core minor that is already released:

```bash
package_path=packages/llamadart_llama_cpp_flutter
tmp_package="$(mktemp -d)"
rsync -a --delete \
  --exclude='.dart_tool' \
  --exclude='build' \
  --exclude='pubspec.lock' \
  --exclude='pubspec_overrides.yaml' \
  "$package_path/" "$tmp_package/"
(cd "$tmp_package" && flutter pub publish)
```

- Each companion commits a `pubspec_overrides.yaml` that resolves `llamadart`
  from this checkout, because a release-prep PR constrains companions to a
  core version pub.dev does not have yet. Pub leaves the file out of published
  archives. CI's companion publish dry-run points the same override at the
  checkout; the real publish drops it.

- `docs_version_cut.yml` reads the docs from the core release tag and
  commits only the snapshot files in a worktree based on current `main`.
  It pushes with `GITHUB_TOKEN`, which starts no CI or demo deployment.
- `docs_pages.yml`: deploys docs to GitHub Pages after successful
  `docs_version_cut.yml` runs (and can be manually triggered).
- `ci.yml` (`deploy-chat-app`) and `laya_tetris_hf_static_deploy.yml`: the
  release-prep merge commit redeploys the hosted chat app and Laya Tetris
  demos. Each upload is skipped, without failing, only when a newer `main`
  commit changes that demo's inputs; the docs snapshot commit does not.
- `release_on_prep_merge.yml` runs after a release-prep PR is merged into
  `main` or `release/M.m.x`. It validates the version, pushes the core tag,
  waits for pub.dev, publishes any missing companion versions, and confirms
  the GitHub Release exists. Before pushing any tag,
  `tool/release/companion_pub_preflight.dart` checks that every companion
  under `packages/` exists on pub.dev and otherwise stops with the
  first-publish steps above; publish the package, then rerun the run. It
  retries each pub.dev request once after a timeout, including a stalled
  body, or a 5xx answer.

## 4. Post-release verification

- Verify `release_on_prep_merge.yml`, `publish_pubdev.yml`,
  `publish_companion_pubdev.yml` when relevant, `docs_version_cut.yml`, and
  `docs_pages.yml` all completed successfully.
- Verify pub.dev package page and API docs for the new version.
- Verify the GitHub Release exists and is marked latest.
- Verify docs version selector includes the new release.
- For releases from `main`, verify both hosted demos serve the release commit.
  Patch-branch releases leave both demos tracking `main`. The chat app deploys
  at the end of the release commit's CI run, and the Laya Tetris demo a few
  minutes after the merge:

  ```bash
  git rev-list -n 1 v<release-version>
  curl -fsS https://leehack-llamadart.static.hf.space/llamadart-build.json
  curl -fsS https://leehack-flutter-laya-tetris.static.hf.space/deploy-sha.txt
  ```

  A later commit is fine when it changed no demo input. If a demo is behind,
  for example because its deployment failed, redeploy `main` by hand. The CI
  run tests `main`'s tip in full before it deploys the chat app. Its unique
  concurrency group retains other main CI runs, including pending runs;
  deployment serialization and stale-input guards still apply:

  ```bash
  gh workflow run ci.yml --ref main
  gh workflow run laya_tetris_hf_static_deploy.yml --ref main
  ```

- Re-run smoke checks for representative examples.

## 5. If automation is blocked

If **Validate release state** fails after the prep lands, record the failed
run, landed prep SHA and current target-branch SHA. Reproduce the failure at the
landed SHA with its immutable message from `git show -s --format=%B`.
Retry a transient failure at the same SHA after the dependency has recovered.

For a deterministic failure, open a release-blocking issue and hold
publication. Stop or drain existing publishers and hold reruns until the
recovery lands. Reruns that predate the consumed-record guard can still use
their original workflow.

1. Look up the merged prep PR and its target ref update in GitHub repository
   activity. The update must end at the landed prep SHA and start at its sole
   Git parent. The start of that update is `before`.
2. Confirm the owner repository has no exact tag or GitHub Release for the
   attempted core version or any new Apple companion version. Check draft
   releases with maintainer access. Check each package's exact pub.dev
   version endpoint, using the companion's own version. Previously shipped
   companion versions can stay. If any attempted version reached a tag,
   GitHub Release or pub.dev, use the partial-publication and resume procedure
   in [Propagation waits](#propagation-waits).
3. Start an ordinary branch at the current target tip. Apply the inverse with
   `git revert --no-commit "$prep"`. If a later change overlaps the
   prep, keep publication held and take the conflict to the blocking issue.
   Add one regular, nonexecutable record at
   `tool/release/recoveries/<full-landed-sha>.json`. Use the exact key order
   and compact JSON encoding below, followed by one newline. The two SHAs
   must be full and lowercase. Set `pr` to the positive original PR number.

   ```json
   {"version":"0.20.4","prep":"1111111111111111111111111111111111111111","before":"2222222222222222222222222222222222222222","pr":1234}
   ```

4. Open a same-repository PR to the original target branch with an ordinary
   branch name and a specific Changelog N/A. On a patch branch, add the
   open release-blocking issue as the `Forward-port:` link. Run the
   protected-changelog policy against the
   immutable event base and head and the tested merge commit. For a local
   check, fetch the PR merge ref with `git fetch origin "refs/pull/$number/merge"`
   using the recovery PR number. Resolve it with `git rev-parse FETCH_HEAD`,
   confirm its parents match the event base and head in that order, and run the
   check from a worktree at that merge commit. Save the real PR event fields
   and use `GITHUB_EVENT_NAME=pull_request`,
   `GITHUB_EVENT_PATH` for that file, `GITHUB_REPOSITORY=leehack/llamadart` and
   `GITHUB_SHA` for the two-parent tested merge when running
   `dart run tool/testing/check_released_changelog_sections.dart`.
   Compare the intended squash tree with the tested tree. Immediately before
   approving that squash, recheck artifact absence and confirm both the PR
   head and the tested base are current.
5. Regenerate release notes from the recovered branch and the last published
   tag. The ledger records the failed prep and the recovery SHA. Attach the
   new ledger and receipt to a fresh prep for the same version. Run the
   normal CI, pre-tag checks and independent audit.

For a multi-commit target update, a two-parent merge or unavailable GitHub
boundary evidence, keep publication held and attach the PR and activity
evidence, Git graph and candidate path diffs to the release-blocking issue.
Retry missing reads. If the boundary still cannot be verified, a maintainer
must independently establish the actual previous target tip and review a
case-specific repair and its collector impact. Keep the marker absent and the
protected-changelog policy active during that review.

If the docs snapshot workflow cannot push directly to `main`, create a PR
branch in a worktree at current `origin/main`. From `website/` in a separate
worktree at the release tag, run
`dart run tool/cut_version.dart VERSION /absolute/path/to/main-worktree/website`.
Commit `website/versions.json`, `website/versioned_docs/` and
`website/versioned_sidebars/` in the PR worktree. Open a PR to `main` with
a specific changelog N/A.

## Collect and review core release notes

Use the approved release version, its previous core tag and the exact
current target-branch SHA. Set `base_ref` to `main` or `release/M.m.x`. Run
from the root with full tag history.

```bash
dart pub get
dart tool/release/collect_pr_changelog.dart --version "$version" \
  --from "$previous_tag" --through "$through" --base-ref "$base_ref"
dart tool/release/collect_pr_changelog.dart --version "$version" \
  --from "$previous_tag" --through "$through" --base-ref "$base_ref" --write
```

The collector prefers the landed commit's changelog after removing Git
attribution. It rejoins adjacent lines that match GitHub's greedy wrap at 72
Unicode code points. If a `- ` row could be a continuation or a new bullet,
the ledger identifies the commit and boundary. The collector then reads the
authored description through the verified PR association on the target
branch. The description uses one physical line per entry. Missing or
conflicting provenance blocks generation.

Land individual PRs, including independent package release preps, with
**Squash and merge**. Keep the `(#N)` subject suffix and the `## Changelog`
section in the squash message. Reserve rebase merges for batch integration
PRs whose constituent commits already carry both.

To resolve an already-landed, single-commit PR whose commit lacks both a
trailing `(#N)` and a readable `## Changelog` section, commit a reviewed
record at `tool/release/pr_resolutions/<40-hex-sha>.json`. Never use a
resolution record for a batch integration PR, even one with a single
constituent commit. Use one compact JSON line with the keys in the order
below and a final LF.
Run `dart tool/release/collect_pr_changelog.dart --section-sha256 PR_BODY.md`
on the reviewed PR description to compute the digest.

```json
{"version":"0.20.7","sha":"48af8ec5bc294620bd63a1e1818f6c6593afb5d3","pr":2180,"sectionSha256":"c99db03b6bdb4ef1bc771c35d31d2c766d52dd77f21fe94896266271ceb0a14e"}
```

Land the record on the target branch before pinning `--through`. The collector reads
the regular non-executable file from that commit and requires the record's
version to match the release being prepared. It verifies through GitHub
that the PR merged a single commit to this repository's target branch, that its
merge SHA matches the record, and that its changelog still has the reviewed
digest. The ledger records the resolution path.

Review the entire ledger including legacy seed, package-only notes, N/A
entries, duplicates, fallbacks and reversals. Keep the ledger with the PR.
Copy the emitted `## Release notes input` into the prep body beside its
`## Changelog`. To compact, pass a local `--curated FILE` to the writer and
use `--review FILE` with the draft prep body. In
`## Release notes review`, record `- <full SHA> <specific disposition>`
for each required source affected by editorial changes. Fix unresolved
input at its source before continuing.

Before merge, **Verify release prep** checks the tested merge tree with the
PR title and body as written, variants with co-author and sign-off trailers,
and GitHub's default squash message. GitHub rewraps description lines over
72 characters in its default message. A receipt value can move to the line
after its key, and a review entry can continue on adjacent unindented lines.
The verifier reads both forms. Opening, reopening, pushing to, editing or
retargeting a prep, marking it ready, and adding or removing any label rerun
the check. An invalid description fails the check. All subscribed events on a
same-repository PR recheck the protected changelogs. After removing
`release-prep` from an ordinary branch, later title or label changes continue
to apply the ordinary PR rules.

A push to a target branch rechecks its open core release preps. Completion
of **Docs Version Cut** rechecks open preps targeting `main`. Find
**Verify release prep (#PR)** in the **PR changelog** run. Its log records the
PR head and the tested base.
GitHub Actions cache access is disabled for the verifier job, which runs
code from the tested merge tree.
When the target branch advances, regenerate the ledger, review and receipt
and update the PR description. GitHub's **Re-run jobs** button
reuses the original event. Before merging, require a completed success from
the latest run for the current head, base and description.
End the receipt block with no trailing attribution or whitespace.

Land a release prep using **Squash and merge** only. Use GitHub's default
message or the exact PR title and body. A rebase merge, a merge commit or an
edited squash message can fail the publisher after merge. Before creating a
tag, the publisher reads the receipt from the immutable squash message and
verifies it with the landed tree. Refresh the ledger, review and receipt if
the target branch moves. Retry at the same landed SHA even when its tag
already exists.

For a local rehearsal, fetch the same headline and body. Set `number` to the
release-prep PR number.

```bash
gh api graphql -f owner=leehack -f name=llamadart -F number="$number" -f query='
  query($owner: String!, $name: String!, $number: Int!) {
    repository(owner: $owner, name: $name) {
      pullRequest(number: $number) {
        viewerMergeHeadlineText(mergeType: SQUASH)
        viewerMergeBodyText(mergeType: SQUASH)
      }
    }
  }'
```

`PR changelog` validates PR descriptions, including docs, bots and batch
envelopes. Analyze and docs version CI compare the real PR head against
its merge base with the immutable event base. Core release prep can change
numbered core changelogs or the archive. The
[unpublished prep recovery](#5-if-automation-is-blocked) is the only other
route. It restores the exact pre-prep tree entries and adds a single immutable
recovery record. Published section bytes and the cutover marker stay fixed.
Apple companion, Genkit and Model Store package notes follow their own
changelog rules.

## Changelog size

pub.dev rejects an upload whose `CHANGELOG.md`, `README.md`, `LICENSE` or
Example-tab file is over 256 KiB (262,144 bytes, `maxContentLength` in
pub-dev's `pub_package_reader`), and it does so only after the release tag is
pushed: `v0.19.2` was tagged but never published for this reason. It likewise
rejects a `pubspec.yaml` over 128 KiB (131,072 bytes, an inline `128 * 1024`
in the same reader).
`verify_release_docs_versions.dart` checks those files in the core, every
Apple companion and `genkit_llamadart`, in PR CI and in
`release_on_prep_merge.yml` before any tag. It fails a file over the limit and
warns above 90% of it. Genkit joins only this size check: its version and
release routing stay independent ([Genkit package](./genkit-package.md)). A
genkit-only PR and a genkit release do not run it, so check the
`genkit_llamadart` sizes by hand when preparing its release.

`CHANGELOG.md` keeps every release from 0.10.0 on; older ones are in
`doc/changelog_archive.md`, which pub does not package (`/doc/` is in
`.pubignore`) and `CHANGELOG.md` links by absolute URL. When the warning
appears, move the oldest `## <version>` sections of `CHANGELOG.md`, unchanged,
to the start of the archive's releases, and update the release named in both
files' introductions. Any PR may do this; the released-section check verifies
that nothing changed in the move.

## Published README compatibility

Keep moved-topic headings and visible migration links at the old fragments in
installation, native build hooks and image generation: published package
READMEs are immutable. `test/fixtures/published_readme_links.json` in the
website package records the 14 old destinations (17 link occurrences) from
the published 0.17.0 core and Apple companion READMEs. Website tests exercise
the same Markdown parser and URL rewriting used by the site.

Working docs changes repair `/docs/next` when deployed; `/docs` continues to
serve the latest released snapshot until the next version cut. Verify the
legacy `/docs` destinations after 0.17.4 is cut and deployed, without editing
historical snapshots. During release prep, decide companion patch bumps from
all accumulated publishable changes, including README changes; compatibility
links do not replace that decision.
