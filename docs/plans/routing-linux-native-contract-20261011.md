# Linux native input contract

The Linux B consumer accepts only an explicitly approved x86_64 input. The
fixed authorization source is this App checkout's
`docs/plans/routing-linux-native-accepted-inputs.json`; a producer archive or
receipt cannot supply or replace the ledger. An empty ledger means no Linux
native input is approved. Each acceptance entry also commits a canonical
`consumerSourceClosure` containing a sorted list of repository/path/SHA-256
records and a hash of that list.

## Consumer inputs

Routing mode is opt-in through `MEDIA_KIT_ROUTING_MODE=ON`. It requires all of
`MEDIA_KIT_LINUX_NATIVE_ROOT`, `MEDIA_KIT_LINUX_NATIVE_RECEIPT`,
`MEDIA_KIT_LINUX_NATIVE_APP_ROOT`, `MEDIA_KIT_LINUX_NATIVE_APP_SHA`, and
`MEDIA_KIT_LINUX_NATIVE_MEDIA_KIT_SHA`. Routing mode does not use the legacy
release URL fallback. The expected SHAs bind the exact clean task-branch
checkouts used by the consumer. App and media-kit remotes must identify the
Goodwu repositories. The exact HEADs are captured in the acquisition receipt;
the source closure separately binds reviewed production inputs across the
ledger-only commit that records acceptance.

Before invoking the App verifier, the media-kit-owned local preflight checks
both repositories, exact branch and HEAD, clean source state, and exact Git
blobs for the App verifier and fixed ledger. It then invokes the App verifier
with fixed argument names. The App verifier independently rechecks the
ledger, consumer checkout, receipt data, and payload. The receipt is evidence
data only: `nativeVerified` is recomputed and cannot authorize an entry.

## Accepted archive

The accepted payload root has `lib/libmpv.so.2`, exactly the declared
`lib/deps/<SONAME>` closure, the complete declared `include/mpv` header tree,
`payload.zip`, `provenance/manifest.json`, and the exact manifest evidence
attachments. No symlinks, extra files, or embedded authorization ledger are
allowed. The manifest binds FFmpeg, mpv, libplacebo, the producer recipe,
toolchain/sysroot, ordered link inputs, staging evidence, and payload hashes.

Every DSO must be ELF64 little-endian x86_64 `ET_DYN`, with the reviewed
Build ID, SONAME, ordered `DT_NEEDED`, symbol-version requirements, and
bounded `$ORIGIN` runtime paths. The plugin is the actual CMake output
`libmedia_kit_video_plugin.so`; the final application bundle must place it and
every accepted DSO directly at `bundle/lib/<SONAME>`. The plugin must have
exactly one runtime search path, `$ORIGIN`; CMake routing mode disables
link-path-derived RPATH injection. The full dependency closure resolves each
needed SONAME either to one hashed bundled DSO or to an explicit system
contract covered by the accepted manifest. The verifier uses `readelf` and
rejects tool errors; it does not infer system availability from `ldd`.
Bundle verification checks canonical install-relative files and follows each
reviewed bundled dependency edge at that loader-visible location; a matching
file elsewhere in the archive does not satisfy the contract.
Every delivered `.so*` object is separately required to be a regular,
non-symlink ELF64 little-endian x86_64 `ET_DYN`, and its ELF inspection tool
must succeed. Accepted producer DSOs are hash/SONAME/Build-ID bound by the
manifest; the generated media-kit plugin is checked for its actual ELF and
link contract. Flutter runtime, app AOT, and other build-generated shared
objects are recorded with path, SHA-256, ABI, and an explicit
`unbound-generated-build-output` source status. This consumer stage does not
authorize arbitrary extra libraries as producer inputs and does not claim
their source provenance: `fullBundleProvenanceVerified` and `releaseVerified`
remain false until a later build/package gate binds those generated outputs.
The `nativeVerified` field remains scoped to the accepted producer closure and
verified plugin link only.

The producer payload and provenance artifacts must have distinct artifact
IDs from the same repository, workflow run, attempt, and source HEAD. Their
artifact IDs, upload job IDs, ZIP digests, and producer identity are recorded
in the fixed ledger only after CORE review. `approval.coreCommit` names the
actual review record commit, never the future commit that adds the ledger
entry.

## Consumer source closure

The closure paths are fixed by the verifier, not selected by a receipt or
manifest. For `Goodwu/PiliPlusX` it includes all tracked files under `lib/` and `linux/`
and `.github/actions/routing-bootstrap/`, plus `.github/workflows/build.yml`,
`.github/workflows/linux_x64.yml`, `pubspec.yaml`, `pubspec.lock`, `.fvmrc`,
and these fixed scripts: `scripts/acquire_routing_linux_native.py`,
`scripts/verify_routing_linux_native.py`, `scripts/verify_routing_sources.py`,
`scripts/prepare_routing_ci.py`, `scripts/verify_media_kit_lock.py`,
`scripts/verify_workflow_media_kit_refs.py`, `scripts/verify_binary_arch.py`,
`scripts/release_manifest.py`, `scripts/verify_release_manifest.py`,
`scripts/shared_gate_execution.py`, and `scripts/prepare_ohos_package_patches.py`.
The `lib/` prefix captures App player-controller and route-option production
sources. The `linux/` prefix captures production CMake build/install policy,
Flutter and runner CMake, and runner sources. The named scripts cover native
acquisition/verification, release gates and their directly imported helper,
plus the Linux workflow's package-preparation dependency. These fixed inputs
keep approval applicable only while executable gate and build policy remains
unchanged.
For `Goodwu/media-kit` it includes all tracked files under `media_kit/lib/`,
`media_kit_video/lib/`, `media_kit_video/linux/`,
`libs/linux/media_kit_libs_linux/`, and `libs/universal/media_kit_libs_video/`,
plus `media_kit/lib/media_kit.dart`, `media_kit_video/lib/media_kit_video.dart`,
`media_kit/pubspec.yaml`, and `media_kit_video/pubspec.yaml`. Test files
and cache directories under `media_kit_video/linux/` are excluded. This binds
the Linux gate and source bootstrap, shared verifier, App production APIs,
Linux CMake consumer, native plugin/FFI code, and Linux package build/export
logic. All matching tracked paths are enumerated, so production additions and
deletions also change the closure.

The fixed accepted ledger and its approval record are outside these prefixes.
That allows the ledger-only commit to change App HEAD without changing the
reviewed source closure. `approval.coreCommit` points to the independent
existing CORE review record. Current App and media-kit full HEADs, clean state,
and source freshness are still verified for each build; closure equality does
not substitute for compiling the current source vector. A production blob
change or added/deleted matching path requires a new reviewed acceptance.

## Evidence boundaries

The consumer verifies acquisition, producer and consumer source closures, ELF ABI, bundle members,
plugin link requirements, requester-local runtime resolution, and source
freshness. This is host build/package evidence only. It does not claim native producer completion, installation,
runtime, device playback, HDR output, or release acceptance. Those remain
separate checks; no Linux entry is currently approved in the ledger.
