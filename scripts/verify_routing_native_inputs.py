#!/usr/bin/env python3
"""Fail closed on unreviewed routing Android native inputs; never attest display output."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib
from pathlib import Path, PurePosixPath

from verify_artifact import verify_android_archive

TASK = "MK-ROUTING-20261011"
MEMBERS = tuple(f"lib/arm64-v8a/{name}" for name in
                ("libmpv.so", "libmediakitandroidhelper.so", "libc++_shared.so"))
COMPONENTS = {"FFmpeg", "mpv", "libplacebo", "helper", "recipe"}
VULKAN = {"vkGetPhysicalDeviceProperties2", "vkGetPhysicalDeviceQueueFamilyProperties2"}
ACCEPTED = Path(__file__).resolve().parents[1] / "docs/plans/routing-native-accepted-inputs.json"
HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")


class GateError(ValueError):
    pass


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def file_digest(path: Path) -> str:
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def keys(value: object, required: set[str], location: str) -> dict:
    if not isinstance(value, dict) or set(value) != required:
        raise GateError(f"{location}: expected exactly {sorted(required)}")
    return value


def text(value: object, location: str) -> str:
    if not isinstance(value, str) or not value.strip() or value != value.strip() or any(ord(c) < 32 for c in value):
        raise GateError(f"{location}: nonempty string required")
    return value


def sha(value: object, location: str, length: int = 64) -> str:
    if not isinstance(value, str) or not (HEX40 if length == 40 else HEX64).fullmatch(value):
        raise GateError(f"{location}: lowercase SHA-{length} required")
    return value


def relative(value: object, location: str) -> str:
    value = text(value, location)
    parts = PurePosixPath(value)
    if "\\" in value or value.startswith("/") or any(p in ("", ".", "..") for p in value.split("/")) or ":" in value:
        raise GateError(f"{location}: unsafe relative path")
    if str(parts) != value:
        raise GateError(f"{location}: noncanonical path")
    return value


def read_json(path: Path) -> tuple[dict, bytes]:
    if not path.is_file() or path.is_symlink():
        raise GateError(f"JSON input missing or symbolic link: {path}")
    raw = path.read_bytes()
    if len(raw) > 4 * 1024 * 1024:
        raise GateError("JSON input exceeds size limit")
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise GateError(f"duplicate JSON field: {key}")
            result[key] = value
        return result
    try:
        return json.loads(raw, object_pairs_hook=unique), raw
    except (UnicodeError, json.JSONDecodeError) as error:
        raise GateError(f"invalid JSON: {error}") from error


def identity(value: object) -> dict:
    value = keys(value, {"repository", "runId", "artifactId", "attempt"}, "artifact identity")
    if not re.fullmatch(r"Goodwu/[A-Za-z0-9_.-]+", text(value["repository"], "repository")):
        raise GateError("artifact repository must identify the Goodwu producer")
    for field in ("runId", "artifactId", "attempt"):
        if type(value[field]) is not int or value[field] < 1:
            raise GateError(f"artifact identity {field}: positive integer required")
    return value


def validate_manifest(value: object) -> dict:
    value = keys(value, {"schemaVersion", "task", "platform", "artifact", "components", "toolchain", "staging", "linkInputs", "evidence", "members"}, "manifest")
    if type(value["schemaVersion"]) is not int or value["schemaVersion"] != 1 or value["task"] != TASK or value["platform"] != "android":
        raise GateError("unsupported manifest schema/task/platform")
    artifact = keys(value["artifact"], {"kind", "name", "sha256", "identity"}, "artifact")
    if artifact["kind"] != "jar" or "/" in text(artifact["name"], "artifact name") or "\\" in artifact["name"] or not artifact["name"].endswith(".jar"):
        raise GateError("artifact must name a JAR basename")
    sha(artifact["sha256"], "JAR hash")
    identity(artifact["identity"])
    components = keys(value["components"], COMPONENTS, "components")
    refs = []
    for name, component in components.items():
        keys(component, {"repository", "commit", "tree", "patches", "sourceEvidence"}, name)
        if not re.fullmatch(r"https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:\.git)?", text(component["repository"], name)):
            raise GateError(f"{name}: explicit Git repository URL required")
        sha(component["commit"], f"{name} commit", 40)
        sha(component["tree"], f"{name} tree", 40)
        refs.append((component["sourceEvidence"], "source"))
        if not isinstance(component["patches"], list):
            raise GateError(f"{name}: ordered patches array required (empty means none)")
        paths = set()
        for patch in component["patches"]:
            keys(patch, {"path", "sha256", "evidence"}, "patch")
            path = relative(patch["path"], "patch path")
            if path in paths:
                raise GateError("duplicate ordered patch")
            paths.add(path)
            sha(patch["sha256"], "patch hash")
            refs.append((patch["evidence"], "patch"))
    toolchain = keys(value["toolchain"], {"ndkVersion", "ndkSha256", "compilerVersion", "compilerSha256", "sysrootSha256", "evidence"}, "toolchain")
    for field in ("ndkVersion", "compilerVersion"):
        text(toolchain[field], field)
    for field in ("ndkSha256", "compilerSha256", "sysrootSha256"):
        sha(toolchain[field], field)
    refs.append((toolchain["evidence"], "toolchain"))
    staging = keys(value["staging"], {"cleanEvidence", "membersEvidence", "linkEvidence"}, "staging")
    refs.extend((staging[field], kind) for field, kind in
                (("cleanEvidence", "staging"), ("membersEvidence", "members"), ("linkEvidence", "link")))
    if not isinstance(value["linkInputs"], list) or not value["linkInputs"]:
        raise GateError("ordered link inputs required")
    linked = set()
    seen_inputs = set()
    for item in value["linkInputs"]:
        keys(item, {"component", "path", "sha256"}, "link input")
        if not isinstance(item["component"], str) or item["component"] not in COMPONENTS | {"toolchain"}:
            raise GateError("unknown link input component")
        pair = (item["component"], relative(item["path"], "link input path"))
        if pair in seen_inputs:
            raise GateError("duplicate link input")
        seen_inputs.add(pair)
        linked.add(item["component"])
        sha(item["sha256"], "link input hash")
    if not {"FFmpeg", "mpv", "libplacebo", "helper", "toolchain"} <= linked:
        raise GateError("incomplete linked native component closure")
    if not isinstance(value["evidence"], list) or not value["evidence"]:
        raise GateError("evidence attachments required")
    evidence = {}
    evidence_paths = set()
    for item in value["evidence"]:
        keys(item, {"id", "path", "sha256", "kind"}, "evidence")
        label = text(item["id"], "evidence id")
        path = relative(item["path"], "evidence path")
        if label in evidence or path in evidence_paths:
            raise GateError("duplicate evidence identity/path")
        if not isinstance(item["kind"], str) or item["kind"] not in {"source", "patch", "toolchain", "staging", "members", "link", "weak-import-contract"}:
            raise GateError("unknown evidence kind")
        sha(item["sha256"], "evidence hash")
        evidence[label] = item
        evidence_paths.add(path)
    for label, kind in refs:
        if not isinstance(label, str) or label not in evidence or evidence[label]["kind"] != kind:
            raise GateError(f"missing {kind} evidence: {label}")
    for component in components.values():
        for patch in component["patches"]:
            if evidence[patch["evidence"]]["sha256"] != patch["sha256"]:
                raise GateError("patch attachment differs from ordered patch hash")
    members = keys(value["members"], set(MEMBERS), "members")
    for name, member in members.items():
        keys(member, {"sha256", "buildId", "soname", "needed", "elfClass", "machine"}, name)
        sha(member["sha256"], "member hash")
        if not isinstance(member["buildId"], str) or not re.fullmatch(r"[0-9a-f]{8,128}", member["buildId"]):
            raise GateError("nonempty ELF Build ID required")
        if member["soname"] != PurePosixPath(name).name:
            raise GateError("member SONAME must match canonical member name")
        if type(member["elfClass"]) is not int or member["elfClass"] != 64 or type(member["machine"]) is not int or member["machine"] != 183:
            raise GateError("ELF64/AArch64 required")
        needed = member["needed"]
        if not isinstance(needed, list) or not needed or any(not isinstance(n, str) or not re.fullmatch(r"[A-Za-z0-9_.+-]+\.so(?:\.[0-9.]+)?", n) for n in needed) or len(set(needed)) != len(needed):
            raise GateError("nonempty unique ELF NEEDED basenames required")
    return value


def closure_hash(manifest: dict) -> str:
    return digest(canonical({k: manifest[k] for k in ("components", "toolchain", "staging", "linkInputs", "evidence", "members")}))


def accepted_entry(accepted: object, manifest: dict, manifest_sha: str) -> dict:
    accepted = keys(accepted, {"schemaVersion", "task", "entries"}, "trusted acceptance ledger")
    if type(accepted["schemaVersion"]) is not int or accepted["schemaVersion"] != 1 or accepted["task"] != TASK or not isinstance(accepted["entries"], list):
        raise GateError("unsupported acceptance ledger")
    matches = []
    seen = set()
    for entry in accepted["entries"]:
        keys(entry, {"manifestSha256", "sourceClosureSha256", "artifactIdentity", "jarSha256", "approval", "allowedWeakVulkanImports", "weakImportEvidence"}, "acceptance record")
        for field in ("manifestSha256", "sourceClosureSha256", "jarSha256"):
            sha(entry[field], field)
        if entry["manifestSha256"] in seen:
            raise GateError("duplicate accepted manifest")
        seen.add(entry["manifestSha256"])
        identity(entry["artifactIdentity"])
        approval = keys(entry["approval"], {"reviewUrl", "coreCommit"}, "CORE approval")
        sha(approval["coreCommit"], "CORE reviewed evidence commit", 40)
        if not isinstance(approval["reviewUrl"], str) or not re.fullmatch(r"https://github\.com/Goodwu/media-kit/pull/4#(?:issuecomment|pullrequestreview)-[0-9]+", approval["reviewUrl"]):
            raise GateError("central CORE review URL required")
        allowed = entry["allowedWeakVulkanImports"]
        if not isinstance(allowed, dict) or not set(allowed) <= set(MEMBERS):
            raise GateError("invalid weak import approval")
        for values in allowed.values():
            if not isinstance(values, list) or any(not isinstance(v, str) or v not in VULKAN for v in values) or len(set(values)) != len(values):
                raise GateError("weak import approval must explicitly list unique target names")
        has_weak = any(allowed.values())
        weak_evidence = entry["weakImportEvidence"]
        if has_weak:
            if not isinstance(weak_evidence, str):
                raise GateError("weak imports require approved contract evidence")
        elif weak_evidence is not None:
            raise GateError("unused weak contract evidence must be null")
        if entry["manifestSha256"] == manifest_sha:
            matches.append(entry)
    if len(matches) != 1:
        raise GateError("native manifest has no unique CORE-reviewed acceptance record")
    result = matches[0]
    if result["sourceClosureSha256"] != closure_hash(manifest) or result["artifactIdentity"] != manifest["artifact"]["identity"] or result["jarSha256"] != manifest["artifact"]["sha256"]:
        raise GateError("accepted source closure/artifact identity/JAR hash mismatch")
    if any(result["allowedWeakVulkanImports"].values()):
        attached = {e["id"]: e for e in manifest["evidence"]}
        label = result["weakImportEvidence"]
        if label not in attached or attached[label]["kind"] != "weak-import-contract":
            raise GateError("weak import contract attachment missing")
    return result


def evidence_files(manifest: dict, root: Path) -> None:
    if not root.is_dir() or root.is_symlink():
        raise GateError("evidence root missing or symbolic link")
    root = root.resolve()
    for item in manifest["evidence"]:
        file = root / item["path"]
        for ancestor in (file, *file.parents):
            if ancestor == root:
                break
            if ancestor.is_symlink():
                raise GateError("evidence path contains symbolic link")
        if not file.is_file() or file.stat().st_size > 64 * 1024 * 1024 or file_digest(file) != item["sha256"]:
            raise GateError(f"evidence attachment missing/changed/oversized: {item['id']}")


def archive_members(path: Path, jar: bool) -> dict[str, bytes]:
    if not path.is_file() or path.is_symlink() or path.stat().st_size > 1024 * 1024 * 1024:
        raise GateError("archive missing/symbolic link/oversized")
    result = {}
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        if len(entries) > 100000:
            raise GateError("too many ZIP entries")
        seen = set()
        total = 0
        for item in entries:
            name = item.filename
            if item.orig_filename != name or (item.is_dir() and item.file_size != 0):
                raise GateError("truncated ZIP filename or nonempty directory entry")
            relative(name.rstrip("/") if item.is_dir() else name, "ZIP entry")
            if name in seen:
                raise GateError("duplicate ZIP entry")
            seen.add(name)
            if stat.S_ISLNK(item.external_attr >> 16) or item.flag_bits & 1:
                raise GateError("symlink/encrypted ZIP member rejected")
            total += item.file_size
            if jar and total > 384 * 1024 * 1024:
                raise GateError("JAR expansion limit exceeded")
            if total > 1024 * 1024 * 1024 or item.file_size > 256 * 1024 * 1024 or (item.file_size > 1024 * 1024 and item.file_size > max(1, item.compress_size) * 250):
                raise GateError("ZIP expansion limit exceeded")
            if jar and name not in set(MEMBERS) | {"lib/", "lib/arm64-v8a/"}:
                raise GateError(f"unexpected JAR member: {name}")
            if name.endswith(".so") and not re.fullmatch(r"lib/arm64-v8a/[A-Za-z0-9_.+-]+\.so", name):
                raise GateError(f"native member outside canonical arm64 ABI directory: {name}")
            # Drain every entry, including extra APK plugins/resources, to make
            # decompression and CRC failures observable without unbounded reads.
            chunks = []
            expanded = 0
            try:
                with archive.open(item) as stream:
                    while chunk := stream.read(1024 * 1024):
                        expanded += len(chunk)
                        if expanded > item.file_size or expanded > 256 * 1024 * 1024:
                            raise GateError("ZIP expansion limit exceeded while reading")
                        if name in MEMBERS:
                            chunks.append(chunk)
            except (zipfile.BadZipFile, OSError, RuntimeError, EOFError, zlib.error) as error:
                raise GateError(f"ZIP member integrity failure: {name}: {error}") from error
            if expanded != item.file_size:
                raise GateError(f"ZIP member size mismatch: {name}")
            if name in MEMBERS:
                result[name] = b"".join(chunks)
        if set(result) != set(MEMBERS):
            raise GateError("archive lacks exact three native members")
    return result


def run_tool(argv: list[str], receipt: dict) -> str:
    record = {"argv": argv, "exitCode": None}
    receipt["commands"].append(record)
    try:
        result = subprocess.run(argv, text=True, capture_output=True, timeout=60, check=False)
    except (OSError, subprocess.TimeoutExpired, UnicodeError) as error:
        record["error"] = str(error)
        raise GateError(f"ELF tool invocation failed: {argv[0]}") from error
    record.update(exitCode=result.returncode, stdout=result.stdout, stderr=result.stderr)
    if result.returncode != 0:
        raise GateError(f"ELF tool exited {result.returncode}: {argv[0]}")
    if result.stderr.strip():
        raise GateError(f"ELF tool diagnostic despite successful exit: {argv[0]}")
    return result.stdout


def dynamic_imports(output: str) -> dict[str, str]:
    """Require a complete readable dynsym table, rather than an absent listing."""
    headers = re.findall(r"^Symbol table '\.dynsym' contains ([0-9]+) entries:$", output, re.MULTILINE)
    if len(headers) != 1 or int(headers[0]) < 1:
        raise GateError("complete dynamic symbol table unavailable; cannot infer absent imports")
    rows = []
    for line in output.splitlines():
        if not line.strip() or line.startswith("Symbol table ") or re.fullmatch(r"\s*Num:\s+Value\s+Size\s+Type\s+Bind\s+Vis\s+Ndx\s+Name\s*", line):
            continue
        row = re.fullmatch(r"\s*([0-9]+):\s+([0-9a-fA-F]+)\s+([0-9]+)\s+(\w+)\s+(\w+)\s+(\w+)\s+(\S+)(?:\s+(\S+)(?:\s+\([0-9]+\))?)?\s*", line)
        if row is None:
            raise GateError("unrecognized dynamic symbol table output")
        rows.append(row.groups())
    if len(rows) != int(headers[0]) or [int(row[0]) for row in rows] != list(range(len(rows))):
        raise GateError("incomplete dynamic symbol table")
    if rows[0][3:7] != ("NOTYPE", "LOCAL", "DEFAULT", "UND") or int(rows[0][1], 16) or int(rows[0][2]) or rows[0][7]:
        raise GateError("dynamic symbol null entry missing")
    imports = {}
    for _, _, _, kind, binding, _, index, name in rows[1:]:
        if index != "UND":
            continue
        if not name or binding not in {"GLOBAL", "WEAK"}:
            raise GateError("unrecognized dynamic import binding/name")
        symbol = name.split("@", 1)[0]
        if symbol in imports:
            raise GateError("ambiguous duplicate dynamic import")
        imports[symbol] = "U" if binding == "GLOBAL" else ("v" if kind == "OBJECT" else "w")
    return imports


def elf_member(name: str, data: bytes, declaration: dict, weak: list[str], readelf: str, nm: str, receipt: dict, directory: Path) -> dict:
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01" or data[6] != 1 or struct.unpack_from("<HHI", data, 16) != (3, 183, 1):
        raise GateError(f"not a little-endian ELF64 AArch64 shared library: {name}")
    if digest(data) != declaration["sha256"]:
        raise GateError(f"member hash mismatch: {name}")
    file = directory / PurePosixPath(name).name
    file.write_bytes(data)
    header = run_tool([readelf, "-h", str(file)], receipt)
    if not re.search(r"Class:\s+ELF64\b", header) or not re.search(r"Machine:\s+AArch64\b", header) or not re.search(r"Type:\s+DYN\b", header):
        raise GateError("readelf header does not confirm ELF64/AArch64/DYN")
    notes = run_tool([readelf, "-n", str(file)], receipt)
    build_ids = re.findall(r"Build ID:\s*([0-9a-fA-F]+)", notes)
    if len(build_ids) != 1 or build_ids[0].lower() != declaration["buildId"]:
        raise GateError(f"Build ID mismatch/missing/ambiguous: {name}")
    dynamic = run_tool([readelf, "-d", str(file)], receipt)
    sonames = re.findall(r"\(SONAME\).*?\[([^\]]+)\]", dynamic)
    needed = re.findall(r"\(NEEDED\).*?\[([^\]]+)\]", dynamic)
    if sonames != [declaration["soname"]] or needed != declaration["needed"]:
        raise GateError(f"SONAME/NEEDED mismatch: {name}")
    complete_imports = dynamic_imports(run_tool([readelf, "--dyn-syms", "--wide", str(file)], receipt))
    symbols = run_tool([nm, "-D", "--undefined-only", "--format=posix", str(file)], receipt)
    imports = {}
    for line in symbols.splitlines():
        fields = line.split()
        if not 2 <= len(fields) <= 4 or fields[1] not in {"U", "w", "v"}:
            raise GateError("unrecognized undefined-symbol output; cannot infer absent imports")
        symbol = fields[0].split("@", 1)[0]
        if symbol in imports:
            raise GateError("ambiguous duplicate undefined symbol")
        imports[symbol] = fields[1]
    if imports != complete_imports:
        raise GateError("nm/dynamic symbol import sets disagree; cannot infer absent imports")
    target = {symbol: imports.get(symbol) for symbol in sorted(VULKAN)}
    for symbol, binding in target.items():
        if binding == "U" or (binding in {"w", "v"} and symbol not in weak):
            raise GateError(f"unapproved Vulkan import: {symbol} ({binding})")
    return {"sha256": digest(data), "buildId": build_ids[0].lower(), "soname": sonames[0], "needed": needed, "vulkanImports": target}


def verify(jar: Path, manifest_path: Path, evidence_root: Path, accepted: dict, consumer: dict, receipt: dict, *, apk: Path | None = None, readelf: str = "readelf", nm: str = "nm") -> None:
    receipt.update(schemaVersion=1, task=TASK, stage="manifest", status="failed", nativeVerified=False, deviceVerified=False, consumer=consumer, commands=[])
    keys(consumer, {"appCommit", "mediaKitCommit"}, "consumer vector")
    for name in ("appCommit", "mediaKitCommit"):
        sha(consumer.get(name), f"consumer {name}", 40)
    manifest, raw = read_json(manifest_path)
    validate_manifest(manifest)
    receipt["native"] = {"manifestSha256": digest(raw), "sourceClosureSha256": closure_hash(manifest), "artifactIdentity": manifest["artifact"]["identity"]}
    receipt["stage"] = "CORE-acceptance"
    entry = accepted_entry(accepted, manifest, digest(raw))
    receipt["approval"] = entry["approval"]
    receipt["stage"] = "evidence"
    evidence_files(manifest, evidence_root)
    receipt["stage"] = "JAR"
    if jar.name != manifest["artifact"]["name"] or not jar.is_file() or jar.is_symlink() or jar.stat().st_size > 1024 * 1024 * 1024 or file_digest(jar) != manifest["artifact"]["sha256"]:
        raise GateError("JAR name/hash mismatch")
    members = archive_members(jar, True)
    receipt["stage"] = "ELF"
    receipt["members"] = {}
    with tempfile.TemporaryDirectory(prefix="routing-native-elf-") as directory:
        for name in MEMBERS:
            receipt["members"][name] = elf_member(name, members[name], manifest["members"][name], entry["allowedWeakVulkanImports"].get(name, []), readelf, nm, receipt, Path(directory))
    if apk is not None:
        receipt["stage"] = "APK"
        packaged = archive_members(apk, False)
        verify_android_archive(apk, "arm64-v8a")
        for name in MEMBERS:
            if packaged[name] != members[name]:
                raise GateError(f"APK native member differs from approved JAR: {name}")
        receipt["apk"] = {"sha256": file_digest(apk), "members": {name: digest(packaged[name]) for name in MEMBERS}}
    receipt.update(stage="complete", status="passed", nativeVerified=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--apk", type=Path)
    parser.add_argument("--app-commit", required=True)
    parser.add_argument("--media-kit-commit", required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--readelf", default="readelf")
    parser.add_argument("--nm", default="nm")
    args = parser.parse_args()
    receipt = {"schemaVersion": 1, "task": TASK, "stage": "acceptance-ledger", "status": "failed", "nativeVerified": False, "deviceVerified": False, "commands": [], "consumer": {"appCommit": args.app_commit, "mediaKitCommit": args.media_kit_commit}}
    code = 0
    try:
        accepted, _ = read_json(ACCEPTED)
        verify(args.jar, args.manifest, args.evidence_root, accepted, receipt["consumer"], receipt, apk=args.apk, readelf=args.readelf, nm=args.nm)
    except Exception as error:
        receipt.update(status="failed", nativeVerified=False, reason=str(error))
        code = 1
    args.receipt.parent.mkdir(parents=True, exist_ok=True)
    args.receipt.write_text(json.dumps(receipt, indent=2) + "\n")
    print(f"routing native gate: {receipt['status']} ({receipt['stage']})")
    return code


if __name__ == "__main__":
    sys.exit(main())
