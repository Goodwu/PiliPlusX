import importlib.util
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
SPEC = importlib.util.spec_from_file_location("linux_acquire", ROOT / "scripts/acquire_routing_linux_native.py")
acquire = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(acquire)


class LinuxAcquireTest(unittest.TestCase):
    def test_artifact_metadata_must_bind_run_attempt_and_upload_job(self):
        spec = {"artifactId": 12, "name": "payload.zip", "zipSha256": "a" * 64,
                "runId": 40, "attempt": 2, "headSha": "b" * 40,
                "uploadJobId": 7}
        metadata = {"id": 12, "name": "payload.zip", "expired": False,
                    "digest": "sha256:" + "a" * 64, "size_in_bytes": 10,
                    "workflow_run": {"id": 40, "head_sha": "b" * 40},
                    "created_at": "2026-10-12T02:00:00Z"}
        job = {"id": 7, "run_id": 40, "run_attempt": 2, "head_sha": "b" * 40,
               "status": "completed", "conclusion": "success",
               "started_at": "2026-10-12T01:59:00Z", "completed_at": "2026-10-12T02:01:00Z"}
        acquire.validate_metadata(spec, metadata, [job])
        with self.assertRaisesRegex(acquire.gate.GateError, "run attempt"):
            acquire.validate_metadata(spec, metadata, [{**job, "run_attempt": 1}])

    def test_zip_rejects_extra_or_traversal_member(self):
        with tempfile.TemporaryDirectory() as temp:
            archive_path = Path(temp) / "payload.zip"
            with zipfile.ZipFile(archive_path, "w") as archive:
                archive.writestr("lib/libmpv.so.2", b"not an elf")
                archive.writestr("../outside", b"bad")
            with self.assertRaises(acquire.gate.GateError):
                acquire.inspect_archive(archive_path)

    def test_empty_ledger_fails_closed_before_network_acquisition(self):
        with self.assertRaisesRegex(acquire.gate.GateError, "missing-accepted-linux-native-input"):
            acquire.gate.selected_entry({"schemaVersion": 1, "task": acquire.gate.TASK,
                                         "selectedManifestSha256": None, "entries": []})


if __name__ == "__main__":
    unittest.main()
