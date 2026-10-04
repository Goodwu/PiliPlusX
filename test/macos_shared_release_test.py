from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from shared_gate_execution import GATE_SCRIPTS


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


candidate = load("release_candidate_under_test", ROOT / "scripts/run_macos_shared_ci_candidate.py")
release = load("shared_release_under_test", ROOT / "scripts/run_macos_shared_release.py")


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def completed(argv, stdout="", stderr="", code=0):
    return subprocess.CompletedProcess(argv, code, stdout, stderr)


class SharedReleaseTests(unittest.TestCase):
    def test_hosted_preflight_rejects_self_hosted_environment(self):
        hosted_markers = {"GITHUB_ACTIONS": "true", "RUNNER_OS": "macOS",
                          "RUNNER_ARCH": "ARM64", "RUNNER_ENVIRONMENT": "self-hosted"}
        with mock.patch.dict(os.environ, hosted_markers, clear=False):
            with self.assertRaisesRegex(release.ReleaseError, "hosted macOS ARM64/Python 3.11 runner"):
                release.require_hosted_preflight()

    def make_pipeline(self, base: Path, run_dir: Path | None = None) -> tuple[dict, dict]:
        run_dir = run_dir or (base / "run")
        run_dir.mkdir(parents=True, exist_ok=True)
        artifact = run_dir / "artifact"
        artifact.mkdir()
        app = artifact / "PiliPlusX-shared-candidate.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Frameworks/Mpv.framework/Versions/A").mkdir(parents=True)
        info = {"CFBundleExecutable": "PiliPlusX", "MediaKitSharedRenderer": True}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        (app / "Contents/MacOS/PiliPlusX").write_bytes(b"universal runner fixture")
        (app / "Contents/Frameworks/Mpv.framework/Versions/A/Mpv").write_bytes(b"universal mpv fixture")
        for name in ("libplacebo.dylib", "libvulkan.1.dylib", "libshaderc_shared.1.dylib"):
            (app / "Contents/Frameworks" / name).write_bytes(name.encode())

        recipe = run_dir / "media-kit/tool/shared_gpu_next"
        recipe.mkdir(parents=True)
        source_manifest = recipe / "manifest.json"
        source_manifest.write_text(json.dumps({"schema_version": 1, "files": {}}))
        source_identity = sha(source_manifest)
        prepared_source = run_dir / "shared-work/source"
        prepared_source.mkdir(parents=True)
        (prepared_source / "fixture.c").write_text("int fixture;\n")
        core_path = app.with_suffix(".shared-core.json")
        backend_path = app.with_suffix(".shared-backend.json")
        build_identity = "a" * 64
        sealed_identity = hashlib.sha256(json.dumps({"sealed": True}).encode()).hexdigest()
        consumer_identity = "f" * 64
        runner_sha = sha(app / "Contents/MacOS/PiliPlusX")
        mpv_sha = sha(app / "Contents/Frameworks/Mpv.framework/Versions/A/Mpv")
        core = {
            "shared_renderer_enabled": True,
            "runner_sha256": runner_sha,
            "framework_sha256": mpv_sha,
            "build_identity_sha256": build_identity,
            "complete_source": {"base_archive_sha256": "1" * 64,
                                "patch_sha256": "2" * 64,
                                "source_tree_sha256": "3" * 64,
                                "manifest_sha256": source_identity,
                                "file_count": 1},
            "candidate_consumer": {"status": "staged-gates-passed",
                                   "input_kind_claim": "normal",
                                   "consumer_sha256": consumer_identity,
                                   "build_identity_sha256": build_identity,
                                   "sealed_inputs_manifest_sha256": sealed_identity},
        }
        backend = {"framework_sha256": mpv_sha, "manifest_sha256": source_identity,
                   "backend_creation_and_empty_target_render": {
                       "arm64": {"exit_code": 0, "stdout": "PASS arm64", "stderr": ""},
                       "x86_64": {"exit_code": 0, "stdout": "PASS x86_64", "stderr": ""}}}
        core_path.write_text(json.dumps(core, sort_keys=True))
        backend_path.write_text(json.dumps(backend, sort_keys=True))
        consumer_result = run_dir / "consumer-result.json"
        consumer_result.write_text(json.dumps({"status": "published-candidate",
                                               "input_kind_claim": "normal",
                                               "candidate": str(app.resolve()),
                                               "consumer_sha256": consumer_identity,
                                               "build_identity_sha256": build_identity,
                                               "sealed_inputs_manifest_sha256": sealed_identity}))
        manifests = {}
        for filename, body in (("sealed-inputs.json", {"sealed": True}),
                               ("signed-context.json", {"signed": True}),
                               ("runtime.json", {"runtime": True}),
                               ("acquisition.json", {"acquired": True})):
            path = run_dir / filename
            path.write_text(json.dumps(body))
            manifests[filename] = path
        report = {"commands": [{"label": "final-bundle-gate", "argv": [
                                    str(release.ROOT / "scripts/verify_macos_mpv_bundle.sh"),
                                    str(app.resolve())],
                                "exit_code": 0, "stdout": "PASS bundle\n", "stderr": ""}],
                  "approved_media_kit_revision": "c" * 40}
        pipeline = {"final_app": str(app), "shared_core": str(core_path),
                    "shared_backend": str(backend_path), "artifact_directory": str(artifact),
                    "source_ref": "d" * 40, "approved_media_kit_revision": "c" * 40,
                    "recipe": str(recipe), "prepared_source": str(prepared_source),
                    "sealed_inputs_manifest": str(manifests["sealed-inputs.json"]),
                    "signed_context_manifest": str(manifests["signed-context.json"]),
                    "runtime_manifest": str(manifests["runtime.json"]),
                    "raw_acquisition_manifest": str(manifests["acquisition.json"]),
                    "consumer_result": str(consumer_result)}
        return pipeline, report

    def make_metadata_source_checkout(self, base: Path) -> tuple[Path, str, Path]:
        checkout = base / "trusted-source"
        names = {
            "scripts/macos-shared-ci-inputs.lock.json",
            "scripts/verify_release_manifest.py",
            "scripts/verify_release_assets.py",
            "scripts/shared_gate_execution.py",
            *GATE_SCRIPTS,
        }
        for relative in sorted(names):
            destination = checkout / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / relative, destination)
            if relative.endswith(".sh"):
                destination.chmod(0o755)
        for relative in ("pubspec.yaml", "pubspec.lock"):
            shutil.copyfile(ROOT / relative, checkout / relative)
        scripts = checkout / "scripts"
        lock = scripts / "macos-shared-ci-inputs.lock.json"
        lock.write_text(json.dumps({"reviewed_media_kit_revision": "c" * 40},
                                   sort_keys=True) + "\n", encoding="utf-8")
        subprocess.run(["git", "init", "--quiet", str(checkout)], check=True)
        subprocess.run(["git", "config", "user.name", "CPU fixture"], cwd=checkout, check=True)
        subprocess.run(["git", "config", "user.email", "fixture@example.invalid"], cwd=checkout, check=True)
        subprocess.run(["git", "add", "scripts"], cwd=checkout, check=True)
        subprocess.run(["git", "commit", "--quiet", "-m", "trusted source fixture"],
                       cwd=checkout, check=True)
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=checkout, check=True,
                                text=True, capture_output=True).stdout.strip()
        return checkout, commit, lock

    def fake_commands(self, temp_source: Path, *, drift: bool = False):
        mounts: dict[str, Path] = {}
        mounted_dirs: dict[str, Path] = {}

        def invoke(argv, *, cwd=ROOT, timeout=180):
            argv = [str(value) for value in argv]
            name = Path(argv[0]).name
            if name == "ditto":
                shutil.copytree(argv[1], argv[2], symlinks=True)
                return completed(argv)
            if name == "hdiutil" and argv[1] == "create":
                source = Path(argv[argv.index("-srcfolder") + 1])
                destination = Path(argv[-1])
                destination.write_bytes(b"mock read-only DMG")
                mounts[str(destination)] = source
                return completed(argv)
            if name == "hdiutil" and argv[1] == "attach":
                mount = Path(argv[argv.index("-mountpoint") + 1])
                mounted_dirs["/dev/disk99"] = mount
                shutil.copytree(mounts[argv[-1]] / "PiliPlusX-shared-candidate.app",
                                mount / "PiliPlusX-shared-candidate.app", symlinks=True)
                if drift:
                    (mount / "PiliPlusX-shared-candidate.app/Contents/MacOS/PiliPlusX").write_bytes(b"changed")
                result = {"system-entities": [{"dev-entry": "/dev/disk99", "mount-point": str(mount)}]}
                return completed(argv, plistlib.dumps(result).decode("latin1"))
            if name == "hdiutil" and argv[1] == "detach":
                device = Path(argv[-1])
                self.assertEqual(str(device), "/dev/disk99")
                mount = mounted_dirs.pop(str(device))
                for child in mount.iterdir():
                    if child.is_dir() and not child.is_symlink():
                        shutil.rmtree(child)
                    else:
                        child.unlink()
                return completed(argv)
            if any(Path(value).name == "verify_macos_shared_backend.py" for value in argv):
                report = Path(argv[argv.index("--report") + 1])
                app = Path(argv[2])
                record = {"framework_sha256": sha(app / "Contents/Frameworks/Mpv.framework/Versions/A/Mpv"),
                          "manifest_sha256": sha(Path(argv[4])),
                          "backend_creation_and_empty_target_render": {
                              "arm64": {"exit_code": 0, "stdout": "PASS", "stderr": ""},
                              "x86_64": {"exit_code": 0, "stdout": "PASS", "stderr": ""}}}
                report.write_text(json.dumps(record))
                return completed(argv, "PASS\n")
            return completed(argv, "PASS\n")

        return invoke

    def test_tag_source_binding_requires_actual_head_and_peeled_tag(self):
        responses = iter((completed([], "1" * 40 + "\n"), completed([], "1" * 40 + "\n")))
        source = release.validate_release_source("v1.2.3-rc.1", "1" * 40,
                                                 runner=lambda argv: next(responses))
        self.assertEqual(source["peeled_tag_commit"], "1" * 40)
        with self.assertRaisesRegex(release.ReleaseError, "SOURCE_SHA"):
            release.validate_release_source("v1.2.3", "branch-name")
        with self.assertRaisesRegex(release.ReleaseError, "must match"):
            release.validate_release_source("v1.2.3", "2" * 40,
                runner=lambda argv: completed(argv, "1" * 40 + "\n"))

    def test_successful_mock_pipeline_emits_flat_bound_payloads_and_detaches(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            trusted_checkout, source_sha, trusted_lock = self.make_metadata_source_checkout(base)
            with mock.patch.object(release, "ROOT", trusted_checkout):
                pipeline, report = self.make_pipeline(base)
            run_dir = Path(pipeline["artifact_directory"]).parent
            output = run_dir / "distribution"
            fake = self.fake_commands(Path(pipeline["final_app"]).parent)
            source = {"source_ref": source_sha, "release_tag": "v1.2.3",
                      "peeled_tag_commit": source_sha}
            with mock.patch.object(release, "ROOT", trusted_checkout), \
                 mock.patch.object(release, "run", side_effect=fake):
                files = release.package_release(pipeline, source, report, report,
                                                "v1.2.3", run_dir, output,
                                                sha(trusted_lock))
            self.assertEqual({p.name for p in files}, {
                "PiliPlusX_macos_v1.2.3.dmg",
                "PiliPlusX_macos_v1.2.3.shared-core.json",
                "PiliPlusX_macos_v1.2.3.shared-backend.json",
                "PiliPlusX_macos_v1.2.3.shared-distribution.json"})
            self.assertEqual(files[1].read_bytes(), Path(pipeline["shared_core"]).read_bytes())
            self.assertEqual(files[2].read_bytes(), Path(pipeline["shared_backend"]).read_bytes())
            distribution = json.loads(files[3].read_text())
            self.assertTrue(distribution["production_eligible"])
            execution = distribution["gate_execution"]
            self.assertEqual(distribution["schema_version"], 2)
            self.assertEqual(execution["schema_version"], 1)
            self.assertEqual(execution["producer_checkout_root"], str(trusted_checkout))
            self.assertEqual(execution["python_executable"], sys.executable)
            self.assertEqual(set(execution["scripts"]), set(GATE_SCRIPTS))
            self.assertEqual(execution["backend_inputs"], {
                "prepared_source": str(Path(pipeline["prepared_source"]).resolve()),
                "source_manifest": str((Path(pipeline["recipe"]) / "manifest.json").resolve()),
                "report": str((run_dir / "mounted-backend.json").resolve()),
            })
            self.assertEqual(distribution["eligibility"], {"enabled": True, "missing": []})
            self.assertEqual(distribution["consumer"]["backend_gates"]["arm64"]["probe_exit_code"], 0)
            final_gate = distribution["consumer"]["backend_gates"]["final_bundle"]
            self.assertEqual(final_gate["exit_code"], 0)
            self.assertEqual(final_gate["report"]["sha256"], final_gate["report_sha256"])
            self.assertEqual(distribution["consumer"]["app_path"],
                             json.loads(final_gate["report"]["utf8"])["argv"][1])
            self.assertEqual(hashlib.sha256(final_gate["report"]["utf8"].encode("utf-8")).hexdigest(),
                             final_gate["report_sha256"])
            self.assertEqual(json.loads(final_gate["report"]["utf8"])["argv"],
                             [str(trusted_checkout / "scripts/verify_macos_mpv_bundle.sh"),
                              str(Path(pipeline["final_app"]).resolve())])
            self.assertEqual(distribution["mounted_app"]["gates"].keys(),
                             {"codesign", "bundle", "arm64", "x86_64", "backend"})
            self.assertEqual(distribution["consumer"]["app_tree_identity_sha256"],
                             distribution["mounted_app"]["tree_identity_sha256"])
            self.assertTrue((run_dir / "mounted-volume").exists())
            self.assertEqual(list((run_dir / "mounted-volume").iterdir()), [])
            metadata_dir = base / "release-metadata" / "macos"
            metadata_dir.mkdir(parents=True)
            for payload in files:
                shutil.copyfile(payload, metadata_dir / payload.name)
            mounted = distribution["mounted_app"]
            sealed = distribution["sealed"]
            self.assertEqual(mounted["runner_sha256"], distribution["build"]["runner_sha256"])
            self.assertEqual(mounted["mpv_sha256"], distribution["build"]["mpv_sha256"])
            self.assertEqual(mounted["build_identity_sha256"], distribution["build"]["identity_sha256"])
            self.assertEqual(mounted["sealed_input_manifest_sha256"], sealed["input_manifest_sha256"])
            self.assertEqual(mounted["acquisition_manifest_sha256"], sealed["acquisition_manifest_sha256"])
            self.assertEqual(mounted["signed_context_manifest_sha256"], sealed["signed_context_manifest_sha256"])
            self.assertEqual(mounted["runtime_manifest_sha256"], sealed["runtime_manifest_sha256"])
            self.assertEqual(mounted["source_manifest_sha256"], distribution["source_manifest"]["identity_sha256"])
            self.assertEqual(mounted["consumer_app_tree_identity_sha256"], distribution["consumer"]["app_tree_identity_sha256"])
            self.assertEqual(mounted["mounted_app_tree_identity_sha256"], mounted["tree_identity_sha256"])
            self.assertEqual(distribution["consumer"]["app_tree_identity_sha256"],
                             mounted["tree_identity_sha256"])
            manifest_command = [sys.executable, str(ROOT / "scripts/release_manifest.py"),
                str(metadata_dir), "--platform", "macos", "--abi", "universal-arm64+x86_64",
                "--git-commit", source["source_ref"], "--media-kit-commit", "c" * 40,
                "--hdr-backend", "shared-gpu-next",
                "--native-library-version", "mpv@0.41.0+shared-gpu-next"]
            manifest_result = subprocess.run(manifest_command, text=True, capture_output=True)
            self.assertEqual(manifest_result.returncode, 0,
                             manifest_result.stdout + manifest_result.stderr)
            verify_result = subprocess.run([sys.executable,
                str(trusted_checkout / "scripts/verify_release_manifest.py"), str(metadata_dir),
                "--expected-source", source["source_ref"],
                "--source-checkout", str(trusted_checkout)], text=True, capture_output=True)
            self.assertEqual(verify_result.returncode, 0, verify_result.stdout + verify_result.stderr)

            verifier_checkout = base / "cross-root-verifier-source"
            subprocess.run(["git", "clone", "--quiet", str(trusted_checkout),
                            str(verifier_checkout)], check=True)
            self.assertEqual(subprocess.check_output(
                ["git", "-C", str(verifier_checkout), "rev-parse", "HEAD"],
                text=True).strip(), source["source_ref"])
            cross_root_result = subprocess.run([sys.executable,
                str(verifier_checkout / "scripts/verify_release_manifest.py"), str(metadata_dir),
                "--expected-source", source["source_ref"],
                "--source-checkout", str(verifier_checkout)], text=True, capture_output=True)
            self.assertEqual(cross_root_result.returncode, 0,
                             cross_root_result.stdout + cross_root_result.stderr)

            prefix = "PiliPlusX_macos_v1.2.3"
            (metadata_dir / f"{prefix}.manifest.json").write_bytes(
                (metadata_dir / "manifest.json").read_bytes())
            (metadata_dir / f"{prefix}.SHA256SUMS").write_bytes(
                (metadata_dir / "SHA256SUMS").read_bytes())
            (metadata_dir / "manifest.json").unlink()
            (metadata_dir / "SHA256SUMS").unlink()
            for platform_name in ("android", "ios", "ohos"):
                payload_name = f"fixture-{platform_name}.bin"
                payload = metadata_dir / payload_name
                payload.write_bytes(f"{platform_name} fixture\n".encode())
                platform_prefix = f"PiliPlusX_{platform_name}_v1.2.3"
                manifest = {"schema": 1, "platform": platform_name, "abi": "fixture",
                            "hdrBackend": "fixture", "nativeLibraryVersion": "fixture@1",
                            "gitCommit": source["source_ref"],
                            "mediaKitCommit": "c" * 40,
                            "files": [{"path": payload_name, "sha256": sha(payload),
                                       "size": payload.stat().st_size}]}
                (metadata_dir / f"{platform_prefix}.manifest.json").write_text(
                    json.dumps(manifest, sort_keys=True) + "\n")
                (metadata_dir / f"{platform_prefix}.SHA256SUMS").write_text(
                    f"{sha(payload)}  {payload_name}\n")
            same_root_aggregate = subprocess.run([sys.executable,
                str(ROOT / "scripts/verify_release_assets.py"), str(metadata_dir),
                "--expected-source", source["source_ref"],
                "--source-checkout", str(trusted_checkout)], text=True, capture_output=True)
            self.assertEqual(same_root_aggregate.returncode, 0,
                             same_root_aggregate.stdout + same_root_aggregate.stderr)
            aggregate_result = subprocess.run([sys.executable,
                str(ROOT / "scripts/verify_release_assets.py"), str(metadata_dir),
                "--expected-source", source["source_ref"],
                "--source-checkout", str(verifier_checkout)], text=True, capture_output=True)
            self.assertEqual(aggregate_result.returncode, 0,
                             aggregate_result.stdout + aggregate_result.stderr)

    def test_noncanonical_final_gate_argv_fails_before_mount_or_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            trusted_checkout, source_sha, trusted_lock = self.make_metadata_source_checkout(base)
            with mock.patch.object(release, "ROOT", trusted_checkout):
                pipeline, report = self.make_pipeline(base)
            report["commands"][0]["argv"][0] = "/tmp/untrusted/verify_macos_mpv_bundle.sh"
            run_dir = Path(pipeline["artifact_directory"]).parent
            output = run_dir / "distribution"
            source = {"source_ref": source_sha, "release_tag": "v1.2.3",
                      "peeled_tag_commit": source_sha}
            with mock.patch.object(release, "ROOT", trusted_checkout):
                with self.assertRaisesRegex(release.ReleaseError, "final_bundle gate argv"):
                    release.package_release(pipeline, source, report, report,
                                            "v1.2.3", run_dir, output, sha(trusted_lock))
            self.assertFalse(output.exists())
            self.assertFalse((run_dir / "dmg-source").exists())

    def test_gate_script_drift_after_all_gates_blocks_publication(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            trusted_checkout, source_sha, trusted_lock = self.make_metadata_source_checkout(base)
            with mock.patch.object(release, "ROOT", trusted_checkout):
                pipeline, report = self.make_pipeline(base)
            run_dir = Path(pipeline["artifact_directory"]).parent
            output = run_dir / "distribution"
            source = {"source_ref": source_sha, "release_tag": "v1.2.3",
                      "peeled_tag_commit": source_sha}
            fake = self.fake_commands(Path(pipeline["final_app"]).parent)
            script = trusted_checkout / "scripts/verify_macos_mpv_bundle.sh"

            def drift_after_backend(argv, *, cwd=release.ROOT, timeout=180):
                result = fake(argv, cwd=cwd, timeout=timeout)
                if any(Path(value).name == "verify_macos_shared_backend.py" for value in argv):
                    script.write_text(script.read_text() + "# uncommitted drift\n")
                return result

            with mock.patch.object(release, "ROOT", trusted_checkout), \
                 mock.patch.object(release, "run", side_effect=drift_after_backend):
                with self.assertRaisesRegex(release.ReleaseError, "gate execution identity"):
                    release.package_release(pipeline, source, report, report,
                                            "v1.2.3", run_dir, output, sha(trusted_lock))
            self.assertFalse(output.exists())
            self.assertTrue((run_dir / "mounted-volume").exists())
            self.assertEqual(list((run_dir / "mounted-volume").iterdir()), [])

    def test_release_entry_runs_structured_pipeline_hook_and_publishes_only_after_gates(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            trusted_checkout, source_sha, trusted_lock = self.make_metadata_source_checkout(base)
            runner_temp = base / "runner-temp"
            runner_temp.mkdir()
            fake_candidate = load("candidate_success_fixture", ROOT / "scripts/run_macos_shared_ci_candidate.py")
            source = {"source_ref": source_sha, "release_tag": "v1.2.3",
                      "peeled_tag_commit": source_sha}
            command_runner = []

            def prepare_pipeline(report, source_sha, revision, *, production_release):
                self.assertTrue(production_release)
                self.assertEqual(source_sha, source["source_ref"])
                self.assertEqual(revision, "c" * 40)
                pipeline, fixture = self.make_pipeline(base, Path(report["run_dir"]))
                command_runner.append(self.fake_commands(Path(pipeline["final_app"]).parent))
                report["commands"].extend(fixture["commands"])
                return pipeline

            fake_run = None
            with mock.patch.object(fake_candidate, "load_approved_revision", return_value="c" * 40), \
                 mock.patch.object(fake_candidate, "LOCK", trusted_lock), \
                 mock.patch.object(fake_candidate, "require_host"), \
                 mock.patch.object(fake_candidate, "run_pipeline", side_effect=prepare_pipeline), \
                 mock.patch.object(release, "ROOT", trusted_checkout), \
                 mock.patch.object(release, "validate_release_source", return_value=source), \
                 mock.patch.object(release, "require_hosted_preflight"), \
                 mock.patch.object(release, "require_host"), \
                 mock.patch.object(release, "run", side_effect=lambda *args, **kwargs:
                                   command_runner[0](*args, **kwargs)) as fake_run:
                result = release.run_release(release_tag="v1.2.3", source_sha=source_sha,
                    runner_temp=runner_temp, run_id="53", attempt="1", candidate_module=fake_candidate)
            self.assertEqual(result["status"], "ready")
            self.assertEqual(len(result["artifact_files"]), 4)
            output = Path(result["artifact_files"][0]).parent
            self.assertEqual(len(list(output.iterdir())), 4)
            self.assertTrue(fake_run.called)

    def test_mount_tree_drift_fails_and_never_creates_release_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            base = Path(temporary).resolve()
            trusted_checkout, source_sha, trusted_lock = self.make_metadata_source_checkout(base)
            with mock.patch.object(release, "ROOT", trusted_checkout):
                pipeline, report = self.make_pipeline(base)
            run_dir = Path(pipeline["artifact_directory"]).parent
            output = run_dir / "distribution"
            source = {"source_ref": source_sha, "release_tag": "v1.2.3",
                      "peeled_tag_commit": source_sha}
            fake = self.fake_commands(Path(pipeline["final_app"]).parent, drift=True)
            with mock.patch.object(release, "ROOT", trusted_checkout), \
                 mock.patch.object(release, "run", side_effect=fake):
                with self.assertRaisesRegex(release.ReleaseError, "mounted DMG App differs"):
                    release.package_release(pipeline, source, report, report,
                                            "v1.2.3", run_dir, output, sha(trusted_lock))
            self.assertFalse(output.exists())
            self.assertTrue((run_dir / "mounted-volume").exists())
            self.assertEqual(list((run_dir / "mounted-volume").iterdir()), [])

    def test_missing_approved_revision_blocks_before_host_or_pipeline(self):
        with tempfile.TemporaryDirectory() as temporary:
            temp = Path(temporary).resolve()
            (temp / "runner-temp").mkdir()
            fake_candidate = load("candidate_null_pin_fixture", ROOT / "scripts/run_macos_shared_ci_candidate.py")
            with mock.patch.object(fake_candidate, "load_approved_revision",
                                   side_effect=candidate.CandidateError("reviewed media-kit revision unavailable")), \
                 mock.patch.object(fake_candidate, "require_host") as host, \
                 mock.patch.object(fake_candidate, "run_pipeline") as pipeline:
                with self.assertRaisesRegex(candidate.CandidateError, "unavailable"):
                    release.run_release(release_tag="v1.2.3", source_sha="d" * 40,
                        runner_temp=temp / "runner-temp", run_id="12", attempt="1",
                        candidate_module=fake_candidate)
                host.assert_not_called()
                pipeline.assert_not_called()
            diagnostics = temp / "runner-temp/piliplusx-shared-candidate-diagnostics/result.json"
            self.assertTrue(diagnostics.is_file())
            self.assertFalse((temp / "runner-temp/piliplusx-shared-candidate/12-1/flutter-sdk").exists())

    def test_private_release_workflow_has_early_gate_and_success_only_upload(self):
        workflow = (ROOT / ".github/workflows/mac.yml").read_text()
        self.assertLess(workflow.index("Validate source and approved shared inputs"),
                        workflow.index("Setup Flutter"))
        self.assertIn("if: success()", workflow)
        self.assertIn("if: failure()", workflow)
        self.assertIn("release-macos-arm64", workflow)
        self.assertIn("shared-distribution.json", (ROOT / "scripts/release_manifest.py").read_text())
        self.assertIn('--source-checkout "$GITHUB_WORKSPACE"', workflow)

    def test_patch_script_uses_private_pub_cache_and_exact_config_roots(self):
        patcher = (ROOT / "lib/scripts/patch.ps1").read_text()
        self.assertIn("$env:PUB_CACHE", patcher)
        self.assertIn("Get-PackageConfigRoot", patcher)
        self.assertIn("package_config.json", patcher)
        self.assertNotIn("git config --global", patcher)
        self.assertNotIn('Get-ChildItem "$PubCacheDir/hosted/pub.dev"', patcher)


if __name__ == "__main__":
    unittest.main()
