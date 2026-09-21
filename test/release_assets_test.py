import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MANIFEST = Path(__file__).parents[1] / "scripts" / "release_manifest.py"
VERIFY = Path(__file__).parents[1] / "scripts" / "verify_release_assets.py"
COMMIT = "08b7b9410968fa39ae2fc814d57f9f889079afc9"


class ReleaseAssetsTest(unittest.TestCase):
    def write_platform(self, root: Path, platform: str, extension: str) -> None:
        prefix = f"PiliPlusX_{platform}_v1.2.3_arm64"
        artifact = root / f"{prefix}{extension}"
        artifact.write_bytes(platform.encode())
        stage = root / f"stage-{platform}"
        stage.mkdir()
        (stage / artifact.name).write_bytes(artifact.read_bytes())
        subprocess.run(
            [
                sys.executable, str(MANIFEST), str(stage), "--platform", platform,
                "--abi", "arm64", "--media-kit-commit", COMMIT,
                "--native-library-version", "test@1",
            ],
            check=True,
        )
        (stage / "manifest.json").replace(root / f"{prefix}.manifest.json")
        (stage / "SHA256SUMS").replace(root / f"{prefix}.SHA256SUMS")

    def test_complete_release_assets_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for platform, extension in (("android", ".apk"), ("ios", ".ipa"), ("macos", ".dmg"), ("ohos", ".hap")):
                self.write_platform(root, platform, extension)
            subprocess.run([sys.executable, str(VERIFY), str(root)], check=True)

    def test_missing_platform_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_platform(root, "android", ".apk")
            result = subprocess.run([sys.executable, str(VERIFY), str(root)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
