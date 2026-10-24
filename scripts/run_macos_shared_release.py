#!/usr/bin/env python3
"""Build and package the one approved macOS shared release chain.

The release entry is deliberately fail-closed.  It does not invoke the legacy
workflow, accept a caller-supplied media-kit revision, or publish files until
the mounted read-only DMG has passed the product's existing gates.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PREFIX = "PiliPlusX_macos_"
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SHA40 = re.compile(r"^[0-9a-f]{40}$")


class ReleaseError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def canonical_sha(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def write_json(path: Path, value: dict) -> None:
    if path.exists() or path.is_symlink():
        raise ReleaseError(f"refusing to overwrite owned report: {path}")
    path.write_text(json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8")


def run(argv: list[str], *, cwd: Path = ROOT, timeout: int = 180) -> subprocess.CompletedProcess[str]:
    result = subprocess.run([str(part) for part in argv], cwd=cwd, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode:
        raise ReleaseError(f"command failed ({result.returncode}): {argv[0]}: {result.stderr[-2000:]}")
    return result


def validate_release_source(tag: str, requested_sha: str, *, runner=run) -> dict:
    """Bind the exact full source SHA to checkout HEAD and the peeled tag."""
    if not re.fullmatch(r"v\d+\.\d+\.\d+(?:-[0-9A-Za-z][0-9A-Za-z.-]*)?", tag):
        raise ReleaseError("release tag is not an accepted vMAJOR.MINOR.PATCH tag")
    if not SHA40.fullmatch(requested_sha):
        raise ReleaseError("SOURCE_SHA must be a full 40-character commit")
    head = runner(["git", "rev-parse", "HEAD"]).stdout.strip()
    peeled = runner(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"]).stdout.strip()
    if not SHA40.fullmatch(head) or not SHA40.fullmatch(peeled):
        raise ReleaseError("checkout HEAD and peeled release tag must resolve to full commits")
    if head != requested_sha or peeled != requested_sha:
        raise ReleaseError("SOURCE_SHA, actual checkout HEAD, and peeled release tag commit must match")
    return {"source_ref": requested_sha, "release_tag": tag, "peeled_tag_commit": peeled}


def require_host(candidate, report: dict) -> None:
    if os.environ.get("GITHUB_ACTIONS") != "true":
        raise ReleaseError("production shared release requires a hosted GitHub Actions runner")
    if os.environ.get("RUNNER_OS") != "macOS" or os.environ.get("RUNNER_ARCH") != "ARM64":
        raise ReleaseError("production shared release requires the macOS ARM64 hosted runner")
    candidate.require_host(report)


def require_hosted_preflight() -> None:
    """Reject unsupported hosts before Flutter or Pub downloads."""
    if (os.environ.get("GITHUB_ACTIONS") != "true" or
            os.environ.get("RUNNER_OS") != "macOS" or
            os.environ.get("RUNNER_ARCH") != "ARM64" or
            os.environ.get("RUNNER_ENVIRONMENT") != "github-hosted" or
            sys.platform != "darwin" or platform.machine() != "arm64" or
            sys.version_info[:2] != (3, 11)):
        raise ReleaseError("production requires the hosted macOS ARM64/Python 3.11 runner")
    try:
        result = subprocess.run(["/usr/bin/arch", "-x86_64", "/usr/bin/true"],
                                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except OSError as error:
        raise ReleaseError("Rosetta preflight is unavailable") from error
    if result.returncode:
        raise ReleaseError("Rosetta x86_64 qualification failed")


def canonical_private_dir(path: Path, parent: Path) -> Path:
    if path.is_symlink() or not path.is_dir():
        raise ReleaseError(f"private path is not a canonical directory: {path}")
    canonical = path.resolve(strict=True)
    if canonical != path.absolute() or not canonical.is_relative_to(parent):
        raise ReleaseError(f"private path escaped its exclusive run directory: {path}")
    return canonical


def app_tree_identity(root: Path) -> tuple[str, dict[str, dict[str, object]]]:
    if root.is_symlink() or not root.is_dir():
        raise ReleaseError(f"application path is unsafe: {root}")
    root = root.resolve(strict=True)
    nodes: dict[str, dict[str, object]] = {".": {"type": "directory", "mode": stat.S_IMODE(root.stat().st_mode)}}

    def visit(directory: Path) -> None:
        for entry in sorted(os.scandir(directory), key=lambda item: item.name):
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            info = entry.stat(follow_symlinks=False)
            mode = info.st_mode
            if stat.S_ISLNK(mode):
                try:
                    resolved = path.resolve(strict=True)
                except (OSError, RuntimeError) as error:
                    raise ReleaseError(f"broken application symlink: {relative}") from error
                if not resolved.is_relative_to(root):
                    raise ReleaseError(f"application symlink escapes App: {relative}")
                nodes[relative] = {"type": "symlink", "target": os.readlink(path)}
            elif stat.S_ISDIR(mode):
                nodes[relative] = {"type": "directory", "mode": stat.S_IMODE(mode)}
                visit(path)
            elif stat.S_ISREG(mode):
                nodes[relative] = {"type": "file", "mode": stat.S_IMODE(mode),
                                   "bytes": info.st_size, "sha256": sha256(path)}
            else:
                raise ReleaseError(f"special node in application: {relative}")

    visit(root)
    encoded = json.dumps(nodes, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest(), nodes


def command_gate(argv: list[str], *, observed: dict | None = None,
                 runner=None) -> dict:
    runner = runner or run
    try:
        result = runner(argv)
    except BaseException as error:
        stdout = getattr(error, "stdout", "") or ""
        stderr = getattr(error, "stderr", "") or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        gate = {"argv": [str(part) for part in argv], "exit_code": None,
                "stdout_sha256": hashlib.sha256(stdout.encode("utf-8")).hexdigest(),
                "stderr_sha256": hashlib.sha256(stderr.encode("utf-8")).hexdigest(),
                "observed": observed or {}, "error": str(error)}
        failure = ReleaseError(f"mounted App gate execution failed: {argv[0]}: {error}")
        failure.gate_report = gate
        raise failure from error
    gate = {"argv": [str(part) for part in argv], "exit_code": result.returncode,
            "stdout_sha256": hashlib.sha256(result.stdout.encode("utf-8")).hexdigest(),
            "stderr_sha256": hashlib.sha256(result.stderr.encode("utf-8")).hexdigest(),
            "observed": observed or {}}
    if result.returncode != 0:
        failure = ReleaseError(f"mounted App gate failed ({result.returncode}): {argv[0]}")
        failure.gate_report = gate
        raise failure
    return gate


def final_gate_record(report: dict) -> dict:
    matches = [item for item in report.get("commands", []) if item.get("label") == "final-bundle-gate"]
    if len(matches) != 1 or matches[0].get("exit_code") != 0:
        raise ReleaseError("shared consumer did not retain exactly one passing final bundle gate")
    command = matches[0]
    return {"argv": command["argv"], "exit_code": 0,
            "stdout_sha256": hashlib.sha256(command.get("stdout", "").encode()).hexdigest(),
            "stderr_sha256": hashlib.sha256(command.get("stderr", "").encode()).hexdigest()}


def capture_gate_execution(source: dict, pipeline: dict, mounted_backend_path: Path) -> dict:
    helper_path = ROOT / "scripts/shared_gate_execution.py"
    spec = importlib.util.spec_from_file_location("shared_release_gate_execution", helper_path)
    if spec is None or spec.loader is None:
        raise ReleaseError("unable to load the source-bound gate identity helper")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    try:
        return helper.capture_gate_execution(
            ROOT.resolve(strict=True), source["source_ref"],
                python_executable=sys.executable,
            backend_inputs={
                "prepared_source": str(Path(pipeline["prepared_source"]).resolve()),
                "source_manifest": str((Path(pipeline["recipe"]) / "manifest.json").resolve()),
                "report": str(mounted_backend_path.resolve()),
            },
        )
    except (OSError, ValueError, KeyError) as error:
        raise ReleaseError(f"cannot capture source-bound gate execution identity: {error}") from error


def validate_gate_argv(gate_execution: dict, argv: object, gate_name: str,
                       app_path: str, *, consumer_app_path: str | None = None) -> None:
    helper_path = ROOT / "scripts/shared_gate_execution.py"
    spec = importlib.util.spec_from_file_location("shared_release_gate_execution", helper_path)
    if spec is None or spec.loader is None:
        raise ReleaseError("unable to load the source-bound gate identity helper")
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    try:
        helper.validate_gate_argv(argv, gate_name, gate_execution, app_path,
                                  consumer_app_path=consumer_app_path)
    except ValueError as error:
        raise ReleaseError(str(error)) from error


def resolve_distribution_data(pipeline: dict, source: dict, candidate_report: dict,
                              mounted_backend_report: Path, mounted_gates: dict,
                              mounted_identity: str, dmg_name: str, dmg_sha: str,
                              gate_execution: dict,
                              lock_sha: str) -> dict:
    app = Path(pipeline["final_app"])
    core_path = Path(pipeline["shared_core"])
    backend_path = Path(pipeline["shared_backend"])
    core = json.loads(core_path.read_text(encoding="utf-8"))
    backend = json.loads(backend_path.read_text(encoding="utf-8"))
    consumer = json.loads(Path(pipeline["consumer_result"]).read_text(encoding="utf-8"))
    consumer_app_value = consumer.get("candidate")
    if not isinstance(consumer_app_value, str) or not Path(consumer_app_value).is_absolute():
        raise ReleaseError("normal consumer result has no absolute candidate App path")
    consumer_app = Path(consumer_app_value).resolve(strict=True)
    final_app = app.resolve(strict=True)
    if consumer_app != final_app:
        raise ReleaseError("consumer result App path differs from the final consumer App")
    final_gate_path = Path(pipeline["final_gate_report_path"])
    final_gate_bytes = final_gate_path.read_bytes()
    final_gate_sha = hashlib.sha256(final_gate_bytes).hexdigest()
    if final_gate_sha != pipeline.get("final_gate_sha256"):
        raise ReleaseError("final bundle gate report changed after it was recorded")
    try:
        final_gate_value = json.loads(final_gate_bytes.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ReleaseError("final bundle gate report is not valid UTF-8 JSON") from error
    if not isinstance(final_gate_value, dict):
        raise ReleaseError("final bundle gate report is not an object")
    validate_gate_argv(gate_execution, final_gate_value.get("argv"), "final_bundle",
                       str(consumer_app), consumer_app_path=str(consumer_app))
    if consumer.get("status") != "published-candidate":
        raise ReleaseError("shared consumer result did not publish the final candidate")
    sidecar_consumer = core.get("candidate_consumer")
    if (not isinstance(sidecar_consumer, dict) or
            sidecar_consumer.get("status") != "staged-gates-passed" or
            sidecar_consumer.get("input_kind_claim") != "normal" or
            consumer.get("input_kind_claim") != "normal"):
        raise ReleaseError("shared consumer sidecar/result lacks the normal staged-to-published receipt")
    for field in ("consumer_sha256", "build_identity_sha256", "sealed_inputs_manifest_sha256"):
        if sidecar_consumer.get(field) != consumer.get(field):
            raise ReleaseError(f"consumer result and core sidecar differ at {field}")
    sealed_manifest = Path(pipeline["sealed_inputs_manifest"])
    signed_manifest = Path(pipeline["signed_context_manifest"])
    runtime_manifest = Path(pipeline["runtime_manifest"])
    acquisition_manifest = Path(pipeline["raw_acquisition_manifest"])
    recipe_manifest = Path(pipeline["recipe"]) / "manifest.json"
    source_identity = sha256(recipe_manifest)
    if core.get("complete_source", {}).get("manifest_sha256") != source_identity:
        raise ReleaseError("consumer source manifest identity differs from the approved recipe file")
    backend_results = backend.get("backend_creation_and_empty_target_render")
    if not isinstance(backend_results, dict):
        raise ReleaseError("consumer backend sidecar lacks per-ABI probe records")
    abi = {}
    for architecture in ("arm64", "x86_64"):
        entry = backend_results.get(architecture)
        if not isinstance(entry, dict) or entry.get("exit_code") != 0:
            raise ReleaseError(f"consumer backend probe failed or is missing for {architecture}")
        abi[architecture] = {"probe_exit_code": entry["exit_code"],
                             "report_sha256": sha256(backend_path)}
    runner_sha = core.get("runner_sha256")
    mpv_sha = core.get("framework_sha256")
    build_identity = core.get("build_identity_sha256")
    sealed_identity = core.get("candidate_consumer", {}).get("sealed_inputs_manifest_sha256")
    if not all(isinstance(value, str) and SHA256.fullmatch(value)
               for value in (runner_sha, mpv_sha, build_identity, sealed_identity)):
        raise ReleaseError("consumer core sidecar is missing bound product identities")
    if consumer.get("build_identity_sha256") != build_identity:
        raise ReleaseError("consumer result and core sidecar build identities differ")
    if consumer.get("sealed_inputs_manifest_sha256") != sealed_identity:
        raise ReleaseError("consumer result and core sidecar sealed-input identities differ")
    if mounted_backend_report.is_symlink() or not mounted_backend_report.is_file():
        raise ReleaseError("mounted backend report is missing")
    mounted_backend = json.loads(mounted_backend_report.read_text(encoding="utf-8"))
    mounted_abi = mounted_backend.get("backend_creation_and_empty_target_render", {})
    for architecture in ("arm64", "x86_64"):
        if mounted_abi.get(architecture, {}).get("exit_code") != 0:
            raise ReleaseError(f"mounted App CGL/backend probe failed for {architecture}")
    if mounted_backend.get("framework_sha256") != mpv_sha:
        raise ReleaseError("mounted App backend report is not bound to the consumer Mpv framework")
    if mounted_backend.get("manifest_sha256") != source_identity:
        raise ReleaseError("mounted App backend report is not bound to the exact source manifest")
    expected_mounted_gates = {"codesign", "bundle", "arm64", "x86_64", "backend"}
    if set(mounted_gates) != expected_mounted_gates:
        raise ReleaseError("mounted App gate set differs from the required signature/bundle/ABI/backend gates")
    mounted_app_path = pipeline.get("mounted_app_path")
    if not isinstance(mounted_app_path, str) or not Path(mounted_app_path).is_absolute():
        raise ReleaseError("mounted App canonical path is missing")
    for name, gate in mounted_gates.items():
        argv = gate.get("argv") if isinstance(gate, dict) else None
        if (not isinstance(argv, list) or not argv or gate.get("exit_code") != 0 or
                not any(isinstance(argument, str) and
                        (argument == mounted_app_path or argument.startswith(mounted_app_path + os.sep))
                        for argument in argv)):
            raise ReleaseError(f"mounted App gate {name} does not prove a passing check of the mounted App")
        validate_gate_argv(gate_execution, argv, name, mounted_app_path)
        observed = gate.get("observed")
        if (not isinstance(observed, dict) or observed.get("pending_absent") is not True or
                observed.get("shared_renderer_enabled") is not True or
                observed.get("runner_sha256") != runner_sha or observed.get("mpv_sha256") != mpv_sha or
                observed.get("app_tree_identity_sha256") != mounted_identity):
            raise ReleaseError(f"mounted App gate {name} lacks verified mounted product identities")
    return {
        "schema_version": 2,
        "gate_execution": gate_execution,
        "status": "ready",
        "production_eligible": True,
        "eligibility": {"enabled": True, "missing": []},
        "source": source,
        "approved_media_kit_revision": candidate_report["approved_media_kit_revision"],
        "lock": {"path": "scripts/macos-shared-ci-inputs.lock.json", "sha256": lock_sha},
        "build": {"identity_sha256": build_identity, "runner_sha256": runner_sha,
                  "mpv_sha256": mpv_sha},
        "sealed": {"input_manifest_sha256": sha256(sealed_manifest),
                   "acquisition_manifest_sha256": sha256(acquisition_manifest),
                   "signed_context_manifest_sha256": sha256(signed_manifest),
                   "runtime_manifest_sha256": sha256(runtime_manifest)},
        "source_manifest": {"identity_sha256": source_identity},
        "consumer": {"shared_core_sha256": sha256(core_path),
                     "shared_backend_sha256": sha256(backend_path),
                     "app_path": str(consumer_app),
                     "app_tree_identity_sha256": pipeline["app_tree_identity_sha256"],
                     "status": consumer["status"],
                     "result_report": {"utf8": Path(pipeline["consumer_result"]).read_bytes().decode("utf-8"),
                                       "sha256": sha256(Path(pipeline["consumer_result"]))},
                     "backend_gates": {
                         **abi,
                         "final_bundle": {"exit_code": 0,
                                          "report_sha256": final_gate_sha,
                                          "report": {"utf8": final_gate_bytes.decode("utf-8"),
                                                     "sha256": final_gate_sha}},
                         "pending_absent": True,
                         "shared_renderer_enabled": True}},
        "mounted_app": {"app_path": pipeline["mounted_app_path"],
                        "tree_identity_sha256": mounted_identity,
                        "runner_sha256": runner_sha,
                        "mpv_sha256": mpv_sha,
                        "build_identity_sha256": build_identity,
                        "sealed_input_manifest_sha256": sealed_identity,
                        "runtime_manifest_sha256": sha256(runtime_manifest),
                        "acquisition_manifest_sha256": sha256(acquisition_manifest),
                        "signed_context_manifest_sha256": sha256(signed_manifest),
                        "source_manifest_sha256": source_identity,
                        "consumer_app_tree_identity_sha256": pipeline["app_tree_identity_sha256"],
                        "mounted_app_tree_identity_sha256": mounted_identity,
                        "pending_absent": True,
                        "shared_renderer_enabled": True,
                        "gates": mounted_gates},
        "dmg": {"filename": dmg_name, "sha256": dmg_sha},
    }


def package_release(pipeline: dict, source: dict, candidate_report: dict,
                    report: dict, release_tag: str, run_dir: Path,
                    output_dir: Path, lock_sha: str,
                    expected_gate_execution: dict | None = None) -> list[Path]:
    final_app = Path(pipeline["final_app"])
    app_identity, app_nodes = app_tree_identity(final_app)
    pipeline["app_tree_identity_sha256"] = app_identity
    mounted_backend_path = run_dir / "mounted-backend.json"
    gate_execution = capture_gate_execution(source, pipeline, mounted_backend_path)
    if expected_gate_execution is not None and gate_execution != expected_gate_execution:
        raise ReleaseError("gate execution identity changed between pipeline start and mounted gates")
    final_consumer_app = str(final_app.resolve(strict=True))
    gate = final_gate_record(candidate_report)
    validate_gate_argv(gate_execution, gate["argv"], "final_bundle",
                       final_consumer_app, consumer_app_path=final_consumer_app)
    report["gate_execution"] = gate_execution
    pipeline["final_gate_sha256"] = ""
    gate_path = run_dir / "final-bundle-gate.json"
    write_json(gate_path, gate)
    pipeline["final_gate_sha256"] = sha256(gate_path)
    pipeline["final_gate_report_path"] = str(gate_path)
    temp_source = run_dir / "dmg-source"
    temp_source.mkdir(mode=0o700)
    staged_app = temp_source / final_app.name
    run(["/usr/bin/ditto", str(final_app), str(staged_app)])
    staged_identity, _ = app_tree_identity(staged_app)
    if staged_identity != app_identity:
        raise ReleaseError("private DMG source copy differs from the final consumer App")
    dmg_stage = run_dir / f"{PREFIX}{release_tag}.dmg"
    run(["/usr/bin/hdiutil", "create", "-quiet", "-fs", "APFS", "-format", "UDZO",
         "-volname", "PiliPlusX", "-srcfolder", str(temp_source), "-ov", str(dmg_stage)])
    if not dmg_stage.is_file() or dmg_stage.is_symlink():
        raise ReleaseError("DMG creation did not produce a regular disk image")
    mount = run_dir / "mounted-volume"
    mount.mkdir(mode=0o700)
    if any(mount.iterdir()):
        raise ReleaseError("exclusive DMG mount directory is not empty")
    mounted = False
    attach_attempted = False
    device = None
    primary_error = None
    detach_error = None
    mounted_gates: dict[str, dict] = {}
    mounted_identity = ""
    try:
        attach_attempted = True
        attached = run(["/usr/bin/hdiutil", "attach", "-readonly", "-nobrowse", "-owners", "on",
                        "-plist", "-mountpoint", str(mount), str(dmg_stage)])
        mounted = True
        try:
            entities = plistlib.loads(attached.stdout.encode())["system-entities"]
        except Exception as error:
            raise ReleaseError("hdiutil did not return a parseable read-only mount receipt") from error
        matching = [entity for entity in entities if entity.get("mount-point") == str(mount)]
        if len(matching) != 1 or not matching[0].get("dev-entry"):
            raise ReleaseError("DMG mount receipt does not identify one exclusive device/mountpoint")
        device = matching[0]["dev-entry"]
        children = list(mount.iterdir())
        apps = [child for child in children if child.name.endswith(".app") and child.is_dir()]
        if len(apps) != 1 or len(children) != 1 or apps[0].name != final_app.name:
            raise ReleaseError("mounted DMG must contain exactly the final App and no other files")
        mounted_app = apps[0]
        mounted_identity, mounted_nodes = app_tree_identity(mounted_app)
        if mounted_nodes != app_nodes:
            raise ReleaseError("mounted DMG App differs in bytes, permissions, directories, or links")
        info = plistlib.loads((mounted_app / "Contents/Info.plist").read_bytes())
        observed = {"pending_absent": "MediaKitSharedBootstrapPending" not in info,
                    "shared_renderer_enabled": info.get("MediaKitSharedRenderer") is True,
                    "runner_sha256": sha256(mounted_app / "Contents/MacOS" / info["CFBundleExecutable"]),
                    "mpv_sha256": sha256(mounted_app / "Contents/Frameworks/Mpv.framework/Versions/A/Mpv"),
                    "app_tree_identity_sha256": mounted_identity}
        if not observed["pending_absent"] or not observed["shared_renderer_enabled"]:
            raise ReleaseError("mounted App pending/shared-renderer Info.plist gate failed")
        execution_root = Path(gate_execution["producer_checkout_root"])
        execution_python = gate_execution["python_executable"]
        backend_inputs = gate_execution["backend_inputs"]
        gates = [
            ("codesign", ["/usr/bin/codesign", "--verify", "--deep", "--strict", str(mounted_app)]),
            ("bundle", [str(execution_root / "scripts/verify_macos_mpv_bundle.sh"), str(mounted_app)]),
            ("arm64", [execution_python, str(execution_root / "scripts/verify_binary_arch.py"),
                        str(mounted_app / "Contents/MacOS" / info["CFBundleExecutable"]),
                        "--platform", "macos", "--arch", "arm64"]),
            ("x86_64", [execution_python, str(execution_root / "scripts/verify_binary_arch.py"),
                        str(mounted_app / "Contents/MacOS" / info["CFBundleExecutable"]),
                        "--platform", "macos", "--arch", "x86_64"]),
        ]
        for name, argv in gates:
            try:
                mounted_gates[name] = command_gate(argv, observed=observed)
            except ReleaseError as error:
                mounted_gates[name] = getattr(error, "gate_report", {"argv": argv, "error": str(error)})
                report["mounted_app"] = {"app_path": str(mounted_app.resolve(strict=True)),
                                         "tree_identity_sha256": mounted_identity,
                                         "gates": mounted_gates}
                raise
        backend_argv = [execution_python, str(execution_root / "scripts/verify_macos_shared_backend.py"),
                        str(mounted_app), backend_inputs["prepared_source"],
                        backend_inputs["source_manifest"], "--report", backend_inputs["report"]]
        try:
            mounted_gates["backend"] = command_gate(backend_argv, observed=observed, runner=run)
        except ReleaseError as error:
            mounted_gates["backend"] = getattr(error, "gate_report", {"argv": backend_argv, "error": str(error)})
            report["mounted_app"] = {"app_path": str(mounted_app.resolve(strict=True)),
                                     "tree_identity_sha256": mounted_identity,
                                     "gates": mounted_gates}
            raise
        report["mounted_app"] = {"path": str(mounted_app), "tree_identity_sha256": mounted_identity,
                                 "gates": mounted_gates}
        pipeline["mounted_app_path"] = str(mounted_app.resolve(strict=True))
    except BaseException as error:
        primary_error = error
    finally:
        if mounted or attach_attempted:
            if not device:
                try:
                    inventory = run(["/usr/bin/hdiutil", "info", "-plist"])
                    entities = plistlib.loads(inventory.stdout.encode()).get("images", [])
                    matches = [item for image in entities for item in image.get("system-entities", [])
                               if item.get("mount-point") == str(mount)]
                    if len(matches) == 1 and matches[0].get("dev-entry"):
                        device = matches[0]["dev-entry"]
                        mounted = True
                    elif matches:
                        detach_error = ReleaseError("hdiutil inventory has ambiguous owned mount devices")
                    elif any(mount.iterdir()):
                        detach_error = ReleaseError("possible partial DMG mount has content but no safe device identity")
                except BaseException as error:
                    detach_error = ReleaseError(f"unable to inspect possibly partial DMG mount: {error}")
            if not device:
                if detach_error is None and mounted:
                    detach_error = ReleaseError("mounted DMG has no safe detach device identity")
            elif mounted:
                try:
                    detached = run(["/usr/bin/hdiutil", "detach", device])
                    if any(mount.iterdir()):
                        raise ReleaseError("DMG mount directory is not empty after detach")
                    report["mount_cleanup"] = {"argv": ["/usr/bin/hdiutil", "detach", device],
                                               "exit_code": detached.returncode, "status": "detached"}
                except BaseException as error:
                    detach_error = error
                    report["mount_cleanup"] = {"argv": ["/usr/bin/hdiutil", "detach", device],
                                               "status": "failed", "error": str(error)}
        if primary_error is not None and detach_error is not None:
            raise ReleaseError(f"release gate failed: {primary_error}; DMG detach also failed: {detach_error}") from primary_error
        if primary_error is not None:
            raise primary_error
        if detach_error is not None:
            raise ReleaseError(f"DMG detach failed after mounted gate sequence: {detach_error}") from detach_error
    final_gate_execution = capture_gate_execution(source, pipeline, mounted_backend_path)
    if final_gate_execution != gate_execution:
        raise ReleaseError("trusted gate execution identity changed between gates and publication")
    dmg_sha = sha256(dmg_stage)
    output_dir.mkdir(parents=True, exist_ok=False)
    prefix = f"{PREFIX}{release_tag}"
    output_dmg = output_dir / f"{prefix}.dmg"
    output_core = output_dir / f"{prefix}.shared-core.json"
    output_backend = output_dir / f"{prefix}.shared-backend.json"
    output_distribution = output_dir / f"{prefix}.shared-distribution.json"
    shutil.copy2(dmg_stage, output_dmg)
    shutil.copyfile(pipeline["shared_core"], output_core)
    shutil.copyfile(pipeline["shared_backend"], output_backend)
    if sha256(output_dmg) != dmg_sha:
        raise ReleaseError("published DMG bytes differ from the mounted/gated disk image")
    for original, published in ((Path(pipeline["shared_core"]), output_core),
                                (Path(pipeline["shared_backend"]), output_backend)):
        if original.read_bytes() != published.read_bytes():
            raise ReleaseError("published shared sidecar bytes changed")
    distribution = resolve_distribution_data(pipeline, source, candidate_report,
                                             mounted_backend_path, mounted_gates,
                                             mounted_identity, output_dmg.name, dmg_sha,
                                             gate_execution, lock_sha)
    write_json(output_distribution, distribution)
    report["artifact"] = {"directory": str(output_dir), "files": [p.name for p in
                           (output_dmg, output_core, output_backend, output_distribution)],
                           "distribution_sha256": sha256(output_distribution)}
    return [output_dmg, output_core, output_backend, output_distribution]


def run_release(*, release_tag: str, source_sha: str, runner_temp: Path,
                run_id: str, attempt: str, output_dir: Path | None = None,
                preflight_only: bool = False, candidate_module=None) -> dict:
    if candidate_module is None:
        spec = importlib.util.spec_from_file_location("shared_candidate",
                ROOT / "scripts/run_macos_shared_ci_candidate.py")
        if spec is None or spec.loader is None:
            raise ReleaseError("unable to load the reviewed shared pipeline hook")
        candidate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(candidate)
    else:
        candidate = candidate_module
    report = {"schema_version": 1, "status": "preflight", "commands": [],
              "source": {"release_tag": release_tag}, "mode": "production-shared-release"}
    run_dir = None
    try:
        # Create an exclusive diagnostics/run location before any failure can
        # need reporting; never fall back to a caller-controlled path.
        run_dir, report_path = candidate.owned_runner_paths(runner_temp, run_id, attempt)
        report.update(run_dir=str(run_dir), report_path=str(report_path))
        candidate.save_report(report)
        revision = candidate.load_approved_revision()
        source = validate_release_source(release_tag, source_sha)
        report["source"] = source
        report["approved_media_kit_revision"] = revision
        report["lock_sha256"] = sha256(candidate.LOCK)
        require_hosted_preflight()
        if preflight_only:
            report["status"] = "preflight-passed"
            candidate.save_report(report)
            shutil.rmtree(report_path.parent)
            shutil.rmtree(run_dir)
            shutil.rmtree(run_dir.parent)
            return report
        require_host(candidate, report)
        names = set()
        for manifest in (ROOT / "pubspec.yaml", ROOT / "pubspec.lock"):
            names.update(re.findall(r"(?m)^  (media_kit(?:[^:]*)):\s*$",
                                   manifest.read_text(encoding="utf-8")))
        if not names:
            raise ReleaseError("no media-kit packages in source dependency declarations")
        report["media_kit_package_names"] = sorted(names)
        planned_pipeline = {
            "prepared_source": str((run_dir / "shared-work/source").resolve()),
            "recipe": str((run_dir / "media-kit/tool/shared_gpu_next").resolve()),
        }
        gate_execution = capture_gate_execution(
            source, planned_pipeline, run_dir / "mounted-backend.json")
        report["gate_execution"] = gate_execution
        report["status"] = "building"
        candidate.save_report(report)
        candidate_result = candidate.run_pipeline(report, source_sha, revision, production_release=True)
        output_dir = output_dir or (run_dir / "distribution")
        if output_dir.is_symlink() or output_dir.exists():
            raise ReleaseError("release output directory already exists or is a symlink")
        if not output_dir.absolute().is_relative_to(run_dir.resolve(strict=True)):
            raise ReleaseError("release output must remain under the exclusive RUNNER_TEMP run directory")
        report["pipeline_result"] = candidate_result
        report["status"] = "product-gates-passed"
        candidate.save_report(report)
        json.loads(Path(candidate_result["shared_core"]).read_text(encoding="utf-8"))
        report["pipeline_result"]["app_tree_identity_sha256"] = app_tree_identity(Path(candidate_result["final_app"]))[0]
        final_gate = final_gate_record(report)
        final_gate_path = Path(candidate_result["artifact_directory"]) / "final-bundle-gate.json"
        write_json(final_gate_path, final_gate)
        report["pipeline_result"]["final_gate_sha256"] = sha256(final_gate_path)
        artifact_files = package_release(candidate_result, source, report, report,
                                         release_tag, run_dir, output_dir, sha256(candidate.LOCK),
                                         expected_gate_execution=gate_execution)
        report["status"] = "ready"
        report["artifact_files"] = [str(path) for path in artifact_files]
        candidate.save_report(report)
        return report
    except Exception as error:
        report["status"] = "blocked" if "unavailable" in str(error) or "requires" in str(error) else "failed"
        report["error"] = str(error)
        if run_dir is not None:
            artifact = run_dir / "artifact"
            if artifact.exists() and artifact.is_dir() and not artifact.is_symlink():
                shutil.rmtree(artifact)
            if output_dir is not None and output_dir.is_relative_to(run_dir) and output_dir.exists() and output_dir.is_dir() and not output_dir.is_symlink():
                shutil.rmtree(output_dir)
            candidate.save_report(report)
        raise


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preflight", action="store_true")
    args = parser.parse_args(argv)
    tag = os.environ.get("PILIPLUSX_RELEASE_TAG", "")
    source_sha = os.environ.get("PILIPLUSX_SOURCE_SHA", "")
    if not source_sha:
        source_sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=True).stdout.strip()
    try:
        report = run_release(release_tag=tag, source_sha=source_sha,
                             runner_temp=Path(os.environ.get("RUNNER_TEMP", "")),
                             run_id=os.environ.get("GITHUB_RUN_ID", "0"),
                             attempt=os.environ.get("GITHUB_RUN_ATTEMPT", "1"),
                             output_dir=None,
                             preflight_only=args.preflight)
    except Exception as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 2
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
