#!/usr/bin/env python3
"""Acquire only the Linux payload and evidence artifacts selected by CORE."""
from __future__ import annotations

import argparse
from datetime import datetime
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import threading
import zipfile

import verify_routing_linux_native as gate

MAX_RESPONSE = gate.MAX_ZIP


def timestamp(value: object) -> datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise gate.GateError("GitHub artifact metadata is missing a UTC timestamp")
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise gate.GateError("invalid GitHub artifact UTC timestamp") from error


class GitHub:
    def __init__(self, receipt: dict):
        self.receipt = receipt

    def request(self, endpoint: str, destination: Path, limit: int = MAX_RESPONSE) -> Path:
        command = ["gh", "api", "--method", "GET", endpoint]
        step = {"argv": command, "exitCode": None}
        self.receipt["commands"].append(step)
        errors, stderr_chunks = [], []
        try:
            with destination.open("xb") as output:
                process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

                def drain(pipe, sink, maximum, diagnostic=False):
                    total = 0
                    try:
                        while chunk := pipe.read(65536):
                            total += len(chunk)
                            if total > maximum:
                                raise gate.GateError("GitHub response exceeds streaming limit")
                            if diagnostic:
                                stderr_chunks.append(chunk)
                            else:
                                sink.write(chunk)
                    except Exception as error:
                        errors.append(error)
                        try:
                            process.kill()
                        except ProcessLookupError:
                            pass
                    finally:
                        pipe.close()

                workers = [threading.Thread(target=drain, args=(process.stdout, output, limit)),
                           threading.Thread(target=drain, args=(process.stderr, None, 256 * 1024, True))]
                for worker in workers:
                    worker.start()
                try:
                    process.wait(timeout=60)
                except subprocess.TimeoutExpired as error:
                    errors.append(error)
                    process.kill()
                    process.wait()
                for worker in workers:
                    worker.join()
        except OSError as error:
            step["error"] = str(error)
            raise gate.GateError(f"GitHub API request could not start: {endpoint}") from error
        step.update(exitCode=process.returncode,
                    stderr=b"".join(stderr_chunks).decode("utf-8", "replace"))
        if errors:
            step["error"] = str(errors[0])
            raise gate.GateError(f"GitHub API request failed: {endpoint}: {errors[0]}")
        if process.returncode != 0 or step["stderr"].strip():
            raise gate.GateError(f"GitHub API request failed: {endpoint}: exit {process.returncode}")
        return destination

    def metadata(self, endpoint: str, private_root: Path, label: str) -> dict:
        path = self.request(endpoint, private_root / f"{label}.json", 4 * 1024 * 1024)
        value, _ = gate.read_json(path, "GitHub response")
        return value


def validate_metadata(spec: dict, metadata: dict, jobs: list[dict]) -> None:
    if metadata.get("id") != spec["artifactId"] or metadata.get("name") != spec["name"] or metadata.get("expired") is not False:
        raise gate.GateError("artifact ID/name/expiry differs from accepted ledger")
    if metadata.get("digest") != "sha256:" + spec["zipSha256"]:
        raise gate.GateError("GitHub artifact digest differs from accepted ledger")
    if type(metadata.get("size_in_bytes")) is not int or not 0 < metadata["size_in_bytes"] <= MAX_RESPONSE:
        raise gate.GateError("GitHub artifact size is invalid")
    run = metadata.get("workflow_run", {})
    if run.get("id") != spec["runId"] or run.get("head_sha") != spec["headSha"]:
        raise gate.GateError("artifact producer run/HEAD mismatch")
    matches = [job for job in jobs if job.get("id") == spec["uploadJobId"]]
    if len(matches) != 1:
        raise gate.GateError("accepted upload job missing or ambiguous in exact attempt")
    job = matches[0]
    if (job.get("id") != spec["uploadJobId"] or job.get("run_id") != spec["runId"] or
            job.get("run_attempt") != spec["attempt"] or job.get("head_sha") != spec["headSha"] or
            job.get("status") != "completed" or job.get("conclusion") != "success"):
        raise gate.GateError("artifact upload job does not match accepted successful run attempt")
    if not timestamp(job.get("started_at")) <= timestamp(metadata.get("created_at")) <= timestamp(job.get("completed_at")):
        raise gate.GateError("artifact creation timestamp is outside accepted upload job")


def artifact_api(transport: GitHub, spec: dict, root: Path, label: str) -> tuple[dict, Path]:
    prefix = f"repos/{spec['repository']}/actions"
    metadata = transport.metadata(f"{prefix}/artifacts/{spec['artifactId']}", root, f"{label}-artifact")
    jobs = []
    page = 1
    while True:
        response = transport.metadata(
            f"{prefix}/runs/{spec['runId']}/attempts/{spec['attempt']}/jobs?per_page=100&page={page}",
            root, f"{label}-jobs-{page}")
        batch = response.get("jobs")
        total = response.get("total_count")
        if not isinstance(batch, list) or type(total) is not int or total < 0:
            raise gate.GateError("invalid GitHub attempt jobs response")
        jobs.extend(batch)
        if len(jobs) >= total:
            break
        if not batch or page >= 100:
            raise gate.GateError("incomplete/bounded GitHub attempt jobs pagination")
        page += 1
    validate_metadata(spec, metadata, jobs)
    archive = transport.request(f"{prefix}/artifacts/{spec['artifactId']}/zip",
                                root / f"{label}.zip", MAX_RESPONSE)
    if archive.stat().st_size != metadata["size_in_bytes"] or gate.file_digest(archive) != spec["zipSha256"]:
        raise gate.GateError("downloaded ZIP size/hash differs from accepted artifact metadata")
    return metadata, archive


def inspect_archive(path: Path, expected_names: set[str] | None = None) -> set[str]:
    names = set()
    total = 0
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if not entries or len(entries) > 100000:
            raise gate.GateError("artifact ZIP is empty or has too many entries")
        for item in entries:
            name = item.filename
            if item.orig_filename != name or item.is_dir() or item.flag_bits & 1 or stat.S_ISLNK(item.external_attr >> 16):
                raise gate.GateError("artifact ZIP directory/symlink/encryption/ambiguous path forbidden")
            name = gate.relative(name, "artifact member")
            if name in names:
                raise gate.GateError("duplicate artifact ZIP member")
            names.add(name)
            if expected_names is not None and name not in expected_names:
                raise gate.GateError("artifact ZIP contains undeclared member")
            if item.file_size > gate.MAX_FILE or item.file_size > max(1, item.compress_size) * 250:
                raise gate.GateError("artifact ZIP member exceeds size/ratio limits")
            total += item.file_size
            if total > MAX_RESPONSE:
                raise gate.GateError("artifact ZIP total expansion exceeds limit")
    if expected_names is not None and names != expected_names:
        raise gate.GateError("artifact ZIP member set differs from expected closure")
    return names


def read_zip_member(path: Path, name: str, limit: int) -> bytes:
    with zipfile.ZipFile(path) as archive:
        matches = [item for item in archive.infolist() if item.filename == name]
        if len(matches) != 1:
            raise gate.GateError(f"artifact ZIP requires exactly one {name}")
        info = matches[0]
        if info.file_size > limit:
            raise gate.GateError(f"artifact member exceeds bounded read: {name}")
        with archive.open(info) as source:
            data = source.read(limit + 1)
        if len(data) != info.file_size or len(data) > limit:
            raise gate.GateError(f"artifact member size/CRC mismatch: {name}")
        return data


def validate_manifest_against_ledger(manifest: dict, raw: bytes, entry: dict) -> dict:
    manifest = gate.validate_manifest(manifest)
    artifact = manifest["artifact"]
    if (gate.digest(raw) != entry["manifestSha256"] or
            gate.closure_hash(manifest) != entry["sourceClosureSha256"] or
            artifact["sha256"] != entry["payloadSha256"] or
            artifact["identity"] != {"repository": entry["producer"]["repository"],
                                     "runId": entry["producer"]["runId"],
                                     "attempt": entry["producer"]["attempt"],
                                     "artifactId": entry["producer"]["artifactId"]} or
            artifact["name"] != entry["producer"]["name"]):
        raise gate.GateError("manifest does not match the explicit CORE-selected acceptance")
    return manifest


def fresh_output(output: Path) -> Path:
    runner_temp_value = os.environ.get("RUNNER_TEMP")
    if not runner_temp_value:
        raise gate.GateError("RUNNER_TEMP is required for Linux native acquisition")
    runner_temp = Path(runner_temp_value).resolve(strict=True)
    if output.is_symlink() or output.exists() or not output.is_absolute():
        raise gate.GateError("output must be a fresh absolute path")
    resolved_parent = output.parent.resolve(strict=True)
    if not resolved_parent.is_relative_to(runner_temp):
        raise gate.GateError("output must be a fresh child beneath RUNNER_TEMP")
    current = output.parent
    while current != runner_temp and current != current.parent:
        if current.is_symlink():
            raise gate.GateError("output parent contains a symbolic link")
        current = current.parent
    return runner_temp


def acquire(output: Path, receipt_path: Path, app_root: Path, media_kit_root: Path,
            readelf: str, receipt: dict, transport: GitHub | None = None) -> None:
    receipt.update(schemaVersion=1, task=gate.TASK, scope="routing-linux-native-input",
                   stage="selection", status="failed", nativeVerified=False,
                   deviceVerified=False, commands=[])
    app, app_head, ledger, _ = gate.trusted_app(app_root, receipt)
    entry = gate.selected_entry(ledger)
    media_root_text, media_head = gate.trusted_checkout(media_kit_root, "media-kit", receipt)
    if Path(media_root_text) != media_kit_root.resolve(strict=True):
        raise gate.GateError("media-kit root does not match trusted Git top-level")
    consumer_closure = gate.require_consumer_source_closure(app, Path(media_root_text),
                                                            entry["consumerSourceClosure"])
    consumer = {"appCommit": app_head, "mediaKitCommit": media_head,
                "sourceClosureSha256": consumer_closure["sha256"]}
    receipt["consumer"] = consumer
    root = output.absolute()
    temp = fresh_output(root)
    root.mkdir(mode=0o700)
    private = Path(tempfile.mkdtemp(prefix="routing-linux-native-acquire-", dir=temp))
    transport = transport or GitHub(receipt)
    receipt["stage"] = "acquire-evidence-artifact"
    _, b_zip = artifact_api(transport, entry["evidenceArtifact"], private, "evidence")
    b_names = inspect_archive(b_zip)
    raw_manifest = read_zip_member(b_zip, "manifest.json", 4 * 1024 * 1024)
    manifest = validate_manifest_against_ledger(gate.json_bytes(raw_manifest, "producer manifest"), raw_manifest, entry)
    expected_b = {"manifest.json"} | {"evidence/" + item["path"] for item in manifest["evidence"]}
    inspect_archive(b_zip, expected_b)
    evidence_stage = private / "evidence-unpacked"
    gate.safe_extract_zip(b_zip, evidence_stage, expected_b)
    receipt["stage"] = "acquire-payload-artifact"
    _, a_zip = artifact_api(transport, entry["producer"], private, "payload")
    payload_names = set(manifest["members"]) | set(manifest["headers"])
    inspect_archive(a_zip, payload_names)
    # Preserve the exact accepted archive bytes for independent local revalidation.
    payload_copy = root / "payload.zip"
    payload_copy.write_bytes(a_zip.read_bytes())
    gate.safe_extract_zip(a_zip, root, payload_names)
    provenance = root / "provenance"
    provenance.mkdir(mode=0o700)
    (provenance / "manifest.json").write_bytes(raw_manifest)
    evidence_root = provenance / "evidence"
    evidence_root.mkdir(mode=0o700)
    for item in manifest["evidence"]:
        source = evidence_stage / "evidence" / item["path"]
        target = evidence_root / item["path"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())
    native = {"manifestSha256": entry["manifestSha256"],
              "sourceClosureSha256": entry["sourceClosureSha256"],
              "payloadSha256": entry["payloadSha256"],
              "producer": entry["producer"], "evidenceArtifact": entry["evidenceArtifact"]}
    acquisition_receipt = {"schemaVersion": 1, "task": gate.TASK,
        "scope": "routing-linux-native-input", "stage": "acquired", "status": "acquired",
        "nativeVerified": False, "deviceVerified": False, "consumer": consumer,
        "native": native, "verifierSha256": gate.digest((app / gate.SELF_REL).read_bytes()),
        "files": {"members": {}, "headers": {}}, "commands": list(receipt["commands"])}
    receipt_path.parent.mkdir(parents=True, exist_ok=True)
    receipt_path.write_text(json.dumps(acquisition_receipt, indent=2) + "\n", encoding="utf-8")
    # Re-read the fixed ledger and every payload member using the exact helper from this App HEAD.
    gate_receipt = {"commands": list(receipt["commands"])}
    gate.verify_local(root, receipt_path, app, Path(media_root_text), readelf,
                      gate_receipt, write_cmake=None)
    receipt.update(gate_receipt)
    receipt["stage"] = "verified-input"
    receipt["status"] = "passed"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--app-root", type=Path, required=True)
    parser.add_argument("--media-kit-root", type=Path, required=True)
    parser.add_argument("--readelf", default="readelf")
    args = parser.parse_args()
    receipt = {"schemaVersion": 1, "task": gate.TASK,
               "scope": "routing-linux-native-input", "stage": "selection",
               "status": "failed", "nativeVerified": False, "deviceVerified": False,
               "commands": []}
    try:
        acquire(args.output, args.receipt, args.app_root, args.media_kit_root,
                args.readelf, receipt)
        code = 0
    except Exception as error:
        receipt.update(stage="failed", status="failed", nativeVerified=False,
                       deviceVerified=False, reason=str(error))
        code = 1
    try:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
    except OSError as error:
        print(f"Linux acquisition receipt write failed: {error}", file=sys.stderr)
        return 1
    print(f"routing Linux native acquisition: {receipt['status']} ({receipt['stage']})")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
