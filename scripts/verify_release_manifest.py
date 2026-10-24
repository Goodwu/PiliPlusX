#!/usr/bin/env python3
"""Verify that release metadata and SHA256SUMS describe the same files."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path

from shared_gate_execution import (
    GateIdentityError,
    trusted_gate_digests,
    trusted_lock_identity,
    validate_gate_execution,
    validate_gate_argv,
)


SHA_RE = re.compile(r"^[0-9a-f]{40}$")
HASH_RE = re.compile(r"^[0-9a-f]{64}$")
NATIVE_VERSION_RE = re.compile(r"^[A-Za-z0-9_.-]+@[0-9][A-Za-z0-9+_.-]*$")
TAG_RE = re.compile(r"^v\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?$")
TRUSTED_METADATA_SCRIPTS = (
    "scripts/verify_release_manifest.py",
    "scripts/shared_gate_execution.py",
)


def fail(message: str) -> None:
    raise SystemExit(message)


def required_hash(value: object, label: str) -> str:
    if not isinstance(value, str) or not HASH_RE.fullmatch(value):
        fail(f"macOS shared metadata has invalid {label}")
    return value


def trusted_source(source_checkout: Path, expected_source: str, *, aggregate: bool = False) -> tuple[str, str, Path, dict[str, str]]:
    """Read the approved pin only from a source-bound, clean committed lock."""
    if not SHA_RE.fullmatch(expected_source):
        fail("macOS shared verification requires a full expected source commit")
    if source_checkout.is_symlink():
        fail("trusted source checkout may not be a symbolic link")
    try:
        checkout = source_checkout.resolve(strict=True)
    except OSError as error:
        fail(f"trusted source checkout is unavailable: {error}")
    if not checkout.is_dir():
        fail("trusted source checkout is not a directory")

    def git_bytes(*args: str) -> bytes:
        try:
            return subprocess.run(
                ["git", "-C", str(checkout), *args], check=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            ).stdout
        except (OSError, subprocess.CalledProcessError) as error:
            fail(f"cannot verify trusted source checkout: {error}")

    try:
        head = git_bytes("rev-parse", "--verify", "HEAD").decode("ascii").strip()
    except UnicodeError as error:
        fail(f"trusted source checkout has an invalid HEAD: {error}")
    if head != expected_source:
        fail("trusted source checkout HEAD differs from expected source")

    required = set(TRUSTED_METADATA_SCRIPTS)
    if aggregate:
        required.add("scripts/verify_release_assets.py")
    for relative in required:
        tracked = git_bytes("ls-tree", expected_source, "--", relative).decode("utf-8", "replace")
        if not tracked.startswith("100644 blob ") and not tracked.startswith("100755 blob "):
            fail(f"trusted source does not contain a regular tracked file: {relative}")
        committed = git_bytes("show", f"{expected_source}:{relative}")
        working = checkout / relative
        if working.is_symlink() or not working.is_file() or working.read_bytes() != committed:
            fail(f"trusted source working file differs from its committed bytes: {relative}")
    try:
        revision, lock_sha = trusted_lock_identity(checkout, expected_source)
        gate_digests = trusted_gate_digests(checkout, expected_source)
    except GateIdentityError as error:
        fail(str(error))
    return revision, lock_sha, checkout, gate_digests


def safe_flat_name(value: object, label: str) -> str:
    if (not isinstance(value, str) or not value or value in (".", "..") or
            Path(value).is_absolute() or Path(value).name != value or
            "/" in value or "\\" in value):
        fail(f"macOS shared metadata has unsafe {label}: {value!r}")
    return value


def absolute_app_path(value: object, label: str) -> str:
    if (not isinstance(value, str) or not Path(value).is_absolute() or
            ".." in Path(value).parts or not Path(value).name.endswith(".app")):
        fail(f"macOS shared metadata has no canonical {label}")
    return value


def read_json(path: Path, label: str) -> dict:
    if path.stat().st_size > 64 * 1024 * 1024:
        fail(f"{label} exceeds the metadata size limit")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"cannot read {label}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object")
    return value


def validate_shared_release(root: Path, manifest: dict, expected: dict[str, str],
                           checkout: Path, approved_media_kit: str,
                           trusted_lock_sha: str, trusted_digests: dict[str, str]) -> None:
    if manifest.get("schema") != 2:
        fail("macOS shared release requires manifest schema 2")
    if manifest.get("abi") != "universal-arm64+x86_64":
        fail("macOS shared release ABI is not universal arm64+x86_64")
    if manifest.get("hdrBackend") != "shared-gpu-next":
        fail("macOS shared release does not declare shared-gpu-next")

    shared = manifest.get("sharedRelease")
    if (not isinstance(shared, dict) or
            type(shared.get("schema_version")) is not int or shared.get("schema_version") != 1):
        fail("macOS shared release has no supported sharedRelease identity")
    for field in ("distribution", "shared_core", "shared_backend"):
        record = shared.get(field)
        if not isinstance(record, dict):
            fail(f"macOS sharedRelease has no {field} binding")
        name = safe_flat_name(record.get("path"), f"{field}.path")
        if name not in expected or record.get("sha256") != expected[name]:
            fail(f"macOS sharedRelease {field} digest does not bind a declared payload")
    distribution_name = shared["distribution"]["path"]
    core_name = shared["shared_core"]["path"]
    backend_name = shared["shared_backend"]["path"]
    dmgs = [name for name in expected if name.endswith(".dmg")]
    if not (len(dmgs) == 1 and len(expected) == 4):
        fail("macOS shared release must declare exactly one DMG and three sidecars")
    dmg_name = dmgs[0]
    prefix = dmg_name.removesuffix(".dmg")
    if (core_name != f"{prefix}.shared-core.json" or
            backend_name != f"{prefix}.shared-backend.json" or
            distribution_name != f"{prefix}.shared-distribution.json"):
        fail("macOS shared sidecars do not use the DMG release prefix")
    if not prefix.startswith("PiliPlusX_macos_") or not TAG_RE.fullmatch(
        prefix.removeprefix("PiliPlusX_macos_")
    ):
        fail("macOS shared DMG has an invalid release filename")

    distribution = read_json(root / distribution_name, "macOS shared distribution")
    if (type(distribution.get("schema_version")) is not int or distribution.get("schema_version") != 2 or
            distribution.get("status") != "ready" or
            distribution.get("production_eligible") is not True):
        fail("macOS shared distribution is not production eligible")
    eligibility = distribution.get("eligibility")
    if (not isinstance(eligibility, dict) or eligibility.get("enabled") is not True or
            eligibility.get("missing") != []):
        fail("macOS shared distribution eligibility is incomplete")
    git_commit = manifest.get("gitCommit")
    media_commit = manifest.get("mediaKitCommit")
    source = distribution.get("source")
    release_tag = prefix.removeprefix("PiliPlusX_macos_")
    if (not isinstance(source, dict) or source.get("source_ref") != git_commit or
            source.get("peeled_tag_commit") != git_commit or
            source.get("release_tag") != release_tag):
        fail("macOS distribution source ref/tag differs from manifest source")
    if distribution.get("approved_media_kit_revision") != media_commit:
        fail("macOS distribution media-kit revision differs from manifest")
    try:
        execution = validate_gate_execution(distribution.get("gate_execution"), trusted_digests)
    except GateIdentityError as error:
        fail(str(error))
    if media_commit != approved_media_kit:
        fail("macOS manifest media-kit revision differs from the approved source lock")
    lock = distribution.get("lock")
    if (not isinstance(lock, dict) or lock.get("path") != "scripts/macos-shared-ci-inputs.lock.json"):
        fail("macOS distribution does not identify the fixed acquisition lock")
    if required_hash(lock.get("sha256"), "lock.sha256") != trusted_lock_sha:
        fail("macOS distribution lock digest differs from the approved source lock")
    dmg_record = distribution.get("dmg")
    if (not isinstance(dmg_record, dict) or dmg_record.get("filename") != dmg_name or
            dmg_record.get("sha256") != expected[dmg_name]):
        fail("macOS distribution DMG identity differs from the declared payload")

    core = read_json(root / core_name, "shared core sidecar")
    backend = read_json(root / backend_name, "shared backend sidecar")
    build = distribution.get("build")
    sealed = distribution.get("sealed")
    source_manifest = distribution.get("source_manifest")
    consumer = distribution.get("consumer")
    mounted = distribution.get("mounted_app")
    if not all(isinstance(value, dict) for value in (build, sealed, source_manifest, consumer, mounted)):
        fail("macOS distribution is missing build, sealed, source, consumer, or mounted identities")
    core_source = core.get("complete_source")
    core_consumer = core.get("candidate_consumer")
    if not isinstance(core_source, dict) or not isinstance(core_consumer, dict):
        fail("shared core sidecar has no complete source or consumer report")
    for field in ("base_archive_sha256", "patch_sha256", "source_tree_sha256", "manifest_sha256"):
        required_hash(core_source.get(field), f"shared core complete_source.{field}")
    if type(core_source.get("file_count")) is not int or core_source["file_count"] <= 0:
        fail("shared core complete_source.file_count must be a positive integer")
    runner_sha = required_hash(build.get("runner_sha256"), "build.runner_sha256")
    mpv_sha = required_hash(build.get("mpv_sha256"), "build.mpv_sha256")
    build_identity = required_hash(build.get("identity_sha256"), "build.identity_sha256")
    sealed_input = required_hash(sealed.get("input_manifest_sha256"), "sealed.input_manifest_sha256")
    required_hash(sealed.get("acquisition_manifest_sha256"), "sealed.acquisition_manifest_sha256")
    required_hash(sealed.get("signed_context_manifest_sha256"), "sealed.signed_context_manifest_sha256")
    required_hash(sealed.get("runtime_manifest_sha256"), "sealed.runtime_manifest_sha256")
    source_identity = required_hash(source_manifest.get("identity_sha256"), "source_manifest.identity_sha256")
    consumer_tree = required_hash(consumer.get("app_tree_identity_sha256"), "consumer.app_tree_identity_sha256")
    mounted_tree = required_hash(mounted.get("tree_identity_sha256"), "mounted_app.tree_identity_sha256")
    if (runner_sha != core.get("runner_sha256") or runner_sha != mounted.get("runner_sha256") or
            mpv_sha != core.get("framework_sha256") or mpv_sha != mounted.get("mpv_sha256")):
        fail("macOS runner or Mpv SHA does not match the consumer/mounted app")
    if (mounted.get("build_identity_sha256") != build_identity or
            mounted.get("sealed_input_manifest_sha256") != sealed_input or
            mounted.get("acquisition_manifest_sha256") != sealed.get("acquisition_manifest_sha256") or
            mounted.get("signed_context_manifest_sha256") != sealed.get("signed_context_manifest_sha256") or
            mounted.get("runtime_manifest_sha256") != sealed.get("runtime_manifest_sha256") or
            mounted.get("source_manifest_sha256") != source_identity or
            mounted.get("consumer_app_tree_identity_sha256") != consumer_tree or
            mounted.get("mounted_app_tree_identity_sha256") != mounted_tree):
        fail("mounted App report contains inconsistent build, source, or tree identities")
    if (build_identity != core.get("build_identity_sha256") or
            build_identity != core_consumer.get("build_identity_sha256")):
        fail("macOS build identity differs from the shared core sidecar")
    if (sealed_input != core_consumer.get("sealed_inputs_manifest_sha256") or
            source_identity != core_source.get("manifest_sha256")):
        fail("macOS sealed or source manifest identity differs from the shared core sidecar")
    if consumer_tree != mounted_tree:
        fail("mounted DMG app tree differs from consumer app tree")
    result_report = consumer.get("result_report")
    if not isinstance(result_report, dict) or not isinstance(result_report.get("utf8"), str):
        fail("distribution does not embed the final consumer result report")
    result_text = result_report["utf8"]
    result_bytes = result_text.encode("utf-8")
    if len(result_bytes) > 16 * 1024 * 1024:
        fail("embedded consumer result report exceeds the size limit")
    result_sha = hashlib.sha256(result_bytes).hexdigest()
    if result_sha != result_report.get("sha256"):
        fail("embedded consumer result report SHA-256 is invalid")
    try:
        result_value = json.loads(result_text)
    except json.JSONDecodeError as error:
        fail(f"embedded consumer result report is invalid JSON: {error}")
    if not isinstance(result_value, dict):
        fail("embedded consumer result report must be a JSON object")
    consumer_app_path = absolute_app_path(consumer.get("app_path"), "consumer App path")
    if result_value.get("candidate") != consumer_app_path:
        fail("distribution consumer App path differs from the embedded consumer result")
    if (result_value.get("status") != "published-candidate" or
            consumer.get("status") != result_value.get("status") or
            result_value.get("input_kind_claim") != "normal"):
        fail("embedded consumer result does not report a completed normal candidate")
    if (result_value.get("build_identity_sha256") != build_identity or
            result_value.get("sealed_inputs_manifest_sha256") != sealed_input or
            result_value.get("consumer_sha256") != core_consumer.get("consumer_sha256")):
        fail("embedded consumer result identity differs from shared core/distribution")
    if (consumer.get("shared_core_sha256") != expected[core_name] or
            consumer.get("shared_backend_sha256") != expected[backend_name]):
        fail("consumer identities do not bind the raw sidecar bytes")
    if backend.get("framework_sha256") != mpv_sha:
        fail("backend sidecar Mpv framework SHA differs from distribution")
    if backend.get("manifest_sha256") != source_identity:
        fail("backend sidecar source manifest SHA differs from distribution")

    backend_results = backend.get("backend_creation_and_empty_target_render")
    gates = consumer.get("backend_gates")
    if not isinstance(backend_results, dict) or not isinstance(gates, dict):
        fail("macOS distribution has no structured two-architecture backend gate")
    if set(gates) != {"arm64", "x86_64", "final_bundle", "pending_absent", "shared_renderer_enabled"}:
        fail("macOS backend_gates has unexpected or missing entries")
    backend_hash = expected[backend_name]
    for architecture in ("arm64", "x86_64"):
        result = backend_results.get(architecture)
        gate = gates.get(architecture)
        if (not isinstance(result, dict) or type(result.get("exit_code")) is not int or
                result.get("exit_code") != 0):
            fail(f"actual backend report failed for {architecture}")
        if (not isinstance(gate, dict) or type(gate.get("probe_exit_code")) is not int or
                gate.get("probe_exit_code") != 0 or
                gate.get("report_sha256") != backend_hash):
            fail(f"distribution does not bind the actual {architecture} backend report")
    final_gate = gates.get("final_bundle")
    if (not isinstance(final_gate, dict) or type(final_gate.get("exit_code")) is not int or
            final_gate.get("exit_code") != 0):
        fail("shared final bundle gate did not exit successfully")
    final_report = final_gate.get("report")
    if not isinstance(final_report, dict) or not isinstance(final_report.get("utf8"), str):
        fail("distribution does not embed the canonical final bundle gate report")
    final_report_bytes = final_report["utf8"].encode("utf-8")
    if len(final_report_bytes) > 1024 * 1024:
        fail("embedded final bundle gate report exceeds the size limit")
    final_report_sha = hashlib.sha256(final_report_bytes).hexdigest()
    declared_final_report_sha = required_hash(
        final_gate.get("report_sha256"), "consumer.backend_gates.final_bundle.report_sha256")
    if final_report.get("sha256") != final_report_sha or declared_final_report_sha != final_report_sha:
        fail("embedded final bundle gate report SHA-256 is invalid or unbound")
    try:
        final_report_value = json.loads(final_report["utf8"])
    except json.JSONDecodeError as error:
        fail(f"embedded final bundle gate report is invalid JSON: {error}")
    if (not isinstance(final_report_value, dict) or
            set(final_report_value) != {"argv", "exit_code", "stdout_sha256", "stderr_sha256"}):
        fail("embedded final bundle gate report has an unexpected structure")
    final_argv = final_report_value.get("argv")
    if (not isinstance(final_argv, list) or
            type(final_report_value.get("exit_code")) is not int or
            final_report_value.get("exit_code") != 0):
        fail("embedded final bundle gate report does not show a successful command")
    final_app_path = absolute_app_path(
        final_argv[1] if len(final_argv) == 2 else None,
        "final-bundle consumer App path",
    )
    if final_app_path != consumer_app_path:
        fail("final bundle gate target differs from the embedded consumer App")
    try:
        validate_gate_argv(final_argv, "final_bundle", execution, final_app_path,
                           consumer_app_path=consumer_app_path)
    except GateIdentityError as error:
        fail(str(error))
    if final_app_path == mounted.get("app_path"):
        fail("final bundle gate must target the consumer App before the read-only DMG mount")
    required_hash(final_report_value.get("stdout_sha256"), "final bundle report stdout_sha256")
    required_hash(final_report_value.get("stderr_sha256"), "final bundle report stderr_sha256")
    if gates.get("pending_absent") is not True or gates.get("shared_renderer_enabled") is not True:
        fail("consumer final gate does not prove pending absence and shared renderer")
    if (core.get("shared_renderer_enabled") is not True or
            core_consumer.get("status") != "staged-gates-passed" or
            core_consumer.get("input_kind_claim") != "normal"):
        fail("shared core sidecar does not report a normal shared consumer with staged gates")

    mounted_gates = mounted.get("gates")
    if not isinstance(mounted_gates, dict) or not mounted_gates:
        fail("macOS distribution has no mounted App gate reports")
    required_mounted_gates = {"codesign", "bundle", "arm64", "x86_64", "backend"}
    if set(mounted_gates) != required_mounted_gates:
        fail("mounted App gate reports must be exactly codesign, bundle, arm64, x86_64, and backend")
    app_path = absolute_app_path(mounted.get("app_path"), "mounted App path")
    for gate_name, gate in mounted_gates.items():
        if (not isinstance(gate_name, str) or not gate_name or not isinstance(gate, dict) or
                not isinstance(gate.get("argv"), list) or not gate["argv"] or
                any(not isinstance(argument, str) or not argument for argument in gate["argv"]) or
                type(gate.get("exit_code")) is not int or gate.get("exit_code") != 0):
            fail(f"invalid mounted app gate report: {gate_name!r}")
        try:
            validate_gate_argv(gate["argv"], gate_name, execution, app_path)
        except GateIdentityError as error:
            fail(str(error))
        required_hash(gate.get("stdout_sha256"), f"mounted_app.gates.{gate_name}.stdout_sha256")
        required_hash(gate.get("stderr_sha256"), f"mounted_app.gates.{gate_name}.stderr_sha256")
        observed = gate.get("observed")
        if (not isinstance(observed, dict) or observed.get("pending_absent") is not True or
                observed.get("shared_renderer_enabled") is not True or
                observed.get("runner_sha256") != runner_sha or observed.get("mpv_sha256") != mpv_sha or
                observed.get("app_tree_identity_sha256") != mounted_tree):
            fail(f"mounted app gate does not bind required observed values: {gate_name}")
    if (mounted.get("pending_absent") is not True or
            mounted.get("shared_renderer_enabled") is not True):
        fail("mounted DMG app is pending or shared renderer is disabled")
    for field, value in (
        ("runner_sha256", runner_sha), ("mpv_sha256", mpv_sha),
        ("build_identity_sha256", build_identity),
        ("sealed_input_manifest_sha256", sealed_input),
        ("acquisition_manifest_sha256", required_hash(sealed.get("acquisition_manifest_sha256"), "sealed.acquisition_manifest_sha256")),
        ("signed_context_manifest_sha256", required_hash(sealed.get("signed_context_manifest_sha256"), "sealed.signed_context_manifest_sha256")),
        ("runtime_manifest_sha256", required_hash(sealed.get("runtime_manifest_sha256"), "sealed.runtime_manifest_sha256")),
        ("source_manifest_sha256", source_identity),
        ("consumer_app_tree_identity_sha256", consumer_tree),
        ("mounted_app_tree_identity_sha256", mounted_tree),
    ):
        if shared.get(field) != value:
            fail(f"manifest sharedRelease {field} differs from distribution")
    if (distribution.get("dmg", {}).get("sha256") != expected[dmg_name]):
        fail("distribution DMG hash differs from SHA256SUMS")


def digest(path: Path) -> str:
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("--expected-source", default=None,
                        help="full expected application source commit from the release context job")
    parser.add_argument("--source-checkout", type=Path, default=None,
                        help="trusted checkout whose committed lock and gate scripts qualify macOS metadata")
    args = parser.parse_args()
    if args.root.is_symlink():
        raise SystemExit("release metadata root may not be a symbolic link")
    root = args.root.resolve(strict=True)
    manifest_path = root / "manifest.json"
    sums_path = root / "SHA256SUMS"
    if manifest_path.is_symlink() or sums_path.is_symlink():
        raise SystemExit("manifest and SHA256SUMS must be regular files")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if (not isinstance(manifest, dict) or type(manifest.get("schema")) is not int or
            manifest.get("schema") not in (1, 2)):
        raise SystemExit("unsupported release manifest schema")
    if args.expected_source is not None:
        if not SHA_RE.fullmatch(args.expected_source) or manifest.get("gitCommit") != args.expected_source:
            raise SystemExit("release manifest source commit differs from expected source")
    for field in ("platform", "abi", "hdrBackend", "nativeLibraryVersion"):
        if not isinstance(manifest.get(field), str) or not manifest[field].strip():
            raise SystemExit(f"release manifest has invalid {field}")
    media_kit_commit = manifest.get("mediaKitCommit")
    if not isinstance(media_kit_commit, str) or not SHA_RE.fullmatch(media_kit_commit):
        raise SystemExit("release manifest has no full immutable mediaKitCommit")
    player_commit = manifest.get("gitCommit")
    if not isinstance(player_commit, str) or not SHA_RE.fullmatch(player_commit):
        raise SystemExit("release manifest has no full player gitCommit")
    if not NATIVE_VERSION_RE.fullmatch(manifest["nativeLibraryVersion"]):
        raise SystemExit("release manifest has invalid nativeLibraryVersion")
    entries = manifest.get("files")
    if not isinstance(entries, list) or not entries:
        raise SystemExit("release manifest has no files")

    expected: dict[str, str] = {}
    for entry in entries:
        if not isinstance(entry, dict):
            raise SystemExit("release manifest contains an invalid file entry")
        relative = entry.get("path")
        if (not isinstance(relative, str) or not relative or Path(relative).is_absolute() or
                Path(relative).name != relative or "/" in relative or "\\" in relative):
            raise SystemExit(f"invalid manifest path: {relative!r}")
        if relative in expected:
            raise SystemExit(f"duplicate manifest path: {relative}")
        path = (root / relative).resolve()
        original_path = root / relative
        if original_path.is_symlink() or root not in path.parents or not path.is_file():
            raise SystemExit(f"manifest file is missing: {relative}")
        actual = digest(path)
        size = entry.get("size")
        if (actual != entry.get("sha256") or type(size) is not int or
                path.stat().st_size != size):
            raise SystemExit(f"manifest does not match file: {relative}")
        expected[relative] = actual

    observed: dict[str, str] = {}
    for line in sums_path.read_text(encoding="utf-8").splitlines():
        checksum, separator, relative = line.partition("  ")
        if not separator or not HASH_RE.fullmatch(checksum) or not relative:
            raise SystemExit(f"invalid SHA256SUMS line: {line!r}")
        if relative in observed:
            raise SystemExit(f"duplicate SHA256SUMS path: {relative}")
        observed[relative] = checksum
    if observed != expected:
        raise SystemExit("SHA256SUMS does not match manifest")
    if manifest.get("platform") == "macos":
        if args.source_checkout is None or args.expected_source is None:
            fail("macOS shared release verification requires --expected-source and --source-checkout")
        approved_media_kit, trusted_lock_sha, checkout, gate_digests = trusted_source(
            args.source_checkout, args.expected_source)
        validate_shared_release(root, manifest, expected, checkout,
                                approved_media_kit, trusted_lock_sha, gate_digests)
    elif manifest.get("schema") != 1:
        raise SystemExit("schema 2 is reserved for macOS shared releases")
    print(f"release manifest verified: {len(expected)} files")


if __name__ == "__main__":
    main()
