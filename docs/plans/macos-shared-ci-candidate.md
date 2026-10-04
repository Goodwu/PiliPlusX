# macOS shared-core candidate workflow

`.github/workflows/mac-shared-candidate.yml` is an opt-in `workflow_dispatch`
path for producing a reviewable shared-core candidate. It does not change the
normal macOS release workflow or enable the shared backend by default. The
result is a ZIP of the final candidate App, the consumer's `.shared-core.json`
and `.shared-backend.json` sidecars, sealed acquisition/runtime/input/consumer
receipt manifests, retained pipeline/runtime build logs, and a run report.
Visual acceptance stays pending.

## Source authorization

The workflow checks out the exact dispatch `GITHUB_SHA`. The runner requires a
full 40-character `SOURCE_REF`, equality with `GITHUB_SHA`, and equality with
the checked-out `HEAD`. The existing `scripts/macos-shared-ci-inputs.lock.json`
is the sole authority for the media-kit revision; its complete file digest is
fixed in the acquirer and candidate runner. A missing or malformed
`reviewed_media_kit_revision` exits before dependency download, source import,
`flutter pub get`, or build. The lock now pins the locally reviewed commit
`252c5851e2ebbcb0876f3bb819303c21fbfe29cd`. This commit has not been pushed;
remote availability and hosted-fresh execution remain unverified. No workflow input
can supply an unreviewed ref, recipe, URL, archive digest, or libass digest.

When a revision is approved in that existing lock, the runner fetches only
`https://github.com/Goodwu/media-kit.git` at that revision. It checks out the
shared recipe and Swift bridge from that same commit. Temporary Pub overrides
map every locked `media_kit*` package to the fixed Git URL, revision and exact
package subpath. The resolved package roots must all come from this run's
private `PUB_CACHE` checkout. The runner compares the complete package/recipe
checkout inventory and tracked contents with the approved Git tree, rejecting
modified, untracked, or ignored files. It locates the Swift bridge below the
resolved `media_kit_video` package root and compares it with that checkout.
For Pub's local Git remotes, it follows the checkout origin only when it points
to a canonical path inside this run's private cache, then verifies that target
is a bare repository with the fixed Goodwu origin and the approved commit
object. Direct fixed-URL checkout origins remain supported when exactly one
matching private bare cache contains that commit. Both forms require the
resolved checkout HEAD and all consumed package/recipe scopes to match the
same approved commit.

The standard Flutter compatibility step is constrained to the exact
deterministic `TargetPlatform.ohos` transformation implemented by
`prepare_standard_flutter_package_compat.py`. The runner computes the expected
file set and bytes before invoking it and rejects any additional or different
change. Eligible package paths are restricted to `lib/src/util.dart` and the
five generated type files for content blocker action, permission resource,
print-job color, print-job duplex, and print-job orientation. The affected
package must resolve inside this run's private Pub cache. The runner compares
a full node inventory before and after the patch, including regular file
content hashes, directory entries (including empty directories), symlink
targets, and special-node types. Only the six allowlisted regular-file byte
changes are accepted.
The original `pubspec_overrides.yaml`, `pubspec.lock`, app compatibility-edited
source and package configuration are restored in `finally` after success or
failure. The report records package mappings, lock/package-config checks, full
source-tree checks, bridge digest, and compatibility before/after hashes.

## Fresh build sequence

The runner validates `RUNNER_TEMP` as an existing canonical non-symlink path,
requires numeric single-segment run/attempt identifiers, and exclusively
creates the run and diagnostics directories. It never falls back to a
non-validated path if setup or logging fails; outputs are never resumed or
reused. The required order is:

1. Fetch and verify the fixed archives, derive signed framework contexts, and
   verify the signed contexts again.
2. Build the universal runtime from fresh source inputs with Python 3.11, then
   run the runtime verifier. Darwin arm64, Rosetta x86_64 execution, and the
   consumer's actual two-architecture CGL/backend probe are required gates.
3. Prepare and verify sealed shared inputs using the just-verified Ass binary
   hash from the signed-context manifest, fixed uchardet header digest, fresh
   runtime, and approved media-kit recipe.
4. Build a Release bootstrap App with the bootstrap mode set only in that
   Flutter subprocess. Check its signature, universal Runner, and pending
   marker; the ordinary bundle verifier must explicitly reject that pending
   App.
5. Run the existing full shared candidate consumer with `--input-kind normal`
   and four jobs. Re-run the final bundle gate, require the pending marker to
   be absent and the shared-core marker enabled, and preserve the two consumer
   sidecars.
6. Upload the candidate ZIP and sidecars only after every previous step passes.
   The successful artifact also retains the source manifests, stage receipts,
   and raw tool logs without copying source caches or intermediate Apps. A
   failed run uploads diagnostics and logs only; it never publishes a bootstrap
   App or staging directory as a candidate.

Commands are executed as argument arrays. The CPU/mock suite executes the
complete orchestration against a temporary workspace, checks the ZIP, sidecars
and receipts on success, and injects failures at Pub get, compatibility patch,
consumer and final gate to verify restoration and that no candidate archive
becomes eligible. It also rejects symlink/dangling output paths, traversal,
source-tree drift and compatibility changes outside the approved
transformation. The script records each command,
working directory, exit code and output in the run report. Existing acquire,
prepare, runtime, bootstrap and consumer programs retain ownership of their
own integrity, signing and publication gates.

## Current limit

This workflow is candidate-only, not a production release. It does not alter
`mac.yml`, production `pubspec.yaml`/lock behavior, the native bridge, normal
ensure logic, or the existing prepare/consumer internals. Since the approved
media-kit revision is currently absent, no successful hosted build can run
until that exact source revision is approved through the existing lock and the
lock digest identity is reviewed. CPU/mock tests cannot prove hosted signing,
Rosetta, CGL, video playback, or visible color and smoothness.
