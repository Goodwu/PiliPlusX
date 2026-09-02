import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parents[1]))

from scripts.verify_android_native_parity import native_hashes


def write_apk(path: Path, payload: bytes) -> None:
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("lib/arm64-v8a/libmedia_kit.so", payload)


class AndroidNativeParityTest(unittest.TestCase):
    def test_native_hashes_are_stable(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / "app.apk"
            write_apk(apk, b"same")
            self.assertEqual(
                native_hashes(str(apk)),
                {
                    "lib/arm64-v8a/libmedia_kit.so": (
                        "0967115f2813a3541eaef77de9d9d5773f1c0c04314b0bbfe4ff3b3b1c55b5d5"
                    )
                },
            )


if __name__ == "__main__":
    unittest.main()
