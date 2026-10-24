import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "validate_release_tag.py"


class ReleaseTagTest(unittest.TestCase):
    def test_stable_tag(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "v2.1.2"], text=True, capture_output=True, check=True
        )
        self.assertEqual(result.stdout, "tag=v2.1.2\nversion=2.1.2\nprerelease=false\n")

    def test_prerelease_tag(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "v2.1.2-rc.1"], text=True, capture_output=True, check=True
        )
        self.assertIn("prerelease=true", result.stdout)

    def test_invalid_tag_fails(self) -> None:
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "release-2.1.2"], text=True, capture_output=True
        )
        self.assertNotEqual(result.returncode, 0)

    def test_github_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "github-output"
            subprocess.run(
                [sys.executable, str(SCRIPT), "v2.1.2-beta.1", "--github-output", str(output)],
                check=True,
            )
            self.assertEqual(output.read_text(), "tag=v2.1.2-beta.1\nversion=2.1.2\nprerelease=true\n")


if __name__ == "__main__":
    unittest.main()
