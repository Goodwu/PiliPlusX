#!/usr/bin/env python3
"""Orchestrate one isolated, fresh macOS shared-core CI candidate.

The fixed acquisition lock is the only authority for a media-kit revision. The
runner rejects missing or malformed approved revisions before network access,
imports of repository build modules, pub get, or any build. The approved source
must also be available at the fixed origin. This script never enables the
production/default backend.
"""
from __future__ import annotations

import hashlib
import difflib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import stat
import shutil
import subprocess
import sys
from typing import Optional
import urllib.parse

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "scripts/macos-shared-ci-inputs.lock.json"
LOCK_SHA256 = "8c3ec367b8d89e74d0b2ce6beefb74e240a5defa85846b8bc899b54a69766ab9"
MEDIA_KIT_URL = "https://github.com/Goodwu/media-kit.git"
SHA40 = re.compile(r"^[0-9a-f]{40}$")
MEDIA_KIT_BRIDGE = "common/darwin/Classes/plugin/MetalSurfaceBlitter.swift"
COMPAT_ALLOWED_DART_FILES = frozenset({
    "lib/src/util.dart",
    "lib/src/types/content_blocker_action_type.g.dart",
    "lib/src/types/permission_resource_type.g.dart",
    "lib/src/types/print_job_color_mode.g.dart",
    "lib/src/types/print_job_duplex_mode.g.dart",
    "lib/src/types/print_job_orientation.g.dart",
})


class CandidateError(RuntimeError):
    pass


def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def tree_digest(root: Path) -> str:
    """Hash sorted relative package files and link targets for compatibility evidence."""
    records = []
    for path in sorted(root.rglob("*")):
        relative = path.relative_to(root).as_posix()
        if path.is_symlink():
            records.append([relative, "link", os.readlink(path)])
        elif path.is_file():
            records.append([relative, "file", digest(path)])
        elif path.is_dir():
            records.append([relative, "dir"])
    return hashlib.sha256(json.dumps(records, separators=(",", ":")).encode()).hexdigest()


def node_inventory(root: Path) -> dict[str, dict[str, object]]:
    """Inventory every node without following symlinks, including empty dirs."""
    if root.is_symlink():
        raise CandidateError(f"cannot inventory through a symlink root: {root}")
    root = root.resolve(strict=True)
    nodes: dict[str, dict[str, object]] = {".": {"type": "directory"}}

    def visit(directory: Path) -> None:
        for entry in sorted(os.scandir(directory), key=lambda item: item.name):
            path = Path(entry.path)
            relative = path.relative_to(root).as_posix()
            info = entry.stat(follow_symlinks=False)
            mode = info.st_mode
            if stat.S_ISLNK(mode):
                nodes[relative] = {"type": "symlink", "target": os.readlink(path)}
            elif stat.S_ISDIR(mode):
                nodes[relative] = {"type": "directory"}
                visit(path)
            elif stat.S_ISREG(mode):
                nodes[relative] = {"type": "file", "sha256": digest(path), "bytes": info.st_size}
            else:
                kind = ("fifo" if stat.S_ISFIFO(mode) else "socket" if stat.S_ISSOCK(mode)
                        else "character-device" if stat.S_ISCHR(mode)
                        else "block-device" if stat.S_ISBLK(mode) else "special")
                nodes[relative] = {"type": kind, "mode": stat.S_IFMT(mode)}

    visit(root)
    return nodes


def require_expected_compat_nodes(expected: dict[str, dict[str, object]],
                                 actual: dict[str, dict[str, object]]) -> None:
    if actual != expected:
        changed_nodes = sorted(name for name in set(actual) | set(expected)
                               if actual.get(name) != expected.get(name))
        raise CandidateError("compatibility patch changed package nodes outside the approved byte transforms: " +
                             ", ".join(changed_nodes))


def assert_no_symlink_path(path: Path, base: Path) -> Path:
    if base.is_symlink():
        raise CandidateError(f"private cache root is a symlink: {base}")
    base = base.resolve(strict=True)
    if base != base.absolute():
        raise CandidateError(f"private cache root is not canonical: {base}")
    absolute = path.absolute()
    try:
        relative = absolute.relative_to(base)
    except ValueError as error:
        raise CandidateError(f"path escaped its private cache: {path}") from error
    current = base
    for part in relative.parts:
        current = current / part
        if current.is_symlink():
            raise CandidateError(f"symlink in private cache source path: {current}")
    resolved = current.resolve(strict=True)
    try:
        resolved.relative_to(base)
    except ValueError as error:
        raise CandidateError(f"resolved path escaped private cache: {path}") from error
    return resolved


def receipt(path: Path) -> dict:
    if not path.is_file() or path.is_symlink():
        raise CandidateError(f"stage receipt is missing or unsafe: {path}")
    return {"path": str(path), "sha256": digest(path), "bytes": path.stat().st_size}


def restore_file(path: Path, content: Optional[bytes]) -> None:
    """Restore a workspace file without following a replacement symlink."""
    if path.parent.is_symlink() or path.parent.resolve(strict=True) != path.parent:
        raise CandidateError(f"refusing restore through non-canonical parent: {path.parent}")
    if content is None:
        if path.is_dir() and not path.is_symlink():
            raise CandidateError(f"refusing to remove directory while restoring {path}")
        path.unlink(missing_ok=True)
        return
    temporary = path.with_name(f".{path.name}.restore-{os.getpid()}")
    if temporary.exists() or temporary.is_symlink():
        raise CandidateError(f"restore staging file already exists: {temporary}")
    with temporary.open("xb") as stream:
        stream.write(content)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def retain_log_tree(source: Path, destination: Path) -> dict:
    """Copy only regular build logs, never cached sources, Apps or staging trees."""
    if not source.is_dir() or source.is_symlink() or destination.exists():
        raise CandidateError(f"unsafe or missing log tree: {source}")
    destination.mkdir(parents=True)
    for path in sorted(source.rglob("*")):
        relative = path.relative_to(source)
        target = destination / relative
        if path.is_symlink():
            raise CandidateError(f"symlink in retained log tree: {path}")
        if path.is_dir():
            target.mkdir()
        elif path.is_file():
            shutil.copy2(path, target)
        else:
            raise CandidateError(f"special file in retained log tree: {path}")
    return {"source": str(source), "artifact_path": str(destination),
            "source_tree_sha256": tree_digest(source), "artifact_tree_sha256": tree_digest(destination)}


def run(argv: list[str], *, cwd: Optional[Path] = None, env: Optional[dict[str, str]] = None,
        report: Optional[dict] = None, label: str = "command", check: bool = True) -> subprocess.CompletedProcess:
    """Run argv directly, retaining exact arguments and separate output."""
    result = subprocess.run(argv, cwd=cwd, env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if report is not None:
        report.setdefault("commands", []).append({
            "label": label, "argv": [str(x) for x in argv],
            "cwd": str(cwd) if cwd else None, "exit_code": result.returncode,
            "stdout": result.stdout, "stderr": result.stderr,
        })
        save_report(report)
    if check and result.returncode:
        raise CandidateError(f"{label} failed ({result.returncode}): {result.stderr[-2000:]}")
    return result


def save_report(report: dict) -> None:
    path = Path(report["report_path"])
    parent = path.parent
    if parent.is_symlink() or not parent.is_dir() or parent.resolve(strict=True) != parent:
        raise CandidateError("diagnostics directory is not the owned canonical directory")
    temporary = path.with_suffix(".tmp")
    if temporary.exists() or temporary.is_symlink():
        raise CandidateError("diagnostics temporary report already exists")
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise CandidateError("diagnostics report path is unsafe")
    with temporary.open("x", encoding="utf-8") as stream:
        stream.write(json.dumps(report, sort_keys=True, indent=2) + "\n")
    os.replace(temporary, path)


def safe_run_identity(value: str, label: str) -> str:
    if not re.fullmatch(r"[0-9]+", value) or value in {".", ".."}:
        raise CandidateError(f"{label} must be a single numeric path segment")
    return value


def owned_runner_paths(runner_temp: Path, run_id: str, attempt: str) -> tuple[Path, Path]:
    if runner_temp.is_symlink() or not runner_temp.is_dir():
        raise CandidateError("RUNNER_TEMP must be an existing non-symlink directory")
    canonical = runner_temp.resolve(strict=True)
    if canonical != runner_temp.absolute():
        raise CandidateError("RUNNER_TEMP must be canonical")
    if canonical == ROOT or canonical.is_relative_to(ROOT) or ROOT.is_relative_to(canonical):
        raise CandidateError("RUNNER_TEMP must be independent from the checkout")
    run_id = safe_run_identity(run_id, "GITHUB_RUN_ID")
    attempt = safe_run_identity(attempt, "GITHUB_RUN_ATTEMPT")
    run_parent = canonical / "piliplusx-shared-candidate"
    diag = canonical / "piliplusx-shared-candidate-diagnostics"
    for path in (run_parent, diag):
        if path.is_symlink() or path.exists():
            raise CandidateError(f"candidate output path already exists or is a symlink: {path}")
    # Exclusive mkdirs establish ownership. On any race or pre-existing path,
    # fail without writing through it or falling back to another location.
    run_parent.mkdir(mode=0o700)
    try:
        diag.mkdir(mode=0o700)
        run_dir = run_parent / f"{run_id}-{attempt}"
        run_dir.mkdir(mode=0o700)
    except Exception:
        try:
            run_parent.rmdir()
        except OSError:
            pass
        raise
    return run_dir, diag / "result.json"


def verify_source_tree(checkout: Path, revision: str, paths: dict[str, str],
                       report: dict) -> None:
    """Require clean, complete package+recipe trees from the approved commit."""
    scopes = sorted(set(paths.values()) | {"tool/shared_gpu_next"})
    diff = run(["git", "-C", str(checkout), "diff", "--quiet", revision, "--", *scopes],
               report=report, label="approved-source-tree-diff", check=False)
    if diff.returncode != 0:
        raise CandidateError("media-kit package or recipe tracked content drifted from approved commit")
    status = run(["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=all",
                  "--ignored", "--", *scopes], report=report,
                 label="approved-source-tree-inventory")
    if status.stdout.strip():
        raise CandidateError("media-kit package or recipe tree contains untracked/ignored content")
    report["approved_source_tree"] = {"revision": revision, "scopes": scopes,
                                      "diff_clean": True, "inventory_clean": True}
    save_report(report)


def verify_pub_git_source(checkout: Path, private_cache: Path, revision: str,
                          report: dict, name: str) -> Path:
    """Validate the Pub checkout through its private, URL-pinned bare cache."""
    checkout = assert_no_symlink_path(checkout, private_cache)
    head = run(["git", "-C", str(checkout), "rev-parse", "HEAD"], report=report,
               label=f"package-head-{name}").stdout.strip()
    if head != revision:
        raise CandidateError(f"{name}: Pub checkout HEAD differs from approved revision")
    origin = run(["git", "-C", str(checkout), "remote", "get-url", "origin"], report=report,
                 label=f"package-origin-{name}").stdout.strip()
    if origin == MEDIA_KIT_URL:
        cache_root = assert_no_symlink_path(private_cache / "git/cache", private_cache)
        candidates = [p for p in sorted(cache_root.iterdir()) if p.name.startswith("media-kit-")]
        trusted = []
        for candidate_path in candidates:
            if candidate_path.is_symlink():
                raise CandidateError(f"symlink in private media-kit bare-cache inventory: {candidate_path}")
            bare = assert_no_symlink_path(candidate_path, private_cache)
            is_bare = run(["git", "-C", str(bare), "rev-parse", "--is-bare-repository"],
                          report=report, label=f"package-cache-bare-{name}", check=False)
            if is_bare.returncode != 0 or is_bare.stdout.strip() != "true":
                continue
            bare_origin = run(["git", "-C", str(bare), "remote", "get-url", "origin"],
                              report=report, label=f"package-cache-origin-{name}", check=False)
            if bare_origin.returncode == 0 and bare_origin.stdout.strip() == MEDIA_KIT_URL:
                trusted.append(bare)
    else:
        parsed = urllib.parse.urlparse(origin)
        if parsed.scheme == "file":
            origin_path = Path(urllib.parse.unquote(parsed.path))
        else:
            origin_path = Path(origin)
            if not origin_path.is_absolute():
                origin_path = checkout / origin_path
        trusted = [assert_no_symlink_path(origin_path, private_cache)]
    trusted = list(dict.fromkeys(trusted))
    if len(trusted) != 1:
        raise CandidateError(f"{name}: expected one canonical private Goodwu media-kit bare cache, got {len(trusted)}")
    bare = trusted[0]
    bare_origin = run(["git", "-C", str(bare), "remote", "get-url", "origin"], report=report,
                      label=f"package-cache-origin-verified-{name}").stdout.strip()
    bare_status = run(["git", "-C", str(bare), "rev-parse", "--is-bare-repository"], report=report,
                      label=f"package-cache-bare-verified-{name}").stdout.strip()
    if bare_origin != MEDIA_KIT_URL or bare_status != "true":
        raise CandidateError(f"{name}: Pub bare cache has an unapproved origin or is not bare")
    run(["git", "-C", str(bare), "cat-file", "-e", f"{revision}^{{commit}}"], report=report,
        label=f"package-cache-approved-commit-{name}")
    report.setdefault("pub_git_sources", {})[name] = {
        "checkout": str(checkout), "checkout_head": head,
        "checkout_origin": origin, "trusted_bare_cache": str(bare),
        "bare_origin": bare_origin, "bare": True, "approved_commit_present": True,
    }
    return bare


def expected_compat_transform(text: str) -> tuple[str, int]:
    pattern = re.compile(r"(?m)^[ \t]*case TargetPlatform\.ohos:\n[\s\S]*?(?=^[ \t]*(?:case TargetPlatform\.|default:)|\Z)")
    text, removed = pattern.subn("", text)
    text, comparisons = re.subn(r"(?:!isWeb\s*&&\s*)?defaultTargetPlatform\s*==\s*TargetPlatform\.ohos", "false", text)
    if "TargetPlatform.ohos" in text:
        raise CandidateError("compatibility source contains an unsupported OHOS expression")
    return text, removed + comparisons


def compatibility_plan(root: Path) -> dict[str, bytes]:
    if root.is_symlink():
        raise CandidateError("compatibility package root must not be a symlink")
    plan = {}
    for path in sorted(root.rglob("*.dart")):
        if path.is_symlink():
            raise CandidateError(f"symlink in compatibility package: {path}")
        before = path.read_text(encoding="utf-8")
        if "TargetPlatform.ohos" not in before:
            continue
        relative = path.relative_to(root).as_posix()
        if relative not in COMPAT_ALLOWED_DART_FILES:
            raise CandidateError(f"compatibility patch target is outside the reviewed file allowlist: {relative}")
        after, count = expected_compat_transform(before)
        if count == 0:
            raise CandidateError(f"compatibility transform made no approved change: {path}")
        plan[relative] = after.encode("utf-8")
    if not plan:
        raise CandidateError("no approved TargetPlatform.ohos compatibility changes found")
    return plan


def load_approved_revision() -> str:
    if digest(LOCK) != LOCK_SHA256:
        raise CandidateError("fixed acquisition lock differs from reviewed identity")
    lock = json.loads(LOCK.read_text(encoding="utf-8"))
    revision = lock.get("reviewed_media_kit_revision")
    if not isinstance(revision, str) or not SHA40.fullmatch(revision):
        raise CandidateError("reviewed media-kit revision unavailable")
    return revision


def validate_source_ref(source_ref: str, github_sha: str) -> str:
    if not SHA40.fullmatch(source_ref) or not SHA40.fullmatch(github_sha):
        raise CandidateError("source_ref and GITHUB_SHA must be full 40-character commits")
    if source_ref != github_sha:
        raise CandidateError("source_ref must equal workflow GITHUB_SHA")
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if head.returncode or head.stdout.strip() != source_ref:
        raise CandidateError("checked-out source HEAD does not equal source_ref")
    return source_ref


def require_host(report: dict) -> None:
    if sys.platform != "darwin" or platform.machine() != "arm64":
        raise CandidateError("candidate requires a Darwin arm64 host")
    if sys.version_info[:2] != (3, 11):
        raise CandidateError("candidate requires Python 3.11")
    for tool in ("xcodebuild", "codesign", "lipo", "otool", "flutter", "git", "brew"):
        if shutil.which(tool) is None:
            raise CandidateError(f"required tool is unavailable: {tool}")
    # Rosetta and CGL are mandatory gates. Do not convert either failure into a
    # skip; the consumer's actual two-ABI backend probe remains authoritative.
    run([sys.executable, "--version"], report=report, label="python-version")
    run(["/usr/bin/arch", "-x86_64", "/usr/bin/true"], report=report, label="rosetta-preflight")
    run(["/usr/bin/sw_vers", "-productVersion"], report=report, label="macos-version")
    run(["xcodebuild", "-version"], report=report, label="xcode-version")
    run(["flutter", "--version", "--machine"], report=report, label="flutter-version")


def check_lock(lockfile: Path, revision: str, report: dict) -> None:
    run([sys.executable, str(ROOT / "scripts/verify_media_kit_lock.py"), str(lockfile),
         "--commit", revision, "--url", MEDIA_KIT_URL], cwd=ROOT, report=report,
        label="media-kit-lock-gate")
    data = lockfile.read_text(encoding="utf-8")
    found = re.findall(r"(?m)^  (media_kit(?:[^:]*)):\n", data)
    required = report["media_kit_package_names"]
    if sorted(found) != required:
        raise CandidateError(f"media-kit lock package set mismatch: {sorted(found)}")
    # Existing verifier covers source/url/resolved-ref. Enforce exact package
    # subpaths too; Pub lock does not retain the requested Git ref separately.
    blocks = re.split(r"(?m)^  (?=media_kit(?:[^:]*):)", data)[1:]
    for block in blocks:
        name = block.split(":", 1)[0]
        if name not in required:
            continue
        path_match = re.search(r'(?m)^      path: (?:"([^"\n]+)"|([^\n]+))$', block)
        expected_path = report.get("package_paths", {}).get(name)
        actual_path = (path_match.group(1) or path_match.group(2)).strip() if path_match else None
        if actual_path != expected_path:
            raise CandidateError(f"{name}: resolved package subpath differs from approved checkout")
        requested = re.search(r'(?m)^      ref: (?:"([^"\n]+)"|([^\n]+))$', block)
        requested_ref = (requested.group(1) or requested.group(2)).strip() if requested else None
        if requested_ref != revision:
            raise CandidateError(f"{name}: requested git ref differs from approved revision")
        resolved = re.search(r"(?m)^      resolved-ref: (.+)$", block)
        if not resolved or resolved.group(1).strip().strip('"') != revision:
            raise CandidateError(f"{name}: resolved git ref differs from approved revision")


def package_paths(checkout: Path, names: list[str]) -> dict[str, str]:
    """Map every media_kit package name to one checked path in the checkout."""
    rows = {}
    manifests = list(checkout.rglob("pubspec.yaml"))
    for name in names:
        matches = []
        for manifest in manifests:
            try:
                first = manifest.read_text(encoding="utf-8").splitlines()[0]
            except (OSError, UnicodeError, IndexError):
                continue
            if first == f"name: {name}":
                matches.append(manifest.parent.relative_to(checkout).as_posix())
        if len(matches) != 1:
            raise CandidateError(f"{name}: expected one package path in approved checkout, got {matches}")
        rows[name] = matches[0]
    return rows


def package_overrides(revision: str, paths: dict[str, str]) -> str:
    rows = []
    for name, path in sorted(paths.items()):
        rows.extend([f"  {name}:", "    git:", f"      url: {MEDIA_KIT_URL}",
                     f"      ref: {revision}", f"      path: {path}"])
    return "\n".join(rows) + "\n"


def merge_overrides(existing: Optional[bytes], revision: str, paths: dict[str, str]) -> bytes:
    """Preserve non-media-kit Pub overrides while replacing all media-kit entries."""
    text = existing.decode("utf-8") if existing is not None else ""
    if not text:
        return ("dependency_overrides:\n" + package_overrides(revision, paths)).encode("utf-8")
    lines = text.splitlines(keepends=True)
    header_candidates = [i for i, line in enumerate(lines)
                         if re.match(r"^dependency_overrides:", line.rstrip("\r\n"))]
    if len(header_candidates) > 1:
        raise CandidateError("existing Pub overrides contain duplicate dependency_overrides keys")
    header = header_candidates[0] if header_candidates else None
    if header is not None and lines[header].rstrip("\r\n") != "dependency_overrides:":
        raise CandidateError("existing Pub overrides use an unsupported inline mapping")
    generated = package_overrides(revision, paths)
    if header is None:
        separator = "" if text.endswith("\n") else "\n"
        return (text + separator + "\ndependency_overrides:\n" + generated).encode("utf-8")
    end = next((i for i in range(header + 1, len(lines))
                if lines[i].strip() and not lines[i][0].isspace()), len(lines))
    body = lines[header + 1:end]
    starts = [i for i, line in enumerate(body)
              if re.match(r"^  [A-Za-z0-9_-]+:\s*(?:#.*)?(?:\r?\n)?$", line)]
    preamble = body[:starts[0]] if starts else body
    kept = list(preamble)
    for position, start in enumerate(starts):
        stop = starts[position + 1] if position + 1 < len(starts) else len(body)
        block = body[start:stop]
        match = re.match(r"^  ([A-Za-z0-9_-]+):", block[0])
        if match and not match.group(1).startswith("media_kit"):
            kept.extend(block)
    replacement = lines[:header + 1] + kept + [generated] + lines[end:]
    return "".join(replacement).encode("utf-8")


def package_roots(workspace: Path, private_cache: Path) -> dict[str, Path]:
    config = json.loads((workspace / ".dart_tool/package_config.json").read_text(encoding="utf-8"))
    result = {}
    for item in config.get("packages", []):
        if not item.get("name", "").startswith("media_kit"):
            continue
        parsed = urllib.parse.urlparse(item["rootUri"])
        if parsed.scheme != "file":
            raise CandidateError(f"unsupported media-kit package root: {item['rootUri']}")
        result[item["name"]] = assert_no_symlink_path(
            Path(urllib.parse.unquote(parsed.path)), private_cache)
    return result


def verify_package_config(workspace: Path, checkout: Path, revision: str,
                          expected_names: list[str], paths: dict[str, str], report: dict,
                          private_cache: Optional[Path] = None) -> None:
    if private_cache is None:
        raise CandidateError("media-kit package resolution requires the isolated Pub cache")
    roots = package_roots(workspace, private_cache)
    if sorted(roots) != expected_names:
        raise CandidateError(f"package_config media-kit set mismatch: {sorted(roots)}")
    checkout = checkout.resolve(strict=True)
    git_roots = set()
    for name, package_root in roots.items():
        git_root_result = run(["git", "-C", str(package_root), "rev-parse", "--show-toplevel"],
                              report=report, label=f"package-root-{name}")
        git_root = assert_no_symlink_path(Path(git_root_result.stdout.strip()), private_cache)
        git_roots.add(git_root)
        if private_cache is not None:
            try:
                git_root.relative_to(private_cache.resolve(strict=True))
            except ValueError as error:
                raise CandidateError(f"{name}: Pub cache checkout escaped this run's private cache") from error
        expected_root = git_root / paths[name]
        if package_root != expected_root.resolve(strict=True):
            raise CandidateError(f"{name}: package_config path differs from requested package subpath")
        verify_pub_git_source(git_root, private_cache, revision, report, name)
        manifest = package_root / "pubspec.yaml"
        if not manifest.is_file() or manifest.read_text(encoding="utf-8").splitlines()[0] != f"name: {name}":
            raise CandidateError(f"{name}: package_config path does not contain the named package")
    video = roots.get("media_kit_video")
    if video is None:
        raise CandidateError("package_config lacks media_kit_video")
    package_bridge = video / MEDIA_KIT_BRIDGE
    source_bridge = checkout / "media_kit_video" / MEDIA_KIT_BRIDGE
    if not package_bridge.is_file() or not source_bridge.is_file():
        raise CandidateError("shared Swift bridge is absent from package_config or approved checkout")
    if digest(package_bridge) != digest(source_bridge):
        raise CandidateError("resolved media_kit_video bridge differs from approved media-kit revision")
    if len(git_roots) != 1:
        raise CandidateError("media-kit packages resolve from more than one Git checkout")
    verify_source_tree(next(iter(git_roots)), revision, paths, report)
    report.setdefault("package_config", []).append({
        "revision": revision, "checkout": str(next(iter(git_roots))),
        "roots": {k: str(v) for k, v in sorted(roots.items())},
        "bridge_path": str(package_bridge), "bridge_sha256": digest(package_bridge),
    })
    save_report(report)


def run_pipeline(report: dict, source_ref: str, revision: str, *,
                 production_release: bool = False) -> dict:
    """Run the single shared chain and return its final, gated product paths.

    The candidate CLI keeps its strict GITHUB_SHA binding and ZIP publication.
    The production caller supplies an independently validated tag/HEAD source
    and asks for the same pipeline result without creating a candidate ZIP.
    """
    run_dir = Path(report["run_dir"])
    raw, signed, runtime_work, runtime, sealed = [run_dir / n for n in
        ("raw", "signed", "runtime-work", "runtime", "sealed")]
    recipe_checkout = run_dir / "media-kit"
    logs = run_dir / "logs"
    for directory in (logs,):
        directory.mkdir(parents=True, exist_ok=False)
    # Fetch the exact approved revision from the fixed origin.
    recipe_checkout.mkdir()
    run(["git", "init", "--quiet"], cwd=recipe_checkout, report=report, label="media-kit-init")
    run(["git", "remote", "add", "origin", MEDIA_KIT_URL], cwd=recipe_checkout, report=report,
        label="media-kit-origin")
    run(["git", "fetch", "--depth=1", "origin", revision], cwd=recipe_checkout, report=report,
        label="media-kit-fetch")
    run(["git", "checkout", "--detach", "FETCH_HEAD"], cwd=recipe_checkout, report=report,
        label="media-kit-checkout")
    actual = run(["git", "rev-parse", "HEAD"], cwd=recipe_checkout, report=report,
                 label="media-kit-head").stdout.strip()
    if actual != revision:
        raise CandidateError("media-kit checkout HEAD differs from approved revision")
    recipe = recipe_checkout / "tool/shared_gpu_next"
    bridge = recipe_checkout / "media_kit_video" / MEDIA_KIT_BRIDGE
    if not recipe.is_dir() or not bridge.is_file():
        raise CandidateError("approved revision does not contain recipe and shared Swift bridge")
    names = report["media_kit_package_names"]
    paths = package_paths(recipe_checkout, names)
    report["package_paths"] = paths
    save_report(report)
    verify_source_tree(recipe_checkout, revision, paths, report)
    overrides = ROOT / "pubspec_overrides.yaml"
    lockfile = ROOT / "pubspec.lock"
    view_file = ROOT / "lib/pages/video/view.dart"
    if overrides.is_symlink() or lockfile.is_symlink() or view_file.is_symlink():
        raise CandidateError("dependency/source isolation refuses symlink targets")
    package_config = ROOT / ".dart_tool/package_config.json"
    if package_config.parent.is_symlink() or package_config.is_symlink():
        raise CandidateError(".dart_tool package configuration must not use symlinks")
    old_overrides = overrides.read_bytes() if overrides.exists() else None
    old_lock = lockfile.read_bytes() if lockfile.exists() else None
    pubspec = ROOT / "pubspec.yaml"
    release_data = ROOT / "pili_release.json"
    if any(path.is_symlink() for path in (pubspec, release_data)):
        raise CandidateError("release source transaction refuses symlink source files")
    old_pubspec = pubspec.read_bytes()
    old_release_data = release_data.read_bytes() if release_data.is_file() else None
    normalized_patch_files = sorted((ROOT / "lib/scripts/material").glob("*.patch")) + \
        sorted((ROOT / "lib/scripts/cupertino").glob("*.patch"))
    if any(path.is_symlink() for path in normalized_patch_files):
        raise CandidateError("release source transaction refuses symlink patch files")
    old_patch_files = [(path, path.read_bytes()) for path in normalized_patch_files]
    old_view = view_file.read_bytes()
    compat_pointer_line = b"            pointerDownFilter: _allowOuterVideoPointer,\n"
    if old_view.count(compat_pointer_line) != 1:
        raise CandidateError("standard Flutter pointer-filter source must occur exactly once")
    expected_view = old_view.replace(compat_pointer_line, b"", 1)
    old_package_config = package_config.read_bytes() if package_config.is_file() else None
    pub_cache = run_dir / "pub-cache"
    pub_cache.mkdir()
    env = os.environ.copy()
    env["PUB_CACHE"] = str(pub_cache)
    if production_release:
        private_flutter = run_dir / "flutter-sdk"
        configured_flutter = env.get("FLUTTER_ROOT")
        source_flutter = Path(configured_flutter) if configured_flutter else None
        if source_flutter is None or not source_flutter.is_dir():
            flutter_command = shutil.which("flutter")
            if not flutter_command:
                raise CandidateError("Flutter SDK is unavailable for the private release copy")
            source_flutter = Path(flutter_command).resolve().parent.parent
        source_flutter = source_flutter.resolve(strict=True)
        if source_flutter == ROOT or source_flutter.is_relative_to(ROOT):
            raise CandidateError("Flutter SDK source overlaps the product checkout")
        shutil.copytree(source_flutter, private_flutter, symlinks=True)
        env["FLUTTER_ROOT"] = str(private_flutter)
        env["PATH"] = str(private_flutter / "bin") + os.pathsep + env.get("PATH", "")
        env["GITHUB_WORKSPACE"] = str(ROOT)
        env.setdefault("PILIPLUSX_SKIP_POINTER_FILTER_PATCH", "1")
        github_env = run_dir / "github-env"
        github_env.write_text("", encoding="utf-8")
        env["GITHUB_ENV"] = str(github_env)
        pwsh = shutil.which("pwsh")
        if not pwsh:
            raise CandidateError("PowerShell Core is required by the existing macOS release patch scripts")
    try:
        overrides.write_bytes(merge_overrides(old_overrides, revision, paths))
        if production_release:
            run([pwsh, "-File", str(ROOT / "lib/scripts/build.ps1")], cwd=ROOT,
                env=env, report=report, label="release-version-build-script")
            run([pwsh, "-File", str(ROOT / "lib/scripts/patch.ps1"), "macOS", "-SdkOnly"],
                cwd=ROOT, env=env, report=report, label="release-sdk-patches")
        run(["flutter", "pub", "get"], cwd=ROOT, env=env, report=report, label="pub-get")
        check_lock(lockfile, revision, report)
        verify_package_config(ROOT, recipe_checkout, revision, names, paths, report, pub_cache)
        if production_release:
            run([pwsh, "-File", str(ROOT / "lib/scripts/patch.ps1"), "macOS", "-PackagesOnly"],
                cwd=ROOT, env=env, report=report, label="release-package-patches")
            check_lock(lockfile, revision, report)
            verify_package_config(ROOT, recipe_checkout, revision, names, paths, report, pub_cache)
        compat_config = json.loads((ROOT / ".dart_tool/package_config.json").read_text(encoding="utf-8"))
        compat_package = next((item for item in compat_config["packages"]
                               if item["name"] == "flutter_inappwebview_platform_interface"), None)
        if compat_package is None:
            raise CandidateError("compatibility package missing from package_config")
        parsed = urllib.parse.urlparse(compat_package["rootUri"])
        if parsed.scheme != "file":
            raise CandidateError("compatibility package root is not a local file URI")
        compat_root = assert_no_symlink_path(Path(urllib.parse.unquote(parsed.path)), pub_cache)
        compat_plan = compatibility_plan(compat_root)
        before_nodes = node_inventory(compat_root)
        expected_nodes = {name: dict(node) for name, node in before_nodes.items()}
        for relative, content in compat_plan.items():
            expected_nodes[relative] = {"type": "file", "sha256": hashlib.sha256(content).hexdigest(),
                                        "bytes": len(content)}
        run([sys.executable, str(ROOT / "scripts/prepare_standard_flutter_package_compat.py"),
             "--workspace", str(ROOT)], cwd=ROOT, env=env, report=report, label="compatibility-patch")
        after_nodes = node_inventory(compat_root)
        if view_file.read_bytes() != expected_view:
            raise CandidateError("compatibility patch changed app source outside the approved pointer-filter removal")
        require_expected_compat_nodes(expected_nodes, after_nodes)
        changed = [{"path": path, "before": before_nodes[path], "after": after_nodes[path]}
                   for path in sorted(compat_plan)]
        report["compatibility_patch"] = {"package": "flutter_inappwebview_platform_interface",
                                         "package_root": str(compat_root), "changed_files": changed,
                                         "node_inventory_sha256": hashlib.sha256(json.dumps(
                                             {"before": before_nodes, "after": after_nodes},
                                             sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
                                         "workspace_view_before_sha256": hashlib.sha256(old_view).hexdigest(),
                                         "workspace_view_after_sha256": digest(view_file),
                                         "workspace_view_unified_diff": "".join(difflib.unified_diff(
                                             old_view.decode("utf-8").splitlines(keepends=True),
                                             view_file.read_text(encoding="utf-8").splitlines(keepends=True),
                                             fromfile="before/lib/pages/video/view.dart",
                                             tofile="after/lib/pages/video/view.dart")),
                                         "workspace_view_restored_after_build": True}
        save_report(report)
        check_lock(lockfile, revision, report)
        verify_package_config(ROOT, recipe_checkout, revision, names, paths, report, pub_cache)
        verify_source_tree(recipe_checkout, revision, paths, report)

        acquire = ROOT / "scripts/fetch_macos_shared_ci_inputs.py"
        run([sys.executable, str(acquire), "fetch", "--output", str(raw), "--log-dir", str(logs / "fetch")],
            report=report, label="acquire-fetch")
        run([sys.executable, str(acquire), "verify", "--directory", str(raw)], report=report,
            label="acquire-verify")
        report["stage_receipts"] = {"raw_acquisition_manifest": receipt(raw / "acquisition-manifest.json")}
        save_report(report)
        run([sys.executable, str(acquire), "sign-contexts", "--inputs", str(raw), "--output", str(signed),
             "--log-dir", str(logs / "sign")], report=report, label="sign-contexts")
        run([sys.executable, str(acquire), "verify-contexts", "--inputs", str(raw), "--directory", str(signed),
             "--log-dir", str(logs / "verify-contexts")], report=report, label="verify-contexts")
        signed_manifest_path = signed / "sealed/signed-context-manifest.json"
        signed_manifest = json.loads(signed_manifest_path.read_text())
        ass = signed / "frameworks/Ass.framework/Versions/A/Ass"
        ass_sha = signed_manifest["after"]["Ass"]["binary_sha256"]
        if digest(ass) != ass_sha:
            raise CandidateError("verified signed Ass manifest does not match framework binary")
        report["verified_signed_ass_sha256"] = ass_sha
        report["stage_receipts"]["signed_context_manifest"] = receipt(signed_manifest_path)
        save_report(report)

        run([sys.executable, str(ROOT / "scripts/build_macos_mpv_runtime.py"), str(runtime),
             "--work-dir", str(runtime_work), "--jobs", "4"], report=report, label="fresh-runtime-build")
        run([sys.executable, str(ROOT / "scripts/verify_macos_mpv_runtime.py"), str(runtime)],
            report=report, label="fresh-runtime-verify")
        report["stage_receipts"]["fresh_runtime_manifest"] = receipt(runtime / "manifest.json")
        save_report(report)
        prepare = [sys.executable, str(ROOT / "scripts/prepare_macos_shared_inputs.py"),
            "--goodwu-archive", str(raw / "archives/libmpv-macos.tar.gz"),
            "--mpv-archive", str(raw / "archives/mpv.tar.gz"),
            "--ffmpeg-archive", str(raw / "archives/ffmpeg.tar.xz"),
            "--libass-archive", str(raw / "archives/libass.tar.gz"),
            "--runtime-work", str(runtime_work), "--runtime-directory", str(runtime),
            "--recipe", str(recipe), "--libass-library", str(ass),
            "--libass-library-sha256", ass_sha, "--uchardet-header", str(raw / "include/uchardet.h"),
            "--uchardet-header-sha256", "3322493803399ae88a24608d2844e57933cc15f33c529d8d4cce92e0b19f56cb",
            "--library-root", str(signed / "frameworks"), "--output", str(sealed)]
        run(prepare, report=report, label="prepare-sealed-inputs")
        run([sys.executable, str(ROOT / "scripts/prepare_macos_shared_inputs.py"), "--verify", str(sealed),
             "--recipe", str(recipe)], report=report, label="verify-sealed-inputs")
        report["stage_receipts"]["sealed_inputs_manifest"] = receipt(sealed / "sealed/inputs-manifest.json")
        save_report(report)

        # Keep the source lock and any pre-existing overrides byte-for-byte
        # isolated. Flutter sees the bootstrap mode only in its child process.
        build_env = env.copy()
        build_env["PILIPLUSX_MPV_BUNDLE_MODE"] = "shared-candidate-bootstrap"
        flutter_build_dir = run_dir / "flutter-build"
        run(["flutter", "build", "macos", "--release", "--dart-define-from-file=pili_release.json",
             "--no-pub", "--build-dir", str(flutter_build_dir)],
            cwd=ROOT, env=build_env, report=report, label="bootstrap-release-build")
        app = flutter_build_dir / "macos/Build/Products/Release/PiliPlusX.app"
        info = app / "Contents/Info.plist"
        runner = app / "Contents/MacOS/PiliPlusX"
        with info.open("rb") as stream:
            bootstrap_info = plistlib.load(stream)
        report["bootstrap_info"] = {"sha256": digest(info),
                                     "pending": bootstrap_info.get("MediaKitSharedBootstrapPending"),
                                     "runner_sha256": digest(runner)}
        save_report(report)
        if bootstrap_info.get("MediaKitSharedBootstrapPending") is not True:
            raise CandidateError("bootstrap App must be signed with pending=true")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], report=report,
            label="bootstrap-signature")
        for arch in ("arm64", "x86_64"):
            run(["/usr/bin/lipo", "-verify_arch", arch, str(runner)], report=report,
                label=f"bootstrap-runner-{arch}")
        gate = run([str(ROOT / "scripts/verify_macos_mpv_bundle.sh"), str(app)], report=report,
                   label="bootstrap-ordinary-guard", check=False)
        if gate.returncode == 0 or "shared bootstrap is pending" not in gate.stdout + gate.stderr:
            raise CandidateError("ordinary bundle guard did not explicitly reject pending bootstrap")

        artifact = run_dir / "artifact"
        artifact.mkdir()
        candidate = artifact / "PiliPlusX-shared-candidate.app"
        slices = run_dir / "shared-slices"
        run([sys.executable, str(ROOT / "scripts/build_macos_shared_candidate.py"),
             "--input-app", str(app), "--inputs", str(sealed), "--recipe", str(recipe),
             "--work-dir", str(run_dir / "shared-work"), "--published-dir", str(slices),
             "--output-app", str(candidate), "--log-dir", str(logs / "consumer"),
             "--input-kind", "normal", "--jobs", "4"], report=report, label="shared-consumer")
        consumer_result = logs / "consumer/result.json"
        consumer_receipt = receipt(consumer_result)
        consumer_receipt["summary"] = json.loads(consumer_result.read_text())
        report["stage_receipts"]["consumer_result"] = consumer_receipt
        save_report(report)
        run([str(ROOT / "scripts/verify_macos_mpv_bundle.sh"), str(candidate)], report=report,
            label="final-bundle-gate")
        final_info_path = candidate / "Contents/Info.plist"
        with final_info_path.open("rb") as stream:
            final_info = plistlib.load(stream)
        report["final_info"] = {"sha256": digest(final_info_path),
                                "pending_key_present": "MediaKitSharedBootstrapPending" in final_info,
                                "shared_renderer": final_info.get("MediaKitSharedRenderer")}
        save_report(report)
        if "MediaKitSharedBootstrapPending" in final_info:
            raise CandidateError("final candidate still contains bootstrap pending marker")
        if final_info.get("MediaKitSharedRenderer") is not True:
            raise CandidateError("final candidate does not enable the shared core")
        for sidecar in (candidate.with_suffix(".shared-core.json"),
                        candidate.with_suffix(".shared-backend.json")):
            if not sidecar.is_file():
                raise CandidateError(f"consumer sidecar missing: {sidecar.name}")
        archive = None
        if not production_release:
            archive = artifact / "PiliPlusX-shared-candidate.zip"
            run(["/usr/bin/ditto", "-c", "-k", "--keepParent", str(candidate), str(archive)],
                report=report, label="candidate-archive")
        receipts_dir = artifact / "receipts"
        receipts_dir.mkdir()
        retained = {}
        receipt_sources = {
            "acquisition-manifest.json": raw / "acquisition-manifest.json",
            "signed-context-manifest.json": signed_manifest_path,
            "runtime-manifest.json": runtime / "manifest.json",
            "sealed-inputs-manifest.json": sealed / "sealed/inputs-manifest.json",
            "consumer-result.json": consumer_result,
        }
        for name, source in receipt_sources.items():
            destination = receipts_dir / name
            shutil.copy2(source, destination)
            retained[name] = {**receipt(destination), "source_sha256": digest(source)}
        retained["pipeline_logs"] = retain_log_tree(logs, receipts_dir / "logs")
        retained["fresh_runtime_build_logs"] = retain_log_tree(runtime_work / "logs",
                                                                 receipts_dir / "runtime-build-logs")
        (receipts_dir / "stage-receipts.json").write_text(
            json.dumps({"source_ref": source_ref, "approved_media_kit_revision": revision,
                        "receipts": retained}, sort_keys=True, indent=2) + "\n")
        report["stage_receipts"]["published_candidate"] = {
            **({"app_zip": receipt(archive)} if archive else {}),
            "shared_core": receipt(candidate.with_suffix(".shared-core.json")),
            "shared_backend": receipt(candidate.with_suffix(".shared-backend.json")),
            "retained_receipts_index": receipt(receipts_dir / "stage-receipts.json"),
        }
        if production_release:
            app_nodes = node_inventory(candidate)
            app_identity = hashlib.sha256(json.dumps(app_nodes, sort_keys=True,
                separators=(",", ":")).encode()).hexdigest()
            report["stage_receipts"]["published_candidate"]["final_app"] = {
                "path": str(candidate), "tree_identity_sha256": app_identity,
                "node_count": len(app_nodes), "inventory_sha256": app_identity,
            }
        else:
            report["stage_receipts"]["published_candidate"]["app_zip"] = receipt(archive)
        report["artifact"] = {"directory": str(artifact),
                              **({"app_zip": str(archive)} if archive else {"final_app": str(candidate)}),
                              "sidecars": [str(candidate.with_suffix(".shared-core.json")),
                                           str(candidate.with_suffix(".shared-backend.json"))],
                              "production_default_enabled": False, "visual_acceptance": "pending"}
        report["status"] = "candidate-built"
        save_report(report)
        pipeline_result = {
            "final_app": str(candidate),
            "shared_core": str(candidate.with_suffix(".shared-core.json")),
            "shared_backend": str(candidate.with_suffix(".shared-backend.json")),
            "artifact_directory": str(artifact),
            "source_ref": source_ref,
            "approved_media_kit_revision": revision,
            "recipe": str(recipe),
            "sealed_inputs_manifest": str(sealed / "sealed/inputs-manifest.json"),
            "signed_context_manifest": str(signed_manifest_path),
            "runtime_manifest": str(runtime / "manifest.json"),
            "raw_acquisition_manifest": str(raw / "acquisition-manifest.json"),
            "consumer_result": str(consumer_result),
            "prepared_source": str(run_dir / "shared-work/source"),
            "consumer_log_directory": str(logs / "consumer"),
            "report_path": report["report_path"],
            "production_release": production_release,
        }
    finally:
        restore_errors = []
        for path, content in ((overrides, old_overrides), (lockfile, old_lock),
                              (view_file, old_view), (package_config, old_package_config),
                              (pubspec, old_pubspec), (release_data, old_release_data)):
            try:
                restore_file(path, content)
            except Exception as restore_error:
                restore_errors.append(f"{path}: {restore_error}")
        for path, content in old_patch_files:
            try:
                restore_file(path, content)
            except Exception as restore_error:
                restore_errors.append(f"{path}: {restore_error}")
        if restore_errors:
            raise CandidateError("workspace restoration failed: " + "; ".join(restore_errors))
    return pipeline_result


def main() -> int:
    preflight_only = "--preflight" in sys.argv[1:]
    source_ref = os.environ.get("SOURCE_REF", "")
    github_sha = os.environ.get("GITHUB_SHA", "")
    report = {"schema": 1, "status": "preflight", "source_ref": source_ref,
              "github_sha": github_sha, "commands": [], "media_kit_package_names": []}
    owned = False
    try:
        runner_temp = Path(os.environ.get("RUNNER_TEMP", ""))
        run_dir, report_path = owned_runner_paths(
            runner_temp, os.environ.get("GITHUB_RUN_ID", "0"),
            os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
        report.update(run_dir=str(run_dir), report_path=str(report_path))
        owned = True
        save_report(report)
        # Authorization precedes host checks, imports, network, pub get and build.
        revision = load_approved_revision()
        validate_source_ref(source_ref, github_sha)
        report["approved_media_kit_revision"] = revision
        if preflight_only:
            # A successful preflight leaves no reservation behind; the full
            # runner creates its own exclusive diagnostics/run directories.
            shutil.rmtree(run_dir)
            shutil.rmtree(report_path.parent)
            shutil.rmtree(run_dir.parent)
            print(json.dumps({"source_ref": source_ref,
                              "approved_media_kit_revision": revision}, sort_keys=True))
            return 0
        report["status"] = "running"
        runner_temp = runner_temp.resolve(strict=True)
        if runner_temp == ROOT or runner_temp.is_relative_to(ROOT) or ROOT.is_relative_to(runner_temp):
            raise CandidateError("RUNNER_TEMP must be independent from the checkout")
        save_report(report)
        require_host(report)
        # Parse source manifests only after the immutable approval gate.
        names = set()
        for manifest in (ROOT / "pubspec.yaml", ROOT / "pubspec.lock"):
            text = manifest.read_text(encoding="utf-8")
            names.update(re.findall(r"(?m)^  (media_kit(?:[^:]*)):\s*$", text))
        report["media_kit_package_names"] = sorted(names)
        if not names:
            raise CandidateError("no media-kit packages in source dependency declarations")
        save_report(report)
        run_pipeline(report, source_ref, revision)
        return 0
    except Exception as error:
        report["status"] = "source-preflight-failed" if preflight_only else "failed"
        report["error"] = str(error)
        if owned:
            save_report(report)
        print(f"FAIL: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
