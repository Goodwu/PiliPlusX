"""Synthetic fixtures exercise rejection semantics; they are not native candidates."""
import copy
import importlib.util
import json
import struct
import subprocess
import sys
import tempfile
import unittest
import warnings
import zipfile
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
spec = importlib.util.spec_from_file_location("native_gate", SCRIPTS / "verify_routing_native_inputs.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


class NativeInputTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.evidence = self.root / "evidence"
        self.evidence.mkdir()
        self.jar = self.root / "native.jar"
        self.manifest_file = self.root / "manifest.json"
        self.receipt = {}
        self.consumer = {"appCommit": "a" * 40, "mediaKitCommit": "b" * 40}
        self.data = {}
        self.manifest = {"schemaVersion": 1, "task": gate.TASK, "platform": "android", "artifact": {"kind": "jar", "name": self.jar.name, "sha256": "0" * 64, "identity": {"repository": "Goodwu/native-build", "runId": 1, "artifactId": 2, "attempt": 1}}, "components": {}, "toolchain": {"ndkVersion": "synthetic-27", "ndkSha256": "c" * 64, "compilerVersion": "synthetic-clang", "compilerSha256": "d" * 64, "sysrootSha256": "e" * 64, "evidence": "toolchain"}, "staging": {"cleanEvidence": "staging", "membersEvidence": "members", "linkEvidence": "link"}, "linkInputs": [], "evidence": [], "members": {}}
        for kind in ("toolchain", "staging", "members", "link"):
            self.add_evidence(kind, kind)
        for component in sorted(gate.COMPONENTS):
            self.add_evidence(component, "source")
            self.manifest["components"][component] = {"repository": f"https://github.com/Goodwu/{component}", "commit": "1" * 40, "tree": "2" * 40, "patches": [], "sourceEvidence": component}
            self.manifest["linkInputs"].append({"component": component, "path": f"objects/{component}.a", "sha256": "3" * 64})
        self.manifest["linkInputs"].append({"component": "toolchain", "path": "sysroot/libc++_shared.so", "sha256": "4" * 64})
        for i, name in enumerate(gate.MEMBERS):
            binary = bytearray(64)
            binary[:7] = b"\x7fELF\x02\x01\x01"
            struct.pack_into("<HHI", binary, 16, 3, 183, 1)
            binary.extend(f"synthetic-{i}".encode())
            self.data[name] = bytes(binary)
            self.manifest["members"][name] = {"sha256": gate.digest(bytes(binary)), "buildId": "abcde012", "soname": Path(name).name, "needed": ["libc.so"], "elfClass": 64, "machine": 183}
        self.write_jar()
        self.accept()

    def add_evidence(self, label, kind):
        content = f"synthetic {label}\n".encode()
        path = f"{label}.txt"
        (self.evidence / path).write_bytes(content)
        self.manifest["evidence"].append({"id": label, "path": path, "sha256": gate.digest(content), "kind": kind})

    def write_jar(self, extra=None):
        with zipfile.ZipFile(self.jar, "w") as archive:
            for name, data in self.data.items():
                archive.writestr(name, data)
            if extra:
                for name, data in extra:
                    archive.writestr(name, data)
        self.manifest["artifact"]["sha256"] = gate.digest(self.jar.read_bytes())

    def accept(self):
        self.manifest_file.write_text(json.dumps(self.manifest))
        self.accepted = {"schemaVersion": 1, "task": gate.TASK, "entries": [{"manifestSha256": gate.digest(self.manifest_file.read_bytes()), "sourceClosureSha256": gate.closure_hash(self.manifest), "artifactIdentity": copy.deepcopy(self.manifest["artifact"]["identity"]), "jarSha256": self.manifest["artifact"]["sha256"], "approval": {"reviewUrl": "https://github.com/Goodwu/media-kit/pull/4#issuecomment-1", "coreCommit": "5" * 40}, "allowedWeakVulkanImports": {}, "weakImportEvidence": None}]}

    def symbols(self, imports):
        rows = ["0: 0000000000000000 0 NOTYPE LOCAL DEFAULT UND"]
        for i, (name, binding) in enumerate(imports.items(), 1):
            rows.append(f"{i}: 0000000000000000 0 FUNC {'GLOBAL' if binding == 'U' else 'WEAK'} DEFAULT UND {name}")
        return f"Symbol table '.dynsym' contains {len(rows)} entries:\n Num: Value Size Type Bind Vis Ndx Name\n" + "\n".join(rows) + "\n"

    def tool(self, argv, **kwargs):
        name = Path(argv[-1]).name
        if argv[0] == "readelf" and argv[1] == "-h":
            out = "Class: ELF64\nType: DYN (Shared object file)\nMachine: AArch64\n"
        elif argv[0] == "readelf" and argv[1] == "-n":
            out = "Build ID: abcde012\n"
        elif argv[0] == "readelf" and argv[1] == "-d":
            out = f"0 (SONAME) Library soname: [{name}]\n0 (NEEDED) Shared library: [libc.so]\n"
        elif argv[0] == "readelf" and argv[1] == "--dyn-syms":
            out = self.symbols({"malloc": "U"})
        else:
            out = "malloc U\n"
        return subprocess.CompletedProcess(argv, 0, out, "")

    def verify(self, **kwargs):
        with patch.object(gate.subprocess, "run", side_effect=kwargs.pop("tool", self.tool)):
            gate.verify(self.jar, self.manifest_file, self.evidence, self.accepted, self.consumer, self.receipt, **kwargs)

    def reject(self, reason, **kwargs):
        with self.assertRaisesRegex(gate.GateError, reason):
            self.verify(**kwargs)
        self.assertFalse(self.receipt["nativeVerified"])

    def mutate_manifest(self, mutate, approve=False):
        mutate(self.manifest)
        self.manifest_file.write_text(json.dumps(self.manifest))
        if approve:
            self.accept()

    def test_synthetic_accepted_input_passes_all_binary_checks(self):
        self.verify()
        self.assertTrue(self.receipt["nativeVerified"])
        self.assertFalse(self.receipt["deviceVerified"])
        self.assertEqual(len(self.receipt["commands"]), 15)
        self.assertTrue(all(c["exitCode"] == 0 for c in self.receipt["commands"]))
        self.assertEqual(self.receipt["consumer"], self.consumer)

    def test_checked_in_ledger_does_not_authorize_synthetic_fixture(self):
        actual, _ = gate.read_json(gate.ACCEPTED)
        self.accepted = actual
        self.reject("no unique CORE-reviewed")
        self.assertEqual(self.receipt["commands"], [])

    def test_manifest_cannot_authorize_itself(self):
        self.mutate_manifest(lambda m: m.update(reviewStatus="approved"))
        self.reject("expected exactly")

    def test_missing_component(self):
        self.mutate_manifest(lambda m: m["components"].pop("FFmpeg"))
        self.reject("components: expected exactly")

    def test_changed_component_is_not_accepted(self):
        self.mutate_manifest(lambda m: m["components"]["FFmpeg"].update(commit="9" * 40))
        self.reject("no unique CORE-reviewed")

    def test_changed_ordered_patch_is_not_accepted(self):
        self.add_evidence("patch", "patch")
        self.manifest["components"]["mpv"]["patches"] = [{"path": "patches/fix.patch", "sha256": self.manifest["evidence"][-1]["sha256"], "evidence": "patch"}]
        self.accept()
        self.mutate_manifest(lambda m: m["components"]["mpv"]["patches"][0].update(sha256="9" * 64))
        self.reject("patch attachment differs")

    def test_patch_order_is_bound_by_manifest(self):
        for label in ("p1", "p2"):
            self.add_evidence(label, "patch")
            self.manifest["components"]["mpv"]["patches"].append({"path": f"patches/{label}.patch", "sha256": self.manifest["evidence"][-1]["sha256"], "evidence": label})
        self.accept()
        self.mutate_manifest(lambda m: m["components"]["mpv"]["patches"].reverse())
        self.reject("no unique CORE-reviewed")

    def test_incomplete_link_inputs(self):
        self.mutate_manifest(lambda m: m.update(linkInputs=[i for i in m["linkInputs"] if i["component"] != "helper"]))
        self.reject("incomplete linked")

    def test_missing_link_staging_or_members_evidence(self):
        for field in ("cleanEvidence", "membersEvidence", "linkEvidence"):
            with self.subTest(field=field):
                old = self.manifest["staging"][field]
                self.mutate_manifest(lambda m: m["staging"].update({field: "absent"}))
                self.reject("missing .* evidence")
                self.manifest["staging"][field] = old

    def test_attachment_bytes_must_match(self):
        (self.evidence / "link.txt").write_bytes(b"changed")
        self.reject("evidence attachment")

    def test_attachment_symlink_is_rejected(self):
        file = self.evidence / "link.txt"
        saved = self.root / "outside.txt"
        file.rename(saved)
        file.symlink_to(saved)
        self.reject("symbolic link")

    def test_duplicate_jar_member(self):
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            self.write_jar([(gate.MEMBERS[0], self.data[gate.MEMBERS[0]])])
        self.accept()
        self.reject("duplicate ZIP")

    def test_extra_jar_member(self):
        self.write_jar([("lib/arm64-v8a/libextra.so", b"extra")])
        self.accept()
        self.reject("unexpected JAR")

    def test_zip_traversal(self):
        self.write_jar([("../escape", b"x")])
        self.accept()
        self.reject("unsafe relative")

    def test_wrong_abi(self):
        self.write_jar([("lib/x86/libextra.so", b"extra")])
        self.accept()
        self.reject("unexpected JAR")

    def test_zip_expansion_bomb(self):
        with zipfile.ZipFile(self.jar, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for name in gate.MEMBERS:
                archive.writestr(name, b"\0" * (2 * 1024 * 1024))
        self.manifest["artifact"]["sha256"] = gate.digest(self.jar.read_bytes())
        self.accept()
        self.reject("expansion limit")

    def test_wrong_elf_class_and_machine(self):
        for offset, value in ((4, 1), (18, 62)):
            with self.subTest(offset=offset):
                saved = self.data[gate.MEMBERS[0]]
                data = bytearray(saved)
                data[offset] = value
                self.data[gate.MEMBERS[0]] = bytes(data)
                self.manifest["members"][gate.MEMBERS[0]]["sha256"] = gate.digest(bytes(data))
                self.write_jar()
                self.accept()
                self.reject("not a little-endian ELF64")
                self.data[gate.MEMBERS[0]] = saved

    def test_nm_nonzero_cannot_mean_no_imports(self):
        def failed(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 7, "", "cannot read") if argv[0] == "nm" else self.tool(argv, **kwargs)
        self.reject("exited 7", tool=failed)
        self.assertEqual(self.receipt["commands"][-1]["exitCode"], 7)

    def test_nm_missing_tool_keeps_unknown_exit(self):
        def failed(argv, **kwargs):
            if argv[0] == "nm":
                raise FileNotFoundError("synthetic missing tool")
            return self.tool(argv, **kwargs)
        self.reject("invocation failed", tool=failed)
        self.assertIsNone(self.receipt["commands"][-1]["exitCode"])
        self.assertIn("missing tool", self.receipt["commands"][-1]["error"])

    def test_nm_malformed_success_cannot_mean_no_imports(self):
        def malformed(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, "nm: unsupported format\n", "") if argv[0] == "nm" else self.tool(argv, **kwargs)
        self.reject("unrecognized undefined", tool=malformed)

    def test_each_vulkan_target_is_checked_independently(self):
        for symbol in sorted(gate.VULKAN):
            with self.subTest(symbol=symbol):
                def imported(argv, **kwargs):
                    if argv[1] == "--dyn-syms":
                        return subprocess.CompletedProcess(argv, 0, self.symbols({symbol: "U"}), "")
                    return subprocess.CompletedProcess(argv, 0, f"{symbol} U\n", "") if argv[0] == "nm" else self.tool(argv, **kwargs)
                self.reject(symbol, tool=imported)

    def test_weak_targets_require_explicit_CORE_approval(self):
        symbol = "vkGetPhysicalDeviceQueueFamilyProperties2"
        def weak(argv, **kwargs):
            if argv[1] == "--dyn-syms":
                return subprocess.CompletedProcess(argv, 0, self.symbols({symbol: "w"}), "")
            return subprocess.CompletedProcess(argv, 0, f"{symbol} w\n", "") if argv[0] == "nm" else self.tool(argv, **kwargs)
        self.reject("unapproved Vulkan", tool=weak)
        self.add_evidence("weak-contract", "weak-import-contract")
        self.accept()
        self.accepted["entries"][0]["allowedWeakVulkanImports"] = {name: [symbol] for name in gate.MEMBERS}
        self.accepted["entries"][0]["weakImportEvidence"] = "weak-contract"
        self.verify(tool=weak)
        self.assertTrue(self.receipt["nativeVerified"])

    def test_successful_empty_symbol_output_is_distinct_from_read_failure(self):
        def empty(argv, **kwargs):
            if argv[1] == "--dyn-syms":
                return subprocess.CompletedProcess(argv, 0, self.symbols({}), "")
            return subprocess.CompletedProcess(argv, 0, "", "") if argv[0] == "nm" else self.tool(argv, **kwargs)
        self.verify(tool=empty)
        self.assertTrue(self.receipt["nativeVerified"])
        self.assertEqual(set(self.receipt["members"][gate.MEMBERS[0]]["vulkanImports"].values()), {None})

    def test_build_id_soname_needed_cannot_be_missing_or_relabelled(self):
        for field, value in (("buildId", "deadbeef"), ("needed", ["libm.so"])):
            with self.subTest(field=field):
                original = self.manifest["members"][gate.MEMBERS[0]][field]
                self.manifest["members"][gate.MEMBERS[0]][field] = value
                self.accept()
                self.reject("Build ID|SONAME/NEEDED")
                self.manifest["members"][gate.MEMBERS[0]][field] = original

    def test_acceptance_binds_artifact_identity_closure_and_jar(self):
        for field, value in (("sourceClosureSha256", "9" * 64), ("jarSha256", "9" * 64), ("artifactIdentity", {"repository": "Goodwu/native-build", "runId": 9, "artifactId": 2, "attempt": 1})):
            with self.subTest(field=field):
                self.accept()
                self.accepted["entries"][0][field] = value
                self.reject("accepted source closure")

    def test_manifest_duplicate_fields_rejected(self):
        self.manifest_file.write_text('{"task":"a","task":"b"}')
        self.reject("duplicate JSON field")

    def test_apk_matches_three_members_and_preserves_extra_arm64_plugins(self):
        apk = self.root / "app.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            for name, data in self.data.items():
                archive.writestr(name, data)
            archive.writestr("lib/arm64-v8a/libflutter.so", b"synthetic flutter")
            archive.writestr("classes.dex", b"synthetic")
        self.verify(apk=apk)
        self.assertEqual(set(self.receipt["apk"]["members"]), set(gate.MEMBERS))

    def test_apk_substituted_library_rejected(self):
        apk = self.root / "app.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            for name, data in self.data.items():
                archive.writestr(name, data + (b"changed" if name == gate.MEMBERS[0] else b""))
        self.reject("APK native member differs", apk=apk)
        self.assertEqual(self.receipt["stage"], "APK")

    def test_apk_wrong_plugin_abi_rejected(self):
        apk = self.root / "app.apk"
        with zipfile.ZipFile(apk, "w") as archive:
            for name, data in self.data.items():
                archive.writestr(name, data)
            archive.writestr("lib/x86/libflutter.so", b"wrong")
        self.reject("canonical arm64", apk=apk)

    def test_successful_nm_with_no_symbols_diagnostic_is_rejected(self):
        def unreadable(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, "", "native.so: no symbols\n") if argv[0] == "nm" else self.tool(argv, **kwargs)
        self.reject("diagnostic despite successful exit", tool=unreadable)
        self.assertEqual(self.receipt["commands"][-1]["exitCode"], 0)
        self.assertIn("no symbols", self.receipt["commands"][-1]["stderr"])

    def test_empty_listing_without_dynamic_table_is_unknown(self):
        def unreadable(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, "", "") if argv[1] == "--dyn-syms" else self.tool(argv, **kwargs)
        self.reject("dynamic symbol table unavailable", tool=unreadable)

    def test_nm_empty_listing_cannot_erase_observed_dynamic_imports(self):
        def erased(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 0, "", "") if argv[0] == "nm" else self.tool(argv, **kwargs)
        self.reject("import sets disagree", tool=erased)

    def test_dynamic_table_must_be_complete(self):
        def truncated(argv, **kwargs):
            output = self.symbols({"malloc": "U"}).replace("contains 2 entries", "contains 3 entries")
            return subprocess.CompletedProcess(argv, 0, output, "") if argv[1] == "--dyn-syms" else self.tool(argv, **kwargs)
        self.reject("incomplete dynamic symbol", tool=truncated)

    def test_corrupt_extra_apk_plugin_crc_is_rejected(self):
        apk = self.root / "corrupt-extra.apk"
        with zipfile.ZipFile(apk, "w", compression=zipfile.ZIP_STORED) as archive:
            for name, data in self.data.items():
                archive.writestr(name, data)
            archive.writestr("lib/arm64-v8a/libflutter.so", b"synthetic extra plugin")
        with zipfile.ZipFile(apk) as archive:
            item = archive.getinfo("lib/arm64-v8a/libflutter.so")
        data = bytearray(apk.read_bytes())
        name_len, extra_len = struct.unpack_from("<HH", data, item.header_offset + 26)
        data[item.header_offset + 30 + name_len + extra_len] ^= 1
        apk.write_bytes(data)
        self.reject("ZIP member integrity failure: lib/arm64-v8a/libflutter.so", apk=apk)
        self.assertEqual(self.receipt["stage"], "APK")

    def test_weak_import_allowance_without_contract_is_rejected(self):
        self.accepted["entries"][0]["allowedWeakVulkanImports"] = {gate.MEMBERS[0]: ["vkGetPhysicalDeviceProperties2"]}
        self.reject("approved contract evidence")

    def test_readelf_failure_cannot_verify_binary(self):
        def failed(argv, **kwargs):
            return subprocess.CompletedProcess(argv, 3, "", "read failed")
        self.reject("exited 3", tool=failed)
        self.assertEqual(len(self.receipt["commands"]), 1)

    def test_tool_timeout_has_no_fabricated_exit_code(self):
        def timeout(argv, **kwargs):
            raise subprocess.TimeoutExpired(argv, 60)
        self.reject("invocation failed", tool=timeout)
        self.assertIsNone(self.receipt["commands"][0]["exitCode"])

    def test_evidence_traversal_is_rejected(self):
        self.mutate_manifest(lambda m: m["evidence"][0].update(path="../outside.txt"))
        self.reject("unsafe relative")

    def test_duplicate_acceptance_record_is_rejected(self):
        self.accepted["entries"].append(copy.deepcopy(self.accepted["entries"][0]))
        self.reject("duplicate accepted")

    def test_jar_symlink_rejected_before_member_read(self):
        original = self.root / "stored.jar"
        self.jar.rename(original)
        self.jar.symlink_to(original)
        self.reject("JAR name/hash mismatch")

    def test_apk_duplicate_member_is_rejected(self):
        apk = self.root / "duplicate.apk"
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(apk, "w") as archive:
                for name, data in self.data.items():
                    archive.writestr(name, data)
                archive.writestr(gate.MEMBERS[0], self.data[gate.MEMBERS[0]])
        self.reject("duplicate ZIP", apk=apk)

    def test_malformed_field_types_are_rejected_without_TypeError(self):
        for section, field in (("linkInputs", "component"), ("evidence", "kind")):
            with self.subTest(section=section):
                original = self.manifest[section][0][field]
                self.mutate_manifest(lambda m: m[section][0].update({field: []}))
                self.reject("unknown")
                self.manifest[section][0][field] = original

    def test_cli_missing_input_writes_failure_receipt_without_tools(self):
        receipt_file = self.root / "receipt.json"
        result = subprocess.run([sys.executable, str(SCRIPTS / "verify_routing_native_inputs.py"), "--jar", str(self.jar), "--manifest", str(self.root / "absent.json"), "--evidence-root", str(self.evidence), "--app-commit", self.consumer["appCommit"], "--media-kit-commit", self.consumer["mediaKitCommit"], "--receipt", str(receipt_file)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        receipt = json.loads(receipt_file.read_text())
        self.assertFalse(receipt["nativeVerified"])
        self.assertEqual(receipt["stage"], "manifest")
        self.assertEqual(receipt["commands"], [])


if __name__ == "__main__":
    unittest.main()
