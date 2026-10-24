from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from shared_gate_execution import (
    GATE_SCRIPTS,
    GateIdentityError,
    capture_gate_execution,
    trusted_gate_digests,
    validate_gate_execution,
)


MANIFEST = ROOT / "scripts" / "release_manifest.py"
VERIFY = ROOT / "scripts" / "verify_release_manifest.py"
ASSETS = ROOT / "scripts" / "verify_release_assets.py"
MEDIA = "b" * 40
HASH = "c" * 64
TAG = "v1.2.3"
PREFIX = f"PiliPlusX_macos_{TAG}"
LOCK = "scripts/macos-shared-ci-inputs.lock.json"
TRUSTED_FILES = (
    LOCK,
    "scripts/verify_release_manifest.py",
    "scripts/verify_release_assets.py",
    "scripts/shared_gate_execution.py",
    *GATE_SCRIPTS,
)
PRODUCER_ROOT = "/Users/actions/work/PiliPlusX/PiliPlusX"
CONSUMER_ROOT = "/home/temporary-consumer/PiliPlusX"


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def create_trusted_source_checkout(root: Path, approved: str | None = MEDIA) -> tuple[Path, str, str]:
    """Create an isolated temporary Git source identity for CPU-only tests."""
    root.mkdir(parents=True)
    for relative in TRUSTED_FILES:
        destination = root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if relative == LOCK:
            lock = json.loads((ROOT / relative).read_text(encoding="utf-8"))
            lock["reviewed_media_kit_revision"] = approved
            data = (json.dumps(lock, sort_keys=True, indent=2) + "\n").encode()
        else:
            data = (ROOT / relative).read_bytes()
        destination.write_bytes(data)
        if relative.endswith(".sh"):
            destination.chmod(0o755)
    subprocess.run(["git", "init", "-q", str(root)], check=True, capture_output=True)
    subprocess.run(["git", "-C", str(root), "config", "user.email", "metadata-test@example.invalid"], check=True)
    subprocess.run(["git", "-C", str(root), "config", "user.name", "Metadata CPU Fixture"], check=True)
    subprocess.run(["git", "-C", str(root), "add", *TRUSTED_FILES], check=True)
    subprocess.run(["git", "-C", str(root), "commit", "-qm", "isolated trusted metadata fixture"], check=True)
    source = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    return root.resolve(), source, sha((root / LOCK).read_bytes())


class SharedReleaseMetadataTest(unittest.TestCase):
    def setUp(self) -> None:
        self.source_directory = tempfile.TemporaryDirectory(prefix="release-metadata-source-")
        self.source_checkout, self.source, self.lock_sha = create_trusted_source_checkout(
            Path(self.source_directory.name) / "source")
        self.addCleanup(self.source_directory.cleanup)

    def verifier_command(self, root: Path, *, source: str | None = None,
                         checkout: Path | None = None) -> list[str]:
        return [sys.executable, str(VERIFY), str(root), "--expected-source", source or self.source,
                "--source-checkout", str(checkout or self.source_checkout)]

    def write_macos(self, root: Path, mutate=None, *, source_checkout: Path | None = None,
                    source: str | None = None, lock_sha: str | None = None,
                    media: str = MEDIA) -> dict[str, Path]:
        root.mkdir(parents=True, exist_ok=True)
        checkout = source_checkout or self.source_checkout
        release_source = source or self.source
        trusted_lock_sha = lock_sha or self.lock_sha
        execution = {
            "schema_version": 1,
            "producer_checkout_root": PRODUCER_ROOT,
            "python_executable": "/Users/actions/python/bin/python3",
            "scripts": trusted_gate_digests(checkout, release_source),
            "backend_inputs": {
                "prepared_source": "/Users/actions/runner_temp/shared-source",
                "source_manifest": "/Users/actions/runner_temp/recipe/manifest.json",
                "report": "/Users/actions/runner_temp/mounted-backend.json",
            },
        }
        bundle_verifier = f"{PRODUCER_ROOT}/scripts/verify_macos_mpv_bundle.sh"
        arch_verifier = f"{PRODUCER_ROOT}/scripts/verify_binary_arch.py"
        backend_verifier = f"{PRODUCER_ROOT}/scripts/verify_macos_shared_backend.py"
        dmg_name = f"{PREFIX}.dmg"
        core_name = f"{PREFIX}.shared-core.json"
        backend_name = f"{PREFIX}.shared-backend.json"
        distribution_name = f"{PREFIX}.shared-distribution.json"
        dmg = root / dmg_name
        dmg.write_bytes(b"test DMG bytes")

        core = {
            "framework_sha256": HASH,
            "runner_sha256": "d" * 64,
            "build_identity_sha256": "e" * 64,
            "shared_renderer_enabled": True,
            "complete_source": {
                "base_archive_sha256": "a" * 64,
                "patch_sha256": "b" * 64,
                "source_tree_sha256": "c" * 64,
                "manifest_sha256": "f" * 64,
                "file_count": 42,
            },
            "candidate_consumer": {
                "status": "staged-gates-passed",
                "input_kind_claim": "normal",
                "build_identity_sha256": "e" * 64,
                "sealed_inputs_manifest_sha256": "1" * 64,
                "consumer_sha256": "9" * 64,
            },
        }
        core_path = root / core_name
        core_path.write_text(json.dumps(core) + "\n", encoding="utf-8")

        backend = {
            "framework_sha256": HASH,
            "manifest_sha256": "f" * 64,
            "backend_creation_and_empty_target_render": {
                "arm64": {"exit_code": 0},
                "x86_64": {"exit_code": 0},
            },
        }
        backend_path = root / backend_name
        backend_bytes = (json.dumps(backend, sort_keys=True) + "\n").encode()
        backend_path.write_bytes(backend_bytes)
        backend_sha = sha(backend_bytes)
        consumer_app_path = f"{CONSUMER_ROOT}/candidate/PiliPlusX.app"
        result_report = {
            "status": "published-candidate",
            "candidate": consumer_app_path,
            "input_kind_claim": "normal",
            "build_identity_sha256": "e" * 64,
            "sealed_inputs_manifest_sha256": "1" * 64,
            "consumer_sha256": "9" * 64,
        }
        result_text = json.dumps(result_report, sort_keys=True) + "\n"
        final_bundle_report = {
            "argv": [
                bundle_verifier,
                consumer_app_path,
            ],
            "exit_code": 0,
            "stdout_sha256": "8" * 64,
            "stderr_sha256": "7" * 64,
        }
        final_bundle_text = json.dumps(final_bundle_report, sort_keys=True, indent=2) + "\n"
        final_bundle_sha = sha(final_bundle_text.encode("utf-8"))

        mounted_tree = "2" * 64
        gate = {
            "argv": [
                "/usr/bin/codesign", "--verify", "--deep", "--strict",
                f"{CONSUMER_ROOT}/mounted/PiliPlusX.app",
            ],
            "exit_code": 0,
            "stdout_sha256": "3" * 64,
            "stderr_sha256": "4" * 64,
            "observed": {
                "pending_absent": True,
                "shared_renderer_enabled": True,
                "runner_sha256": "d" * 64,
                "mpv_sha256": HASH,
                "app_tree_identity_sha256": mounted_tree,
            },
        }
        gates = {
            "codesign": gate,
            "bundle": {**gate, "argv": [
                bundle_verifier, f"{CONSUMER_ROOT}/mounted/PiliPlusX.app",
            ]},
            "arm64": {**gate, "argv": [
                execution["python_executable"], arch_verifier,
                f"{CONSUMER_ROOT}/mounted/PiliPlusX.app/Contents/MacOS/PiliPlusX",
                "--platform", "macos", "--arch", "arm64",
            ]},
            "x86_64": {**gate, "argv": [
                execution["python_executable"], arch_verifier,
                f"{CONSUMER_ROOT}/mounted/PiliPlusX.app/Contents/MacOS/PiliPlusX",
                "--platform", "macos", "--arch", "x86_64",
            ]},
            "backend": {**gate, "argv": [
                execution["python_executable"], backend_verifier,
                f"{CONSUMER_ROOT}/mounted/PiliPlusX.app",
                execution["backend_inputs"]["prepared_source"],
                execution["backend_inputs"]["source_manifest"], "--report",
                execution["backend_inputs"]["report"],
            ]},
        }
        distribution = {
            "schema_version": 2,
            "gate_execution": execution,
            "status": "ready",
            "production_eligible": True,
            "eligibility": {"enabled": True, "missing": []},
            "source": {
                "source_ref": release_source,
                "release_tag": TAG,
                "peeled_tag_commit": release_source,
            },
            "approved_media_kit_revision": media,
            "lock": {
                "path": LOCK,
                "sha256": trusted_lock_sha,
            },
            "build": {
                "identity_sha256": "e" * 64,
                "runner_sha256": "d" * 64,
                "mpv_sha256": HASH,
            },
            "sealed": {
                "input_manifest_sha256": "1" * 64,
                "acquisition_manifest_sha256": "6" * 64,
                "signed_context_manifest_sha256": "7" * 64,
                "runtime_manifest_sha256": "a" * 64,
            },
            "source_manifest": {"identity_sha256": "f" * 64},
            "consumer": {
                "status": "published-candidate",
                "app_path": consumer_app_path,
                "result_report": {"utf8": result_text, "sha256": sha(result_text.encode())},
                "shared_core_sha256": sha(core_path.read_bytes()),
                "shared_backend_sha256": backend_sha,
                "app_tree_identity_sha256": mounted_tree,
                "backend_gates": {
                    "arm64": {"probe_exit_code": 0, "report_sha256": backend_sha},
                    "x86_64": {"probe_exit_code": 0, "report_sha256": backend_sha},
                    "final_bundle": {
                        "exit_code": 0,
                        "report_sha256": final_bundle_sha,
                        "report": {
                            "utf8": final_bundle_text,
                            "sha256": final_bundle_sha,
                        },
                    },
                    "pending_absent": True,
                    "shared_renderer_enabled": True,
                },
            },
            "mounted_app": {
                "app_path": f"{CONSUMER_ROOT}/mounted/PiliPlusX.app",
                "tree_identity_sha256": mounted_tree,
                "runner_sha256": "d" * 64,
                "mpv_sha256": HASH,
                "build_identity_sha256": "e" * 64,
                "sealed_input_manifest_sha256": "1" * 64,
                "acquisition_manifest_sha256": "6" * 64,
                "signed_context_manifest_sha256": "7" * 64,
                "runtime_manifest_sha256": "a" * 64,
                "source_manifest_sha256": "f" * 64,
                "consumer_app_tree_identity_sha256": mounted_tree,
                "mounted_app_tree_identity_sha256": mounted_tree,
                "pending_absent": True,
                "shared_renderer_enabled": True,
                "gates": gates,
            },
            "dmg": {"filename": dmg_name, "sha256": sha(dmg.read_bytes())},
        }
        if mutate:
            mutate(distribution, backend, core)
            core_path.write_text(json.dumps(core) + "\n", encoding="utf-8")
            backend_path.write_text(json.dumps(backend, sort_keys=True) + "\n", encoding="utf-8")
            updated_backend_sha = sha(backend_path.read_bytes())
            distribution["consumer"]["shared_core_sha256"] = sha(core_path.read_bytes())
            distribution["consumer"]["shared_backend_sha256"] = updated_backend_sha
            for architecture in ("arm64", "x86_64"):
                distribution["consumer"]["backend_gates"][architecture]["report_sha256"] = updated_backend_sha
        distribution_path = root / distribution_name
        distribution_path.write_text(json.dumps(distribution, sort_keys=True) + "\n", encoding="utf-8")
        subprocess.run(
            [
                sys.executable, str(MANIFEST), str(root),
                "--platform", "macos",
                "--abi", "universal-arm64+x86_64",
                "--media-kit-commit", media,
                "--git-commit", release_source,
                "--hdr-backend", "shared-gpu-next",
                "--native-library-version", "mpv@0.41.0",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        return {
            "root": root,
            "source_checkout": checkout,
            "source": release_source,
            "lock_sha": trusted_lock_sha,
            "dmg": dmg,
            "core": core_path,
            "backend": backend_path,
            "distribution": distribution_path,
        }

    def write_platform(self, root: Path, platform: str) -> None:
        prefix = f"PiliPlusX_{platform}_{TAG}"
        extension = {"android": ".apk", "ios": ".ipa", "ohos": ".hap"}[platform]
        stage = root / f"stage-{platform}"
        stage.mkdir(parents=True)
        (stage / f"{prefix}{extension}").write_bytes(platform.encode())
        subprocess.run(
            [
                sys.executable, str(MANIFEST), str(stage),
                "--platform", platform,
                "--abi", "arm64",
                "--media-kit-commit", MEDIA,
                "--git-commit", self.source,
                "--native-library-version", "test@1",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        (stage / "manifest.json").replace(root / f"{prefix}.manifest.json")
        (stage / "SHA256SUMS").replace(root / f"{prefix}.SHA256SUMS")
        for artifact in stage.iterdir():
            artifact.replace(root / artifact.name)
        stage.rmdir()

    def test_mac_shared_manifest_binds_real_sidecars_and_mount_gates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self.write_macos(Path(directory) / "macos")
            manifest = json.loads((paths["root"] / "manifest.json").read_text())
            self.assertEqual(manifest["schema"], 2)
            self.assertEqual(manifest["abi"], "universal-arm64+x86_64")
            self.assertEqual(manifest["hdrBackend"], "shared-gpu-next")
            subprocess.run(self.verifier_command(paths["root"]), check=True,
                           capture_output=True, text=True)

    def test_ineligible_distribution_fails_before_manifest_is_written(self) -> None:
        cases = (
            (
                "legacy distribution schema",
                lambda distribution, _backend, _core: distribution.update(schema_version=1),
                "not a production-eligible ready report",
            ),
            (
                "disabled",
                lambda distribution, _backend, _core: (
                    distribution.update(
                        production_eligible=False,
                        eligibility={"enabled": False, "missing": ["hosted-proof"]},
                    )
                ),
                "not a production-eligible ready report",
            ),
            (
                "unapproved",
                lambda distribution, _backend, _core: distribution.update(
                    approved_media_kit_revision=None
                ),
                "does not bind the approved media-kit revision",
            ),
        )
        for name, mutate, message in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory) / "macos"
                with self.assertRaises(subprocess.CalledProcessError) as error:
                    self.write_macos(root, mutate)
                self.assertIn(message, (error.exception.stderr or "") + (error.exception.stdout or ""))
                self.assertFalse((root / "manifest.json").exists())
                self.assertFalse((root / "SHA256SUMS").exists())

    def test_publish_lock_anchor_rejects_null_and_unapproved_pin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            null_checkout, null_source, null_lock_sha = create_trusted_source_checkout(
                Path(directory) / "null-source", approved=None)
            null_paths = self.write_macos(
                Path(directory) / "null-mac", source_checkout=null_checkout,
                source=null_source, lock_sha=null_lock_sha)
            result = subprocess.run(self.verifier_command(
                null_paths["root"], source=null_source, checkout=null_checkout),
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("no approved immutable media-kit revision", result.stderr)

            other_revision = "4" * 40
            other_checkout, other_source, other_lock_sha = create_trusted_source_checkout(
                Path(directory) / "other-source", approved=other_revision)
            other_paths = self.write_macos(
                Path(directory) / "other-mac", source_checkout=other_checkout,
                source=other_source, lock_sha=other_lock_sha, media=MEDIA)
            result = subprocess.run(self.verifier_command(
                other_paths["root"], source=other_source, checkout=other_checkout),
                capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("differs from the approved source lock", result.stderr)

    def test_publish_lock_anchor_rejects_lock_drift_and_wrong_checkout(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self.write_macos(Path(directory) / "macos")
            distribution = json.loads(paths["distribution"].read_text())
            distribution["lock"]["sha256"] = "0" * 64
            paths["distribution"].write_text(json.dumps(distribution, sort_keys=True) + "\n")
            subprocess.run(
                [sys.executable, str(MANIFEST), str(paths["root"]), "--platform", "macos",
                 "--abi", "universal-arm64+x86_64", "--media-kit-commit", MEDIA,
                 "--git-commit", self.source, "--hdr-backend", "shared-gpu-next",
                 "--native-library-version", "mpv@0.41.0"],
                check=True, capture_output=True, text=True)
            result = subprocess.run(self.verifier_command(paths["root"]), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("differs from the approved source lock", result.stderr)

            wrong_checkout, _, _ = create_trusted_source_checkout(
                Path(directory) / "wrong-source", approved="4" * 40)
            result = subprocess.run(self.verifier_command(
                paths["root"], checkout=wrong_checkout), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("HEAD differs from expected source", result.stderr)

    def test_publish_lock_anchor_rejects_uncommitted_lock_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkout, source, lock_sha = create_trusted_source_checkout(
                Path(directory) / "source", approved=MEDIA)
            paths = self.write_macos(Path(directory) / "macos", source_checkout=checkout,
                                     source=source, lock_sha=lock_sha)
            lock_path = checkout / LOCK
            lock = json.loads(lock_path.read_text())
            lock["reviewed_media_kit_revision"] = "4" * 40
            lock_path.write_text(json.dumps(lock, sort_keys=True) + "\n")
            result = subprocess.run(self.verifier_command(
                paths["root"], source=source, checkout=checkout), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("working bytes differ from commit", result.stderr)

    def test_backend_report_must_show_both_real_architecture_gates(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self.write_macos(Path(directory) / "macos")
            backend = json.loads(paths["backend"].read_text())
            backend["backend_creation_and_empty_target_render"]["x86_64"]["exit_code"] = 1
            backend_bytes = (json.dumps(backend, sort_keys=True) + "\n").encode()
            paths["backend"].write_bytes(backend_bytes)
            distribution = json.loads(paths["distribution"].read_text())
            backend_sha = sha(backend_bytes)
            distribution["consumer"]["shared_backend_sha256"] = backend_sha
            distribution["consumer"]["backend_gates"]["arm64"]["report_sha256"] = backend_sha
            distribution["consumer"]["backend_gates"]["x86_64"]["report_sha256"] = backend_sha
            paths["distribution"].write_text(
                json.dumps(distribution, sort_keys=True) + "\n", encoding="utf-8"
            )
            subprocess.run(
                [
                    sys.executable, str(MANIFEST), str(paths["root"]),
                    "--platform", "macos", "--abi", "universal-arm64+x86_64",
                    "--media-kit-commit", MEDIA, "--git-commit", self.source,
                    "--hdr-backend", "shared-gpu-next",
                    "--native-library-version", "mpv@0.41.0",
                ],
                check=True, capture_output=True, text=True,
            )
            result = subprocess.run(self.verifier_command(paths["root"]), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("actual backend report failed for x86_64", result.stderr)

    def test_embedded_consumer_report_must_be_a_real_success_result(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "macos"

            def fail_report(distribution, _backend, _core):
                result = distribution["consumer"]["result_report"]
                value = json.loads(result["utf8"])
                value["status"] = "failed"
                result["utf8"] = json.dumps(value, sort_keys=True) + "\n"
                result["sha256"] = sha(result["utf8"].encode())

            paths = self.write_macos(root, fail_report)
            result = subprocess.run(self.verifier_command(paths["root"]), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("embedded consumer result does not report", result.stderr)

    def test_final_bundle_gate_report_is_verifiable_offline(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            def tamper_report(distribution, _backend, _core):
                final = distribution["consumer"]["backend_gates"]["final_bundle"]
                final["report"]["utf8"] = final["report"]["utf8"].replace("exit_code\": 0", "exit_code\": 1")

            paths = self.write_macos(Path(directory) / "macos", tamper_report)
            result = subprocess.run(self.verifier_command(paths["root"]), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("embedded final bundle gate report SHA-256 is invalid", result.stderr)

    def test_mounted_gate_must_target_the_mounted_app(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            def redirect_gate(distribution, _backend, _core):
                distribution["mounted_app"]["gates"]["backend"]["argv"] = [
                    "/usr/bin/python3",
                    str(self.source_checkout / "scripts/verify_macos_shared_backend.py"),
                    "/tmp/other/PiliPlusX.app", "/tmp/prepared-source",
                    "/tmp/recipe/manifest.json", "--report", "/tmp/mounted-backend.json",
                ]

            paths = self.write_macos(Path(directory) / "macos", redirect_gate)
            result = subprocess.run(self.verifier_command(paths["root"]), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("backend gate argv differs from its trusted execution identity", result.stderr)

    def test_architecture_gates_require_exact_tools_targets_and_abi_flags(self) -> None:
        cases = (
            ("mixed producer root", lambda gate: gate["argv"].__setitem__(1,
                gate["argv"][1].replace(PRODUCER_ROOT, "/Users/actions/work/OtherProject"))),
            ("wrong tool", lambda gate: gate["argv"].__setitem__(1, "/usr/bin/true")),
            ("wrong target", lambda gate: gate["argv"].__setitem__(2, "/tmp/other.app/Contents/MacOS/PiliPlusX")),
            ("missing architecture", lambda gate: gate["argv"].pop()),
            ("wrong architecture", lambda gate: gate["argv"].__setitem__(-1, "arm64")),
            ("duplicate architecture", lambda gate: gate["argv"].extend(["--arch", "x86_64"])),
        )
        for name, change in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                def mutate(distribution, _backend, _core):
                    change(distribution["mounted_app"]["gates"]["x86_64"])

                paths = self.write_macos(Path(directory) / "macos", mutate)
                result = subprocess.run(self.verifier_command(paths["root"]),
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("x86_64 gate argv differs from its trusted execution identity", result.stderr)

    def test_final_bundle_gate_requires_trusted_script_and_consumer_path(self) -> None:
        cases = (
            ("wrong tool", ["/usr/bin/true", "/private/tmp/candidate/PiliPlusX.app"]),
            ("wrong target", [str(self.source_checkout / "scripts/verify_macos_mpv_bundle.sh"),
                               "/private/tmp/other/PiliPlusX.app"]),
        )
        for name, argv in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                def mutate(distribution, _backend, _core):
                    final = distribution["consumer"]["backend_gates"]["final_bundle"]
                    report = json.loads(final["report"]["utf8"])
                    report["argv"] = argv
                    report_text = json.dumps(report, sort_keys=True, indent=2) + "\n"
                    report_sha = sha(report_text.encode())
                    final["report"] = {"utf8": report_text, "sha256": report_sha}
                    final["report_sha256"] = report_sha

                paths = self.write_macos(Path(directory) / "macos", mutate)
                result = subprocess.run(self.verifier_command(paths["root"]),
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue("final_bundle gate argv differs" in result.stderr or
                                "differs from the embedded consumer App" in result.stderr)

    def test_backend_gate_requires_trusted_script_and_source_manifest_argument(self) -> None:
        cases = (
            ("wrong tool", lambda argv: argv.__setitem__(1, "/usr/bin/true")),
            ("wrong manifest", lambda argv: argv.__setitem__(4, "/tmp/other/source.json")),
            ("missing report", lambda argv: argv.pop()),
        )
        for name, change in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                def mutate(distribution, _backend, _core):
                    change(distribution["mounted_app"]["gates"]["backend"]["argv"])

                paths = self.write_macos(Path(directory) / "macos", mutate)
                result = subprocess.run(self.verifier_command(paths["root"]),
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("backend gate argv differs from its trusted execution identity", result.stderr)

    def test_consumer_app_path_must_match_raw_result_and_final_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            def mutate(distribution, _backend, _core):
                distribution["consumer"]["app_path"] = "/tmp/other/PiliPlusX.app"

            paths = self.write_macos(Path(directory) / "macos", mutate)
            result = subprocess.run(self.verifier_command(paths["root"]),
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("differs from the embedded consumer result", result.stderr)

    def test_complete_source_identity_requires_full_structured_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            def mutate(distribution, _backend, core):
                del core["complete_source"]["source_tree_sha256"]
                distribution["consumer"]["shared_core_sha256"] = sha(
                    json.dumps(core, sort_keys=True).encode())

            paths = self.write_macos(Path(directory) / "macos", mutate)
            result = subprocess.run(self.verifier_command(paths["root"]),
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("complete_source.source_tree_sha256", result.stderr)

    def test_all_platforms_must_match_expected_source_and_exact_asset_set(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mac = self.write_macos(root / "mac-source")
            for platform in ("android", "ios", "ohos"):
                self.write_platform(root, platform)
            for name in (mac["dmg"].name, mac["core"].name,
                         mac["backend"].name, mac["distribution"].name):
                (mac["root"] / name).replace(root / name)
            (mac["root"] / "manifest.json").replace(root / f"{PREFIX}.manifest.json")
            (mac["root"] / "SHA256SUMS").replace(root / f"{PREFIX}.SHA256SUMS")
            mac["root"].rmdir()
            subprocess.run(
                [sys.executable, str(ASSETS), str(root), "--expected-source", self.source,
                 "--source-checkout", str(self.source_checkout)],
                check=True, capture_output=True, text=True,
            )

            android_manifest = root / f"PiliPlusX_android_{TAG}.manifest.json"
            original = android_manifest.read_text(encoding="utf-8")
            edited = json.loads(original)
            edited["gitCommit"] = "9" * 40
            android_manifest.write_text(json.dumps(edited) + "\n", encoding="utf-8")
            result = subprocess.run(
                [sys.executable, str(ASSETS), str(root), "--expected-source", self.source,
                 "--source-checkout", str(self.source_checkout)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("does not match release source", result.stderr)
            android_manifest.write_text(original, encoding="utf-8")

            (root / "undeclared.txt").write_text("extra")
            result = subprocess.run(
                [sys.executable, str(ASSETS), str(root), "--expected-source", self.source,
                 "--source-checkout", str(self.source_checkout)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unexpected=['undeclared.txt']", result.stderr)

    def test_manifest_path_traversal_and_sidecar_tampering_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self.write_macos(Path(directory) / "macos")
            manifest_path = paths["root"] / "manifest.json"
            manifest = json.loads(manifest_path.read_text())
            manifest["files"][0]["path"] = "../escape.dmg"
            manifest_path.write_text(json.dumps(manifest))
            result = subprocess.run(self.verifier_command(paths["root"]), capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_release_aggregate_rejects_symlinked_payload(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            mac = self.write_macos(root / "mac-stage")
            for platform in ("android", "ios", "ohos"):
                self.write_platform(root, platform)
            for payload in (mac["dmg"], mac["core"], mac["backend"], mac["distribution"]):
                payload.replace(root / payload.name)
            (mac["root"] / "manifest.json").replace(root / f"{PREFIX}.manifest.json")
            (mac["root"] / "SHA256SUMS").replace(root / f"{PREFIX}.SHA256SUMS")
            mac["root"].rmdir()
            original = root / "PiliPlusX_android_v1.2.3_arm64.apk"
            alias = root / "PiliPlusX_android_v1.2.3_arm64-copy.apk"
            alias.symlink_to(original.name)
            result = subprocess.run(
                [sys.executable, str(ASSETS), str(root), "--expected-source", self.source,
                 "--source-checkout", str(self.source_checkout)],
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("non-regular entry", result.stderr)

    def test_cross_host_gate_execution_uses_only_committed_script_digests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            paths = self.write_macos(Path(directory) / "macos")
            execution = json.loads(paths["distribution"].read_text())["gate_execution"]
            self.assertEqual(execution["producer_checkout_root"], PRODUCER_ROOT)
            self.assertNotEqual(execution["producer_checkout_root"], str(self.source_checkout))
            self.assertEqual(set(execution["scripts"]), set(GATE_SCRIPTS))
            # A nonexistent foreign host path is intentional: the consumer verifies
            # argv strings and committed digests without resolving producer paths.
            self.assertEqual(execution["scripts"], trusted_gate_digests(
                self.source_checkout, self.source))
            result = subprocess.run(self.verifier_command(paths["root"]),
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_gate_execution_rejects_missing_extra_drift_schema_and_bad_paths(self) -> None:
        valid = {
            "schema_version": 1,
            "producer_checkout_root": PRODUCER_ROOT,
            "python_executable": "/Users/actions/python/bin/python3",
            "scripts": trusted_gate_digests(self.source_checkout, self.source),
            "backend_inputs": {
                "prepared_source": "/Users/actions/runner_temp/shared-source",
                "source_manifest": "/Users/actions/runner_temp/recipe/manifest.json",
                "report": "/Users/actions/runner_temp/mounted-backend.json",
            },
        }
        invalid_cases = []
        for label, mutate in (
            ("wrong schema", lambda item: item.update(schema_version=2)),
            ("non-python executable", lambda item: item.update(python_executable="/Users/actions/true")),
            ("missing script", lambda item: item["scripts"].pop(GATE_SCRIPTS[0])),
            ("extra script", lambda item: item["scripts"].update({"scripts/untrusted.py": "a" * 64})),
            ("digest drift", lambda item: item["scripts"].update({GATE_SCRIPTS[0]: "0" * 64})),
            ("root traversal", lambda item: item.update(producer_checkout_root="/Users/actions/../other")),
            ("double slash", lambda item: item.update(producer_checkout_root="/Users//actions/work")),
            ("trailing slash", lambda item: item.update(producer_checkout_root="/Users/actions/work/")),
            ("filesystem root", lambda item: item.update(producer_checkout_root="/")),
            ("NUL", lambda item: item.update(producer_checkout_root="/Users/actions/\x00work")),
            ("backend traversal", lambda item: item["backend_inputs"].update(
                prepared_source="/Users/actions/../outside")),
            ("manifest mismatch", lambda item: item["backend_inputs"].update(
                source_manifest="/Users/actions/recipe/source.json")),
        ):
            item = json.loads(json.dumps(valid))
            mutate(item)
            invalid_cases.append((label, item))
        trusted = trusted_gate_digests(self.source_checkout, self.source)
        for label, item in invalid_cases:
            with self.subTest(label=label), self.assertRaises(GateIdentityError):
                validate_gate_execution(item, trusted)

    def test_consumer_rejects_schema_one_and_unbound_gate_script_set(self) -> None:
        cases = (
            ("missing gate", lambda d, _b, _c: d["gate_execution"]["scripts"].pop(GATE_SCRIPTS[0]),
             "exactly the fixed seven scripts"),
            ("extra gate", lambda d, _b, _c: d["gate_execution"]["scripts"].update(
                {"scripts/extra.py": "a" * 64}), "exactly the fixed seven scripts"),
            ("drifted digest", lambda d, _b, _c: d["gate_execution"]["scripts"].update(
                {GATE_SCRIPTS[0]: "0" * 64}), f"gate script identity differs from trusted source: {GATE_SCRIPTS[0]}"),
        )
        for name, mutate, expected in cases:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                paths = self.write_macos(Path(directory) / "macos", mutate)
                result = subprocess.run(self.verifier_command(paths["root"]),
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

        with tempfile.TemporaryDirectory() as directory:
            paths = self.write_macos(Path(directory) / "macos")
            distribution = json.loads(paths["distribution"].read_text())
            distribution["schema_version"] = 1
            paths["distribution"].write_text(json.dumps(distribution, sort_keys=True) + "\n")
            manifest_path = paths["root"] / "manifest.json"
            manifest = json.loads(manifest_path.read_text())
            sums = []
            for entry in manifest["files"]:
                data = (paths["root"] / entry["path"]).read_bytes()
                entry["sha256"] = sha(data)
                entry["size"] = len(data)
                sums.append(f"{entry['sha256']}  {entry['path']}\n")
            manifest["sharedRelease"]["distribution"]["sha256"] = sha(
                paths["distribution"].read_bytes())
            manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
            (paths["root"] / "SHA256SUMS").write_text("".join(sums))
            result = subprocess.run(self.verifier_command(paths["root"]),
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("macOS shared distribution is not production eligible", result.stderr)

    def test_producer_capture_rechecks_source_lock_and_all_seven_scripts(self) -> None:
        execution = capture_gate_execution(
            self.source_checkout, self.source,
            python_executable="/usr/bin/python3",
            backend_inputs={
                "prepared_source": "/tmp/fixture/source",
                "source_manifest": "/tmp/fixture/recipe/manifest.json",
                "report": "/tmp/fixture/backend.json",
            },
        )
        self.assertEqual(set(execution["scripts"]), set(GATE_SCRIPTS))
        self.assertEqual(execution["producer_checkout_root"], str(self.source_checkout))
        self.assertEqual(execution["scripts"], trusted_gate_digests(
            self.source_checkout, self.source))
        with self.assertRaises(GateIdentityError):
            capture_gate_execution(
                self.source_checkout, self.source,
                python_executable="/usr/bin/python3",
                backend_inputs={
                    "prepared_source": "/tmp/fixture/source/",
                    "source_manifest": "/tmp/fixture/recipe/manifest.json",
                    "report": "/tmp/fixture/backend.json",
                },
            )

    def test_trusted_gate_source_rejects_missing_drift_and_symlink_scripts(self) -> None:
        script = self.source_checkout / GATE_SCRIPTS[0]
        original = script.read_bytes()
        script.unlink()
        with self.assertRaisesRegex(GateIdentityError, "missing"):
            trusted_gate_digests(self.source_checkout, self.source)
        script.write_bytes(original)

        script.write_bytes(original + b"\n# uncommitted drift\n")
        with self.assertRaisesRegex(GateIdentityError, "working bytes differ"):
            trusted_gate_digests(self.source_checkout, self.source)
        script.write_bytes(original)

        native_dir = self.source_checkout / "scripts/native"
        moved = self.source_checkout / "scripts/native-real"
        native_dir.rename(moved)
        native_dir.symlink_to(moved, target_is_directory=True)
        with self.assertRaisesRegex(GateIdentityError, "symbolic link"):
            trusted_gate_digests(self.source_checkout, self.source)

    def test_publish_job_checks_out_and_verifies_the_context_source(self) -> None:
        workflow = (ROOT / ".github/workflows/release.yml").read_text(encoding="utf-8")
        source_expression = "$" + "{{ needs.context.outputs.source_sha }}"
        self.assertIn(f"ref: {source_expression}", workflow)
        self.assertIn(f'--expected-source "{source_expression}"', workflow)
        self.assertIn('--source-checkout "$GITHUB_WORKSPACE"', workflow)
        self.assertIn('--source-checkout "$GITHUB_WORKSPACE"', workflow)


if __name__ == "__main__":
    unittest.main()
