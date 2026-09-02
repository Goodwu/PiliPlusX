import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "verify_binary_arch.py"


class VerifyBinaryArchTest(unittest.TestCase):
    def test_invalid_binary_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "not-a-binary"
            binary.write_text("not executable")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    str(binary),
                    "--platform",
                    "linux",
                    "--arch",
                    "x86_64",
                ],
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
