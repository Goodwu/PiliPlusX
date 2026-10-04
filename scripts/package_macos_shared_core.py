#!/usr/bin/env python3
"""Package a fresh, explicitly identified shared-core candidate.

This creates a separate app and verifies existing version/loading/signature
gates. Real backend rendering and visible acceptance are separate requirements.
"""
import argparse
import ctypes
import os
import stat
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import shutil
import tempfile
import sys


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(*command):
    subprocess.run(list(map(str, command)), check=True)



PENDING = "MediaKitSharedBootstrapPending"
SUFFIXES = (".shared-core.json", ".shared-backend.json")


def app_tree(root):
    """Include all entries and link target text; never follow external links."""
    result = {}
    def walk(directory):
        for path in sorted(directory.iterdir()):
            relative = path.relative_to(root).as_posix()
            mode = path.lstat().st_mode
            if stat.S_ISLNK(mode):
                if not path.resolve(strict=True).is_relative_to(root):
                    raise ValueError("application link escapes root: " + str(path))
                result[relative] = ("link", os.readlink(path))
            elif stat.S_ISDIR(mode):
                result[relative] = ("directory", stat.S_IMODE(mode))
                walk(path)
            elif stat.S_ISREG(mode):
                result[relative] = ("file", stat.S_IMODE(mode), sha(path))
            else:
                raise ValueError("unsafe application entry: " + str(path))
    walk(root)
    if not result:
        raise ValueError("empty source application")
    return result


def overlap(a, b):
    return a == b or a.is_relative_to(b) or b.is_relative_to(a)


def preflight(args):
    outputs = [args.output_app, *(args.output_app.with_suffix(s) for s in SUFFIXES)]
    protected = [args.input_app, *(getattr(args, n).resolve() for n in
                  ("arm64", "x86_64", "slice_manifest", "prepared_source", "source_manifest")),
                 Path(__file__).resolve().parents[1]]
    for index, output in enumerate(outputs):
        if os.path.lexists(output):
            raise ValueError("output or evidence already exists: " + str(output))
        if any(overlap(output, p) for p in protected + outputs[:index]):
            raise ValueError("output overlaps an input or other output: " + str(output))
    if not args.output_app.parent.is_dir():
        raise ValueError("output parent must already exist")


def publish_absent(stage, destination):
    if sys.platform != "darwin":
        raise RuntimeError("exclusive application publication requires macOS")
    libc = ctypes.CDLL(None, use_errno=True)
    function = libc.renamex_np
    function.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(os.fsencode(stage), os.fsencode(destination), 4):
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(destination))


def publish(staged, output):
    destinations = [output, *(output.with_suffix(s) for s in SUFFIXES)]
    if any(os.path.lexists(p) for p in destinations):
        raise FileExistsError("output or sidecar appeared before publication")
    installed = []
    try:
        for suffix in SUFFIXES:
            source = staged.with_suffix(suffix)
            if source.is_symlink() or not source.is_file():
                raise ValueError("missing regular evidence sidecar")
            destination = output.with_suffix(suffix)
            os.link(source, destination)
            installed.append((destination, destination.lstat().st_ino))
        publish_absent(staged, output)
    except BaseException:
        for path, inode in reversed(installed):
            if (not path.is_symlink() and path.exists()
                    and path.lstat().st_ino == inode):
                path.unlink()
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input_app", type=Path)
    parser.add_argument("output_app", type=Path)
    parser.add_argument("arm64", type=Path)
    parser.add_argument("x86_64", type=Path)
    parser.add_argument("slice_manifest", type=Path,
                        help="JSON mapping architecture to the approved slice SHA-256")
    parser.add_argument("--prepared-source", type=Path, required=True)
    parser.add_argument("--source-manifest", type=Path, required=True)
    args = parser.parse_args(argv)
    if args.output_app.is_symlink():
        parser.error("output app must not be a symbolic link")
    args.input_app = args.input_app.resolve(strict=True)
    args.output_app = args.output_app.resolve()
    preflight(args)
    before = app_tree(args.input_app)
    run("codesign", "--verify", "--deep", "--strict", args.input_app)
    manifest = json.loads(args.slice_manifest.read_text())
    for architecture in ("arm64", "x86_64"):
        library = getattr(args, architecture)
        if sha(library) != manifest[architecture]:
            parser.error(f"{architecture} library hash differs from the selected input")
        actual = subprocess.check_output(["lipo", "-archs", str(library)], text=True).strip()
        if actual != architecture:
            parser.error(f"expected a single {architecture} slice, got {actual}")
    frameworks = args.input_app / "Contents/Frameworks"
    plugin = frameworks / "media_kit_video.framework/Versions/A/media_kit_video"
    # SPM links this plugin statically into Runner; CocoaPods may embed it.
    with (args.input_app / "Contents/Info.plist").open("rb") as stream:
        input_info = plistlib.load(stream)
        executable = input_info["CFBundleExecutable"]
    pending = PENDING in input_info
    if pending and input_info[PENDING] is not True:
        parser.error("invalid bootstrap pending value; expected true or absent")
    if not isinstance(executable, str) or "/" in executable or executable in (".", ".."):
        parser.error("invalid input application executable")
    runner = args.input_app / "Contents/MacOS" / executable
    runner_architectures = set(subprocess.check_output(
        ["lipo", "-archs", str(runner)], text=True).split())
    if runner_architectures != {"arm64", "x86_64"}:
        parser.error("shared-core universal candidate requires an arm64+x86_64 application")
    bridge_binary = plugin if plugin.is_file() else args.input_app / "Contents/MacOS" / executable
    if not bridge_binary.is_file() or b"MediaKitSharedRenderer" not in bridge_binary.read_bytes():
        parser.error("input app must be rebuilt with the shared-core bridge before packaging")
    with tempfile.TemporaryDirectory(prefix="shared-bridge-check-") as temporary:
        for architecture in ("arm64", "x86_64"):
            thin = Path(temporary) / architecture
            run("lipo", bridge_binary, "-thin", architecture, "-output", thin)
            if b"MediaKitSharedRenderer" not in thin.read_bytes():
                parser.error(f"{architecture} application lacks the shared bridge marker")
    with tempfile.TemporaryDirectory(prefix="." + args.output_app.stem + ".shared-core-",
                                     dir=args.output_app.parent) as temporary:
        staged_app = Path(temporary) / "Candidate.app"
        run("ditto", args.input_app, staged_app)
        # A copied absolute link can still point at the source App. Validate
        # containment and exact copy identity before modifying or signing it.
        if app_tree(staged_app) != before:
            raise ValueError("private application copy differs from source tree")
        binary = staged_app / "Contents/Frameworks/Mpv.framework/Versions/A/Mpv"
        # Normalize each thin copy independently: architectures may have different
        # build RPATHs, which install_name_tool cannot delete in a fat image at once.
        with tempfile.TemporaryDirectory(prefix="shared-slices-") as temporary:
            slices = []
            for architecture in ("arm64", "x86_64"):
                thin = Path(temporary) / architecture
                shutil.copy2(getattr(args, architecture), thin)
                run("install_name_tool", "-id", "@rpath/Mpv.framework/Versions/A/Mpv", thin)
                commands = subprocess.check_output(["otool", "-l", str(thin)], text=True).splitlines()
                old_paths = set()
                for index, line in enumerate(commands):
                    if line.strip() == "cmd LC_RPATH":
                        old_paths.add(commands[index + 2].strip().split(" (offset")[0].removeprefix("path "))
                for path in old_paths:
                    run("install_name_tool", "-delete_rpath", path, thin)
                run("install_name_tool", "-add_rpath", "@loader_path/../../..", thin)
                slices.append(thin)
            run("lipo", "-create", *slices, "-output", binary)
        info = staged_app / "Contents/Info.plist"
        with info.open("rb") as stream:
            values = plistlib.load(stream)
        values.pop(PENDING, None)
        values["MediaKitSharedRenderer"] = True
        with info.open("wb") as stream:
            plistlib.dump(values, stream)
        run("codesign", "--force", "--sign", "-", staged_app / "Contents/Frameworks/Mpv.framework")
        run("codesign", "--force", "--sign", "-", "--preserve-metadata=entitlements,requirements,flags", staged_app)
        run(Path(__file__).with_name("verify_macos_mpv_bundle.sh"), staged_app)
        run(sys.executable, Path(__file__).with_name("verify_macos_shared_backend.py"),
            staged_app, args.prepared_source, args.source_manifest,
            "--report", staged_app.with_suffix(".shared-backend.json"))
        output_runner = staged_app / "Contents/MacOS" / executable
        record = {"bootstrap_source_pending": pending, "slice_inputs": manifest, "framework_sha256": sha(binary),
                  "runner_sha256": sha(output_runner),
                  "bridge_input_sha256": sha(bridge_binary),
                  "bridge_marker_check": "passed-both-architectures; auxiliary freshness only",
                  "shared_renderer_enabled": True, "visible_acceptance": "pending",
                  "shared_backend_creation_and_empty_target_render": "passed-both-architectures",
                  "shared_video_content_acceptance": "pending"}
        staged_app.with_suffix(".shared-core.json").write_text(json.dumps(record, indent=2) + "\n")

        if app_tree(args.input_app) != before:
            raise ValueError("source application changed during packaging")
        for architecture in ("arm64", "x86_64"):
            if sha(getattr(args, architecture)) != manifest[architecture]:
                raise ValueError("selected slice changed during packaging")
        final_info = plistlib.loads((staged_app / "Contents/Info.plist").read_bytes())
        if PENDING in final_info:
            raise ValueError("bootstrap pending was not cleared in staged product")
        preflight(args)
        publish(staged_app, args.output_app)


if __name__ == "__main__":
    main()
