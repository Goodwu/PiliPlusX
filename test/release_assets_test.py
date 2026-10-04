import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

MANIFEST = Path(__file__).parents[1] / "scripts" / "release_manifest.py"
VERIFY = Path(__file__).parents[1] / "scripts" / "verify_release_assets.py"
MEDIA = "b" * 40
MAC_PREFIX = "PiliPlusX_macos_v1.2.3"


def make_shared_macos_fixture(root: Path, source_checkout: Path,
                              source: str, lock_sha: str) -> dict[str, Path]:
    # Reuse the realistic sidecar fixture without importing its TestCase into
    # this module, which would cause unittest discovery to execute it twice.
    import importlib

    fixture_module = importlib.import_module("macos_shared_release_metadata_test")
    return fixture_module.SharedReleaseMetadataTest().write_macos(
        root, source_checkout=source_checkout, source=source, lock_sha=lock_sha)


class ReleaseAssetsTest(unittest.TestCase):
    def setUp(self) -> None:
        import importlib

        fixture_module = importlib.import_module("macos_shared_release_metadata_test")
        self.source_directory = tempfile.TemporaryDirectory(prefix="release-assets-source-")
        self.source_checkout, self.source, self.lock_sha = fixture_module.create_trusted_source_checkout(
            Path(self.source_directory.name) / "source")
        self.addCleanup(self.source_directory.cleanup)

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
                "--abi", "arm64", "--media-kit-commit", MEDIA,
                "--git-commit", self.source,
                "--native-library-version", "test@1",
            ],
            check=True,
        )
        (stage / "manifest.json").replace(root / f"{prefix}.manifest.json")
        (stage / "SHA256SUMS").replace(root / f"{prefix}.SHA256SUMS")
        (stage / artifact.name).unlink()
        stage.rmdir()

    def test_complete_release_assets_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "assets"
            root.mkdir()
            for platform, extension in (("android", ".apk"), ("ios", ".ipa"), ("ohos", ".hap")):
                self.write_platform(root, platform, extension)
            mac_stage = root / "mac-stage"
            paths = make_shared_macos_fixture(mac_stage, self.source_checkout,
                                              self.source, self.lock_sha)
            for payload in (paths["dmg"], paths["core"], paths["backend"], paths["distribution"]):
                payload.replace(root / payload.name)
            (mac_stage / "manifest.json").replace(root / f"{MAC_PREFIX}.manifest.json")
            (mac_stage / "SHA256SUMS").replace(root / f"{MAC_PREFIX}.SHA256SUMS")
            mac_stage.rmdir()
            subprocess.run(
                [sys.executable, str(VERIFY), str(root), "--expected-source", self.source,
                 "--source-checkout", str(self.source_checkout)],
                check=True,
            )

    def test_missing_platform_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.write_platform(root, "android", ".apk")
            result = subprocess.run(
                [sys.executable, str(VERIFY), str(root), "--expected-source", self.source],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)

    def test_legacy_arm64_single_dmg_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for platform, extension in (("android", ".apk"), ("ios", ".ipa"), ("ohos", ".hap")):
                self.write_platform(root, platform, extension)
            filename = "PiliPlusX_macos_v1.2.3_arm64.dmg"
            payload = root / filename
            payload.write_bytes(b"legacy arm64 DMG")
            digest = hashlib.sha256(payload.read_bytes()).hexdigest()
            prefix = filename.removesuffix(".dmg")
            manifest = {
                "schema": 1,
                "platform": "macos",
                "abi": "arm64",
                "gitCommit": self.source,
                "mediaKitCommit": MEDIA,
                "hdrBackend": "texture-tone-map",
                "nativeLibraryVersion": "mpv@0.36.0",
                "files": [{"path": filename, "sha256": digest, "size": payload.stat().st_size}],
            }
            (root / f"{prefix}.manifest.json").write_text(json.dumps(manifest) + "\n")
            (root / f"{prefix}.SHA256SUMS").write_text(f"{digest}  {filename}\n")
            result = subprocess.run(
                [sys.executable, str(VERIFY), str(root), "--expected-source", self.source,
                 "--source-checkout", str(self.source_checkout)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("macOS shared release requires manifest schema 2", result.stderr)


if __name__ == "__main__":
    unittest.main()
