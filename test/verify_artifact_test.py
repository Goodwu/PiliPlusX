import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "scripts" / "verify_artifact.py"


class VerifyArtifactTest(unittest.TestCase):
    def run_verifier(self, artifact: Path, platform: str, abi: str) -> None:
        subprocess.run(
            [
                sys.executable,
                str(SCRIPT),
                str(artifact),
                "--platform",
                platform,
                "--abi",
                abi,
            ],
            check=True,
        )

    def test_android_archive_has_only_requested_abi(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "app.apk"
            with zipfile.ZipFile(artifact, "w") as archive:
                archive.writestr("lib/arm64-v8a/libapp.so", b"native")
            self.run_verifier(artifact, "android", "arm64-v8a")

    def test_ohos_archive_has_manifest_and_arm64_libraries(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            artifact = Path(directory) / "entry-default-unsigned.hap"
            with zipfile.ZipFile(artifact, "w") as archive:
                archive.writestr("libs/arm64-v8a/libapp.so", b"app")
                archive.writestr("libs/arm64-v8a/libflutter.so", b"flutter")
                archive.writestr("libs/arm64-v8a/libmpv.so", b"mpv")
                archive.writestr("module.json", b"{}")
            self.run_verifier(artifact, "ohos", "arm64-v8a")


if __name__ == "__main__":
    unittest.main()
