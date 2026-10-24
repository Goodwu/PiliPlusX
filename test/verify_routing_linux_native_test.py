import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
SPEC = importlib.util.spec_from_file_location("linux_gate", SCRIPTS / "verify_routing_linux_native.py")
gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(gate)


def git(root, *args):
    return subprocess.run(["git", "-C", str(root), *args], check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True).stdout.strip()


def fixture_repo(root, remote, files):
    root.mkdir(parents=True)
    git(root, "init", "-b", "routing/MK-ROUTING-20261011")
    git(root, "config", "user.email", "test@example.invalid")
    git(root, "config", "user.name", "Test")
    git(root, "remote", "add", "origin", remote)
    for name, data in files.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data if isinstance(data, bytes) else data.encode())
    git(root, "add", "--all")
    git(root, "commit", "-m", "source fixture")


def synthetic_manifest():
    evidence = []
    for identifier, kind in (("ffmpeg", "source"), ("mpv", "source"),
                             ("placebo", "source"), ("recipe", "source"),
                             ("toolchain", "toolchain"), ("clean", "staging"),
                             ("members", "members"), ("link", "link"),
                             ("dep-contract", "dependency-contract")):
        evidence.append({"id": identifier, "path": f"{identifier}.txt",
                         "sha256": "a" * 64, "kind": kind})
    components = {}
    for name, ref in (("FFmpeg", "ffmpeg"), ("mpv", "mpv"),
                      ("libplacebo", "placebo"), ("recipe", "recipe")):
        components[name] = {"repository": f"https://github.com/Goodwu/{name}.git",
                             "commit": "1" * 40, "tree": "2" * 40,
                             "patches": [], "sourceEvidence": ref}
    link_inputs = [{"component": name, "path": f"src/{name}.a", "sha256": "b" * 64}
                   for name in ("FFmpeg", "mpv", "libplacebo", "recipe", "toolchain")]
    member = {"sha256": "c" * 64, "buildId": "1234567890abcdef",
              "soname": "libmpv.so.2", "elfClass": 64, "machine": 62,
              "type": "DYN", "needed": ["libc.so.6"], "rpath": [], "runpath": [],
              "versionNeeds": [{"library": "libc.so.6", "versions": ["GLIBC_2.2.5"]}]}
    return {"schemaVersion": 1, "task": gate.TASK, "platform": "linux-x86_64",
            "artifact": {"kind": "zip", "name": "linux-native.zip", "sha256": "d" * 64,
                          "identity": {"repository": "Goodwu/libmpv-linux-build", "runId": 1,
                                       "attempt": 1, "artifactId": 2}},
            "components": components,
            "toolchain": {"name": "clang", "version": "17", "sha256": "e" * 64,
                          "sysrootSha256": "f" * 64, "evidence": "toolchain"},
            "staging": {"cleanEvidence": "clean", "membersEvidence": "members", "linkEvidence": "link"},
            "linkInputs": link_inputs, "evidence": evidence,
            "members": {gate.ROOT_MEMBER: member},
            "headers": {"include/mpv/client.h": "9" * 64},
            "dependencyClosure": [{"requester": gate.ROOT_MEMBER, "needed": "libc.so.6",
                                   "kind": "system", "contract": "glibc"}],
            "systemContracts": [{"id": "glibc", "evidence": "dep-contract", "abi": "x86_64",
                                 "minimumBaseline": "glibc-2.17",
                                 "sonames": [{"name": "libc.so.6", "versions": ["GLIBC_2.2.5"]}]}]}


class LinuxNativeGateTest(unittest.TestCase):
    def test_plugin_runtime_path_is_exact_and_rejects_empty_absolute_and_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            plugin = Path(temporary) / "libmedia_kit_video_plugin.so"
            plugin.write_bytes(b"synthetic ELF fixture")
            manifest = synthetic_manifest()
            old_verify_local, old_run_tool = gate.verify_local, gate.run_tool
            try:
                gate.verify_local = lambda *args, **kwargs: manifest
                def reader(argv, _receipt):
                    if argv[1] == "-h":
                        return "Class: ELF64\nData: 2's complement, little endian\nType: DYN (Shared object file)\nMachine: Advanced Micro Devices X86-64\n"
                    return "(NEEDED) Shared library: [libmpv.so.2]\n(RUNPATH) Library runpath: [$ORIGIN]\n"
                gate.run_tool = reader
                gate.verify_plugin(plugin, base, base / "receipt",
                                   base, base, "readelf", {})
                for runpath in ("/tmp/evil:$ORIGIN", "$ORIGIN::", "$ORIGIN/../outside",
                                "$ORIGIN:$ORIGIN/lib"):
                    def unsafe_reader(argv, receipt, value=runpath):
                        if argv[1] == "-h":
                            return "Class: ELF64\nData: 2's complement, little endian\nType: DYN (Shared object file)\nMachine: Advanced Micro Devices X86-64\n"
                        return f"(NEEDED) Shared library: [libmpv.so.2]\n(RUNPATH) Library runpath: [{value}]\n"
                    gate.run_tool = unsafe_reader
                    with self.assertRaisesRegex(gate.GateError, "runtime search path"):
                        gate.verify_plugin(plugin, base, base / "receipt",
                                           base, base, "readelf", {})
            finally:
                gate.verify_local, gate.run_tool = old_verify_local, old_run_tool

    def test_bundle_requires_canonical_loader_visible_paths_and_rejects_duplicates(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, bundle = base / "native", base / "bundle"
            (root / "lib").mkdir(parents=True)
            (bundle / "lib").mkdir(parents=True)
            raw = bytearray(64)
            raw[:6] = b"\x7fELF\x02\x01"
            raw[16:18] = (3).to_bytes(2, "little")
            raw[18:20] = (62).to_bytes(2, "little")
            (root / "lib/libmpv.so.2").write_bytes(raw)
            (bundle / "lib/libmpv.so.2").write_bytes(raw)
            (bundle / "lib/libmedia_kit_video_plugin.so").write_bytes(raw)
            manifest = synthetic_manifest()
            old = (gate.verify_local, gate.verify_plugin, gate.inspect_elf, gate.run_tool)
            try:
                gate.verify_local = lambda *args, **kwargs: manifest
                gate.verify_plugin = lambda plugin, *args, **kwargs: self.assertEqual(
                    plugin, bundle / "lib/libmedia_kit_video_plugin.so")
                gate.inspect_elf = lambda path, rel, declaration, *args, **kwargs: declaration
                def reader(argv, receipt):
                    if argv[1] == "-h":
                        return "Class: ELF64\nData: 2's complement, little endian\nType: DYN (Shared object file)\nMachine: Advanced Micro Devices X86-64\n"
                    return "(NEEDED) Shared library: [libmpv.so.2]"
                gate.run_tool = reader
                receipt = {}
                gate.verify_bundle(bundle, root, base / "receipt", base, base, "readelf", receipt)
                self.assertFalse(receipt["fullBundleProvenanceVerified"])
                self.assertFalse(receipt["releaseVerified"])
                extra = bundle / "lib/libflutter_linux_gtk.so"
                extra.write_bytes(raw)
                receipt = {}
                gate.verify_bundle(bundle, root, base / "receipt", base, base, "readelf", receipt)
                item = next(obj for obj in receipt["bundleSharedLibraries"]
                            if obj["path"] == "lib/libflutter_linux_gtk.so")
                self.assertEqual(item["sourceStatus"], "unbound-generated-build-output")
                self.assertFalse(receipt["fullBundleProvenanceVerified"])
                wrong_abi = bytearray(raw)
                wrong_abi[18:20] = (183).to_bytes(2, "little")
                extra.write_bytes(wrong_abi)
                with self.assertRaisesRegex(gate.GateError, "ET_DYN"):
                    gate.verify_bundle(bundle, root, base / "receipt", base, base, "readelf", {})
                extra.write_bytes(raw)
                old_reader = gate.run_tool
                gate.run_tool = lambda argv, receipt: (_ for _ in ()).throw(
                    gate.GateError("ELF inspection tool failed")) if argv[1] == "-h" and "libflutter" in argv[-1] else old_reader(argv, receipt)
                with self.assertRaisesRegex(gate.GateError, "ELF inspection tool failed"):
                    gate.verify_bundle(bundle, root, base / "receipt", base, base, "readelf", {})
                gate.run_tool = old_reader
                moved = bundle / "elsewhere"
                moved.mkdir()
                (bundle / "lib/libmpv.so.2").rename(moved / "libmpv.so.2")
                with self.assertRaisesRegex(gate.GateError, "canonical DSO"):
                    gate.verify_bundle(bundle, root, base / "receipt", base, base, "readelf", {})
                (moved / "libmpv.so.2").rename(bundle / "lib/libmpv.so.2")
                duplicate = bundle / "duplicate"
                duplicate.mkdir()
                (duplicate / "libmpv.so.2").write_bytes(b"accepted DSO")
                with self.assertRaisesRegex(gate.GateError, "outside canonical"):
                    gate.verify_bundle(bundle, root, base / "receipt", base, base, "readelf", {})
            finally:
                gate.verify_local, gate.verify_plugin, gate.inspect_elf, gate.run_tool = old

    def test_bundle_resolves_each_bundled_needed_edge_using_its_requester_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary)
            root, bundle = base / "native", base / "bundle"
            (root / "lib/deps").mkdir(parents=True)
            (bundle / "lib").mkdir(parents=True)
            raw = bytearray(64)
            raw[:6] = b"\x7fELF\x02\x01"
            raw[16:18] = (3).to_bytes(2, "little")
            raw[18:20] = (62).to_bytes(2, "little")
            names = ("libmpv.so.2", "libreviewdep.so.1", "libreviewleaf.so.1")
            paths = ("lib/libmpv.so.2", "lib/deps/libreviewdep.so.1",
                     "lib/deps/libreviewleaf.so.1")
            manifest = synthetic_manifest()
            root_member = manifest["members"][gate.ROOT_MEMBER]
            root_member.update(needed=[names[1]], runpath=["$ORIGIN"])
            dep1 = {**root_member, "sha256": "0" * 64, "soname": names[1],
                    "needed": [names[2]], "versionNeeds": [], "runpath": ["$ORIGIN"]}
            dep2 = {**root_member, "sha256": "0" * 64, "soname": names[2],
                    "needed": ["libc.so.6"], "versionNeeds": [], "runpath": []}
            for idx, (path, soname) in enumerate(zip(paths, names)):
                contents = bytes(raw) + bytes([idx])
                (root / path).parent.mkdir(parents=True, exist_ok=True)
                (root / path).write_bytes(contents)
                (bundle / "lib" / soname).write_bytes(contents)
                declaration = root_member if idx == 0 else dep1 if idx == 1 else dep2
                declaration["sha256"] = gate.digest(contents)
                declaration["buildId"] = "1234567890abcdef"
                if idx:
                    manifest["members"][path] = declaration
            manifest["dependencyClosure"] = [
                {"requester": paths[0], "needed": names[1], "kind": "bundled",
                 "member": paths[1], "sha256": manifest["members"][paths[1]]["sha256"]},
                {"requester": paths[1], "needed": names[2], "kind": "bundled",
                 "member": paths[2], "sha256": manifest["members"][paths[2]]["sha256"]},
                {"requester": paths[2], "needed": "libc.so.6", "kind": "system",
                 "contract": "glibc"},
            ]
            plugin = bundle / "lib/libmedia_kit_video_plugin.so"
            plugin.write_bytes(raw)
            old = (gate.verify_local, gate.verify_plugin, gate.inspect_elf, gate.run_tool)
            try:
                gate.verify_local = lambda *args, **kwargs: manifest
                gate.verify_plugin = lambda *args, **kwargs: None
                gate.inspect_elf = lambda path, rel, declaration, *args, **kwargs: declaration
                gate.run_tool = lambda argv, receipt: (
                    "Class: ELF64\nData: 2's complement, little endian\nType: DYN (Shared object file)\nMachine: Advanced Micro Devices X86-64\n"
                    if argv[1] == "-h" else "(NEEDED) Shared library: [libmpv.so.2]")
                gate.verify_bundle(bundle, root, base / "receipt", base, base, "readelf", {})
                for rel in paths[:2]:
                    declaration = manifest["members"][rel]
                    prior = declaration["runpath"]
                    declaration["runpath"] = []
                    with self.assertRaisesRegex(gate.GateError, r"requester lacks its own exact \$ORIGIN"):
                        gate.verify_bundle(bundle, root, base / "receipt", base, base, "readelf", {})
                    declaration["runpath"] = prior
            finally:
                gate.verify_local, gate.verify_plugin, gate.inspect_elf, gate.run_tool = old

    def test_empty_ledger_is_explicitly_unapproved(self):
        ledger = {"schemaVersion": 1, "task": gate.TASK,
                  "selectedManifestSha256": None, "entries": []}
        self.assertEqual(ledger["entries"], [])
        with self.assertRaisesRegex(gate.GateError, "missing-accepted-linux-native-input"):
            gate.selected_entry(ledger)

    def test_receipt_cannot_self_authorize_an_empty_ledger(self):
        with tempfile.TemporaryDirectory() as temp:
            app = Path(temp) / "app"
            app.mkdir()
            git(app, "init", "-b", "routing/MK-ROUTING-20261011")
            git(app, "config", "user.email", "test@example.invalid")
            git(app, "config", "user.name", "Test")
            git(app, "remote", "add", "origin", "https://github.com/Goodwu/PiliPlusX.git")
            (app / "scripts").mkdir()
            (app / "scripts/verify_routing_linux_native.py").write_bytes((SCRIPTS / "verify_routing_linux_native.py").read_bytes())
            ledger_path = app / gate.LEDGER_REL
            ledger_path.parent.mkdir(parents=True)
            ledger_path.write_text(json.dumps({"schemaVersion": 1, "task": gate.TASK,
                                               "selectedManifestSha256": None, "entries": []}) + "\n")
            git(app, "add", "--all")
            git(app, "commit", "-m", "fixture")
            receipt = {"schemaVersion": 1, "task": gate.TASK,
                       "scope": "routing-linux-native-input", "stage": "verified-input",
                       "status": "passed", "nativeVerified": True, "deviceVerified": False,
                       "consumer": {}, "native": {}, "verifierSha256": "f" * 64,
                       "files": {"members": {}, "headers": {}}, "commands": []}
            result = subprocess.run([sys.executable, str(SCRIPTS / "verify_routing_linux_native.py"),
                                     "--check-ledger", "--app-root", str(app),
                                     "--receipt", str(Path(temp) / "result.json")],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            saved = __import__("json").loads((Path(temp) / "result.json").read_text())
            self.assertIn("missing-accepted-linux-native-input", saved["reason"])

    def test_duplicate_json_fields_are_rejected(self):
        with self.assertRaisesRegex(gate.GateError, "duplicate JSON field"):
            gate.json_bytes(b'{"task":"a","task":"b"}', "fixture")

    def test_synthetic_elf_dependency_closure_is_explicit_and_bounded(self):
        manifest = gate.validate_manifest(synthetic_manifest())
        self.assertEqual(manifest["dependencyClosure"][0]["contract"], "glibc")
        missing = synthetic_manifest()
        missing["dependencyClosure"] = []
        with self.assertRaisesRegex(gate.GateError, "missing or adds a NEEDED resolution"):
            gate.validate_manifest(missing)
        weakened = synthetic_manifest()
        weakened["systemContracts"][0]["sonames"][0]["versions"] = []
        with self.assertRaisesRegex(gate.GateError, "exceed approved contract"):
            gate.validate_manifest(weakened)
        unsafe = synthetic_manifest()
        unsafe["members"][gate.ROOT_MEMBER]["runpath"] = ["/tmp/lib"]
        with self.assertRaisesRegex(gate.GateError, "only bounded ORIGIN-relative"):
            gate.validate_manifest(unsafe)

    def test_synthetic_elf_reader_checks_metadata_and_rejects_tool_failure(self):
        # Synthetic bytes and reader output exercise parser decisions only; they
        # are not evidence of a native producer artifact or Linux release.
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binary = root / "libmpv.so.2"
            raw = bytearray(64)
            raw[:6] = b"\x7fELF\x02\x01"
            raw[16:18] = (3).to_bytes(2, "little")
            raw[18:20] = (62).to_bytes(2, "little")
            binary.write_bytes(raw)
            fake_tool = root / "readelf"
            fake_tool.write_text("""#!/usr/bin/env python3
import sys
option = sys.argv[1]
if option == '-h':
 print('  Class: ELF64\\n  Data: 2\\'s complement, little endian\\n  Type: DYN (Shared object file)\\n  Machine: Advanced Micro Devices X86-64')
elif option == '-n': print('Build ID: 1234567890abcdef')
elif option == '-d': print(' 0x (SONAME) Library soname: [libmpv.so.2]\\n 0x (NEEDED) Shared library: [libc.so.6]')
elif option == '--version-info': print('File: libc.so.6\\n  Name: GLIBC_2.2.5')
else: sys.exit(2)
""")
            fake_tool.chmod(0o755)
            declaration = synthetic_manifest()["members"][gate.ROOT_MEMBER]
            result = gate.inspect_elf(binary, gate.ROOT_MEMBER, declaration, str(fake_tool), {"commands": []})
            self.assertEqual(result["soname"], "libmpv.so.2")
            fake_tool.write_text("#!/usr/bin/env python3\nimport sys\nsys.stderr.write('readelf failure')\nsys.exit(1)\n")
            with self.assertRaisesRegex(gate.GateError, "ELF inspection tool failed"):
                gate.inspect_elf(binary, gate.ROOT_MEMBER, declaration, str(fake_tool), {"commands": []})

    def test_nonempty_approved_closure_survives_ledger_only_commit_head_change(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            app = base / "app"
            media = base / "media"
            fixture_repo(app, "https://github.com/Goodwu/PiliPlusX.git", {
                "lib/player.dart": "route API\n", "scripts/acquire_routing_linux_native.py": "acquire\n",
                "scripts/verify_routing_linux_native.py": "verify\n", "scripts/verify_routing_sources.py": "source verify\n",
                "scripts/prepare_routing_ci.py": "bootstrap\n", ".github/actions/routing-bootstrap/action.yml": "action\n",
                "scripts/routing_flutter_version.py": "exact SDK pin\n",
                "scripts/verify_media_kit_lock.py": "lock gate\n",
                "scripts/verify_workflow_media_kit_refs.py": "workflow gate\n",
                "scripts/verify_binary_arch.py": "abi gate\n", "scripts/release_manifest.py": "release\n",
                "scripts/verify_release_manifest.py": "release verify\n",
                "scripts/shared_gate_execution.py": "shared gate\n",
                "scripts/prepare_ohos_package_patches.py": "linux preparation dependency\n",
                "linux/CMakeLists.txt": "linux app\n",
                "linux/flutter/CMakeLists.txt": "flutter cmake\n",
                "linux/runner/CMakeLists.txt": "runner cmake\n",
                "linux/runner/main.cc": "main\n",
                "linux/runner/my_application.cc": "app\n",
                "linux/runner/my_application.h": "header\n",
                ".github/workflows/build.yml": "build dispatch\n", ".github/workflows/linux_x64.yml": "linux\n",
                "pubspec.yaml": "app package\n", "pubspec.lock": "lock\n", ".fvmrc": "3.0\n",
                "lib/plugin/pl_player/controller.dart": "player consumer\n",
                "lib/plugin/pl_player/route_options.dart": "route consumer\n",
            })
            fixture_repo(media, "https://github.com/Goodwu/media-kit.git", {
                "media_kit/lib/player.dart": "shared API\n", "media_kit/pubspec.yaml": "core package\n",
                "media_kit/lib/media_kit.dart": "public core API\n",
                "media_kit_video/lib/route.dart": "route API\n", "media_kit_video/pubspec.yaml": "video package\n",
                "media_kit_video/lib/media_kit_video.dart": "public video API\n",
                "media_kit_video/linux/CMakeLists.txt": "consumer\n",
                "media_kit_video/linux/verify_routing_linux_native_local.py": "preflight\n",
                "media_kit_video/linux/media_kit_video_plugin.cc": "FFI\n",
                "media_kit_video/linux/test_verify_routing_linux_native_local.py": "test only\n",
                "libs/linux/media_kit_libs_linux/linux/CMakeLists.txt": "linux package\n",
                "libs/universal/media_kit_libs_video/pubspec.yaml": "shared linux package\n",
            })
            before = gate.compute_consumer_source_closure(app, media)
            self.assertNotIn("media_kit_video/linux/test_verify_routing_linux_native_local.py",
                             {item["path"] for item in before["files"]})
            old_head = git(app, "rev-parse", "HEAD")
            ledger_path = app / gate.LEDGER_REL
            ledger_path.parent.mkdir(parents=True, exist_ok=True)
            entry = {"manifestSha256": "1" * 64, "sourceClosureSha256": "2" * 64,
                     "consumerSourceClosure": before, "payloadSha256": "3" * 64,
                     "producer": {"repository": "Goodwu/libmpv-linux", "runId": 1, "attempt": 1,
                                  "headSha": "4" * 40, "artifactId": 10, "name": "linux.zip",
                                  "zipSha256": "5" * 64, "uploadJobId": 20},
                     "evidenceArtifact": {"repository": "Goodwu/libmpv-linux", "runId": 1, "attempt": 1,
                                          "headSha": "4" * 40, "artifactId": 11, "name": "evidence.zip",
                                          "zipSha256": "6" * 64, "uploadJobId": 21},
                     "approval": {"reviewUrl": "https://github.com/Goodwu/media-kit/pull/4#issuecomment-12",
                                  "coreCommit": "7" * 40}}
            ledger = {"schemaVersion": 1, "task": gate.TASK,
                      "selectedManifestSha256": "1" * 64, "entries": [entry]}
            ledger_path.write_text(json.dumps(ledger, sort_keys=True, indent=2) + "\n")
            git(app, "add", gate.LEDGER_REL.as_posix())
            git(app, "commit", "-m", "record synthetic CORE acceptance fixture")
            new_head = git(app, "rev-parse", "HEAD")
            self.assertNotEqual(old_head, new_head)
            after = gate.require_consumer_source_closure(app, media, entry["consumerSourceClosure"])
            self.assertEqual(before, after)
            _, selected = gate.validate_ledger(ledger)
            self.assertIs(selected, entry)
            self.assertEqual(gate.validate_consumer_closure_record(before), before)
            forged = {**before, "sha256": "8" * 64}
            with self.assertRaisesRegex(gate.GateError, "hash does not match canonical"):
                gate.validate_consumer_closure_record(forged)
            outside = {**before, "files": [*before["files"],
                       {"repository": "Goodwu/PiliPlusX", "path": "docs/approval.json", "sha256": "9" * 64}]}
            outside["files"].sort(key=lambda item: (item["repository"], item["path"]))
            outside["sha256"] = gate.digest(gate.canonical(outside["files"]))
            with self.assertRaisesRegex(gate.GateError, "outside fixed closure policy"):
                gate.validate_consumer_closure_record(outside)

    def test_consumer_closure_rejects_modified_added_or_deleted_production_source(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            app = base / "app"
            media = base / "media"
            fixture_repo(app, "https://github.com/Goodwu/PiliPlusX.git", {
                "lib/player.dart": "route API\n", "lib/plugin/pl_player/controller.dart": "controller\n",
                "lib/plugin/pl_player/route_options.dart": "routes\n",
                "scripts/acquire_routing_linux_native.py": "acquire\n",
                "scripts/verify_routing_linux_native.py": "verify\n",
                "scripts/verify_routing_sources.py": "source verify\n",
                "scripts/prepare_routing_ci.py": "bootstrap\n",
                "scripts/routing_flutter_version.py": "exact SDK pin\n",
                "scripts/verify_media_kit_lock.py": "lock gate\n",
                "scripts/verify_workflow_media_kit_refs.py": "workflow gate\n",
                "scripts/verify_binary_arch.py": "abi gate\n", "scripts/release_manifest.py": "release\n",
                "scripts/verify_release_manifest.py": "release verify\n",
                "scripts/shared_gate_execution.py": "shared gate\n",
                "scripts/prepare_ohos_package_patches.py": "linux preparation dependency\n",
                "linux/CMakeLists.txt": "linux app\n",
                "linux/flutter/CMakeLists.txt": "flutter cmake\n",
                "linux/runner/CMakeLists.txt": "runner cmake\n",
                "linux/runner/main.cc": "main\n",
                "linux/runner/my_application.cc": "app\n",
                "linux/runner/my_application.h": "header\n",
                ".github/actions/routing-bootstrap/action.yml": "action\n",
                ".github/workflows/build.yml": "build\n", ".github/workflows/linux_x64.yml": "linux\n",
                "pubspec.yaml": "app package\n", "pubspec.lock": "lock\n", ".fvmrc": "3.0\n",
            })
            fixture_repo(media, "https://github.com/Goodwu/media-kit.git", {
                "media_kit/lib/player.dart": "shared API\n", "media_kit/pubspec.yaml": "core package\n",
                "media_kit/lib/media_kit.dart": "public core API\n",
                "media_kit_video/lib/route.dart": "route API\n",
                "media_kit_video/pubspec.yaml": "video package\n",
                "media_kit_video/lib/media_kit_video.dart": "public video API\n",
                "media_kit_video/linux/CMakeLists.txt": "consumer\n",
                "media_kit_video/linux/verify_routing_linux_native_local.py": "preflight\n",
                "libs/linux/media_kit_libs_linux/linux/CMakeLists.txt": "linux package\n",
                "libs/universal/media_kit_libs_video/pubspec.yaml": "universal package\n",
            })
            accepted = gate.compute_consumer_source_closure(app, media)
            pin_path = "scripts/routing_flutter_version.py"
            pin = app / pin_path
            pin.write_text("changed SDK selection\n")
            with self.assertRaisesRegex(gate.GateError, "differs from CORE-approved closure"):
                gate.require_consumer_source_closure(app, media, accepted)
            pin.write_text("exact SDK pin\n")
            git(app, "rm", pin_path)
            with self.assertRaisesRegex(gate.GateError, "missing fixed inputs"):
                gate.compute_consumer_source_closure(app, media)
            pin.write_text("exact SDK pin\n")
            git(app, "add", pin_path)
            (media / "media_kit_video/linux/CMakeLists.txt").write_text("changed\n")
            with self.assertRaisesRegex(gate.GateError, "(differs from CORE-approved closure|missing fixed inputs)"):
                gate.require_consumer_source_closure(app, media, accepted)
            (media / "media_kit_video/linux/CMakeLists.txt").write_text("consumer\n")
            preflight = media / "media_kit_video/linux/verify_routing_linux_native_local.py"
            preflight.write_text("modified shared preflight\n")
            with self.assertRaisesRegex(gate.GateError, "differs from CORE-approved closure"):
                gate.require_consumer_source_closure(app, media, accepted)
            preflight.write_text("preflight\n")
            new_source = media / "media_kit_video/linux/new_consumer.cc"
            new_source.write_text("new production input\n")
            git(media, "add", "--all")
            with self.assertRaisesRegex(gate.GateError, "differs from CORE-approved closure"):
                gate.require_consumer_source_closure(app, media, accepted)
            git(media, "rm", "media_kit_video/linux/CMakeLists.txt")
            with self.assertRaisesRegex(gate.GateError, "(differs from CORE-approved closure|missing fixed inputs)"):
                gate.require_consumer_source_closure(app, media, accepted)


if __name__ == "__main__":
    unittest.main()
