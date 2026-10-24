# macOS shared production release

## Status

This plan defines the only macOS release path: the shared GPU-next consumer
pipeline followed by read-only DMG verification and shared release metadata.
The lock currently has no reviewed media-kit revision, so preflight must stop
before Flutter setup, Pub downloads, or SDK/package patches. No alternate
legacy release path or dispatch-supplied media-kit SHA is allowed.

## Source and eligibility gates

The release source is a full 40-character SHA. The release runner requires it
to equal the checked-out `HEAD` and the peeled commit of the exact release tag.
The media-kit revision comes only from the existing reviewed input lock after
the lock's reviewed digest is checked. Missing revision or hosted-runner
qualification produces a failure diagnostic, never a successful artifact.

The workflow performs source, lock, explicit GitHub-hosted ARM64/Python 3.11
and Rosetta checks before setting up Flutter; self-hosted runners are rejected.
The full path also requires the existing CGL and
both architecture backend probes; failures are terminal.

## Isolated build transaction

The shared pipeline hook runs the existing version preparation and patches the
private Flutter SDK first. It then resolves the approved Git overrides,
validates the resulting lock and package configuration, applies package
patches, and repeats the lock/configuration guards before compatibility edits.
Modern mpv acquisition, runtime build, sealed input preparation, bootstrap
build and the normal-input shared consumer run under one
exclusive `RUNNER_TEMP` run directory. It uses a private Flutter SDK copy, a
private `PUB_CACHE` and temporary media-kit overrides bound to the approved
revision. The source checkout, lock, overrides, package configuration,
compatibility source, release metadata source files and patch text are restored
in `finally` on success or failure.

The patch script resolves `material_ui` and `cupertino_ui` only through the
workspace's exact `.dart_tool/package_config.json` roots and requires those
roots to be under the transaction's `PUB_CACHE`. It does not scan or mutate a
global Pub cache and does not change global Git configuration.

The shared hook records the final App as a directory receipt containing its
node count and inventory digest; it never passes an App directory to the
regular-file receipt helper. It returns the final consumer App, original sidecar bytes, source,
build, acquisition, signing and sealed-input identities, and consumer result
receipt. It does not run a second Flutter build. The release packager copies
only that final App into a temporary DMG source tree.

## DMG and distribution gates

The packager creates a compressed disk image, attaches it read-only at an
exclusive mount point, requires exactly one App, and compares the mounted App's
complete node inventory against the consumer App. The comparison includes
regular-file bytes and modes, directory modes, and internal symlink targets;
special nodes and escaping links fail.

While mounted, it reruns the final bundle verifier (mpv version, both runtime
closures, minimum OS, relocatable imports, dynamic loading and signature),
explicit arm64/x86_64 architecture checks, a deep/strict signature check, and
the two-architecture shared-backend/CGL probe. Detach is attempted on every
mounted path. Gate and detach failures are both retained when both fail. The
four flat release payloads are published only after all checks pass:

- `PiliPlusX_macos_<tag>.dmg`
- `PiliPlusX_macos_<tag>.shared-core.json`
- `PiliPlusX_macos_<tag>.shared-backend.json`
- `PiliPlusX_macos_<tag>.shared-distribution.json`

The two consumer sidecars are copied byte-for-byte. The distribution report
binds the tag/source SHA, approved revision and lock digest, build and sealed
manifests, source manifest, Runner/Mpv SHA values, raw sidecar SHA values,
consumer result report and tree identity, mounted tree identity, each mounted
gate's argv/exit/stdout/stderr identities, and the final DMG SHA. The metadata
workflow then generates and verifies the release manifest and checksum list.
Verification is anchored to the checked-out release source: its HEAD must match
the expected source commit; the committed lock bytes and reviewed revision must
match the distribution's pin and lock digest, and the gate scripts used by the
verifier must match the pinned checkout. This binds the report to the reviewed
source; it does not claim to reconstruct the hosted build's complete source
tree. The upload contains those two metadata files plus the four payloads.

The distribution uses schema 2 and embeds `gate_execution` schema 1. Before
running product gates, the producer captures the checked-out commit identity,
its absolute checkout root, the actual Python executable, hashes of the exact
seven committed gate scripts, and the absolute prepared-source, recipe
manifest, and backend-report paths. It captures the same structure again
before publication and fails closed if any field changes. Gate argv is stored
exactly as executed. A verifier on another runner validates those argv strings
against the captured identity and trusted script hashes from the expected
commit; it never resolves or opens producer-local absolute paths.

## Validation boundary

Local checks use temporary Git fixtures with a committed synthetic lock and
gate scripts plus mocked OS commands. They validate same-root and cross-root
single-platform and aggregate verification, source/gate drift rejection,
exact payload names/bytes, mounted-tree drift rejection, mount cleanup, and
structured distribution identities. They do not claim real macOS signing,
CGL, mounted disk image behavior, hosted runner qualification, or visible
video acceptance. Those remain hosted-runner release gates.
