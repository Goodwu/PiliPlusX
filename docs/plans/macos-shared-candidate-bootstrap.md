# macOS shared candidate bootstrap

Runner's early `Prepare Bundle Info` phase derives
`$(DERIVED_FILE_DIR)/PiliPlusX-BundleInfo.plist` from the unchanged
`Runner/Info.plist` source. The same derived input is configured for Debug,
Profile and Release, so Xcode's normal `ProcessInfoPlistFile` still expands build
settings and owns the final App Info.plist. The generator defaults an unset
`PILIPLUSX_MPV_BUNDLE_MODE` to `legacy`; an empty or unknown value fails.

The normal Xcode hook passes the selected mode to `ensure_macos_mpv_bundle.sh`.
In `legacy`, the derived plist has no pending key and the existing archive, mpv
version, dependency, dual-architecture, loading and signing checks remain in
place. Unknown modes fail before the App is changed or dependencies are acquired.

An independent candidate build may explicitly set
`PILIPLUSX_MPV_BUNDLE_MODE=shared-candidate-bootstrap`. The derived input contains
the strict boolean `MediaKitSharedBootstrapPending=true`; the final Xcode
bootstrap hook only verifies that value and does not edit the App. Xcode must
finish signing that source App, and the final bundle guard still rejects pending
before ordinary package checks.
This is an intermediate build, unsuitable for distribution. The ordinary final
bundle guard rejects any presence of the pending key, regardless of its value or
environment variables. Switching back to legacy recomputes the derived plist
from the clean source template, removing the key without inheriting stale output.
The generator compares deterministic bytes and leaves an unchanged derived file
untouched. These source contracts do not establish that a particular installed
Xcode version builds the expected dependency graph or signs the final App; keep
those checks attached to the actual build evidence.

Pass the signed intermediate App to the existing sealed-input consumer:

```sh
python3 scripts/build_macos_shared_candidate.py \
  --input-app "$SIGNED_BOOTSTRAP_APP" --inputs "$SEALED_INPUTS" \
  --recipe "$SHARED_RECIPE" --work-dir "$FRESH_WORK" \
  --published-dir "$FRESH_SLICES" --output-app "$NEW_CANDIDATE_APP" \
  --log-dir "$NEW_LOG_DIR" --input-kind unknown
```

Its existing explicit input, recipe, work, output and log arguments still apply.
After checking every embedded runtime library against sealed inputs and its
strict signature, the consumer signs only its private Runtime.app envelope,
preserving App entitlements, requirements and flags. It does not deep-sign or
re-sign locked libraries. It compares each library's whole-file hash, both thin
hashes and CDHashes before and after, verifies the App deeply and strictly, and
records `runtime-envelope.json`; source tree drift fails. This restores the
private App envelope after dependency replacement so that the core's independent
signed-input check remains meaningful.

The shared core packager independently verifies the signed source and both
architecture bridge markers. It copies into its own private directory, embeds
the approved shared slices, clears the pending key only there, enables the shared
renderer, signs that copy, and runs all existing final bundle and both-ABI backend
gates. It records whether the source was a bootstrap App in `.shared-core.json`.
Immediately after copying, containment and full tree equality are checked
before any staged content mutation or signing. An internal source absolute link
that escapes the copied App is rejected; valid relative framework links remain
supported. Source tree and selected slice drift fail before publication. App and both
evidence sidecars must be absent; sidecars are linked exclusively and the App is
published last with macOS `renamex_np(RENAME_EXCL)`. Failed publication removes
only sidecars with the same inode installed by this operation. The source App
and competing outputs are never cleaned. The outer sealed-input consumer also
asserts that the final App has no pending key before publication.

CPU verification:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p macos_shared_bootstrap_test.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p build_macos_shared_candidate_test.py
```

Shell protocol tests execute real plist/file operations and reject native tools
through sentinels. Core orchestration tests mock signing, Mach-O and rendering
tool boundaries; filesystem staging and publication remain real. They establish
failure/publication semantics, not real Xcode signing, compiled playback, GPU or
visible acceptance. This change does not enable a workflow, change dependency
revisions or make shared candidates the production default. Those steps still
require their own reviewed configuration and actual runtime acceptance.
