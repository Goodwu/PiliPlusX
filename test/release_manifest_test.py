import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "release_manifest.py"


class ReleaseManifestTest(unittest.TestCase):
    def test_manifest_and_hashes_are_consistent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            artifact = output / "app.bin"
            artifact.write_bytes(b"PiliPlusX")
            subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(output),
                    "--platform",
                    "android",
                    "--abi",
                    "arm64-v8a",
                    "--media-kit-commit",
                    "08b7b9410968fa39ae2fc814d57f9f889079afc9",
                    "--native-library-version",
                    "test",
                ],
                check=True,
            )
            manifest = json.loads((output / "manifest.json").read_text())
            expected = hashlib.sha256(b"PiliPlusX").hexdigest()
            self.assertEqual(
                manifest["mediaKitCommit"],
                "08b7b9410968fa39ae2fc814d57f9f889079afc9",
            )
            self.assertEqual(
                manifest["files"],
                [{"path": "app.bin", "sha256": expected, "size": 9}],
            )
            self.assertEqual(
                (output / "SHA256SUMS").read_text(),
                f"{expected}  app.bin\n",
            )


if __name__ == "__main__":
    unittest.main()
